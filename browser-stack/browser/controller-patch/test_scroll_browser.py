"""The scroll patch (happy_live_frames, "scroll") against a real Chromium (make browser-controller-scroll-test).

Runs in the controller image, connected to a throwaway Playwright server in the browser-node image
(HAPPY_SCROLL_TEST_WS); skipped without one. The pages are set with set_content: no network.
"""

from __future__ import annotations

import os
import unittest
from typing import Any

os.environ.setdefault("HAPPY_LIVE_FRAMES_NO_AUTOLOAD", "1")

import happy_live_frames as hlf  # noqa: E402
from app.browser.services.actions import BrowserActionService  # noqa: E402
from app.models import BrowserActionDecision  # noqa: E402

WS = os.environ.get("HAPPY_SCROLL_TEST_WS")
hlf.apply()

# An app shell like Instimate's portal: the document does not scroll; a fixed sidebar at the left
# (where the mouse rests at (0, 0)) and a main pane that scrolls its own content.
INNER = """<!doctype html><html><head><style>
html, body { margin: 0; height: 100%; overflow: hidden; }
.sidebar { position: fixed; left: 0; top: 0; bottom: 0; width: 228px; background: #eee; }
main.app-main { position: absolute; left: 228px; right: 0; top: 0; bottom: 0; overflow-y: auto; }
.content { height: 3000px; position: relative; }
#all { position: absolute; top: 1652px; left: 20px; }
</style></head><body>
<div class="sidebar"><div class="sidebar-brand">Brand</div></div>
<main class="app-main"><div class="content"><p>Top</p><a id="all" href="#">View all estimates</a></div></main>
</body></html>"""

# The same shell with a main pane that swallows wheel events (a custom scroller): only the fallback moves it.
SWALLOW = INNER.replace("</body>", "<script>document.querySelector('main').addEventListener('wheel', (e) => e.preventDefault(), { passive: false });</script></body>")

PLAIN = "<!doctype html><html><body style='margin:0'><div style='height:4000px'>long</div></body></html>"
SHORT = "<!doctype html><html><body><p>short</p></body></html>"


class FakeManager:
    """Just enough manager for the patched scroll: runs the operation and verifies as the pipeline does."""

    def __init__(self, page: Any) -> None:
        self.session = type("S", (), {"page": page})()

    async def get_session(self, session_id: str) -> Any:
        return self.session

    async def _settle(self, page: Any) -> None:
        await page.wait_for_timeout(100)

    async def _run_action(self, session: Any, action_name: str, target: dict[str, Any], operation: Any) -> dict[str, Any]:
        before = {"url": "u", "title": "t", "text_excerpt": "same"}
        await operation()
        after = dict(before)  # a scroll changes none of upstream's signals
        return {"target": target, "verification": BrowserActionService.action_verification(action_name, target, before, after)}


@unittest.skipUnless(WS, "needs HAPPY_SCROLL_TEST_WS (make browser-controller-scroll-test)")
class ScrollBrowserTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        from playwright.async_api import async_playwright

        self.pw = await async_playwright().start()
        self.browser = await self.pw.chromium.connect(WS)
        self.page = await self.browser.new_page(viewport={"width": 1920, "height": 1085})
        self.service = BrowserActionService(FakeManager(self.page))

    async def asyncTearDown(self) -> None:
        await self.browser.close()
        await self.pw.stop()

    async def act(self, html: str, **decision: Any) -> dict[str, Any]:
        await self.page.set_content(html)
        d = BrowserActionDecision(action="scroll", reason="test", **decision)
        return await self.service._dispatch_decision("s", d, approval_id=None)

    async def main_top(self) -> int:
        return await self.page.evaluate("document.querySelector('main').scrollTop")

    async def all_y(self) -> float:
        return await self.page.evaluate("document.getElementById('all').getBoundingClientRect().y")

    async def test_upstream_wheel_at_the_resting_mouse_does_not_move_an_inner_container(self) -> None:
        # The bug as reported: the wheel at (0, 0) lands on the sidebar; nothing scrolls.
        await self.page.set_content(INNER)
        y = await self.all_y()
        await self.page.mouse.wheel(0, 800)
        await self.page.wait_for_timeout(500)
        self.assertEqual(await self.main_top(), 0)
        self.assertEqual(await self.all_y(), y)

    async def test_inner_container_scrolls_and_verifies(self) -> None:
        await self.page.set_content(INNER)
        y = await self.all_y()
        result = await self.act(INNER, delta_y=800)
        report = result["target"]["scroll"]
        self.assertEqual(report["point"], "largest_scroller")
        self.assertEqual(report["method"], "wheel")
        self.assertTrue(report["moved"])
        self.assertGreater(await self.main_top(), 0)
        self.assertLess(await self.all_y(), y - 700)
        self.assertEqual([s["element"] for s in report["scrolled"]], ["main.app-main"])
        self.assertTrue(result["verification"]["verified"])
        self.assertIn(hlf.SCROLL_SIGNAL, result["verification"]["signals"])

    async def test_given_point_is_used(self) -> None:
        result = await self.act(INNER, delta_y=800, x=1000, y=600)
        report = result["target"]["scroll"]
        self.assertEqual((report["x"], report["y"], report["point"]), (1000, 600, "given"))
        self.assertEqual(result["target"]["x"], 1000)
        self.assertTrue(report["moved"])
        self.assertTrue(result["verification"]["verified"])

    async def test_a_point_off_the_viewport_is_clamped(self) -> None:
        result = await self.act(INNER, delta_y=800, x=99999, y=600)
        self.assertEqual(result["target"]["scroll"]["x"], 1919)
        self.assertTrue(result["target"]["scroll"]["moved"])

    async def test_a_given_point_over_nothing_scrollable_reports_not_moved(self) -> None:
        result = await self.act(INNER, delta_y=800, x=50, y=50)
        report = result["target"]["scroll"]
        self.assertFalse(report["moved"])
        self.assertEqual(report["method"], "none")
        self.assertFalse(result["verification"]["verified"])
        self.assertEqual(await self.main_top(), 0)

    async def test_swallowed_wheel_falls_back_to_script(self) -> None:
        result = await self.act(SWALLOW, delta_y=800)
        report = result["target"]["scroll"]
        self.assertEqual(report["method"], "script")
        self.assertEqual(await self.main_top(), 800)
        self.assertTrue(result["verification"]["verified"])

    async def test_scroll_up_after_down(self) -> None:
        await self.act(INNER, delta_y=800)
        d = BrowserActionDecision(action="scroll", reason="test", delta_y=-800)
        result = await self.service._dispatch_decision("s", d, approval_id=None)
        self.assertTrue(result["target"]["scroll"]["moved"])
        self.assertEqual(await self.main_top(), 0)

    async def test_plain_long_page_scrolls_the_document(self) -> None:
        result = await self.act(PLAIN, delta_y=800)
        report = result["target"]["scroll"]
        self.assertEqual(report["point"], "viewport_centre")
        self.assertEqual(report["method"], "wheel")
        self.assertEqual(report["scrolled"][0]["element"], "document")
        self.assertGreater(await self.page.evaluate("scrollY"), 0)
        self.assertTrue(result["verification"]["verified"])

    async def test_page_that_cannot_scroll_is_not_verified(self) -> None:
        result = await self.act(SHORT, delta_y=800)
        report = result["target"]["scroll"]
        self.assertFalse(report["moved"])
        self.assertIn("reason", report)
        self.assertFalse(result["verification"]["verified"])
        self.assertNotIn(hlf.SCROLL_SIGNAL, result["verification"]["signals"])


if __name__ == "__main__":
    unittest.main()
