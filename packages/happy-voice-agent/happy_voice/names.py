"""Persona names: the name a voice answers to.

Kokoro voice ids encode the name and the gender: ``am_michael`` is a male voice
called Michael, ``bf_emma`` a female one called Emma. ``OVERRIDES`` renames
voices whose persona differs from the id (``am_morgan`` answers to Morgan
Freeman, its fine-tuned persona). ``voice_name`` resolves
the persona name of a validated voice spec (a single name or a weighted
blend); a blend answers to its first voice. Specs without a resolvable name
fall back to ``Happy``. Keep the app-side mirror (``voicePersona`` in
``packages/happy-app/sources/realtime/voiceCatalog.ts``) in sync.
"""

from __future__ import annotations

from typing import Any

from .voices import parse_voice

# Names that differ from the id derivation.
OVERRIDES: dict[str, str] = {
    # Fine-tuned Morgan Freeman voice.
    "am_morgan": "Morgan Freeman",
}

FALLBACK_NAME = "Happy"


def _derive(name: str) -> str | None:
    """``am_morgan`` -> ``Morgan``; None when the id has no usable name part."""
    prefix, sep, tail = name.partition("_")
    if not sep or not prefix.isalpha() or len(prefix) > 2:
        return None
    words = [w for w in tail.split("_") if w]
    if not words:
        return None
    return " ".join(w[:1].upper() + w[1:] for w in words)


def voice_name(spec: Any) -> str:
    """The persona name a voice spec answers to; ``Happy`` when it has none."""
    if not isinstance(spec, str):
        return FALLBACK_NAME
    parts = parse_voice(spec)
    if not parts:
        return FALLBACK_NAME
    name = parts[0][0]
    if name in OVERRIDES:
        return OVERRIDES[name]
    return _derive(name) or FALLBACK_NAME
