"""Environment configuration for the voice worker."""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field

# Kokoro voice per language (the voice prefix selects Kokoro's phonemizer language).
KOKORO_VOICES = {
    "en": "af_heart",
    "en-gb": "bf_emma",
    "es": "ef_dora",
    "fr": "ff_siwis",
    "hi": "hf_alpha",
    "it": "if_sara",
    "ja": "jf_alpha",
    "pt": "pf_dora",
    "zh": "zf_xiaobei",
}


logger = logging.getLogger("happy-voice")

# history compaction defaults, in tokens; see Settings.compaction
COMPACT_TRIGGER = 32000
COMPACT_KEEP = 8000
# The newest history a compaction always keeps verbatim, whatever VOICE_COMPACT_KEEP says: the
# summary never reaches into it, and a configuration that leaves no room above it turns
# compaction off rather than shrinking it.
COMPACT_KEEP_FLOOR = 8000
CONTEXT_HARD_CAP = 235929  # 90% of the model's 262144-token window
COMPACT_SUMMARY_TOKENS = 1200


def _env(name: str, default: str) -> str:
    value = os.environ.get(name)
    return value if value else default


def _env_float(name: str, default: float, *, minimum: float = 0.0) -> float:
    """A float setting; an unparsable or out-of-range value falls back to the default."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        logger.warning("%s=%r is not a number; using %s", name, raw, default)
        return default
    if value != value or value < minimum:  # NaN or below the minimum
        logger.warning("%s=%r is below %s; using %s", name, raw, minimum, default)
        return default
    return value


def _env_int(name: str, default: int, *, minimum: int = 0) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        logger.warning("%s=%r is not an integer; using %s", name, raw, default)
        return default
    if value < minimum:
        logger.warning("%s=%r is below %s; using %s", name, raw, minimum, default)
        return default
    return value


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw not in ("0", "false", "no", "off")


def _env_optional_seconds(name: str, default: float | None) -> float | None:
    """Seconds, or None when set to none/off/0 (the feature is disabled)."""
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    if raw in ("none", "off", "false", "no"):
        return None
    value = _env_float(name, default if default is not None else 0.0)
    return value if value > 0 else None


@dataclass
class Settings:
    agent_name: str = field(default_factory=lambda: _env("VOICE_AGENT_NAME", "happy-voice"))
    stt_url: str = field(default_factory=lambda: _env("STT_URL", "ws://127.0.0.1:8090/v1/stream"))
    tts_url: str = field(default_factory=lambda: _env("TTS_URL", "http://127.0.0.1:8880/v1"))
    tts_voice: str = field(default_factory=lambda: _env("TTS_VOICE", "af_heart"))
    tts_speed: float = field(default_factory=lambda: float(_env("TTS_SPEED", "1.0")))
    # Kokoro prefixes some segments with ~0.7 s of speech-free noise; see tts_trim.py
    tts_trim_lead: bool = field(default_factory=lambda: _env("TTS_TRIM_LEAD", "1") != "0")
    # agentgateway on 8903, asking for the virtual `coder` model: the gateway decides which
    # backend serves it, and a refused connection is counted unhealthy, so the agent needs no
    # failover of its own.
    #
    # Voice deliberately does not name a tier. It named coder-moe on 2026-10-29 to keep the
    # prefix warm-up and the turn on one backend, and lost tool calling for it: context updates
    # fold into the prompt as pseudo-user messages, and past ~25 of them that backend answers a
    # "tell Claude Code to ..." turn by speaking the argument instead of calling
    # sendMessageToSession. Measured at temperature 0, same prompt, both backends:
    #
    #   context updates   prompt    MoE                     dense
    #   0                 1.3k      sendMessageToSession     -
    #   10                2.6k      sendMessageToSession     -
    #   25                4.7k      spoke "test" out loud    sendMessageToSession
    #   45                7.4k      spoke "test" out loud    sendMessageToSession
    #
    # Naming dense fixed it, and then the tier layout went back under review at the gateway, so
    # pinning from here is the wrong place to hold an opinion. Two failure modes to recognise if
    # voice misbehaves again, both of them the gateway's to resolve: a per-request router can
    # send a turn to a backend the warm-up did not warm, which costs that turn a full prefill;
    # and any backend that cannot reliably emit tool calls drops the relay to Claude Code
    # entirely. tests/e2e_fake_app.py step 8 is the regression test for the second.
    #
    # Not 8903's neighbour 8899 either: that is coder-tool-proxy, which injects a searxng tool
    # into every request and sets stream=False upstream, so first-token latency would become
    # full generation time.
    llm_base_url: str = field(default_factory=lambda: _env("LLM_BASE_URL", "http://127.0.0.1:8903/v1"))
    llm_model: str = field(default_factory=lambda: _env("LLM_MODEL", "coder"))
    llm_api_key: str = field(default_factory=lambda: _env("LLM_API_KEY", "not-needed"))
    llm_temperature: float = field(default_factory=lambda: float(_env("LLM_TEMPERATURE", "0.2")))
    # max_completion_tokens of a turn. A readAloud call's argument counts against it: the
    # longest text it reads (read_aloud_max_chars, 6000) is ~1.5k tokens, and at the old 250 the
    # call was cut off as broken JSON. Spoken replies stay short because the prompt says so.
    llm_max_tokens: int = field(default_factory=lambda: _env_int("LLM_MAX_TOKENS", 2048, minimum=1))
    # Longest text one readAloud call speaks (characters); longer text is cut at a sentence end.
    read_aloud_max_chars: int = field(
        default_factory=lambda: _env_int("VOICE_READ_ALOUD_MAX_CHARS", 6000, minimum=1)
    )
    # extra JSON merged into every chat completion request (vLLM: thinking off for Qwen3)
    # Per-request LLM timeout (s). It bounds each wait for the next bytes of the streamed reply,
    # so the first one covers queueing plus prefill. livekit-agents' default is 10 s, which a
    # 10k-token prompt on the shared coder vLLM exceeds when coding agents keep it busy; the
    # request then timed out and the agent never answered.
    llm_timeout: float = field(default_factory=lambda: _env_float("LLM_TIMEOUT", 60.0, minimum=1.0))
    # Retries after a failed request. A retry restarts the whole prefill from scratch (the old
    # request is aborted), so on a slow server it only adds load; off by default.
    llm_max_retry: int = field(default_factory=lambda: _env_int("LLM_MAX_RETRY", 0))
    # How long a turn may wait for a prefix warm-up already in flight (s). Deliberately far
    # below llm_timeout: this is dead air the user hears before their reply is even requested.
    warmup_turn_wait: float = field(default_factory=lambda: _env_float("WARMUP_TURN_WAIT", 0.5, minimum=0.0))
    llm_extra_body: dict = field(
        default_factory=lambda: json.loads(
            _env("LLM_EXTRA_BODY", '{"chat_template_kwargs": {"enable_thinking": false}}')
        )
    )
    turn_detector: str = field(default_factory=lambda: _env("TURN_DETECTOR", "en"))
    # silence (s) before Silero VAD declares end of speech; below ~0.4 transport jitter splits utterances
    vad_min_silence: float = field(default_factory=lambda: float(_env("VAD_MIN_SILENCE", "0.5")))
    min_endpointing_delay: float = field(default_factory=lambda: float(_env("MIN_ENDPOINTING_DELAY", "0.4")))
    # longest wait after speech ends when the turn detector thinks the user is not done. The
    # English detector scores short questions as unfinished ("How's it going happy": 0.0066
    # against a 0.0289 threshold), so on real calls nearly every turn waited out the full delay;
    # at 1.5 s that was the largest part of reply latency. Preemptive generation and barge-in
    # cover the turns this now cuts off early.
    max_endpointing_delay: float = field(default_factory=lambda: float(_env("MAX_ENDPOINTING_DELAY", "0.8")))
    # Barge-in. Speech shorter than this (s) does not interrupt the agent: coughs, clicks, "uh".
    interrupt_min_duration: float = field(
        default_factory=lambda: _env_float("INTERRUPT_MIN_DURATION", 0.8)
    )
    # Words the STT must have heard before the agent stops talking. 1 keeps one-word barge-ins
    # ("stop", "wait") but ignores noise the VAD takes for speech and the STT hears no words in.
    interrupt_min_words: int = field(default_factory=lambda: _env_int("INTERRUPT_MIN_WORDS", 1))
    # After an interruption with no transcript for this long (s), resume the agent's speech
    # (FALSE_INTERRUPTION_TIMEOUT=off disables).
    false_interruption_timeout: float | None = field(
        default_factory=lambda: _env_optional_seconds("FALSE_INTERRUPTION_TIMEOUT", 2.0)
    )
    resume_false_interruption: bool = field(
        default_factory=lambda: _env_bool("RESUME_FALSE_INTERRUPTION", True)
    )
    # speak the app's "simply say 'X'" tool results directly instead of a second LLM call
    scripted_tool_replies: bool = field(
        default_factory=lambda: _env("SCRIPTED_TOOL_REPLIES", "1").lower() not in ("0", "false", "no")
    )
    config_timeout: float = field(default_factory=lambda: float(_env("CONFIG_RPC_TIMEOUT", "10")))
    tool_timeout: float = field(default_factory=lambda: float(_env("TOOL_RPC_TIMEOUT", "30")))
    # History compaction (happy_voice/compaction.py). A warm turn stays under 2 s even at 250k
    # tokens, but a prefix-cache miss re-prefills the whole history at ~1.1-1.6k tokens/s: 21 s
    # at 32k, past the LLM timeout above ~85k. So once a turn's prompt reaches the trigger, the
    # old part is summarized in the background and the newest ~KEEP tokens stay verbatim.
    # VOICE_COMPACTION=0 turns it off; the request is then exactly what it was without it.
    compaction: bool = field(default_factory=lambda: _env_bool("VOICE_COMPACTION", True))
    compact_trigger: int = field(default_factory=lambda: _env_int("VOICE_COMPACT_TRIGGER", COMPACT_TRIGGER, minimum=1))
    compact_keep: int = field(default_factory=lambda: _env_int("VOICE_COMPACT_KEEP", COMPACT_KEEP, minimum=1))
    # Above this estimated size a request loses its oldest items (on the request only, never the
    # history). Only reached if compaction is off or keeps failing; 90% of the 262144 window.
    context_hard_cap: int = field(
        default_factory=lambda: _env_int("VOICE_CONTEXT_HARD_CAP", CONTEXT_HARD_CAP, minimum=1)
    )
    # max_completion_tokens of the summary request
    compact_summary_tokens: int = field(
        default_factory=lambda: _env_int("VOICE_COMPACT_SUMMARY_TOKENS", COMPACT_SUMMARY_TOKENS, minimum=1)
    )

    def __post_init__(self) -> None:
        # KEEP < TRIGGER < HARD_CAP must hold. The hard cap is the one that protects the call
        # (it is what the server can take), so a valid cap is kept and the trigger lowered to
        # fit under it, rather than all three thrown away for the defaults. KEEP has a floor
        # and is never lowered; when it no longer fits, compaction is off.
        if self.compact_trigger >= self.context_hard_cap:
            trigger = min(COMPACT_TRIGGER, self.context_hard_cap * 3 // 4)
            logger.warning(
                "VOICE_COMPACT_TRIGGER=%d is not below VOICE_CONTEXT_HARD_CAP=%d; using %d",
                self.compact_trigger,
                self.context_hard_cap,
                trigger,
            )
            self.compact_trigger = trigger
        if self.compact_keep < COMPACT_KEEP_FLOOR:
            logger.warning(
                "VOICE_COMPACT_KEEP=%d is below the %d tokens always kept verbatim; using %d",
                self.compact_keep,
                COMPACT_KEEP_FLOOR,
                COMPACT_KEEP_FLOOR,
            )
            self.compact_keep = COMPACT_KEEP_FLOOR
        # KEEP is never lowered to fit: what it keeps is the point. A trigger at or below it
        # turns compaction off instead.
        if self.compaction and self.compact_keep >= self.compact_trigger:
            logger.warning(
                "compaction off: VOICE_COMPACT_KEEP=%d is not below VOICE_COMPACT_TRIGGER=%d",
                self.compact_keep,
                self.compact_trigger,
            )
            self.compaction = False
        # A compaction replaces what lies between KEEP and TRIGGER with a summary of up to
        # SUMMARY_TOKENS. If the summary may be as large as half that, compacting gains little
        # and would run again on the next turn; with no room at all it cannot run.
        room = self.compact_trigger - self.compact_keep
        if self.compaction and 2 * self.compact_summary_tokens >= room:
            logger.warning(
                "compaction off: VOICE_COMPACT_SUMMARY_TOKENS=%d leaves no room between "
                "VOICE_COMPACT_KEEP=%d and VOICE_COMPACT_TRIGGER=%d (needs 2 x summary < "
                "trigger - keep)",
                self.compact_summary_tokens,
                self.compact_keep,
                self.compact_trigger,
            )
            self.compaction = False

    def voice_for(self, language: str | None) -> str:
        if not language:
            return self.tts_voice
        lang = language.lower()
        if lang.startswith("en") and lang not in KOKORO_VOICES:
            return self.tts_voice
        voice = KOKORO_VOICES.get(lang) or KOKORO_VOICES.get(lang.split("-")[0])
        if voice is None or voice.startswith(("af_", "am_")):
            return self.tts_voice
        return voice
