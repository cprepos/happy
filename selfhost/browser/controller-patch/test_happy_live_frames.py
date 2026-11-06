"""Tests for happy_live_frames, run inside the controller image (make browser-patch-test).

python -m unittest test_happy_live_frames, from /app, with this directory on PYTHONPATH and
HAPPY_LIVE_FRAMES_NO_AUTOLOAD=1 (the tests apply the patch themselves).
"""

from __future__ import annotations

import asyncio
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

os.environ.setdefault("HAPPY_LIVE_FRAMES_NO_AUTOLOAD", "1")

import happy_live_frames as hlf  # noqa: E402
from app.browser import page_read  # noqa: E402
from app.browser.page_provenance import PageProvenance  # noqa: E402
from app.browser.services import observation  # noqa: E402
from app.browser.services.observation import SHARE_FRAME_LABEL, BrowserObservationService  # noqa: E402

UPSTREAM_SHARE = BrowserObservationService.share_snapshot
UPSTREAM_LIGHT = BrowserObservationService.light_snapshot
hlf.apply()

RAW = b"RAW-UNSCRUBBED"


class FakePage:
    def __init__(self, artifact_dir: Path) -> None:
        self.url = "https://example.com/one"
        self.artifact_dir = artifact_dir
        self.shots = 0
        self.hang = False
        self.fail = False
        self.seen_in_artifacts: list[list[str]] = []

    async def screenshot(self, *, path: str, full_page: bool = False, timeout: float | None = None) -> bytes:
        self.shots += 1
        if self.hang:
            await asyncio.sleep(30)
        if self.fail:
            raise RuntimeError("Target crashed")
        Path(path).write_bytes(RAW + str(self.shots).encode())
        return b""

    async def title(self) -> str:
        return "Title " + self.url

    async def aria_snapshot(self, **_: object) -> str:
        return ""

    def is_closed(self) -> bool:
        return False


class Scrubber:
    def __init__(self) -> None:
        self.screenshot_enabled = True
        self.screenshot_strict = False
        self.audit_report = False
        self.raise_on_scrub = False
        self.artifact_dir: Path | None = None
        self.raw_visible_during_scrub: list[str] = []

    def screenshot(self, raw: bytes, blocks: list) -> tuple[bytes, list]:
        # While the image is being scrubbed, nothing unscrubbed may sit where a route can serve it.
        if self.artifact_dir is not None:
            for p in self.artifact_dir.glob("*.png"):
                if p.read_bytes().startswith(RAW):
                    self.raw_visible_during_scrub.append(p.name)
        if self.raise_on_scrub:
            raise ValueError("decoder")
        return b"SCRUBBED:" + raw, [{"kind": "email"}]

    def build_audit_report(self, *_: object) -> dict:
        return {}


def make(tmp: Path) -> tuple[BrowserObservationService, SimpleNamespace]:
    artifact_dir = tmp / "artifacts" / "s1"
    artifact_dir.mkdir(parents=True)
    page = FakePage(artifact_dir)
    session = SimpleNamespace(id="s1", artifact_dir=artifact_dir, lock=asyncio.Lock(), page=page, last_screenshot=None)
    scrubber = Scrubber()
    scrubber.artifact_dir = artifact_dir
    counter = {"n": 0}

    async def capture(target: SimpleNamespace, label: str) -> dict[str, str]:
        counter["n"] += 1
        path = target.artifact_dir / f"20260101T00000{counter['n']:03d}Z-{label}.png"
        path.write_bytes(RAW + b"locked")
        return {"path": str(path), "url": f"/artifacts/s1/{path.name}"}

    manager = SimpleNamespace(
        get_session=AsyncMock(return_value=session),
        _capture_screenshot=AsyncMock(side_effect=capture),
        _assert_page_allowed=MagicMock(),
        _page_refused=MagicMock(return_value=False),
        page_provenance=PageProvenance(),
        pii_scrubber=scrubber,
        ocr=SimpleNamespace(
            extract_from_image=AsyncMock(return_value={"available": True, "redaction_blocks": [{"text": "x"}]})
        ),
        settings=SimpleNamespace(pii_scrub_action_screenshots=True),
        element_ids=SimpleNamespace(evaluate=AsyncMock(return_value={"title": "Light"})),
    )
    return BrowserObservationService(manager=manager), session


