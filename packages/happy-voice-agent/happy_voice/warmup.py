"""Keep the LLM's prefix cache warm for the next turn.

The first reply of a voice session has to prefill the whole system prompt (instructions, tool
schemas and the app's session context, often 20k+ characters). On the shared local model that
took 4-8 s in practice, and far longer when coding agents load the GPU, so users hung up before
the agent answered. A completed request leaves its prefix in vLLM's cache: the same prompt then
costs well under a second. So while the greeting plays, and again after each context update,
send the current history with the turn's tools and stop at the first streamed chunk. The real
turn then only prefills what the user just said.

A warm-up and a turn must not prefill the same prompt side by side: vLLM does not share work
between requests in flight, so both would pay the full prefill, and the coder server runs only
two sequences at a time. So a turn waits for a warm-up already sending (then hits its cache)
and drops one not yet sent, and warm-ups scheduled during a turn wait until it is over.

That wait is bounded by `turn_wait`, not by the LLM timeout. The two are not the same budget:
the LLM timeout (60 s here) bounds a *request*, while this bounds how long the user hears
nothing before their reply is even asked for. A session was observed losing 8.4 s to a warm-up
that was itself 13 s slow, and the user hung up before the turn's own request went out
(`llm_prompt_tokens=0`). Waiting only pays off if the warm-up is nearly done; past that, the
turn should issue its own request, and the warm-up is cancelled rather than left to prefill
alongside it.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable
from typing import Any, TypeVar

from livekit.agents import APIConnectOptions, llm

logger = logging.getLogger("happy-voice")

# The model's chat template rejects a request without a user message; a warm-up made before the
# user first speaks ends with this stand-in for the turn that will follow.
WARMUP_PLACEHOLDER = "(warm-up)"

T = TypeVar("T")


class GaveWay(Exception):
    """A between_turns() request was cancelled because a turn started."""


class PrefixWarmer:
    """Debounced warm-up requests; a newer request supersedes one still in flight."""

    def __init__(
        self,
        model: llm.LLM,
        snapshot: Callable[[], tuple[llm.ChatContext, list[Any]]],
        *,
        debounce: float = 0.3,
        timeout: float = 120.0,
        turn_wait: float = 0.5,
        conn_options: APIConnectOptions | None = None,
    ) -> None:
        # `model` must not be the session's LLM: the session logs and bills that one's metrics.
        self._model = model
        self._snapshot = snapshot
        self._debounce = debounce
        self._timeout = timeout
        # how long a turn may wait for a warm-up already sending; see the module docstring
        self._turn_wait = turn_wait
        # without these the plugin's defaults apply: a 10 s timeout and 3 retries, each retry
        # restarting the prefill
        self._conn_options = conn_options
        self._task: asyncio.Task[None] | None = None
        # The task whose request is out. A task, not a flag: a superseded warm-up is still
        # unwinding its cancellation when the next one is scheduled.
        self._sending: asyncio.Task[None] | None = None
        # when that request went out, so begin_turn can tell a nearly-done warm-up from one
        # that has barely started
        self._sending_since: float = 0.0
        # durations of recent completed warm-ups; their median is how long the next one is
        # expected to take. Short, so it tracks the GPU getting busy rather than averaging a
        # whole session.
        self._durations: list[float] = []
        self._turns = 0
        self._idle = asyncio.Event()
        self._idle.set()
        # requests in flight from between_turns(); a turn cancels them rather than wait
        self._background: set[asyncio.Future[Any]] = set()
        self.completed = 0

    @property
    def _expected(self) -> float | None:
        """Median of recent warm-ups, or None until one has finished."""
        if not self._durations:
            return None
        ordered = sorted(self._durations)
        return ordered[len(ordered) // 2]

    def schedule(self) -> None:
        if self._task is not None and not self._task.done():
            # supersede it, even mid-request: its snapshot is already stale
            self._task.cancel()
        self._task = asyncio.create_task(self._run())

    async def _run(self) -> None:
        await asyncio.sleep(self._debounce)
        await self._idle.wait()  # a turn in progress is prefilling; warm up after it
        started = time.monotonic()
        me = asyncio.current_task()
        self._sending = me
        self._sending_since = started
        try:
            chat_ctx, tools = self._snapshot()
            await self._prefill(chat_ctx, tools)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # a failed warm-up only costs latency; never break the session
            logger.warning("llm warm-up failed after %.0fms: %s", (time.monotonic() - started) * 1000, e)
            return
        finally:
            if self._sending is me:
                self._sending = None
        self.completed += 1
        elapsed = time.monotonic() - started
        self._durations.append(elapsed)
        del self._durations[:-5]
        logger.info("llm warm-up: %.0fms", elapsed * 1000)

    async def _prefill(self, chat_ctx: llm.ChatContext, tools: list[Any]) -> None:
        kwargs: dict[str, Any] = {}
        if self._conn_options is not None:
            kwargs["conn_options"] = self._conn_options
        async with asyncio.timeout(self._timeout):
            stream = self._model.chat(chat_ctx=chat_ctx, tools=tools, **kwargs)
            try:
                async for _ in stream:
                    break  # the first chunk means the prompt is prefilled and cached
            finally:
                await stream.aclose()

    async def wait_idle(self) -> None:
        """Returns once no turn is between begin_turn() and end_turn()."""
        await self._idle.wait()

    async def between_turns(self, request: Callable[[], Awaitable[T]]) -> T:
        """Runs `request()` between turns and returns its result, or raises GaveWay.

        For background requests to the same server that a turn must never wait for: the
        compaction summary, and the prefill of a compacted history. It is sent only once no
        turn is running, and a turn that starts while it is in flight cancels it (begin_turn)
        instead of waiting, which is raised here as GaveWay; the caller decides whether to
        send it again. Its own failures are raised as they are.
        """
        while not self._idle.is_set():  # a turn may begin between the wake-up and this check
            await self._idle.wait()
        task = asyncio.ensure_future(request())
        self._background.add(task)
        try:
            # asyncio.wait: a cancellation by begin_turn() is not raised into the caller
            await asyncio.wait({task})
        except asyncio.CancelledError:
            task.cancel()
            await asyncio.wait({task})
            raise
        finally:
            self._background.discard(task)
        if task.cancelled():
            raise GaveWay()
        return task.result()

    async def warm(self, chat_ctx: llm.ChatContext, tools: list[Any], *, attempts: int = 3) -> bool:
        """Prefills one given prompt and waits for it; True once it is cached.

        For a prompt the history does not hold yet (a compacted history before it is swapped
        in), so it does not go through the debounced snapshot. It is sent between_turns(), and
        once more after each turn it gives way to, up to `attempts` times. Its duration is not
        recorded: it is a different, larger prefill than the warm-ups begin_turn() estimates
        from.
        """
        for _ in range(attempts):
            started = time.monotonic()
            try:
                await self.between_turns(lambda: self._prefill(chat_ctx, tools))
            except GaveWay:
                logger.info("one-shot warm-up gave way to a turn after %.0fms", (time.monotonic() - started) * 1000)
                continue
            except Exception as e:
                logger.warning("one-shot warm-up failed after %.0fms: %s", (time.monotonic() - started) * 1000, e)
                return False
            logger.info("one-shot warm-up: %.0fms", (time.monotonic() - started) * 1000)
            return True
        return False

    async def begin_turn(self) -> None:
        """Called before a turn's LLM request; pair with end_turn().

        Waits up to `turn_wait` for a warm-up that is already sending, so the turn reuses its
        cached prefix instead of prefilling the same prompt next to it, and drops one that has
        not been sent (the turn's own request caches the same prefix). A warm-up still running
        when the budget is up is cancelled: the turn is going out regardless, and leaving the
        warm-up in flight means two prefills of the same prompt on a server with two slots.

        It only waits when the warm-up can plausibly finish in time. Waiting out the whole
        budget and then cancelling is the worst of both -- half a second of dead air and no
        cached prefix to show for it, which is what two turns of the 2026-10-29 session did.
        So if the median recent warm-up says this one still has more than the budget left to
        run, drop it now and let the turn's own request do the caching.
        """
        self._turns += 1
        self._idle.clear()
        for request in self._background:
            # compaction's requests; a turn never waits for compaction
            request.cancel()
        task = self._task
        if task is None or task.done():
            return
        if self._sending is not task:
            # still debouncing or waiting for an earlier turn: it would only wait for this
            # one, which caches the same prefix anyway
            task.cancel()
            return
        waited = time.monotonic()
        expected = self._expected
        if expected is not None:
            remaining = expected - (waited - self._sending_since)
            if remaining > self._turn_wait:
                task.cancel()
                logger.info(
                    "turn dropped the warm-up in flight: ~%.0fms left of a typical %.0fms, "
                    "past the %.0fms budget",
                    remaining * 1000,
                    expected * 1000,
                    self._turn_wait * 1000,
                )
                return
        # asyncio.wait: neither the warm-up's failure nor its cancellation is raised here
        done, _ = await asyncio.wait({task}, timeout=self._turn_wait)
        if not done:
            task.cancel()
        logger.info(
            "turn waited %.0fms for the warm-up in flight (%s)",
            (time.monotonic() - waited) * 1000,
            "finished" if done else "cancelled, budget spent",
        )

    def end_turn(self) -> None:
        self._turns = max(0, self._turns - 1)
        if self._turns == 0:
            self._idle.set()

    async def aclose(self) -> None:
        task, self._task = self._task, None
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except BaseException:
                pass
        # a one-shot warm-up still holds a stream on the model; let it unwind before closing it
        background = list(self._background)
        for request in background:
            request.cancel()
        if background:
            await asyncio.wait(background)
        await self._model.aclose()
