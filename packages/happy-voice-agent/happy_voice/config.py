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
    # agentgateway on 8903, asking for the MoE tier (Qwen3.6-35B-A3B on 9081) by name. Each of
    # the gateway's virtual models carries its own failover list -- `coder-moe` tries 9081 and
    # spills over to coder-dense (9080), a refused connection counted unhealthy -- so the agent
    # needs no failover of its own, and naming a tier is not the port pinning that made voice
    # mute on 2026-10-28, when the pinned backend restarted six times while being tuned.
    # Not the gateway's third virtual model, `coder`: that one is difficulty-routed per request,
    # which split one 3-minute session 39/26 between the tiers. Per-turn routing costs more than
    # the slower tier's decode -- the prefix warm-up prefills whichever tier it is given, so a
    # turn that classifies onto the other one pays the full 20k-token prefill the warm-up exists
    # to avoid. MoE for every turn beats the right tier for some of them.
    # Not 8903's neighbour 8899 either: that is coder-tool-proxy, which injects a searxng tool
    # into every request and sets stream=False upstream, so first-token latency would become
    # full generation time.
    llm_base_url: str = field(default_factory=lambda: _env("LLM_BASE_URL", "http://127.0.0.1:8903/v1"))
    llm_model: str = field(default_factory=lambda: _env("LLM_MODEL", "coder-moe"))
    llm_api_key: str = field(default_factory=lambda: _env("LLM_API_KEY", "not-needed"))
    llm_temperature: float = field(default_factory=lambda: float(_env("LLM_TEMPERATURE", "0.2")))
    llm_max_tokens: int = field(default_factory=lambda: int(_env("LLM_MAX_TOKENS", "250")))
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
    # longest wait after speech ends when the turn detector thinks the user is not done
    max_endpointing_delay: float = field(default_factory=lambda: float(_env("MAX_ENDPOINTING_DELAY", "1.5")))
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
