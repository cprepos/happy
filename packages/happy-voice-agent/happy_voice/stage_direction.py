"""Keep bracketed stage directions out of speech.

On 2026-11-06 the model answered "Are you able to hear me?" with the text
"[assistant turned away]", twice, and the worker spoke it. Its history held a turn where it had
called skip_turn; asked again, it narrated that silence as a bracketed aside instead of speaking.
The same history replayed against the model gives "[assistant turned their speaker off]" and
"[interrupted: the user started talking]" too. Every one of these is a whole reply that is
nothing but one bracketed note, which nobody says out loud, so such a reply is dropped before it
reaches TTS or the chat history (where the model would read it next turn and copy it).

A reply that only starts with a bracket and goes on to say something is spoken as is.
"""

from __future__ import annotations

import logging
import re
from typing import Any, AsyncIterable, AsyncIterator

from livekit.agents import llm

logger = logging.getLogger("happy-voice")

_ONLY_BRACKETED_RE = re.compile(r"^\s*\[[^\[\]]*\]\s*$")


def is_stage_direction(text: str) -> bool:
    """True when `text` is one bracketed note and nothing else."""
    return bool(_ONLY_BRACKETED_RE.match(text))


def _content(chunk: Any) -> str | None:
    """The chunk's text; "" for one that carries none (a role, usage); None for a tool call."""
    if isinstance(chunk, str):
        return chunk
    if isinstance(chunk, llm.ChatChunk):
        if chunk.delta is None:
            return ""
        if chunk.delta.tool_calls:
            return None
        return chunk.delta.content or ""
    return None


async def drop_stage_directions(chunks: AsyncIterable[Any]) -> AsyncIterator[Any]:
    """`chunks` with a reply that is only a bracketed note removed.

    Text is held back only while the reply so far could still be such a note (blank, or an
    opening bracket not yet closed or closed with nothing after it). Chunks without text (a role,
    usage) pass straight through; a tool call ends the wait, so text before it keeps its place.
    """
    held: list[Any] = []
    text = ""
    deciding = True
    async for chunk in chunks:
        if not deciding:
            yield chunk
            continue
        content = _content(chunk)
        if content is None:
            if held and not is_stage_direction(text):
                for h in held:
                    yield h
            elif held:
                logger.warning("dropped a reply that was only a stage direction: %r", text.strip())
            held, deciding = [], False
            yield chunk
            continue
        if not content:
            yield chunk
            continue
        held.append(chunk)
        text += content
        stripped = text.lstrip()
        if not stripped:
            continue
        if stripped.startswith("[") and ("]" not in stripped or is_stage_direction(text)):
            continue
        for h in held:
            yield h
        held, deciding = [], False
    if held:
        if is_stage_direction(text):
            logger.warning("dropped a reply that was only a stage direction: %r", text.strip())
        else:
            for h in held:
                yield h
