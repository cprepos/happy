"""Keep the LLM's prefix cache warm for the next turn.

The first reply of a voice session has to prefill the whole system prompt (instructions, tool
schemas and the app's session context, often 20k+ characters). On the shared local model that
took 4-8 s in practice, and far longer when coding agents load the GPU, so users hung up before
the agent answered. A completed request leaves its prefix in vLLM's cache: the same prompt then
costs well under a second. So while the greeting plays, and again after each context update,
send the current history with the turn's tools and stop at the first streamed chunk. The real
turn then only prefills what the user just said.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable
from typing import Any

from livekit.agents import llm

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
    ) -> None:
        # `model` must not be the session's LLM: the session logs and bills that one's metrics.
        self._model = model
        self._snapshot = snapshot
        self._debounce = debounce
        self._timeout = timeout
        self._task: asyncio.Task[None] | None = None
        self.completed = 0

    def schedule(self) -> None:
        if self._task is not None and not self._task.done():
            self._task.cancel()
        self._task = asyncio.create_task(self._run())

    async def _run(self) -> None:
        await asyncio.sleep(self._debounce)
        started = time.monotonic()
        try:
            chat_ctx, tools = self._snapshot()
            async with asyncio.timeout(self._timeout):
                stream = self._model.chat(chat_ctx=chat_ctx, tools=tools)
                try:
                    async for _ in stream:
                        break  # the first chunk means the prompt is prefilled and cached
                finally:
                    await stream.aclose()
        except asyncio.CancelledError:
            raise
        except Exception as e:  # a failed warm-up only costs latency; never break the session
            logger.warning("llm warm-up failed: %s", e)
            return
        self.completed += 1
        logger.info("llm warm-up: %.0fms", (time.monotonic() - started) * 1000)

    async def aclose(self) -> None:
        task, self._task = self._task, None
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except BaseException:
                pass
        await self._model.aclose()
