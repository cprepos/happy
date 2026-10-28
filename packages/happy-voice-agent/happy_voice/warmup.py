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
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable
from typing import Any

from livekit.agents import APIConnectOptions, llm

logger = logging.getLogger("happy-voice")


class PrefixWarmer:
    """Debounced warm-up requests; a newer request supersedes one still in flight."""

    def __init__(
        self,
        model: llm.LLM,
        snapshot: Callable[[], tuple[llm.ChatContext, list[Any]]],
        *,
        debounce: float = 0.3,
        timeout: float = 120.0,
        conn_options: APIConnectOptions | None = None,
    ) -> None:
        # `model` must not be the session's LLM: the session logs and bills that one's metrics.
        self._model = model
        self._snapshot = snapshot
        self._debounce = debounce
        self._timeout = timeout
        # without these the plugin's defaults apply: a 10 s timeout and 3 retries, each retry
        # restarting the prefill
        self._conn_options = conn_options
        self._task: asyncio.Task[None] | None = None
        # The task whose request is out. A task, not a flag: a superseded warm-up is still
        # unwinding its cancellation when the next one is scheduled.
        self._sending: asyncio.Task[None] | None = None
        self._turns = 0
        self._idle = asyncio.Event()
        self._idle.set()
        self.completed = 0

    def schedule(self) -> None:
        if self._task is not None and not self._task.done():
            if self._sending is self._task:
                logger.debug("warmup already sending; keeping it")
                return
            self._task.cancel()
        self._task = asyncio.create_task(self._run())

    async def _run(self) -> None:
        await asyncio.sleep(self._debounce)
        await self._idle.wait()  # a turn in progress is prefilling; warm up after it
        started = time.monotonic()
        me = asyncio.current_task()
        self._sending = me
        try:
            chat_ctx, tools = self._snapshot()
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
        except asyncio.CancelledError:
            raise
        except Exception as e:  # a failed warm-up only costs latency; never break the session
            logger.warning("llm warm-up failed after %.0fms: %s", (time.monotonic() - started) * 1000, e)
            return
        finally:
            if self._sending is me:
                self._sending = None
        self.completed += 1
        logger.info("llm warm-up: %.0fms", (time.monotonic() - started) * 1000)

    async def begin_turn(self) -> None:
        """Called before a turn's LLM request; pair with end_turn().

        Waits for a warm-up that is already sending, so the turn reuses its cached prefix
        instead of prefilling the same prompt next to it, and drops one that has not been sent
        (the turn's own request caches the same prefix).
        """
        self._turns += 1
        self._idle.clear()
        task = self._task
        if task is None or task.done():
            return
        if self._sending is not task:
            # still debouncing or waiting for an earlier turn: it would only wait for this
            # one, which caches the same prefix anyway
            task.cancel()
            return
        waited = time.monotonic()
        # asyncio.wait: neither the warm-up's failure nor its cancellation is raised here
        await asyncio.wait({task}, timeout=self._timeout)
        logger.info("turn waited %.0fms for the warm-up in flight", (time.monotonic() - waited) * 1000)

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
        await self._model.aclose()
