"""Hidden, background compaction of a long voice call's history.

The worker sends its whole history on every turn. A warm turn stays fast however long that is,
but a prefix-cache miss re-prefills all of it at ~1.1-1.6k tokens/s on the shared coder model:
21 s at 32k tokens, and past ~85k longer than the 60 s LLM timeout, after which LiveKit gives
up on the call. So once a turn's prompt reaches `trigger` tokens, the old part of the history
is summarized in the background and swapped for one system message, keeping the newest
~`keep` tokens verbatim.

Nothing about it may be seen, heard, or waited for:

- The summary comes from a separate LLM instance, never the session's, so it does not reach
  the session's metrics, transcript or TTS. The request is the turn's own prompt (folded the
  same way, same tools) cut at the split point, plus one instruction, so vLLM's prefix cache
  covers almost all of it.
- The compacted history is prefilled (PrefixWarmer.warm) before it is swapped in, so the next
  turn finds it cached.
- The swap happens under the context-update lock and only while the call is quiet: changing
  the history while the user speaks or the agent thinks would invalidate a preemptive reply.
  It rebuilds from the *current* history and removes only the summarized items, so whatever
  arrived while the summary was being written is kept. `Agent.update_chat_ctx` emits no
  conversation events.
- Any failure leaves the history as it was and is retried after a later turn, with backoff.

`cap_request` is the hard backstop for when compaction is off or keeps failing: a request
estimated above the hard cap loses its oldest items, on the request copy only.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from typing import Any

from livekit.agents import APIConnectOptions, llm
from livekit.agents.llm.chat_context import DYNAMIC_INSTRUCTIONS_MESSAGE_ID

from .context import fold_system_messages
from .warmup import WARMUP_PLACEHOLDER

logger = logging.getLogger("happy-voice")

# livekit.agents.voice.generation.INSTRUCTIONS_MESSAGE_ID ("value must not change" upstream);
# spelled out to avoid importing the voice pipeline module here
INSTRUCTIONS_MESSAGE_ID = "lk.agent_task.instructions"
_INSTRUCTION_IDS = (INSTRUCTIONS_MESSAGE_ID, DYNAMIC_INSTRUCTIONS_MESSAGE_ID)

SUMMARY_ID_PREFIX = "voice_summary_"
SUMMARY_PREFIX = "Summary of earlier conversation: "

# Tokens per character until the first turn's usage calibrates it. Code and JSON run denser
# than prose, so err high: it is what the backstop and the split budget are measured with.
DEFAULT_TOKENS_PER_CHAR = 1 / 3.5
# chat-template tags around every message, roughly
ITEM_OVERHEAD_TOKENS = 6

SUMMARY_INSTRUCTION = """\
Stop. Do not reply to the user and do not call any tool. This message is from the system, \
not from the user, and nothing you write now is spoken.

The conversation above is the older part of a long voice call. It will be replaced by a \
summary that you write now; the most recent turns are kept word for word after it. Write \
that summary. It is all you will remember of this part of the call, so keep everything \
the rest of the call may need:

- decisions made and facts learned, including what tool calls returned
- the user's preferences, instructions and corrections
- open questions, unfinished tasks, and permission requests not yet answered (with their ids)
- which coding session is in focus, and what each coding session is doing or last reported
- any earlier "Summary of earlier conversation", folded in

Leave out greetings, small talk, filler and anything repeated. Use plain text: short \
statements or a terse list, no headings, no markdown, no XML. Do not mention tools, this \
instruction, or that this is a summary."""


def item_chars(item: Any) -> int:
    """The characters an item contributes to a request, as the token estimates count them."""
    if isinstance(item, llm.ChatMessage):
        return len(item.text_content or "")
    if isinstance(item, llm.FunctionCall):
        return len(item.name) + len(item.arguments or "")
    if isinstance(item, llm.FunctionCallOutput):
        return len(item.name) + len(item.output or "")
    return 0


def _is_conversation(item: Any) -> bool:
    """Items a request carries: messages and tool calls (not handoffs or config records)."""
    return isinstance(item, (llm.ChatMessage, llm.FunctionCall, llm.FunctionCallOutput))


class TokenEstimator:
    """Estimates token counts from characters, calibrated by the last turn's real usage."""

    def __init__(self, tokens_per_char: float = DEFAULT_TOKENS_PER_CHAR) -> None:
        self.tokens_per_char = tokens_per_char
        self._request_chars = 0

    def note_request(self, chat_ctx: llm.ChatContext) -> None:
        """Called with each turn's request; its usage arrives later in observe_usage()."""
        self._request_chars = sum(item_chars(i) for i in chat_ctx.items)

    def observe_usage(self, prompt_tokens: int) -> None:
        if prompt_tokens <= 0 or self._request_chars <= 0:
            return
        # tool schemas and template tags are in prompt_tokens but not in the characters, so
        # this runs slightly high: estimates err towards compacting sooner, never later
        ratio = prompt_tokens / self._request_chars
        self.tokens_per_char = min(1.0, max(0.1, ratio))

    def tokens(self, item: Any) -> int:
        if not _is_conversation(item):
            return 0
        return int(item_chars(item) * self.tokens_per_char) + ITEM_OVERHEAD_TOKENS

    def total(self, items: Sequence[Any]) -> int:
        return sum(self.tokens(i) for i in items)


