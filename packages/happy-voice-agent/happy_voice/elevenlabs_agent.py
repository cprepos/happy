"""A second worker that speaks the ElevenLabs Swift SDK 3.4.0 protocol over the same voice pipeline.

The app's ElevenLabs call (ElevenLabsCallConnection.swift) joins a LiveKit room with the SDK,
waits for a participant whose identity starts with "agent" (a dispatched worker is
"agent-<job id>"), then talks to it in JSON data packets (see elevenlabs_protocol.py). This
worker answers that protocol with the STT, TTS, LLM, VAD, turn detection, warm-up and
compaction of the `happy-voice` worker, imported unchanged from assistant.py:

- conversation_initiation_client_data: the app's prompt override, with its dynamic variables
  ({{initialConversationContext}}) filled in, becomes the instructions; the worker answers with
  conversation_initiation_metadata.
- The app's four client tools (listConversations, readConversation, message, navigate) run as
  client_tool_call -> client_tool_result round trips. skip_turn runs here. end_call says
  goodbye and sends agent_tool_response{tool_name: "end_call"}, on which the SDK hangs up.
- contextual_update is applied like the app's context updates (quiet window, repeat and
  already-in-prompt checks, prefix warm-up); user_message is a text turn; user_activity
  interrupts the agent, as the SDK's interruptAgent() means it to.
- The worker reports user_transcript, agent_response (the words the person heard, so a reply
  cut off by barge-in is reported as far as it played), interruption on barge-in, vad_score
  and a periodic ping.

    python agent_el.py start        # worker for explicit dispatch "happy-voice-el"
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable

from livekit import rtc
from livekit.agents import (
    Agent,
    AgentSession,
    JobContext,
    MetricsCollectedEvent,
    RunContext,
    ToolError,
    function_tool,
    llm,
    metrics,
    room_io,
)
from livekit.agents import tts as tts_mod
from livekit.agents.voice.agent_session import SessionConnectOptions
from livekit.plugins import openai, silero

from . import elevenlabs_protocol as el
from .assistant import (
    CONTEXT_DEFER_MAX,
    SWAP_SETTLE_MARGIN,
    HappyAssistant,
    _EotPredictionLog,
    _make_llm,
    _make_summarizer_llm,
    llm_conn_options,
    no_reply_pending,
    turn_handling,
    warmup_snapshot,
)
from .compaction import Compactor
from .config import Settings
from .context import RecentUpdates, already_in_context
from .nemotron_stt import NemotronSTT
from .names import persona_for
from .prompt import (
    BASE_PROMPT,
    CONTEXT_PREFIX,
    addressing_section,
    build_instructions,
    language_section,
    name_section,
)
from .tts_trim import trim_leading_artifact
from .voices import fetch_known_voices, resolve_tts
from .warmup import PrefixWarmer

logger = logging.getLogger("happy-voice-el")

DEFAULT_AGENT_NAME = "happy-voice-el"
# The SDK sends conversation_initiation_client_data as soon as it sees the agent join; without
# one (an older client) the call starts on the default prompt after this long (s).
INIT_TIMEOUT = float(os.environ.get("EL_INIT_TIMEOUT", "5"))
# The app gives a tool call 8 s (CallToolDeadline); a little longer here, so the app's own
# "timed out" answer is the one the model hears.
TOOL_TIMEOUT = float(os.environ.get("EL_TOOL_TIMEOUT", "10"))
PING_INTERVAL = float(os.environ.get("EL_PING_INTERVAL", "5"))
# After end_call is announced, how long the SDK has to hang up before the worker does (s).
END_CALL_GRACE = 3.0
# how long end_call waits for the goodbye it asked for before hanging up anyway (s)
GOODBYE_TIMEOUT = 10.0


def agent_name() -> str:
    return os.environ.get("VOICE_AGENT_NAME", "").strip() or DEFAULT_AGENT_NAME


# --- tools ---------------------------------------------------------------------------------
# The client tools' names, descriptions and parameters, copied verbatim from the app's
# CallTools.swift (CallTool.summary / CallTool.parameters).


def _string(description: str) -> dict[str, Any]:
    return {"type": "string", "description": description}


def _object(properties: dict[str, Any], required: list[str]) -> dict[str, Any]:
    return {"type": "object", "properties": properties, "required": required}


LIST_CONVERSATIONS_SCHEMA = {
    "name": "listConversations",
    "description": (
        "List the conversations the person sees in the app (bots, tasks, subtasks and project conversations), "
        "in the sidebar's order, with their ref, title, kind, status, parents and when each last did something. "
        "Use it to find conversations started or renamed since the call began. query keeps those whose title "
        "contains it as a case-insensitive substring. Page with nextCursor."
    ),
    "parameters": _object(
        {
            "query": _string("A case-insensitive substring of the title; omit for all."),
            "cursor": _string("The nextCursor of the previous page; omit for the first."),
        },
        [],
    ),
}

READ_CONVERSATION_SCHEMA = {
    "name": "readConversation",
    "description": (
        "Read one conversation before you summarise it: whether it is working or needs the person, when the "
        "person last wrote and the agent last replied, its workspace, its model and effort and the ones it can "
        "switch to, and its turns, by default its last five. It reads backwards: each turn has a ref (t:3f) to "
        "read further back from, and continueFrom says where the next read back starts. A message longer than "
        "words is cut in the middle, and cut says how long it is. On a team, who wrote each message. It doesn't "
        "open the conversation or change the screen."
    ),
    "parameters": _object(
        {
            "ref": _string("A conversation ref (s1, s2, ...) from the context or listConversations. Never a title."),
            "from": _string(
                "Where to start reading, going back: a turn's ref (t:3f) from an earlier read, or a number of "
                "turns back from the newest (0, the default, is the newest)."
            ),
            "backTo": _string(
                "Where to stop, older than from: a turn's ref or a number of turns back, as from. Omit for five "
                "turns in all. At most 50 turns a read."
            ),
            "words": {
                "type": "integer",
                "description": (
                    "The most words of each message; past that it is cut in the middle. Default 500, at most "
                    "5000: raise it to read a cut message whole."
                ),
            },
        },
        ["ref"],
    ),
}

MESSAGE_SCHEMA = {
    "name": "message",
    "description": (
        "Send the person's words to a conversation's agent, or start new work with them as its first message. "
        "Call it only when the person has explicitly asked you to send (\"send it\", \"send that to ...\", "
        "\"tell the backend bot to ...\"), never because you think they would want it sent. A working agent "
        "takes it too. It doesn't change the screen. \"queued\" means queued on the person's device, not "
        "confirmed delivered; after \"uncertain\", never send it again."
    ),
    "parameters": _object(
        {
            "to": _string(
                "Where to send: a conversation ref (s1, s2, ...) from the context or listConversations; new-task "
                "or new-bot to start new work, optionally named after a colon (new-bot:Release helper); omit for "
                "the conversation on screen."
            ),
            "text": _string("The person's message, exactly as they asked to send it. At most 8 KiB of UTF-8."),
            "model": _string(
                "Only when the person asked for a model: a name or id from the models in the context or "
                "readConversation. It stays for the conversation's next messages."
            ),
            "effort": _string(
                "Only when the person asked for an effort: one of that model's efforts, as the context or "
                "readConversation lists them."
            ),
        },
        ["text"],
    ),
}

NAVIGATE_SCHEMA = {
    "name": "navigate",
    "description": (
        "Change what is on the person's screen, as tapping would. Only when the person asks. to is one of the "
        "destinations listed in the context: happy://home (the home list), happy://back (one screen back, "
        "refused at home), or happy://conversation/<ref> (show that conversation)."
    ),
    "parameters": _object(
        {
            "to": _string(
                "A destination URL from the context's destinations, e.g. happy://home, happy://back or "
                "happy://conversation/s3."
            ),
            "focusRevision": {
                "type": "integer",
                "description": (
                    "The latest focusRevision you have seen, from the context, the newest focus event or the last "
                    "tool result. Copy it exactly; never guess or increment it."
                ),
            },
        },
        ["to", "focusRevision"],
    ),
}

# The hosted agent's system tools, as the app's prompt refers to them. The name must stay
# "skip_turn": context.py leaves its calls out of the model's history by that name.
EL_SKIP_TURN_SCHEMA = {
    "name": "skip_turn",
    "description": (
        "Stay silent this turn. Use it when nothing needs saying: an update or news that needs no answer, or "
        "the person is plainly talking to someone else. A question or a request from the person always gets "
        "an answer."
    ),
    "parameters": {"type": "object", "properties": {}, "required": []},
}

END_CALL_SCHEMA = {
    "name": el.END_CALL_TOOL,
    "description": (
        "Hang up the call. Only when the person says goodbye or asks to end the call; never because of "
        "silence or a call-ending notice. Say a short goodbye in the same reply, before calling it."
    ),
    "parameters": {"type": "object", "properties": {}, "required": []},
}


# --- prompt --------------------------------------------------------------------------------

_VOICE_OUTPUT = BASE_PROMPT.split("# How you receive information", 1)[0].strip()

_UPDATES_NOTE = (
    "# How updates reach you\n"
    f'Messages starting with "{CONTEXT_PREFIX.strip()}" are the app\'s updates, not the person\'s words. '
    "They need no answer: use them when they matter to what you are saying. "
    'Messages starting with "[app]" are the app\'s requests for a turn; answer them as the app prompt says.'
)


INITIAL_CONTEXT_VARIABLE = "initialConversationContext"


def build_el_instructions(init: el.InitiationData | None, name: str | None = None) -> str:
    """The instructions for one call, laid out as prompt.build_instructions lays out the app's:
    how to speak, the language, the app's prompt (here with its dynamic variables filled in),
    then the answer-by-default rule and the voice persona's name. The default base prompt when
    the app sent none."""
    language = init.language if init else ""
    prompt = (init.prompt if init else "").strip()
    if not prompt:
        return build_instructions(app_system_prompt="", session_id=None, language=language, name=name)
    sections = [_VOICE_OUTPUT]
    if extra := language_section(language):
        sections.append(extra)
    filled, missing = el.substitute_variables(prompt, init.dynamic_variables if init else {})
    if missing:
        logger.warning("prompt variables without a value: %s", ", ".join(sorted(set(missing))))
    sections.append(filled.strip())
    sections.append(_UPDATES_NOTE)
    sections.append(addressing_section())
    sections.append(name_section(name))
    return "\n\n".join(s for s in sections if s)


def initial_history(init: el.InitiationData | None, instructions: str) -> llm.ChatContext:
    """The history a call starts with. As `happy-voice` does with the app's initialContext: the
    initial context goes in as a system message unless the prompt already embeds it (the
    app's prompt does, through {{initialConversationContext}})."""
    chat_ctx = llm.ChatContext()
    value = (init.dynamic_variables.get(INITIAL_CONTEXT_VARIABLE) if init else None) or ""
    initial = value.strip() if isinstance(value, str) else ""
    if initial and initial not in instructions:
        chat_ctx.add_message(role="system", content=f"Conversation history so far:\n{initial}")
    return chat_ctx


# --- the call's protocol state ---------------------------------------------------------------


@dataclass
class CallState:
    room: rtc.Room
    user_identity: str = ""
    # event ids, as the hosted agent numbers them: one per user turn, shared by the agent's reply
    event_id: int = 0
    ping_id: int = 0
    pings_sent: dict[int, float] = field(default_factory=dict)
    last_ping_ms: int | None = None
    pending_tools: dict[str, asyncio.Future[el.ClientEvent]] = field(default_factory=dict)
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    sent: list[dict[str, Any]] = field(default_factory=list)
    ending: bool = False
    # end_call came without a goodbye: hang up once the reply asked for has played
    goodbye_pending: bool = False
    hung_up: bool = False

    async def hang_up(self, session: Any) -> None:
        """Tells the SDK the call is over (it ends the call on this), and closes the session
        ourselves if the app is still there after END_CALL_GRACE."""
        if self.hung_up:
            return
        self.hung_up = True
        self.goodbye_pending = False
        await self.send(el.agent_tool_response(el.END_CALL_TOOL, f"toolu_{uuid.uuid4().hex[:24]}", self.event_id))

        async def close_if_still_here() -> None:
            await asyncio.sleep(END_CALL_GRACE)
            logger.info("end_call: the app did not hang up; closing the session")
            await session.aclose()

        asyncio.create_task(close_if_still_here())

    async def send(self, event: dict[str, Any]) -> None:
        try:
            payload = el.encode(event)
        except ValueError:
            logger.exception("refusing to send an event the SDK would not parse: %s", event.get("type"))
            return
        try:
            kwargs: dict[str, Any] = {"reliable": True}
            if self.user_identity:
                kwargs["destination_identities"] = [self.user_identity]
            await self.room.local_participant.publish_data(payload, **kwargs)
        except Exception:
            logger.exception("failed to send %s", event.get("type"))
            return
        if event.get("type") not in ("ping", "vad_score"):
            logger.info("-> %s (%d bytes)", event.get("type"), len(payload))

    def post(self, event: dict[str, Any]) -> None:
        asyncio.create_task(self.send(event))


class ElevenLabsAssistant(Agent):
    """The voice pipeline of HappyAssistant with the hosted agent's tools."""

    # The same request shaping, stage-direction filter and warm-up bookkeeping as `happy-voice`:
    # both read only self.warmer, self.compactor and self._settings.
    llm_node = HappyAssistant.llm_node
    _request_ctx = HappyAssistant._request_ctx
    # Scripted tool replies ("[DO NOT say anything else, simply say '...']") and readAloud, as
    # `happy-voice` has them; they read self._settings and self.note_context only.
    _reply_with = HappyAssistant._reply_with
    readAloud = HappyAssistant.readAloud
    _read_aloud_done = HappyAssistant._read_aloud_done

    def __init__(
        self,
        *,
        instructions: str,
        call: CallState,
        settings: Settings,
        chat_ctx: llm.ChatContext | None = None,
    ) -> None:
        super().__init__(instructions=instructions, chat_ctx=chat_ctx)
        self._call = call
        self._settings = settings
        self.warmer: PrefixWarmer | None = None
        self.compactor: Compactor | None = None
        # posts a context note the way contextual_update arrives (see HappyAssistant.note_context)
        self.note_context: Callable[[str], None] = lambda text: None

    async def _client_tool(self, name: str, raw_arguments: dict[str, Any]) -> str:
        call = self._call
        if not call.user_identity:
            raise ToolError("error (the app is not connected)")
        tool_call_id = f"toolu_{uuid.uuid4().hex[:24]}"
        future: asyncio.Future[el.ClientEvent] = asyncio.get_running_loop().create_future()
        call.pending_tools[tool_call_id] = future
        record: dict[str, Any] = {"name": name, "parameters": raw_arguments, "t": time.time()}
        call.tool_calls.append(record)
        t0 = time.monotonic()
        logger.info("tool %s %s", name, raw_arguments)
        try:
            await call.send(el.client_tool_call(name, tool_call_id, raw_arguments, call.event_id))
            result = await asyncio.wait_for(future, timeout=TOOL_TIMEOUT)
        except asyncio.TimeoutError as e:
            logger.warning("tool %s: no result in %.0fs", name, TOOL_TIMEOUT)
            raise ToolError("error (the app did not answer in time)") from e
        finally:
            call.pending_tools.pop(tool_call_id, None)
        record["result"] = result.result
        record["is_error"] = result.is_error
        logger.info(
            "tool %s <- %s%r in %.0fms",
            name,
            "error " if result.is_error else "",
            result.result[:200],
            (time.monotonic() - t0) * 1000,
        )
        if result.is_error:
            raise ToolError(result.result or "error")
        return result.result

    @function_tool(raw_schema=LIST_CONVERSATIONS_SCHEMA)
    async def listConversations(self, raw_arguments: dict[str, Any], context: RunContext) -> str | llm.ToolResult:
        return self._reply_with(await self._client_tool("listConversations", raw_arguments), context)

    @function_tool(raw_schema=READ_CONVERSATION_SCHEMA)
    async def readConversation(self, raw_arguments: dict[str, Any], context: RunContext) -> str | llm.ToolResult:
        return self._reply_with(await self._client_tool("readConversation", raw_arguments), context)

    @function_tool(raw_schema=MESSAGE_SCHEMA)
    async def message(self, raw_arguments: dict[str, Any], context: RunContext) -> str | llm.ToolResult:
        return self._reply_with(await self._client_tool("message", raw_arguments), context)

    @function_tool(raw_schema=NAVIGATE_SCHEMA)
    async def navigate(self, raw_arguments: dict[str, Any], context: RunContext) -> str | llm.ToolResult:
        return self._reply_with(await self._client_tool("navigate", raw_arguments), context)

    @function_tool(raw_schema=EL_SKIP_TURN_SCHEMA)
    async def skip_turn(self, raw_arguments: dict[str, Any], context: RunContext) -> None:
        logger.info("skip_turn: said nothing in reply to the turn above")
        return None

    @function_tool(raw_schema=END_CALL_SCHEMA)
    async def end_call(self, raw_arguments: dict[str, Any], context: RunContext) -> str | None:
        call = self._call
        if call.ending:
            return None
        call.ending = True
        try:
            # the goodbye the model said before calling this
            await context.wait_for_playout()
        except Exception:
            logger.exception("end_call: waiting for the goodbye failed")
        if said_since_last_user_turn(self.chat_ctx.items):
            logger.info("end_call: hanging up after the goodbye")
            await call.hang_up(context.session)
            return None
        # Called without a word: hanging up on the person mid-sentence is worse than one more
        # short reply, so ask for the goodbye and hang up when it has played (_on_speech_done).
        logger.info("end_call: no goodbye said; asking for one before hanging up")
        call.goodbye_pending = True
        session = context.session

        async def hang_up_anyway() -> None:
            await asyncio.sleep(GOODBYE_TIMEOUT)
            if call.goodbye_pending:
                logger.info("end_call: no goodbye in %.0fs; hanging up", GOODBYE_TIMEOUT)
                await call.hang_up(session)

        asyncio.create_task(hang_up_anyway())
        return "Hanging up after your reply. Say a short goodbye now, nothing else."


def said_since_last_user_turn(items: list[Any]) -> bool:
    """Whether the agent said anything after the person's last turn."""
    for item in reversed(items):
        if isinstance(item, llm.ChatMessage):
            if item.role == "user":
                return False
            if item.role == "assistant" and (item.text_content or "").strip():
                return True
    return False


# --- entrypoint ----------------------------------------------------------------------------


async def entrypoint(ctx: JobContext) -> None:
    settings = Settings()
    ctx.log_context_fields = {"room": ctx.room.name}
    call = CallState(room=ctx.room)
    init_future: asyncio.Future[el.InitiationData] = asyncio.get_running_loop().create_future()
    # contextual updates and text turns, applied in arrival order once the session runs
    inbox: asyncio.Queue[tuple[str, str]] = asyncio.Queue()
    session_ref: dict[str, AgentSession] = {}

    def on_event(event: el.ClientEvent) -> None:
        kind = event.type
        if kind == "conversation_initiation_client_data":
            if init_future.done():
                logger.warning("ignoring a second conversation_initiation_client_data")
                return
            assert event.initiation is not None
            init_future.set_result(event.initiation)
        elif kind == "pong":
            sent_at = call.pings_sent.pop(event.event_id or -1, None)
            if sent_at is not None:
                call.last_ping_ms = int((time.monotonic() - sent_at) * 1000)
        elif kind == "client_tool_result":
            future = call.pending_tools.get(event.tool_call_id)
            if future is None:
                logger.warning("client_tool_result for unknown call %s", event.tool_call_id)
            elif not future.done():
                future.set_result(event)
        elif kind == "contextual_update":
            inbox.put_nowait(("context", event.text))
        elif kind == "user_message":
            inbox.put_nowait(("text", event.text))
        elif kind == "user_activity":
            session = session_ref.get("session")
            if session is not None:
                logger.info("user_activity: interrupting the agent")
                session.interrupt()
        elif kind == "feedback":
            logger.info("feedback %s on event %s", event.score, event.event_id)
        else:
            logger.info("ignoring client event %s", kind)

    def on_data(packet: rtc.DataPacket) -> None:
        if packet.topic:
            return
        if call.user_identity and packet.participant and packet.participant.identity != call.user_identity:
            return
        try:
            event = el.parse_client_event(packet.data)
        except el.ProtocolError as e:
            logger.warning("ignoring a data packet that is not a client event: %s", e)
            return
        if event.type not in ("pong",):
            logger.info("<- %s (%d bytes)", event.type, len(packet.data))
        on_event(event)

    ctx.room.on("data_received", on_data)

    await ctx.connect()
    # livekit-server sends joins of non-publishing participants on a 3 s ticker, past the SDK's
    # 3 s agentReadyTimeout; an attribute change goes out at once, so the app sees us now.
    await ctx.room.local_participant.set_attributes({"lk.agent.state": "initializing"})

    participant = await ctx.wait_for_participant(
        kind=[
            rtc.ParticipantKind.PARTICIPANT_KIND_STANDARD,
            rtc.ParticipantKind.PARTICIPANT_KIND_SIP,
            rtc.ParticipantKind.PARTICIPANT_KIND_INGRESS,
        ]
    )
    call.user_identity = participant.identity
    logger.info("user participant %s joined", participant.identity)

    t_init = time.monotonic()
    try:
        init: el.InitiationData | None = await asyncio.wait_for(asyncio.shield(init_future), timeout=INIT_TIMEOUT)
    except asyncio.TimeoutError:
        init = None
        logger.warning("no conversation_initiation_client_data in %.0fs; using the default prompt", INIT_TIMEOUT)
    conversation_id = f"conv_{uuid.uuid4().hex}"
    await call.send(el.conversation_initiation_metadata(conversation_id))

    known_voices = None
    voice = (init.voice_id.strip() or None) if init else None
    if voice is not None:
        known_voices = await fetch_known_voices(settings.tts_url)
    language = (init.language if init else "") or "en"
    tts_voice, tts_speed = resolve_tts(settings, language, voice, init.speed if init else None, known_voices)
    # a name only for a voice the app asked for, as in `happy-voice`
    voice_persona = persona_for(voice, tts_voice, known_voices)
    instructions = build_el_instructions(init, voice_persona)
    chat_ctx = initial_history(init, instructions)
    logger.info(
        "llm %s @ %s; timeout=%.0fs retries=%d; barge-in after %.1fs and %d word(s); eou max %.1fs",
        settings.llm_model,
        settings.llm_base_url,
        settings.llm_timeout,
        settings.llm_max_retry,
        settings.interrupt_min_duration,
        settings.interrupt_min_words,
        settings.max_endpointing_delay,
    )
    logger.info(
        "init after %.0fms: conversation=%s source=%s/%s language=%s voice=%s name=%s speed=%.2f "
        "prompt=%d chars variables=%s first=%r",
        (time.monotonic() - t_init) * 1000,
        conversation_id,
        init.source if init else "",
        init.version if init else "",
        language,
        tts_voice,
        voice_persona,
        tts_speed,
        len(instructions),
        sorted(init.dynamic_variables) if init else [],
        init.first_message if init else "",
    )

    session: AgentSession = AgentSession(
        vad=ctx.proc.userdata.get("vad") or silero.VAD.load(min_silence_duration=settings.vad_min_silence),
        stt=NemotronSTT(url=settings.stt_url, language="en"),
        llm=_make_llm(settings),
        tts=tts_mod.StreamAdapter(
            tts=trim_leading_artifact(
                openai.TTS(
                    base_url=settings.tts_url,
                    api_key="not-needed",
                    model="kokoro",
                    voice=tts_voice,
                    speed=tts_speed,
                    response_format="pcm",
                ),
                enabled=settings.tts_trim_lead,
            ),
            text_pacing=tts_mod.SentenceStreamPacer(
                min_remaining_audio=3.0,
                max_text_length=500,
            ),
        ),
        turn_handling=turn_handling(settings),
        conn_options=SessionConnectOptions(llm_conn_options=llm_conn_options(settings)),
        user_away_timeout=None,
    )
    session_ref["session"] = session

    _EotPredictionLog.install()
    usage = metrics.UsageCollector()

    @session.on("metrics_collected")
    def _on_metrics(ev: MetricsCollectedEvent) -> None:
        usage.collect(ev.metrics)
        m = ev.metrics
        if isinstance(m, metrics.EOUMetrics):
            logger.info(
                "turn: eou_delay=%.0fms transcription_delay=%.0fms",
                m.end_of_utterance_delay * 1000,
                m.transcription_delay * 1000,
            )
        elif isinstance(m, metrics.LLMMetrics):
            logger.info(
                "llm: ttft=%.0fms total=%.0fms prompt=%d cached=%d",
                m.ttft * 1000,
                m.duration * 1000,
                m.prompt_tokens,
                m.prompt_cached_tokens,
            )
            if agent.compactor is not None and not m.cancelled:
                agent.compactor.on_llm_usage(m.prompt_tokens, m.prompt_cached_tokens)
        elif isinstance(m, metrics.TTSMetrics):
            logger.info("tts: ttfb=%.0fms", m.ttfb * 1000)

    @session.on("user_input_transcribed")
    def _on_transcript(ev) -> None:
        if ev.is_final and ev.transcript.strip():
            call.event_id += 1
            logger.info("user said: %r", ev.transcript)
            call.post(el.user_transcript(ev.transcript, call.event_id))

    @session.on("conversation_item_added")
    def _on_item(ev) -> None:
        item = ev.item
        if not isinstance(item, llm.ChatMessage) or item.role != "assistant":
            return
        text = (item.text_content or "").strip()
        logger.info("agent said: %r%s", text, " (interrupted)" if item.interrupted else "")
        if text:
            call.post(el.agent_response(text, call.event_id, f"resp_{uuid.uuid4().hex[:16]}"))

    @session.on("user_state_changed")
    def _on_user_state(ev) -> None:
        call.post(el.vad_score(1.0 if ev.new_state == "speaking" else 0.0))

    def _on_speech_done(handle: Any, event_id: int) -> None:
        if handle.interrupted:
            logger.info("barge-in: agent interrupted (event %d)", event_id)
            call.post(el.interruption(event_id))
        elif call.goodbye_pending and said_since_last_user_turn(session.history.items):
            logger.info("end_call: hanging up after the goodbye")
            asyncio.create_task(call.hang_up(session))

    @session.on("speech_created")
    def _on_speech(ev) -> None:
        event_id = call.event_id
        ev.speech_handle.add_done_callback(lambda h, e=event_id: _on_speech_done(h, e))

    closed = asyncio.Event()

    @session.on("close")
    def _on_close(ev) -> None:
        logger.info("session closed (%s); usage %s", getattr(ev, "reason", ""), usage.get_summary())
        closed.set()
        ctx.shutdown("session closed")

    @ctx.room.on("participant_disconnected")
    def _on_left(p: rtc.RemoteParticipant) -> None:
        if p.identity == call.user_identity:
            logger.info("user participant left; closing")
            asyncio.create_task(session.aclose())

    agent = ElevenLabsAssistant(instructions=instructions, call=call, settings=settings, chat_ctx=chat_ctx)
    agent.note_context = lambda text: inbox.put_nowait(("context", text))

    await session.start(
        agent=agent,
        room=ctx.room,
        room_options=room_io.RoomOptions(
            participant_identity=participant.identity,
            close_on_disconnect=True,
        ),
        record=False,
    )

    warmer = PrefixWarmer(
        _make_llm(settings),
        lambda: warmup_snapshot(session.current_agent),
        timeout=settings.llm_timeout,
        turn_wait=settings.warmup_turn_wait,
        conn_options=llm_conn_options(settings),
    )
    agent.warmer = warmer
    warmer.schedule()

    # Spoken only, never seeded into the history: a scripted greeting there is copied by the
    # model when a later turn is only a greeting.
    if init and init.first_message.strip():
        session.say(init.first_message.strip(), allow_interruptions=True, add_to_chat_ctx=False)
        call.post(el.agent_response(init.first_message.strip(), call.event_id, f"resp_{uuid.uuid4().hex[:16]}"))

    lock = asyncio.Lock()
    recent_updates = RecentUpdates()

    # The same quiet window as `happy-voice` (see assistant.entrypoint): a context update waits
    # out the user speaking and the agent thinking, so it does not invalidate a preemptive reply.
    quiet = asyncio.Event()
    quiet.set()
    quiet_since = time.monotonic()

    def _recheck_quiet(_: Any = None) -> None:
        nonlocal quiet_since
        busy = session.user_state == "speaking" or session.agent_state == "thinking"
        if busy:
            quiet.clear()
        elif not quiet.is_set():
            quiet_since = time.monotonic()
            quiet.set()

    session.on("user_state_changed", _recheck_quiet)
    session.on("agent_state_changed", _recheck_quiet)

    agent.compactor = Compactor(
        agent=lambda: session.current_agent,
        summarizer=_make_summarizer_llm(settings),
        warm=warmer.warm,
        lock=lock,
        quiet=quiet,
        trigger=settings.compact_trigger,
        keep=settings.compact_keep,
        summary_tokens=settings.compact_summary_tokens,
        enabled=settings.compaction,
        turn_idle=warmer.wait_idle,
        quiet_for=lambda: time.monotonic() - quiet_since,
        settle=settings.max_endpointing_delay + SWAP_SETTLE_MARGIN,
        no_reply_pending=lambda: no_reply_pending(session, warmer),
        on_swapped=warmer.schedule,
        timeout=max(settings.llm_timeout, 120.0),
        conn_options=llm_conn_options(settings),
    )
    logger.info(
        "compaction %s: trigger=%d keep=%d summary<=%d; backstop at %d tokens",
        "on" if settings.compaction else "off",
        settings.compact_trigger,
        settings.compact_keep,
        settings.compact_summary_tokens,
        settings.context_hard_cap,
    )

    async def handle_inbox() -> None:
        while True:
            kind, text = await inbox.get()
            text = text.strip()
            if not text:
                continue
            if kind == "context":
                if recent_updates.is_repeat(text, time.monotonic()):
                    logger.info("context update (%d chars) repeats one just applied; skipped", len(text))
                    continue
                if not quiet.is_set():
                    try:
                        await asyncio.wait_for(quiet.wait(), timeout=CONTEXT_DEFER_MAX)
                    except asyncio.TimeoutError:
                        logger.info("context update (%d chars) applied mid-turn after waiting", len(text))
                async with lock:
                    current = session.current_agent
                    if already_in_context(text, current.chat_ctx, current.instructions):
                        logger.info("context update (%d chars) is already in the prompt; skipped", len(text))
                        continue
                    new_ctx = current.chat_ctx.copy()
                    new_ctx.add_message(role="system", content=text)
                    await current.update_chat_ctx(new_ctx)
                logger.info("context update (%d chars)", len(text))
                warmer.schedule()
            else:
                call.event_id += 1
                logger.info("text turn: %r", text[:200])
                session.generate_reply(user_input=text)

    async def ping_loop() -> None:
        while not closed.is_set():
            await asyncio.sleep(PING_INTERVAL)
            call.ping_id += 1
            call.pings_sent[call.ping_id] = time.monotonic()
            # drop pings never answered, so the map stays small
            for stale in [k for k in call.pings_sent if k < call.ping_id - 8]:
                call.pings_sent.pop(stale, None)
            await call.send(el.ping(call.ping_id, call.last_ping_ms))

    tasks = [asyncio.create_task(handle_inbox()), asyncio.create_task(ping_loop())]

    async def _cleanup(reason: str = "") -> None:
        for task in tasks:
            task.cancel()
        for future in call.pending_tools.values():
            if not future.done():
                future.cancel()
        if agent.compactor is not None:
            await agent.compactor.aclose()
        await warmer.aclose()

    ctx.add_shutdown_callback(_cleanup)
