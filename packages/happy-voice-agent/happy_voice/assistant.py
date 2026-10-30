"""The voice assistant: room protocol (contract section 2), tools and the voice pipeline."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from dataclasses import dataclass, field
from typing import Any

from livekit import rtc
from livekit.agents import (
    Agent,
    APIConnectOptions,
    AgentSession,
    JobContext,
    JobProcess,
    MetricsCollectedEvent,
    RunContext,
    ToolError,
    function_tool,
    llm,
    metrics,
    room_io,
)
from livekit.agents.voice.agent_session import SessionConnectOptions
from livekit.agents import tts as tts_mod
from livekit.plugins import openai, silero

from .config import Settings
from .context import (
    RecentUpdates,
    already_in_context,
    focused_session_from,
    fold_system_messages,
)
from .names import persona_for
from .nemotron_stt import NemotronSTT
from .prompt import (
    PERMISSION_SCHEMA,
    SEND_MESSAGE_SCHEMA,
    SKIP_TURN_SCHEMA,
    build_instructions,
)
from .tts_trim import trim_leading_artifact
from .voices import fetch_known_voices, resolve_tts
from .warmup import PrefixWarmer

logger = logging.getLogger("happy-voice")

TOPIC_CONTEXT = "happy.context"
TOPIC_TEXT = "happy.text"
# Empty packet sent when the user barges in, so the app (or the server
# bridging its audio) drops agent speech it has buffered but not played.
TOPIC_INTERRUPTED = "happy.interrupted"
RPC_GET_CONFIG = "happy.getConfig"
WARMUP_PLACEHOLDER = "(warm-up)"
# Longest a context update waits for the exchange to go quiet before being applied anyway (s).
CONTEXT_DEFER_MAX = 10.0

# The app's tool results dictate the exact words to speak, e.g.
# "sent [DO NOT say anything else, simply say 'sent']". Speaking them directly saves a second LLM
# round trip (the most expensive part of a tool turn); the result still goes into the history.
_SCRIPTED_REPLY_RE = re.compile(r"\[\s*DO NOT say anything else,\s*simply say\s*'([^']{1,80})'\s*\]\s*$")


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


@dataclass
class VoiceConfig:
    system_prompt: str = ""
    first_message: str = ""
    initial_context: str = ""
    language: str = "en"
    session_id: str = ""
    # per-chat TTS choice from the app; validated in voices.resolve_tts
    voice: str | None = None
    speed: float | None = None

    @classmethod
    def from_json(cls, raw: str) -> VoiceConfig:
        data = json.loads(raw) if raw else {}
        if not isinstance(data, dict):
            data = {}

        def s(key: str) -> str:
            v = data.get(key)
            return v if isinstance(v, str) else ""

        return cls(
            system_prompt=s("systemPrompt"),
            first_message=s("firstMessage"),
            initial_context=s("initialContext"),
            language=s("language") or "en",
            session_id=s("sessionId"),
            voice=s("voice").strip() or None,
            speed=_number(data.get("speed")),
        )


@dataclass
class ConversationState:
    user_identity: str = ""
    focused_session: str = ""
    tool_calls: list[dict[str, Any]] = field(default_factory=list)


def _make_llm(settings: Settings) -> openai.LLM:
    return openai.LLM(
        base_url=settings.llm_base_url,
        api_key=settings.llm_api_key,
        model=settings.llm_model,
        temperature=settings.llm_temperature,
        parallel_tool_calls=False,
        max_completion_tokens=settings.llm_max_tokens,
        extra_body=settings.llm_extra_body,
    )


def llm_conn_options(settings: Settings) -> APIConnectOptions:
    """Timeout and retries of every LLM request, the turns' and the warm-ups'."""
    return APIConnectOptions(max_retry=settings.llm_max_retry, timeout=settings.llm_timeout)


def turn_handling(settings: Settings) -> dict[str, Any]:
    return {
        "turn_detection": _turn_detector(settings.turn_detector),
        "endpointing": {
            "min_delay": settings.min_endpointing_delay,
            "max_delay": settings.max_endpointing_delay,
        },
        # local VAD barge-in (the adaptive detector is a hosted service), gated so background
        # noise does not cut the agent off: speech must last interrupt_min_duration and the STT
        # must have heard interrupt_min_words; a pause with no words then resumes the reply
        "interruption": {
            "enabled": True,
            "mode": "vad",
            "min_duration": settings.interrupt_min_duration,
            "min_words": settings.interrupt_min_words,
            "false_interruption_timeout": settings.false_interruption_timeout,
            "resume_false_interruption": settings.resume_false_interruption,
        },
    }


def warmup_snapshot(agent: Agent) -> tuple[llm.ChatContext, list[Any]]:
    """The history and tools the agent's next LLM request starts with (see HappyAssistant.llm_node).

    The model's chat template rejects a request without a user message ("No user query found"),
    which is the state before the user first speaks, so a placeholder stands in for the turn
    that will follow; everything before it is the prefix the real request shares.
    """
    ctx = fold_system_messages(agent.chat_ctx.copy())
    if not any(isinstance(m, llm.ChatMessage) and m.role == "user" for m in ctx.items):
        ctx.add_message(role="user", content=WARMUP_PLACEHOLDER)
    return ctx, llm.ToolContext(agent.tools).flatten()


def prewarm(proc: JobProcess) -> None:
    proc.userdata["vad"] = silero.VAD.load(min_silence_duration=Settings().vad_min_silence)


def _turn_detector(kind: str):
    kind = kind.lower()
    if kind in ("", "none", "vad"):
        return "vad"
    if kind in ("multilingual", "intl"):
        from livekit.plugins.turn_detector.multilingual import MultilingualModel

        return MultilingualModel()
    from livekit.plugins.turn_detector.english import EnglishModel

    return EnglishModel()


class HappyAssistant(Agent):
    def __init__(
        self,
        *,
        instructions: str,
        room: rtc.Room,
        state: ConversationState,
        settings: Settings,
        chat_ctx: llm.ChatContext | None = None,
    ) -> None:
        super().__init__(instructions=instructions, chat_ctx=chat_ctx)
        self._room = room
        self._state = state
        self._settings = settings
        self.warmer: PrefixWarmer | None = None

    async def llm_node(self, chat_ctx, tools, model_settings):  # type: ignore[override]
        warmer = self.warmer
        try:
            if warmer is not None:
                await warmer.begin_turn()
            t0 = time.monotonic()
            first = True
            async for chunk in Agent.default.llm_node(
                self, fold_system_messages(chat_ctx), tools, model_settings
            ):
                if first:
                    waited = time.monotonic() - t0
                    if waited > 2.0:
                        logger.info("llm_node: first chunk after %.0fms", waited * 1000)
                    first = False
                yield chunk
        finally:
            if warmer is not None:
                warmer.end_turn()

    def _reply_with(self, result: str, context: RunContext) -> str | llm.ToolResult:
        if not self._settings.scripted_tool_replies:
            return result
        m = _SCRIPTED_REPLY_RE.search(result)
        if not m:
            return result
        context.session.say(m.group(1), allow_interruptions=True, add_to_chat_ctx=True)
        return llm.ToolResult(result, reply_required=False)

    async def _call_app(self, method: str, payload: dict[str, Any]) -> str:
        identity = self._state.user_identity
        record = {"method": method, "payload": payload, "t": time.time()}
        self._state.tool_calls.append(record)
        logger.info("tool %s -> %s %s", method, identity, payload)
        if not identity:
            raise ToolError("error (the app is not connected)")
        try:
            result = await self._room.local_participant.perform_rpc(
                destination_identity=identity,
                method=method,
                payload=json.dumps(payload),
                response_timeout=self._settings.tool_timeout,
            )
        except rtc.RpcError as e:
            logger.warning("tool %s failed: %s %s", method, e.code, e.message)
            if e.code == rtc.RpcError.ErrorCode.RESPONSE_TIMEOUT:
                raise ToolError("error (the app did not answer in time)") from e
            raise ToolError(f"error ({e.message or 'the app could not run the tool'})") from e
        except Exception as e:  # connection lost, etc.
            logger.exception("tool %s failed", method)
            raise ToolError("error (could not reach the app)") from e
        logger.info("tool %s <- %r", method, result)
        record["result"] = result
        return result

    @function_tool(raw_schema=SEND_MESSAGE_SCHEMA)
    async def sendMessageToSession(
        self, raw_arguments: dict[str, Any], context: RunContext
    ) -> str | llm.ToolResult:
        session_id = str(raw_arguments.get("sessionId") or "").strip() or self._state.focused_session
        message = str(raw_arguments.get("message") or "").strip()
        if not message:
            raise ToolError("error (empty message)")
        result = await self._call_app(
            "sendMessageToSession", {"sessionId": session_id, "message": message}
        )
        return self._reply_with(result, context)

    @function_tool(raw_schema=PERMISSION_SCHEMA)
    async def processPermissionRequest(
        self, raw_arguments: dict[str, Any], context: RunContext
    ) -> str | llm.ToolResult:
        request_id = str(raw_arguments.get("requestId") or "").strip()
        decision = str(raw_arguments.get("decision") or "").strip().lower()
        if decision not in ("allow", "deny"):
            raise ToolError("error (decision must be allow or deny)")
        result = await self._call_app(
            "processPermissionRequest", {"requestId": request_id, "decision": decision}
        )
        return self._reply_with(result, context)

    @function_tool(raw_schema=SKIP_TURN_SCHEMA)
    async def skip_turn(self, raw_arguments: dict[str, Any], context: RunContext) -> None:
        # Returning None asks for no follow-up reply.
        # The turn it declined is the "user said:" line logged just above; say so, because a
        # bare "skip_turn" reads like a no-op rather than a dropped question.
        logger.info("skip_turn: said nothing in reply to the turn above")
        return None


class _EotPredictionLog(logging.Filter):
    """Surface the turn detector's end-of-turn probability in our own log.

    The 2026-10-29 session spent 727-1502 ms per turn on endpointing, most turns landing on
    the 1.5 s max_endpointing_delay. Whether that cap is the dial to touch depends on why the
    detector kept waiting -- a genuinely unsure model is a different problem from a threshold
    set too low -- and neither EOUMetrics nor any public event carries the probability.
    livekit-agents logs it as a DEBUG record instead, with the threshold and the delay it
    chose, and `on_eot_prediction` reaches only an internal session host.

    So turn the library's logger to DEBUG, re-log that one record as ours, and drop every
    other DEBUG record before it reaches a handler. Logging from inside a filter is unusual;
    it is here because a filter is the only hook that can drop a record selectively, and
    `livekit.agents` is one logger for the whole library.
    """

    _FIELDS = ("probability", "unlikely_threshold", "endpointing_delay", "trigger", "from_cache")

    def filter(self, record: logging.LogRecord) -> bool:
        if record.levelno > logging.DEBUG:
            return True
        # the raw msg, so the other DEBUG records are never formatted
        if record.msg == "eot prediction":
            logger.info(
                "eot: %s",
                " ".join(f"{f}={getattr(record, f, '?')}" for f in self._FIELDS),
            )
        return False

    @classmethod
    def install(cls) -> None:
        lk = logging.getLogger("livekit.agents")
        if any(isinstance(f, cls) for f in lk.filters):
            return
        lk.addFilter(cls())
        lk.setLevel(logging.DEBUG)


def announce_interruptions(session: Any, publish: Any) -> None:
    """Call `publish(b"", reliable=True, topic=TOPIC_INTERRUPTED)` whenever
    the agent's speech is interrupted."""

    async def send() -> None:
        try:
            await publish(b"", reliable=True, topic=TOPIC_INTERRUPTED)
        except Exception:
            logger.exception("failed to announce interruption")

    def on_done(handle: Any) -> None:
        if handle.interrupted:
            asyncio.create_task(send())

    @session.on("speech_created")
    def _on_speech(ev) -> None:
        ev.speech_handle.add_done_callback(on_done)