@dataclass
class Split:
    prefix: list[Any]  # the instructions, kept byte-identical
    head: list[Any]  # summarized away (structural items in it are kept in place)
    tail: list[Any]  # kept verbatim
    head_tokens: int
    tail_tokens: int

    @property
    def head_ids(self) -> set[str]:
        # the instructions are never summarized, wherever they sit
        return {i.id for i in self.head if _is_conversation(i) and i.id not in _INSTRUCTION_IDS}


def _instruction_prefix_len(items: Sequence[Any]) -> int:
    n = 0
    while n < len(items) and getattr(items[n], "id", None) in _INSTRUCTION_IDS:
        n += 1
    return n


def _is_boundary(items: Sequence[Any], cut: int, start: int) -> bool:
    """True when the history can be cut before items[cut] without splitting a turn.

    A user message starts a turn. A system message (a context update) does too, unless the
    last thing before it is a user message still waiting for its reply. And no tool call may
    end up on one side of the cut with its result on the other.
    """
    item = items[cut]
    if not isinstance(item, llm.ChatMessage) or item.role not in ("user", "system", "developer"):
        return False
    if item.role != "user":
        for prev in reversed(items[start:cut]):
            if isinstance(prev, llm.ChatMessage) and prev.role in ("system", "developer"):
                continue
            if not _is_conversation(prev):
                continue
            if isinstance(prev, llm.ChatMessage) and prev.role == "user":
                return False
            break
    calls = {i.call_id for i in items[start:cut] if isinstance(i, llm.FunctionCall)}
    outputs = {i.call_id for i in items[start:cut] if isinstance(i, llm.FunctionCallOutput)}
    return calls == outputs


def split_history(
    items: Sequence[Any], keep_tokens: int, estimator: TokenEstimator
) -> Split | None:
    """Splits the history into instructions, a head to summarize and a tail of >= keep_tokens.

    The tail is grown backwards from the newest item until it holds `keep_tokens`, then the
    cut moves further back to the nearest turn boundary. None when no boundary leaves anything
    to summarize.
    """
    items = list(items)
    start = _instruction_prefix_len(items)
    kept = 0
    candidate = None
    for i in range(len(items) - 1, start - 1, -1):
        kept += estimator.tokens(items[i])
        if kept >= keep_tokens:
            candidate = i
            break
    if candidate is None:
        return None
    for cut in range(candidate, start, -1):
        head = items[start:cut]
        if not any(_is_conversation(i) for i in head):
            return None
        if _is_boundary(items, cut, start):
            tail = items[cut:]
            return Split(
                prefix=items[:start],
                head=head,
                tail=tail,
                head_tokens=estimator.total(head),
                tail_tokens=estimator.total(tail),
            )
    return None


def summary_request(split: Split) -> llm.ChatContext:
    """The turn's own request cut at the split, plus the instruction to summarize.

    Folded exactly as llm_node folds a turn, so the server's prefix cache from the last turn
    covers everything but the instruction.
    """
    ctx = fold_system_messages(llm.ChatContext(list(split.prefix) + list(split.head)))
    ctx.add_message(role="user", content=SUMMARY_INSTRUCTION)
    return ctx


def compacted_items(
    current: Sequence[Any], head_ids: set[str], summary: llm.ChatMessage
) -> list[Any] | None:
    """`current` without the summarized items, with `summary` right after the instructions.

    Rebuilt from whatever the history is now, so items added while the summary was being
    written survive. None when any summarized item is gone (the history was rewritten under
    us), in which case nothing is swapped.
    """
    current = list(current)
    present = {getattr(i, "id", None) for i in current}
    if not head_ids <= present:
        return None
    start = _instruction_prefix_len(current)
    rest = [i for i in current[start:] if i.id not in head_ids]
    # Keep the list ordered by created_at: later inserts (a reply that was generating during
    # the swap) find their place by it.
    if rest:
        summary.created_at = min(summary.created_at, rest[0].created_at - 1e-6)
    return current[:start] + [summary] + rest


