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
from livekit.plugins import openai, silero

from .config import Settings
from .context import focused_session_from, fold_system_messages
from .nemotron_stt import NemotronSTT
from .prompt import (
    PERMISSION_SCHEMA,
    SEND_MESSAGE_SCHEMA,
    SKIP_TURN_SCHEMA,
    build_instructions,
)

logger = logging.getLogger("happy-voice")

TOPIC_CONTEXT = "happy.context"
TOPIC_TEXT = "happy.text"
RPC_GET_CONFIG = "happy.getConfig"

# The app's tool results dictate the exact words to speak, e.g.
# "sent [DO NOT say anything else, simply say 'sent']". Speaking them directly saves a second LLM
# round trip (the most expensive part of a tool turn); the result still goes into the history.
_SCRIPTED_REPLY_RE = re.compile(r"\[\s*DO NOT say anything else,\s*simply say\s*'([^']{1,80})'\s*\]\s*$")


@dataclass
class VoiceConfig:
    system_prompt: str = ""
    first_message: str = ""
    initial_context: str = ""
    language: str = "en"
    session_id: str = ""

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
        )


@dataclass
class ConversationState:
    user_identity: str = ""
    focused_session: str = ""
    tool_calls: list[dict[str, Any]] = field(default_factory=list)


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

    async def llm_node(self, chat_ctx, tools, model_settings):  # type: ignore[override]
        return Agent.default.llm_node(self, fold_system_messages(chat_ctx), tools, model_settings)

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
        logger.info("skip_turn")
        return None


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
    logger.info(
        "config: session=%s language=%s prompt=%d chars context=%d chars first=%r",
        config.session_id,
        config.language,
        len(config.system_prompt),
        len(config.initial_context),
        config.first_message,
    )

    instructions = build_instructions(
        app_system_prompt=config.system_prompt,
        session_id=config.session_id,
        language=config.language,
    )
    chat_ctx = llm.ChatContext()
    initial = config.initial_context.strip()
    # The app's systemPrompt already embeds initialContext; only add it when it is not there.
    if initial and initial not in config.system_prompt:
        chat_ctx.add_message(role="system", content=f"Conversation history so far:\n{initial}")

    session: AgentSession = AgentSession(
        vad=ctx.proc.userdata.get("vad") or silero.VAD.load(min_silence_duration=settings.vad_min_silence),
        stt=NemotronSTT(url=settings.stt_url, language="en"),
        llm=openai.LLM(
            base_url=settings.llm_base_url,
            api_key=settings.llm_api_key,
            model=settings.llm_model,
            temperature=settings.llm_temperature,
            parallel_tool_calls=False,
            max_completion_tokens=settings.llm_max_tokens,
            extra_body=settings.llm_extra_body,
        ),
        tts=openai.TTS(
            base_url=settings.tts_url,
            api_key="not-needed",
            model="kokoro",
            voice=settings.voice_for(config.language),
            speed=settings.tts_speed,
            response_format="pcm",
        ),
        turn_handling={
            "turn_detection": _turn_detector(settings.turn_detector),
            "endpointing": {
                "min_delay": settings.min_endpointing_delay,
                "max_delay": settings.max_endpointing_delay,
            },
            # local VAD barge-in (the adaptive detector is a hosted service)
            "interruption": {"enabled": True, "mode": "vad"},
        },
        user_away_timeout=None,
    )

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

    if config.first_message.strip():
        session.say(config.first_message.strip(), allow_interruptions=True)

    lock = asyncio.Lock()

    async def handle_inbox() -> None:
        while True:
            topic, text = await inbox.get()
            text = text.strip()
            if not text:
                continue
            if topic == TOPIC_CONTEXT:
                if focused := focused_session_from(text):
                    state.focused_session = focused
                async with lock:
                    current = session.current_agent
                    new_ctx = current.chat_ctx.copy()
                    new_ctx.add_message(role="system", content=text)
                    await current.update_chat_ctx(new_ctx)
                logger.info("context update (%d chars)", len(text))
            else:
                logger.info("text turn: %r", text[:200])
                session.generate_reply(user_input=text)

    inbox_task = asyncio.create_task(handle_inbox())

    async def _cleanup(reason: str = "") -> None:
        inbox_task.cancel()

    ctx.add_shutdown_callback(_cleanup)
