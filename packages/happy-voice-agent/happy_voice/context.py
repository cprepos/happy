"""Chat-context helpers.

Qwen chat templates reject a system message anywhere but first ("System message must be at
the beginning"). The worker keeps app context updates as `system` messages in the session
history (so they are clearly not user speech, and the turn detector ignores them), and right
before each LLM request folds them into a form the template accepts: leading system messages are
merged into one, later ones become user messages tagged with CONTEXT_PREFIX.

It also tags assistant replies the user talked over with INTERRUPTED_MARKER. LiveKit keeps only
the part that played and flags the message `interrupted`; untagged, the model reads its own
replies ending mid-phrase and copies them ("It dropped from about 33", "About", "I"), which is
what the 2026-11-03 call did after compaction left a tail of mostly clipped turns.
"""

from __future__ import annotations

import re

from livekit.agents import llm

from .prompt import CONTEXT_PREFIX, INTERRUPTED_MARKER

_FOCUS_RE = re.compile(r"Session became focused:\s*(\S+)")


def focused_session_from(update: str) -> str | None:
    m = None
    for m in _FOCUS_RE.finditer(update):
        pass
    return m.group(1) if m else None


def _text(msg: llm.ChatMessage) -> str:
    return msg.text_content or ""


def mark_interrupted(msg: llm.ChatMessage) -> llm.ChatMessage:
    """`msg` with INTERRUPTED_MARKER after its text when it is a reply the user cut off.

    A copy with the same id, so the stored history never carries the marker: every request
    builder folds through here, which keeps turns, warm-ups and summaries rendered alike (and
    the prefix cache stable). A reply with no played text, or one already marked, is returned
    as is.
    """
    if msg.role != "assistant" or not msg.interrupted:
        return msg
    content = list(msg.content)
    last = next((i for i in range(len(content) - 1, -1, -1) if isinstance(content[i], str)), None)
    if last is None:
        return msg
    text = content[last].rstrip()
    if not text or text.endswith(INTERRUPTED_MARKER.strip()):
        return msg
    content[last] = text + INTERRUPTED_MARKER
    return msg.model_copy(update={"content": content})


def fold_system_messages(chat_ctx: llm.ChatContext) -> llm.ChatContext:
    items: list[llm.ChatItem] = []
    head: llm.ChatMessage | None = None
    seen_other = False
    for item in chat_ctx.items:
        if isinstance(item, llm.ChatMessage) and item.role in ("system", "developer"):
            text = _text(item)
            if not seen_other:
                if head is None:
                    head = llm.ChatMessage(role="system", content=[text], id=item.id)
                    items.append(head)
                else:
                    head.content = [_text(head) + "\n\n" + text]
                continue
            if not text.startswith(CONTEXT_PREFIX):
                text = CONTEXT_PREFIX + text
            items.append(llm.ChatMessage(role="user", content=[text], id=item.id))
            continue
        seen_other = True
        if isinstance(item, llm.ChatMessage):
            item = mark_interrupted(item)
        items.append(item)
    return llm.ChatContext(items)


# Session dumps run to thousands of characters; short updates ("Session became focused: X")
# are events that may legitimately repeat, so only long ones are checked for duplicates.
DUPLICATE_MIN_CHARS = 1000


def already_in_context(update: str, chat_ctx: llm.ChatContext, instructions: str = "") -> bool:
    """True when a long context update is verbatim part of the prompt already.

    The app puts the current session's full dump into its system prompt and may send the same
    dump again as a context update when voice starts. Added twice, it doubled the prompt
    (about 10k tokens instead of 5k) that every turn has to prefill.
    """
    text = update.strip()
    if len(text) < DUPLICATE_MIN_CHARS:
        return False
    if text in instructions:
        return True
    return any(
        isinstance(item, llm.ChatMessage) and text in _text(item) for item in chat_ctx.items
    )


# A repeat this close together is the sync layer emitting one event twice, not the user doing
# the same thing twice: a tool call is rendered to the same string when it arrives and again
# when its result lands, because the rendering carries no state. Beyond the window, an
# identical update is taken at face value -- the same file really can be read twice.
REPEAT_WINDOW = 2.0


class RecentUpdates:
    """Drops a context update identical to one applied moments ago.

    `already_in_context` exempts short updates on purpose, so these slip past it: the
    2026-10-29 session took ~45 updates in three minutes, among them three pairs 1 ms apart.
    Each one appends a system message, grows every later prefill, and schedules a warm-up.
    """

    def __init__(self, window: float = REPEAT_WINDOW, keep: int = 8) -> None:
        self._window = window
        self._keep = keep
        self._seen: list[tuple[float, str]] = []

    def is_repeat(self, update: str, now: float) -> bool:
        text = update.strip()
        self._seen = [(t, u) for t, u in self._seen if now - t <= self._window]
        if any(u == text for _, u in self._seen):
            return True
        self._seen.append((now, text))
        del self._seen[: -self._keep]
        return False
