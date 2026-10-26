"""Per-chat TTS voice selection: validate the app's requested Kokoro voice and speed.

The app may send ``voice`` and ``speed`` in its ``happy.getConfig`` reply. ``voice``
is either a single Kokoro voice name (``af_heart``) or a weighted blend
(``am_michael(2)+am_onyx(1)``). Anything we cannot validate falls back to the
server defaults (``Settings.voice_for(language)`` / ``Settings.tts_speed``).
"""

from __future__ import annotations

import logging
import re
from typing import Any, Iterable

import aiohttp

logger = logging.getLogger("happy-voice")

MIN_SPEED = 0.5
MAX_SPEED = 1.5
MAX_BLEND_PARTS = 4

# Used only when Kokoro's voice list cannot be fetched.
_FALLBACK_NAME_RE = re.compile(r"^[a-z]{2}_[a-z]+$")
_NAME_RE = re.compile(r"^[a-z0-9_]+$")
_BLEND_PART_RE = re.compile(r"^([a-z0-9_]+)\((\d+)\)$")

_known_voices: frozenset[str] | None = None


def parse_voice(spec: str) -> list[tuple[str, int]] | None:
    """Split a voice spec into (name, weight) parts, or None when malformed.

    A single name has weight 1. A blend is ``name(n)+name(n)`` with 2..4 parts
    and positive integer weights.
    """
    spec = spec.strip()
    if not spec or len(spec) > 200:
        return None
    if "+" not in spec:
        return [(spec, 1)] if _NAME_RE.match(spec) else None
    parts = spec.split("+")
    if len(parts) > MAX_BLEND_PARTS:
        return None
    out: list[tuple[str, int]] = []
    for part in parts:
        m = _BLEND_PART_RE.match(part.strip())
        if not m:
            return None
        weight = int(m.group(2))
        if weight <= 0:
            return None
        out.append((m.group(1), weight))
    return out


def validate_voice(spec: Any, known: Iterable[str] | None) -> str | None:
    """Return a normalized voice spec when every name is a known Kokoro voice, else None.

    ``known`` is Kokoro's voice list; when it is None (fetch failed) names only
    need to look like Kokoro voice names.
    """
    if not isinstance(spec, str):
        return None
    parts = parse_voice(spec)
    if parts is None:
        return None
    known_set = set(known) if known is not None else None
    for name, _ in parts:
        if known_set is not None:
            if name not in known_set:
                return None
        elif not _FALLBACK_NAME_RE.match(name):
            return None
    if len(parts) == 1 and "+" not in spec:
        return parts[0][0]
    return "+".join(f"{name}({weight})" for name, weight in parts)


def clamp_speed(value: Any) -> float | None:
    """Clamp a requested speed to [MIN_SPEED, MAX_SPEED]; None when not a finite number."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    speed = float(value)
    if speed != speed or speed in (float("inf"), float("-inf")):
        return None
    return min(MAX_SPEED, max(MIN_SPEED, speed))


def _voice_names(payload: Any) -> frozenset[str] | None:
    """Kokoro-FastAPI answers ``{"voices": [...]}`` with names or ``{"id", "name"}`` objects."""
    voices = payload.get("voices") if isinstance(payload, dict) else payload
    if not isinstance(voices, list):
        return None
    names: set[str] = set()
    for v in voices:
        if isinstance(v, str):
            names.add(v)
        elif isinstance(v, dict):
            for key in ("id", "name"):
                if isinstance(v.get(key), str):
                    names.add(v[key])
    return frozenset(names) if names else None


async def fetch_known_voices(tts_url: str, timeout: float = 3.0) -> frozenset[str] | None:
    """Kokoro's voice names, fetched once per process; None when unavailable (not cached)."""
    global _known_voices
    if _known_voices is not None:
        return _known_voices
    url = tts_url.rstrip("/") + "/audio/voices"
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout)) as http:
            async with http.get(url) as resp:
                resp.raise_for_status()
                names = _voice_names(await resp.json(content_type=None))
    except Exception as e:  # network, HTTP or JSON errors
        logger.warning("could not list Kokoro voices at %s (%s); using name pattern check", url, e)
        return None
    if names is None:
        logger.warning("unexpected Kokoro voice list from %s; using name pattern check", url)
        return None
    _known_voices = names
    return names


def _uses_english_voice(language: str | None) -> bool:
    return not language or language.lower().startswith("en")


def resolve_tts(
    settings: Any,
    language: str | None,
    voice: Any,
    speed: Any,
    known: Iterable[str] | None,
) -> tuple[str, float]:
    """The (voice, speed) to synthesize with for this conversation.

    The requested voice applies to English conversations only: Kokoro picks its
    phonemizer from the voice prefix, so other languages keep their language voice.
    An invalid voice drops the requested speed too, since presets tune speed per voice.
    """
    default_voice = settings.voice_for(language)
    default_speed = settings.tts_speed
    if voice is None and speed is None:
        return default_voice, default_speed

    if voice is not None and not _uses_english_voice(language):
        logger.info("ignoring requested voice %r for language %s", voice, language)
        return default_voice, default_speed

    requested_speed = None
    if speed is not None:
        requested_speed = clamp_speed(speed)
        if requested_speed is None:
            logger.warning("ignoring invalid TTS speed %r", speed)

    if voice is None:
        return default_voice, requested_speed if requested_speed is not None else default_speed

    valid = validate_voice(voice, known)
    if valid is None:
        logger.warning("ignoring invalid TTS voice %r; using %s", voice, default_voice)
        return default_voice, default_speed
    return valid, requested_speed if requested_speed is not None else default_speed