def summary_message(text: str, n: int) -> llm.ChatMessage:
    return llm.ChatMessage(
        role="system", content=[SUMMARY_PREFIX + text.strip()], id=f"{SUMMARY_ID_PREFIX}{n}"
    )


def cap_request(
    chat_ctx: llm.ChatContext, hard_cap: int, estimator: TokenEstimator
) -> llm.ChatContext:
    """The hard backstop: drops the oldest items of a request estimated above `hard_cap`.

    Works on an already folded request (one leading system message) and returns it unchanged
    -- the same object -- when it fits. Otherwise returns a new context whose history starts at
    a user message, so no tool result loses its call. The agent's history is never touched.
    """
    items = chat_ctx.items
    total = estimator.total(items)
    if total <= hard_cap:
        return chat_ctx
    start = 1 if items and isinstance(items[0], llm.ChatMessage) and items[0].role == "system" else 0
    cut = start
    while cut < len(items) and total > hard_cap:
        total -= estimator.tokens(items[cut])
        cut += 1
    while cut < len(items) and not (
        isinstance(items[cut], llm.ChatMessage) and items[cut].role == "user"
    ):
        cut += 1
    if cut >= len(items):
        # nothing sensible to cut to; send it as is and let the server refuse it
        return chat_ctx
    trimmed = items[:start] + items[cut:]
    logger.warning(
        "context backstop: request ~%d tokens is over the %d cap; dropped the %d oldest items",
        estimator.total(items),
        hard_cap,
        cut - start,
    )
    return llm.ChatContext(trimmed)


async def summarize(
    model: llm.LLM,
    chat_ctx: llm.ChatContext,
    tools: list[Any],
    *,
    timeout: float,
    conn_options: APIConnectOptions | None = None,
) -> str:
    """The text the summarizer wrote; tool calls it makes instead are ignored."""
    kwargs: dict[str, Any] = {"tool_choice": "none"}
    if conn_options is not None:
        kwargs["conn_options"] = conn_options
    parts: list[str] = []
    async with asyncio.timeout(timeout):
        stream = model.chat(chat_ctx=chat_ctx, tools=tools, **kwargs)
        try:
            async for chunk in stream:
                delta = getattr(chunk, "delta", None)
                if delta is not None and delta.content:
                    parts.append(delta.content)
        finally:
            await stream.aclose()
    return "".join(parts).strip()


def warm_request(items: Sequence[Any]) -> llm.ChatContext:
    """What the next turn's request starts with, given the history `items` (cf. warmup_snapshot)."""
    ctx = fold_system_messages(llm.ChatContext(list(items)))
    if not any(isinstance(m, llm.ChatMessage) and m.role == "user" for m in ctx.items):
        ctx.add_message(role="user", content=WARMUP_PLACEHOLDER)
    return ctx


# after a failure, the next attempt waits this long, doubling per failure up to the cap (s)
BACKOFF_BASE = 30.0
BACKOFF_MAX = 600.0
# how long a finished summary may wait for a quiet moment to be swapped in (s)
SWAP_WAIT_MAX = 120.0