def scrubbed(path: str) -> bool:
    return Path(path).read_bytes().startswith(b"SCRUBBED:")


class Base(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.service, self.session = make(self.tmp)
        self.page = self.session.page
        self.scrubber = self.service.manager.pii_scrubber

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def artifact_pngs(self) -> list[Path]:
        return sorted(Path(self.session.artifact_dir).glob("*.png"))

    def assert_nothing_raw_served(self) -> None:
        for p in self.artifact_pngs():
            self.assertFalse(p.read_bytes().startswith(RAW), f"unscrubbed image in the artifact dir: {p.name}")
        self.assertEqual(self.scrubber.raw_visible_during_scrub, [])


class VerifyTests(unittest.TestCase):
    def test_the_image_is_the_pinned_one(self) -> None:
        hlf.verify()

    def _copy_app(self) -> Path:
        import app as pkg

        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        shutil.copytree(Path(pkg.__file__).parent, tmp / "app", ignore=shutil.ignore_patterns("__pycache__"))
        return tmp / "app"

    def test_another_version_is_refused(self) -> None:
        app_dir = self._copy_app()
        (app_dir / "version.py").write_text('__version__ = "1.15.0"\n')
        with self.assertRaisesRegex(hlf.PatchMismatch, "1.15.0"):
            hlf.verify(app_dir)

    def test_a_changed_file_is_refused(self) -> None:
        for rel in hlf.EXPECTED_SHA256:
            app_dir = self._copy_app()
            with open(app_dir / rel, "a") as fh:
                fh.write("\n# changed\n")
            with self.assertRaisesRegex(hlf.PatchMismatch, rel):
                hlf.verify(app_dir)


class LockFreeTests(Base):
    async def test_takes_the_lock_serves_a_scrubbed_frame_and_caches_it(self) -> None:
        result = await self.service.share_snapshot("s1")
        self.assertTrue(scrubbed(result["screenshot_path"]))
        self.assertEqual(result["title"], "Title https://example.com/one")
        self.assertEqual(getattr(self.session, hlf._FRAME_ATTR).path, result["screenshot_path"])
        self.assertEqual(self.page.shots, 1)
        self.assertIsNone(self.session.last_screenshot)
        self.assert_nothing_raw_served()

    async def test_holds_the_lock_while_it_captures(self) -> None:
        seen = []
        original = self.page.screenshot

        async def shot(**kw: object) -> bytes:
            seen.append(self.session.lock.locked())
            return await original(**kw)

        self.page.screenshot = shot
        await self.service.share_snapshot("s1")
        self.assertEqual(seen, [True])
        self.assertFalse(self.session.lock.locked())

    async def test_an_unscrubbed_frame_is_deleted_not_served(self) -> None:
        self.service.manager.ocr.extract_from_image.return_value = {"available": False, "error": "tesseract_not_found"}
        with self.assertRaises(RuntimeError):
            await self.service.share_snapshot("s1")
        self.assertEqual(self.artifact_pngs(), [])
        self.assertIsNone(getattr(self.session, hlf._FRAME_ATTR, None))

    async def test_an_unscrubbed_frame_falls_back_to_the_last_scrubbed_one(self) -> None:
        first = await self.service.share_snapshot("s1")
        self.service.manager.ocr.extract_from_image.return_value = {"available": False, "error": "tesseract_not_found"}
        second = await self.service.share_snapshot("s1")
        self.assertEqual(second["screenshot_path"], first["screenshot_path"])
        self.assert_nothing_raw_served()

    async def test_scrubbing_off_is_upstream_unchanged(self) -> None:
        self.scrubber.screenshot_enabled = False
        await self.session.lock.acquire()
        poll = asyncio.ensure_future(self.service.share_snapshot("s1"))
        await asyncio.sleep(0.2)
        self.assertFalse(poll.done(), "with scrubbing off the poll waits for the lock, as upstream")
        self.assertEqual(self.page.shots, 0)
        self.session.lock.release()
        await poll


class HeldLockTests(Base):
    async def asyncSetUp(self) -> None:
        await self.session.lock.acquire()  # an action holds the session

    async def asyncTearDown(self) -> None:
        if self.session.lock.locked():
            self.session.lock.release()
        task = getattr(self.session, hlf._TASK_ATTR, None)
        if task is not None and not task.done():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def test_a_poll_does_not_wait_for_the_action(self) -> None:
        result = await asyncio.wait_for(self.service.share_snapshot("s1"), timeout=1.0)
        self.assertTrue(scrubbed(result["screenshot_path"]))
        self.assertEqual(Path(result["screenshot_path"]).parent, Path(self.session.artifact_dir))
        self.assertTrue(result["screenshot_path"].endswith(f"-{SHARE_FRAME_LABEL}.png"))
        self.assertEqual(self.page.shots, 1)
        self.assertIsNone(self.session.last_screenshot)  # the agent's last screenshot is not touched
        self.assert_nothing_raw_served()

    async def test_follows_navigation_while_the_lock_is_held(self) -> None:
        first = await self.service.share_snapshot("s1")
        self.page.url = "https://example.com/two"
        await asyncio.sleep(hlf.MIN_CAPTURE_INTERVAL_SECONDS + 0.05)
        second = await self.service.share_snapshot("s1")
        self.assertNotEqual(first["screenshot_path"], second["screenshot_path"])
        self.assertEqual(second["url"], "https://example.com/two")
        self.assertEqual(second["title"], "Title https://example.com/two")

    async def test_raw_capture_never_lands_in_the_artifact_dir(self) -> None:
        self.scrubber.screenshot = MagicMock(side_effect=self.scrubber.screenshot)
        await self.service.share_snapshot("s1")
        self.assert_nothing_raw_served()
        pending = hlf._pending_dir(self.session)
        self.assertFalse(str(pending).startswith(str(self.tmp / "artifacts")))
        self.assertEqual(list(pending.iterdir()), [])

    async def test_ocr_unavailable_serves_the_cached_frame_never_the_raw_one(self) -> None:
        cached = await self.service.share_snapshot("s1")
        self.service.manager.ocr.extract_from_image.return_value = {"available": False, "error": "x"}
        await asyncio.sleep(hlf.MIN_CAPTURE_INTERVAL_SECONDS + 0.05)
        again = await self.service.share_snapshot("s1")
        self.assertEqual(again["screenshot_path"], cached["screenshot_path"])
        self.assertEqual(self.page.shots, 2)
        self.assert_nothing_raw_served()
        self.assertEqual(list(hlf._pending_dir(self.session).iterdir()), [])

    async def test_ocr_unavailable_with_no_cache_is_an_error(self) -> None:
        self.service.manager.ocr.extract_from_image.return_value = {"available": False, "error": "x"}
        with self.assertRaises(RuntimeError):
            await self.service.share_snapshot("s1")
        self.assertEqual(self.artifact_pngs(), [])

    async def test_scrubbing_off_mid_action_does_nothing_new(self) -> None:
        self.scrubber.screenshot_enabled = False
        poll = asyncio.ensure_future(self.service.share_snapshot("s1"))
        await asyncio.sleep(0.2)
        self.assertFalse(poll.done())
        self.assertEqual(self.page.shots, 0)
        poll.cancel()
        await asyncio.gather(poll, return_exceptions=True)

    async def test_a_failed_redaction_is_not_served(self) -> None:
        cached = await self.service.share_snapshot("s1")
        self.scrubber.raise_on_scrub = True
        await asyncio.sleep(hlf.MIN_CAPTURE_INTERVAL_SECONDS + 0.05)
        again = await self.service.share_snapshot("s1")
        self.assertEqual(again["screenshot_path"], cached["screenshot_path"])
        self.assertEqual(self.page.shots, 2)
        self.assert_nothing_raw_served()

    async def test_strict_withhold_is_not_served(self) -> None:
        self.scrubber.screenshot_strict = True
        self.scrubber.raise_on_scrub = True
        with self.assertRaises(RuntimeError):
            await self.service.share_snapshot("s1")
        self.assert_nothing_raw_served()

    async def test_a_stuck_capture_serves_the_cached_frame(self) -> None:
        cached = await self.service.share_snapshot("s1")
        self.page.hang = True
        original = hlf.HELD_WAIT_SECONDS
        hlf_module_globals = hlf.build.__globals__
        hlf_module_globals["HELD_WAIT_SECONDS"] = 0.2
        try:
            await asyncio.sleep(hlf.MIN_CAPTURE_INTERVAL_SECONDS + 0.05)
            again = await asyncio.wait_for(self.service.share_snapshot("s1"), timeout=1.0)
        finally:
            hlf_module_globals["HELD_WAIT_SECONDS"] = original
        self.assertEqual(again["screenshot_path"], cached["screenshot_path"])

    async def test_a_failed_screenshot_serves_the_cached_frame(self) -> None:
        cached = await self.service.share_snapshot("s1")
        self.page.fail = True
        await asyncio.sleep(hlf.MIN_CAPTURE_INTERVAL_SECONDS + 0.05)
        again = await self.service.share_snapshot("s1")
        self.assertEqual(again["screenshot_path"], cached["screenshot_path"])

    async def test_concurrent_polls_share_one_capture(self) -> None:
        results = await asyncio.gather(*(self.service.share_snapshot("s1") for _ in range(5)))
        self.assertEqual(self.page.shots, 1)
        self.assertEqual(len({r["screenshot_path"] for r in results}), 1)

    async def test_a_refused_page_is_refused_and_the_cache_dropped(self) -> None:
        await self.service.share_snapshot("s1")
        self.service.manager._assert_page_allowed.side_effect = PermissionError("refused")
        with self.assertRaises(PermissionError):
            await self.service.share_snapshot("s1")

    async def test_a_page_that_moves_during_the_capture_is_refused(self) -> None:
        refused = {"now": False}
        self.service.manager._page_refused.side_effect = lambda page: refused["now"]
        original = self.page.screenshot

        async def moving(**kw: object) -> bytes:
            out = await original(**kw)
            refused["now"] = True
            return out

        self.page.screenshot = moving
        with self.assertRaises(PermissionError):
            await self.service.share_snapshot("s1")
        self.assertIsNone(getattr(self.session, hlf._FRAME_ATTR, None))
        self.assertEqual(self.artifact_pngs(), [])
        self.assertEqual(list(hlf._pending_dir(self.session).iterdir()), [])


class LightSnapshotTests(Base):
    async def test_a_redacted_action_snapshot_becomes_the_live_frame(self) -> None:
        result = await self.service.light_snapshot(self.session, label="before-click")
        frame = getattr(self.session, hlf._FRAME_ATTR)
        self.assertNotEqual(frame.path, result["screenshot_path"])  # a copy, pruned with share frames
        self.assertTrue(frame.path.endswith(f"-{SHARE_FRAME_LABEL}.png"))
        self.assertTrue(scrubbed(frame.path))
        self.assertEqual(frame.title, "Light")
        # And a held-lock poll that finds the capture failing serves it.
        await self.session.lock.acquire()
        try:
            self.page.fail = True
            snap = await self.service.share_snapshot("s1")
        finally:
            self.session.lock.release()
        self.assertEqual(snap["screenshot_path"], frame.path)

    async def test_an_unscrubbed_action_snapshot_is_not_kept(self) -> None:
        self.service.manager.ocr.extract_from_image.return_value = {"available": False, "error": "x"}
        await self.service.light_snapshot(self.session, label="before-click")
        self.assertIsNone(getattr(self.session, hlf._FRAME_ATTR, None))

    async def test_action_snapshots_left_unredacted_by_setting_are_not_kept(self) -> None:
        self.service.manager.settings.pii_scrub_action_screenshots = False
        await self.service.light_snapshot(self.session, label="before-click")
        self.assertIsNone(getattr(self.session, hlf._FRAME_ATTR, None))

    async def test_the_result_is_upstreams(self) -> None:
        patched = await self.service.light_snapshot(self.session, label="before-click")
        plain = await UPSTREAM_LIGHT(self.service, self.session, label="before-click")
        self.assertEqual(set(patched), set(plain))


if __name__ == "__main__":
    unittest.main()