async def _fetch_config(
    room: rtc.Room, identity: str, timeout: float
) -> VoiceConfig:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while (remaining := deadline - time.monotonic()) > 0:
        try:
            raw = await room.local_participant.perform_rpc(
                destination_identity=identity,
                method=RPC_GET_CONFIG,
                payload="",
                response_timeout=remaining,
            )
            return VoiceConfig.from_json(raw)
        except rtc.RpcError as e:
            last_error = e
            # the app may not have registered its handler yet
            if e.code in (
                rtc.RpcError.ErrorCode.UNSUPPORTED_METHOD,
                rtc.RpcError.ErrorCode.RECIPIENT_NOT_FOUND,
                rtc.RpcError.ErrorCode.RECIPIENT_DISCONNECTED,
            ):
                await asyncio.sleep(0.25)
                continue
            break
        except Exception as e:
            last_error = e
            break
    logger.warning("happy.getConfig failed (%s); using defaults", last_error)
    return VoiceConfig()


async def entrypoint(ctx: JobContext) -> None:
    settings = Settings()
    state = ConversationState()
    ctx.log_context_fields = {"room": ctx.room.name}

    # Data messages may arrive before the session is ready: queue them in arrival order.
    inbox: asyncio.Queue[tuple[str, str]] = asyncio.Queue()

    def on_data(packet: rtc.DataPacket) -> None:
        if packet.topic in (TOPIC_CONTEXT, TOPIC_TEXT):
            try:
                inbox.put_nowait((packet.topic, packet.data.decode("utf-8")))
            except UnicodeDecodeError:
                logger.warning("ignoring non UTF-8 payload on %s", packet.topic)

    ctx.room.on("data_received", on_data)

    def text_stream_handler(topic: str):
        def handler(reader: rtc.TextStreamReader, participant_identity: str) -> None:
            async def read() -> None:
                inbox.put_nowait((topic, await reader.read_all()))

            asyncio.create_task(read())

        return handler

    for topic in (TOPIC_CONTEXT, TOPIC_TEXT):
        ctx.room.register_text_stream_handler(topic, text_stream_handler(topic))

    await ctx.connect()

    participant = await ctx.wait_for_participant(
        kind=[
            rtc.ParticipantKind.PARTICIPANT_KIND_STANDARD,
            rtc.ParticipantKind.PARTICIPANT_KIND_SIP,
            rtc.ParticipantKind.PARTICIPANT_KIND_INGRESS,
        ]
    )
    state.user_identity = participant.identity
    logger.info("user participant %s joined", participant.identity)

    config = await _fetch_config(ctx.room, participant.identity, settings.config_timeout)
    state.focused_session = config.session_id
    known_voices = None
    if config.voice is not None:
        known_voices = await fetch_known_voices(settings.tts_url)
    tts_voice, tts_speed = resolve_tts(settings, config.language, config.voice, config.speed, known_voices)
    # A name only for a voice the app asked for: the default voice is nameless, so the assistant
    # stays Happy however that default is configured.
    voice_persona = persona_for(config.voice, tts_voice, known_voices)
    logger.info(
        "config: session=%s language=%s voice=%s name=%s speed=%.2f prompt=%d chars context=%d chars first=%r",
        config.session_id,
        config.language,
        tts_voice,
        voice_persona,
        tts_speed,
        len(config.system_prompt),
        len(config.initial_context),
        config.first_message,
    )

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

    instructions = build_instructions(
        app_system_prompt=config.system_prompt,
        session_id=config.session_id,
        language=config.language,
        name=voice_persona,
    )
    chat_ctx = llm.ChatContext()
    initial = config.initial_context.strip()
    # The app's systemPrompt already embeds initialContext; only add it when it is not there.
    if initial and initial not in config.system_prompt:
        chat_ctx.add_message(role="system", content=f"Conversation history so far:\n{initial}")

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

    _EotPredictionLog.install()
    announce_interruptions(session, ctx.room.local_participant.publish_data)
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
            logger.info("llm: ttft=%.0fms total=%.0fms", m.ttft * 1000, m.duration * 1000)
        elif isinstance(m, metrics.TTSMetrics):
            logger.info("tts: ttfb=%.0fms", m.ttfb * 1000)

    @session.on("user_input_transcribed")
    def _on_transcript(ev) -> None:
        if ev.is_final:
            logger.info("user said: %r", ev.transcript)

    @session.on("conversation_item_added")
    def _on_item(ev) -> None:
        item = ev.item
        if isinstance(item, llm.ChatMessage) and item.role == "assistant":
            logger.info("agent said: %r", item.text_content)

    closed = asyncio.Event()

    @session.on("close")
    def _on_close(ev) -> None:
        logger.info("session closed (%s); usage %s", getattr(ev, "reason", ""), usage.get_summary())
        closed.set()
        ctx.shutdown("session closed")

    @ctx.room.on("participant_disconnected")
    def _on_left(p: rtc.RemoteParticipant) -> None:
        if p.identity == state.user_identity:
            logger.info("user participant left; closing")
            asyncio.create_task(session.aclose())

    agent = HappyAssistant(
        instructions=instructions,
        room=ctx.room,
        state=state,
        settings=settings,
        chat_ctx=chat_ctx,
    )

    await session.start(
        agent=agent,
        room=ctx.room,
        room_options=room_io.RoomOptions(
            participant_identity=participant.identity,
            close_on_disconnect=True,
        ),
        record=False,
    )

    # Prefill the prompt while the greeting plays, so the first reply does not wait for it.
    warmer = PrefixWarmer(
        _make_llm(settings),
        lambda: warmup_snapshot(session.current_agent),
        timeout=settings.llm_timeout,
        turn_wait=settings.warmup_turn_wait,
        conn_options=llm_conn_options(settings),
    )
    agent.warmer = warmer
    warmer.schedule()

    if config.first_message.strip():
        session.say(config.first_message.strip(), allow_interruptions=True)

    lock = asyncio.Lock()
    recent_updates = RecentUpdates()

    # Applying a context update while a reply is being prepared changes the prompt the
    # preemptive generation was started on, which throws it away ("preemptive generation
    # invalidated after on_user_turn_completed", three times in the 2026-10-29 session) -- the
    # opposite of what the update is for. Nothing in a focus change or a tool-call notice has
    # to reach the model in that half-second, so hold it until the window passes. Only context
    # waits; permission requests and the app's own prompts arrive on TOPIC_TEXT.
    #
    # The window is the user speaking (a preemptive generation is about to start on what they
    # have said so far) through the agent thinking (it is running). Not the agent speaking:
    # by then the request is made, and the greeting alone would hold up the first session dump,
    # which is the one warm-up that decides how long the first reply takes.
    quiet = asyncio.Event()
    quiet.set()

    def _recheck_quiet(_: Any = None) -> None:
        busy = session.user_state == "speaking" or session.agent_state == "thinking"
        quiet.clear() if busy else quiet.set()

    session.on("user_state_changed", _recheck_quiet)
    session.on("agent_state_changed", _recheck_quiet)

    async def handle_inbox() -> None:
        while True:
            topic, text = await inbox.get()
            text = text.strip()
            if not text:
                continue
            if topic == TOPIC_CONTEXT:
                # the focus is state, not prompt text: record it even if the update is dropped
                if focused := focused_session_from(text):
                    state.focused_session = focused
                if recent_updates.is_repeat(text, time.monotonic()):
                    logger.info("context update (%d chars) repeats one just applied; skipped", len(text))
                    continue
                if not quiet.is_set():
                    try:
                        # capped: a long agent monologue must not starve context indefinitely,
                        # and by then there is no preemptive generation left to invalidate
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
                logger.info("text turn: %r", text[:200])
                session.generate_reply(user_input=text)

    inbox_task = asyncio.create_task(handle_inbox())

    async def _cleanup(reason: str = "") -> None:
        inbox_task.cancel()
        await warmer.aclose()

    ctx.add_shutdown_callback(_cleanup)