class Compactor:
    """Schedules and runs one compaction at a time; see the module docstring."""

    def __init__(
        self,
        *,
        agent: Callable[[], Any],
        summarizer: llm.LLM,
        warm: Callable[[llm.ChatContext, list[Any]], Awaitable[bool]],
        lock: asyncio.Lock,
        quiet: asyncio.Event,
        trigger: int,
        keep: int,
        summary_tokens: int,
        enabled: bool = True,
        estimator: TokenEstimator | None = None,
        turn_idle: Callable[[], Awaitable[Any]] | None = None,
        on_swapped: Callable[[], None] | None = None,
        timeout: float = 120.0,
        conn_options: APIConnectOptions | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        # `summarizer` must not be the session's LLM: the session logs, bills and speaks that one
        self._agent = agent
        self._summarizer = summarizer
        self._warm = warm
        self._lock = lock
        self._quiet = quiet
        self.trigger = trigger
        self.keep = keep
        self.summary_tokens = summary_tokens
        self.enabled = enabled
        self.estimator = estimator or TokenEstimator()
        self._turn_idle = turn_idle
        self._on_swapped = on_swapped
        self._timeout = timeout
        self._conn_options = conn_options
        self._clock = clock
        self._task: asyncio.Task[None] | None = None
        self._failures = 0
        self._next_attempt = 0.0
        self._swapped_pending_log = False
        self.compactions = 0

    # -- called from the session --------------------------------------------------------------

    def note_request(self, chat_ctx: llm.ChatContext) -> None:
        self.estimator.note_request(chat_ctx)

    def on_llm_usage(self, prompt_tokens: int, cached_tokens: int) -> None:
        """A turn's usage: calibrates the estimate and starts a compaction past the trigger."""
        self.estimator.observe_usage(prompt_tokens)
        if self._swapped_pending_log:
            self._swapped_pending_log = False
            logger.info(
                "compaction: first turn after the swap: prompt=%d cached=%d", prompt_tokens, cached_tokens
            )
        if not self.enabled or prompt_tokens < self.trigger:
            return
        if self._task is not None and not self._task.done():
            return
        if self._clock() < self._next_attempt:
            return
        self._task = asyncio.create_task(self._run(prompt_tokens))

    async def aclose(self) -> None:
        task, self._task = self._task, None
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except BaseException:
                pass
        await self._summarizer.aclose()

    # -- the work -----------------------------------------------------------------------------

    async def _run(self, prompt_tokens: int) -> None:
        try:
            ok = await self.compact_once(prompt_tokens)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("compaction failed; the history is unchanged")
            ok = False
        if ok:
            self._failures = 0
            return
        self._failures += 1
        backoff = min(BACKOFF_MAX, BACKOFF_BASE * 2 ** (self._failures - 1))
        self._next_attempt = self._clock() + backoff
        logger.info("compaction: next attempt in %.0fs at the earliest", backoff)

    async def compact_once(self, prompt_tokens: int = 0) -> bool:
        """One compaction. True when the history was compacted (or there was nothing to do)."""
        await self._quiet.wait()
        if self._turn_idle is not None:
            await self._turn_idle()
        agent = self._agent()
        split = split_history(agent.chat_ctx.items, self.keep, self.estimator)
        # Not worth a request unless the summary is much smaller than what it replaces; also
        # keeps a call whose instructions alone are past the trigger from summarizing every turn.
        if split is None or split.head_tokens < 2 * self.summary_tokens:
            logger.info(
                "compaction: nothing worth summarizing (head ~%d tokens)",
                split.head_tokens if split else 0,
            )
            self._next_attempt = self._clock() + BACKOFF_BASE
            return True
        tools = llm.ToolContext(agent.tools).flatten()

        t0 = time.monotonic()
        try:
            text = await summarize(
                self._summarizer,
                summary_request(split),
                tools,
                timeout=self._timeout,
                conn_options=self._conn_options,
            )
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.warning("compaction: summary failed after %.0fms: %s", (time.monotonic() - t0) * 1000, e)
            return False
        summary_ms = (time.monotonic() - t0) * 1000
        if not text:
            logger.warning("compaction: empty summary after %.0fms; history unchanged", summary_ms)
            return False

        self.compactions += 1
        summary = summary_message(text, self.compactions)
        head_ids = split.head_ids
        preview = compacted_items(agent.chat_ctx.items, head_ids, summary.model_copy())
        if preview is None:
            logger.warning("compaction: history was rewritten during the summary; not swapped")
            return False
        t1 = time.monotonic()
        warmed = await self._warm(warm_request(preview), tools)
        warm_ms = (time.monotonic() - t1) * 1000
        if not warmed:
            logger.warning("compaction: warm-up failed after %.0fms; history unchanged", warm_ms)
            return False

        swapped = await self._swap(head_ids, summary)
        if swapped is None:
            logger.warning("compaction: no quiet moment to swap in; history unchanged")
            return False
        if swapped is False:
            logger.warning("compaction: history was rewritten before the swap; not swapped")
            return False
        after = self.estimator.total(self._agent().chat_ctx.items)
        logger.info(
            "compaction: prompt %d -> ~%d tokens; summarized %d items (~%d tokens) into %d chars, "
            "kept %d items (~%d tokens); summary %.0fms, warm-up %.0fms",
            prompt_tokens,
            after,
            len(head_ids),
            split.head_tokens,
            len(text),
            len(split.tail),
            split.tail_tokens,
            summary_ms,
            warm_ms,
        )
        self._swapped_pending_log = True
        if self._on_swapped is not None:
            self._on_swapped()
        return True

    async def _swap(self, head_ids: set[str], summary: llm.ChatMessage) -> bool | None:
        """Swaps under the lock while quiet. None if no quiet moment came, False if stale."""
        try:
            async with asyncio.timeout(SWAP_WAIT_MAX):
                while True:
                    await self._quiet.wait()
                    async with self._lock:
                        # a context update may have held the lock while the user started talking
                        if not self._quiet.is_set():
                            continue
                        agent = self._agent()
                        items = compacted_items(agent.chat_ctx.items, head_ids, summary)
                        if items is None:
                            return False
                        await agent.update_chat_ctx(llm.ChatContext(items))
                        return True
        except TimeoutError:
            return None
