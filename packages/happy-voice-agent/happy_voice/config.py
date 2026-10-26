"""Environment configuration for the voice worker."""

from __future__ import annotations

import json
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


def _env(name: str, default: str) -> str:
    value = os.environ.get(name)
    return value if value else default


@dataclass
class Settings:
    agent_name: str = field(default_factory=lambda: _env("VOICE_AGENT_NAME", "happy-voice"))
    stt_url: str = field(default_factory=lambda: _env("STT_URL", "ws://127.0.0.1:8090/v1/stream"))
    tts_url: str = field(default_factory=lambda: _env("TTS_URL", "http://127.0.0.1:8880/v1"))
    tts_voice: str = field(default_factory=lambda: _env("TTS_VOICE", "af_heart"))
    tts_speed: float = field(default_factory=lambda: float(_env("TTS_SPEED", "1.0")))
    llm_base_url: str = field(default_factory=lambda: _env("LLM_BASE_URL", "http://127.0.0.1:9080/v1"))
    llm_model: str = field(default_factory=lambda: _env("LLM_MODEL", "coder"))
    llm_api_key: str = field(default_factory=lambda: _env("LLM_API_KEY", "not-needed"))
    llm_temperature: float = field(default_factory=lambda: float(_env("LLM_TEMPERATURE", "0.2")))
    llm_max_tokens: int = field(default_factory=lambda: int(_env("LLM_MAX_TOKENS", "250")))
    # extra JSON merged into every chat completion request (vLLM: thinking off for Qwen3)
    llm_extra_body: dict = field(
        default_factory=lambda: json.loads(
            _env("LLM_EXTRA_BODY", '{"chat_template_kwargs": {"enable_thinking": false}}')
        )
    )
    turn_detector: str = field(default_factory=lambda: _env("TURN_DETECTOR", "en"))
    # silence (s) before Silero VAD declares end of speech; below ~0.4 transport jitter splits utterances
    vad_min_silence: float = field(default_factory=lambda: float(_env("VAD_MIN_SILENCE", "0.5")))
    min_endpointing_delay: float = field(default_factory=lambda: float(_env("MIN_ENDPOINTING_DELAY", "0.4")))
    max_endpointing_delay: float = field(default_factory=lambda: float(_env("MAX_ENDPOINTING_DELAY", "2.0")))
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
