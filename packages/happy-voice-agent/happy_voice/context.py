"""Chat-context helpers.

Qwen chat templates reject a system message anywhere but first ("System message must be at
the beginning"). The worker keeps app context updates as `system` messages in the session
history (so they are clearly not user speech, and the turn detector ignores them), and right
before each LLM request folds them into a form the template accepts: leading system messages are
merged into one, later ones become user messages tagged with CONTEXT_PREFIX.
"""

from __future__ import annotations

import re

from livekit.agents import llm

from .prompt import CONTEXT_PREFIX

_FOCUS_RE = re.compile(r"Session became focused:\s*(\S+)")


def focused_session_from(update: str) -> str | None:
    m = None
    for m in _FOCUS_RE.finditer(update):
        pass
    return m.group(1) if m else None


def _text(msg: llm.ChatMessage) -> str:
    return msg.text_content or ""


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
        items.append(item)
    return llm.ChatContext(items)
