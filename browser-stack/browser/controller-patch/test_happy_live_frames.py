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

    async def bring_to_front(self) -> None:
        self.fronted = getattr(self, "fronted", 0) + 1
        self.visibility = "visible"

    async def evaluate(self, script: str) -> dict:
        assert "visibilityState" in script and "outerHeight" in script
        # A maximized 1920x1200 window at (0, 0) with 120 px of browser UI above the page.
        geometry = getattr(self, "geometry", None)
        if geometry is None:
            geometry = {"screenX": 0, "screenY": 0, "outerWidth": 1920, "outerHeight": 1200,
                        "innerWidth": 1920, "innerHeight": 1080, "dpr": 1}
        return {"visibility": getattr(self, "visibility", "visible"), **geometry}


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


def png(width: int = 1920, height: int = 1200, tail: bytes = b"") -> bytes:
    import struct

    return hlf.PNG_SIGNATURE + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", width, height) + b"\x08\x02\x00\x00\x00" + tail


class ScreenTests(Base):
    def setUp(self) -> None:
        super().setUp()
        m = self.service.manager
        m.observation = self.service
        m._shown_url = lambda page: page.url
        counter = {"n": 0}

        def target(session: SimpleNamespace, label: str) -> dict[str, str]:
            counter["n"] += 1
            name = f"20260101T00000{counter['n']:03d}Z-{label}.png"
            return {"path": str(Path(session.artifact_dir) / name), "url": f"/artifacts/{session.id}/{name}"}

        m.artifacts = SimpleNamespace(screenshot_target=target)
        m.audit = SimpleNamespace(append=AsyncMock())
        # The scrubber sees PNGs here, so it marks them by what it was handed, not by RAW.
        self.scrubbed_blocks: list = []

        def scrub(raw: bytes, blocks: list) -> tuple[bytes, list]:
            self.scrubbed_blocks.append(blocks)
            return raw + b"SCRUBBED", [{"kind": "email"}]

        self.scrubber.screenshot = scrub

    async def shoot(self, redact: bool = True, **kw: object) -> dict:
        front = await hlf.screen_front(self.service.manager, "s1", redact=redact, **kw)
        return await hlf.screen_scrub(
            self.service.manager, "s1", token=front["token"], png=png(), label="evidence 1", redact=redact
        )

    def audits(self) -> list[dict]:
        return [c.kwargs for c in self.service.manager.audit.append.call_args_list]

    @staticmethod
    def word(text: str, x: int, y: int, w: int = 80, h: int = 14) -> dict:
        return {"text": text, "bbox": {"x": x, "y": y, "width": w, "height": h}, "line": [1, 1, 1]}

    async def test_the_address_bar_is_never_redacted_and_the_page_is(self) -> None:
        url_word = self.word("user@example.com", 300, 60)  # in the address bar
        tab_word = self.word("Inbox", 40, 10)  # in the tab strip
        page_word = self.word("jane@example.com", 300, 400)  # in the page
        straddling = self.word("x@y.z", 300, 110, h=30)  # reaches into the page: stays
        self.service.manager.ocr.extract_from_image.return_value = {
            "available": True,
            "redaction_blocks": [url_word, tab_word, page_word, straddling],
            "blocks": [url_word, page_word],
        }
        seen_ocr = []
        real = self.service._scrub_screenshot_if_needed

        async def spy(session, shot, ocr):
            seen_ocr.append(ocr)
            return await real(session, shot, ocr)

        self.service._scrub_screenshot_if_needed = spy
        out = await self.shoot()
        self.assertEqual(out["chrome_strip"], {"x": 0, "y": 0, "width": 1920, "height": 120, "source": "window"})
        self.assertEqual(seen_ocr[0]["redaction_blocks"], [page_word, straddling])
        self.assertEqual(seen_ocr[0]["blocks"], [page_word])
        self.assertEqual(self.scrubbed_blocks, [[page_word, straddling]])
        self.assertEqual((out["redaction"], out["pii_scrubbed"]), ("on", True))

    async def test_only_the_address_bar_words_means_nothing_to_redact(self) -> None:
        # With every word in the strip, redaction must not fall back to the unfiltered "blocks".
        url_word = self.word("user@example.com", 300, 60)
        self.service.manager.ocr.extract_from_image.return_value = {
            "available": True, "redaction_blocks": [url_word], "blocks": [url_word]
        }
        out = await self.shoot()
        self.assertEqual(self.scrubbed_blocks, [])
        self.assertTrue(out["pii_scrubbed"])

    def test_the_strip_follows_the_window(self) -> None:
        g = {"screenX": 100, "screenY": 50, "outerWidth": 800, "outerHeight": 600,
             "innerWidth": 800, "innerHeight": 500, "dpr": 2}
        self.assertEqual(
            hlf.chrome_strip(hlf._geometry(g), 3840, 2400),
            {"x": 200, "y": 100, "width": 1600, "height": 200, "source": "window"},
        )
        for bad in (None, {**g, "dpr": None}, {**g, "innerHeight": 600}, {**g, "innerHeight": -1000}):
            strip = hlf.chrome_strip(hlf._geometry(bad) if bad else None, 1920, 1200)
            self.assertEqual(strip, {"x": 0, "y": 0, "width": 1920, "height": hlf.CHROME_STRIP_FALLBACK_PX, "source": "fallback"})

    async def test_a_window_that_moved_between_the_steps_is_refused(self) -> None:
        front = await hlf.screen_front(self.service.manager, "s1")
        self.page.geometry = {"screenX": 0, "screenY": 0, "outerWidth": 1920, "outerHeight": 1200,
                              "innerWidth": 1920, "innerHeight": 1000, "dpr": 1}
        with self.assertRaises(hlf.ScreenRefused) as cm:
            await hlf.screen_scrub(self.service.manager, "s1", token=front["token"], png=png())
        self.assertEqual(cm.exception.code, "moved")
        self.assertEqual(self.artifact_pngs(), [])

    async def test_redact_false_files_the_capture_as_it_was_and_audits_it(self) -> None:
        out = await self.shoot(redact=False)
        self.assertEqual((out["pii_scrubbed"], out["redaction"]), (False, "off_by_request"))
        self.assertEqual(Path(out["screenshot_path"]).read_bytes(), png())
        self.service.manager.ocr.extract_from_image.assert_not_called()
        [audit] = self.audits()
        self.assertEqual(audit["event_type"], "evidence_screenshot")
        self.assertEqual(audit["details"]["redacted"], False)
        self.assertEqual(audit["details"]["redaction"], "off_by_request")
        self.assertEqual(audit["details"]["scope"], "screen")
        self.assertEqual(audit["details"]["screenshot_url"], out["screenshot_url"])

    async def test_a_redacted_shot_is_audited_as_redacted(self) -> None:
        await self.shoot()
        [audit] = self.audits()
        self.assertEqual((audit["details"]["redacted"], audit["details"]["redaction"]), (True, "on"))

    async def test_strict_mode_refuses_redact_false_at_both_steps(self) -> None:
        front = await hlf.screen_front(self.service.manager, "s1", redact=False)
        self.scrubber.screenshot_strict = True
        for call in (
            lambda: hlf.screen_front(self.service.manager, "s1", redact=False),
            lambda: hlf.screen_scrub(self.service.manager, "s1", token=front["token"], png=png(), redact=False),
        ):
            with self.assertRaises(hlf.ScreenRefused) as cm:
                await call()
            self.assertEqual((cm.exception.status, cm.exception.code), (403, "redaction_required"))
        self.assertEqual(self.artifact_pngs(), [])

    async def test_an_unredacted_shot_that_cannot_be_audited_is_not_kept(self) -> None:
        self.service.manager.audit.append.side_effect = OSError("disk")
        with self.assertRaises(hlf.ScreenRefused) as cm:
            await self.shoot(redact=False)
        self.assertEqual(cm.exception.code, "audit_failed")
        self.assertEqual(self.artifact_pngs(), [])
        self.assertEqual(list(hlf._pending_dir(self.session).iterdir()), [])
        # A redacted one is kept: the audit is its record, not its permission.
        out = await self.shoot()
        self.assertTrue(Path(out["screenshot_path"]).is_file())

    async def page_setup(self) -> None:
        m = self.service.manager

        async def raw(session, label):
            path = Path(session.artifact_dir) / f"20260101T000000Z-{label}.png"
            path.write_bytes(png(1280, 800))
            return {"path": str(path), "url": f"/artifacts/s1/{path.name}"}

        m._capture_screenshot = AsyncMock(side_effect=raw)

    async def test_page_shot_redacts_by_default_and_not_on_request(self) -> None:
        await self.page_setup()
        out = await hlf.page_shot(self.service.manager, "s1", label="p")
        self.assertEqual((out["redaction"], out["pii_scrubbed"], out["width"]), ("on", True, 1280))
        self.service.manager.ocr.extract_from_image.assert_called_once()
        self.service.manager.ocr.extract_from_image.reset_mock()
        out = await hlf.page_shot(self.service.manager, "s1", label="p", redact=False)
        self.assertEqual((out["redaction"], out["pii_scrubbed"]), ("off_by_request", False))
        self.assertEqual(Path(out["screenshot_path"]).read_bytes(), png(1280, 800))
        self.service.manager.ocr.extract_from_image.assert_not_called()
        self.assertEqual([a["details"]["redaction"] for a in self.audits()], ["on", "off_by_request"])
        self.assertEqual({a["details"]["scope"] for a in self.audits()}, {"page"})
        self.assertFalse(self.session.lock.locked())

    async def test_page_shot_refusals(self) -> None:
        await self.page_setup()
        self.scrubber.screenshot_strict = True
        with self.assertRaises(hlf.ScreenRefused) as cm:
            await hlf.page_shot(self.service.manager, "s1", redact=False)
        self.assertEqual(cm.exception.code, "redaction_required")
        self.scrubber.screenshot_strict = False

        async def moving(session, label):
            path = Path(session.artifact_dir) / "20260101T000000Z-moved.png"
            path.write_bytes(png())
            session.page = FakePage(session.artifact_dir)  # another tab meanwhile
            return {"path": str(path), "url": "/artifacts/s1/x.png"}

        self.service.manager._capture_screenshot = AsyncMock(side_effect=moving)
        with self.assertRaises(PermissionError):
            await hlf.page_shot(self.service.manager, "s1", redact=False)
        self.assertEqual(self.artifact_pngs(), [])
        self.assertFalse(self.session.lock.locked())

    async def test_brings_the_tab_forward_and_files_a_scrubbed_artifact(self) -> None:
        self.page.visibility = "hidden"
        out = await self.shoot()
        self.assertEqual(self.page.fronted, 1)
        self.assertEqual(out["url"], "https://example.com/one")
        self.assertEqual(out["title"], "Title https://example.com/one")
        self.assertEqual((out["width"], out["height"]), (1920, 1200))
        self.assertTrue(out["pii_scrubbed"])
        self.assertNotIn("screenshot_pii_scrub", out)
        self.assertTrue(out["screenshot_path"].endswith("Z-screen-evidence-1.png"))
        self.assertEqual(out["screenshot_url"], "/artifacts/s1/" + Path(out["screenshot_path"]).name)
        data = Path(out["screenshot_path"]).read_bytes()
        self.assertTrue(data.endswith(b"SCRUBBED"))
        import base64

        self.assertEqual(base64.b64decode(out["png"]), data)
        self.assertEqual(list(hlf._pending_dir(self.session).iterdir()), [])
        self.assertFalse(self.session.lock.locked())
        self.assertIsNone(self.session.last_screenshot)

    async def test_ocr_reads_the_image_outside_the_artifact_tree(self) -> None:
        seen = []
        self.service.manager.ocr.extract_from_image.side_effect = lambda path: seen.append(path) or {
            "available": True, "redaction_blocks": [{"text": "x"}]
        }
        await self.shoot()
        self.assertEqual(len(seen), 1)
        self.assertFalse(Path(seen[0]).is_relative_to(self.session.artifact_dir))

    async def test_without_activate_a_tab_not_in_front_is_refused(self) -> None:
        self.page.visibility = "hidden"
        with self.assertRaises(hlf.ScreenRefused) as cm:
            await hlf.screen_front(self.service.manager, "s1", activate=False)
        self.assertEqual(cm.exception.code, "not_in_front")
        self.assertEqual(getattr(self.page, "fronted", 0), 0)
        self.assertFalse(self.session.lock.locked())

    async def test_a_tab_that_will_not_come_forward_is_refused(self) -> None:
        async def stuck() -> None:
            self.page.visibility = "hidden"

        self.page.bring_to_front = stuck
        with self.assertRaises(hlf.ScreenRefused) as cm:
            await hlf.screen_front(self.service.manager, "s1")
        self.assertEqual(cm.exception.code, "not_in_front")

    async def test_a_page_that_navigated_meanwhile_is_refused_and_nothing_filed(self) -> None:
        front = await hlf.screen_front(self.service.manager, "s1")
        self.page.url = "https://example.com/two"
        with self.assertRaises(hlf.ScreenRefused) as cm:
            await hlf.screen_scrub(self.service.manager, "s1", token=front["token"], png=png())
        self.assertEqual(cm.exception.code, "moved")
        self.assertEqual(self.artifact_pngs(), [])

    async def test_another_tab_meanwhile_is_refused(self) -> None:
        front = await hlf.screen_front(self.service.manager, "s1")
        self.session.page = FakePage(self.session.artifact_dir)
        with self.assertRaises(PermissionError):
            await hlf.screen_scrub(self.service.manager, "s1", token=front["token"], png=png())
        self.assertEqual(self.artifact_pngs(), [])

    async def test_a_page_refused_meanwhile_is_refused(self) -> None:
        front = await hlf.screen_front(self.service.manager, "s1")
        self.service.manager._page_refused.return_value = True
        with self.assertRaises(PermissionError):
            await hlf.screen_scrub(self.service.manager, "s1", token=front["token"], png=png())
        self.assertEqual(self.artifact_pngs(), [])

    async def test_a_page_refused_while_it_is_scrubbed_is_refused_and_the_image_deleted(self) -> None:
        front = await hlf.screen_front(self.service.manager, "s1")

        def ocr(path: str) -> dict:
            self.service.manager._page_refused.return_value = True
            return {"available": True, "redaction_blocks": [{"text": "x"}]}

        self.service.manager.ocr.extract_from_image.side_effect = ocr
        with self.assertRaises(PermissionError):
            await hlf.screen_scrub(self.service.manager, "s1", token=front["token"], png=png())
        self.assertEqual(self.artifact_pngs(), [])
        self.assertEqual(list(hlf._pending_dir(self.session).iterdir()), [])
        self.assertFalse(self.session.lock.locked())

    async def test_a_refused_page_is_never_brought_forward(self) -> None:
        self.service.manager._assert_page_allowed.side_effect = PermissionError("refused")
        with self.assertRaises(PermissionError):
            await hlf.screen_front(self.service.manager, "s1")
        self.assertEqual(getattr(self.page, "fronted", 0), 0)

    async def test_a_token_is_used_once_and_expires(self) -> None:
        front = await hlf.screen_front(self.service.manager, "s1")
        await hlf.screen_scrub(self.service.manager, "s1", token=front["token"], png=png())
        with self.assertRaises(hlf.ScreenRefused) as cm:
            await hlf.screen_scrub(self.service.manager, "s1", token=front["token"], png=png())
        self.assertEqual(cm.exception.code, "stale")
        front = await hlf.screen_front(self.service.manager, "s1")
        getattr(self.session, hlf.SCREEN_TOKEN_ATTR)[front["token"]]["at"] -= hlf.SCREEN_TOKEN_SECONDS + 1
        with self.assertRaises(hlf.ScreenRefused) as cm:
            await hlf.screen_scrub(self.service.manager, "s1", token=front["token"], png=png())
        self.assertEqual(cm.exception.code, "stale")

    async def test_not_a_png_is_refused(self) -> None:
        front = await hlf.screen_front(self.service.manager, "s1")
        with self.assertRaises(hlf.ScreenRefused) as cm:
            await hlf.screen_scrub(self.service.manager, "s1", token=front["token"], png=b"GIF89a....")
        self.assertEqual(cm.exception.code, "bad_image")

    async def test_ocr_unavailable_is_disclosed_and_strict_withholds(self) -> None:
        self.service.manager.ocr.extract_from_image.return_value = {"available": False, "error": "tesseract_not_found"}
        out = await self.shoot()
        self.assertFalse(out["pii_scrubbed"])
        self.assertEqual(out["screenshot_pii_scrub"], {"applied": False, "reason": "tesseract_not_found"})
        self.scrubber.screenshot_strict = True
        before = self.artifact_pngs()
        with self.assertRaises(Exception) as cm:
            await self.shoot()
        self.assertIn("withheld", str(cm.exception))
        self.assertEqual(self.artifact_pngs(), before)
        self.assertEqual(list(hlf._pending_dir(self.session).iterdir()), [])
        self.assertFalse(self.session.lock.locked())

    async def test_scrubbing_off_files_the_capture_as_is(self) -> None:
        self.scrubber.screenshot_enabled = False
        out = await self.shoot()
        self.assertFalse(out["pii_scrubbed"])
        self.assertEqual(Path(out["screenshot_path"]).read_bytes(), png())
        self.service.manager.ocr.extract_from_image.assert_not_called()

    def test_the_routes(self) -> None:
        import base64

        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        application = FastAPI()
        hlf.install_routes(application, self.service.manager)
        client = TestClient(application)
        front = client.post("/happy/sessions/s1/screen/front", json={"activate": True})
        self.assertEqual(front.status_code, 200)
        token = front.json()["token"]
        bad = client.post("/happy/sessions/s1/screen/scrub", json={"token": token, "png": "%%%"})
        self.assertEqual((bad.status_code, bad.json()["code"]), (400, "bad_request"))
        ok = client.post(
            "/happy/sessions/s1/screen/scrub",
            json={"token": token, "png": base64.b64encode(png()).decode(), "label": "x"},
        )
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(ok.json()["url"], "https://example.com/one")
        again = client.post(
            "/happy/sessions/s1/screen/scrub", json={"token": token, "png": base64.b64encode(png()).decode()}
        )
        self.assertEqual((again.status_code, again.json()["code"]), (409, "stale"))
        self.page.visibility = "hidden"
        held = client.post("/happy/sessions/s1/screen/front", json={"activate": False})
        self.assertEqual((held.status_code, held.json()["code"]), (409, "not_in_front"))
        self.page.visibility = "visible"
        front = client.post("/happy/sessions/s1/screen/front", json={"redact": False}).json()
        raw = client.post(
            "/happy/sessions/s1/screen/scrub",
            json={"token": front["token"], "png": base64.b64encode(png()).decode(), "redact": False},
        )
        self.assertEqual(raw.json()["redaction"], "off_by_request")
        bad = client.post("/happy/sessions/s1/screen/scrub", json={"token": "t", "png": "", "redact": "no"})
        self.assertEqual((bad.status_code, bad.json()["code"]), (400, "bad_request"))
        self.scrubber.screenshot_strict = True
        strict = client.post("/happy/sessions/s1/screen/front", json={"redact": False})
        self.assertEqual((strict.status_code, strict.json()["code"]), (403, "redaction_required"))
        strict = client.post("/happy/sessions/s1/page-shot", json={"redact": False})
        self.assertEqual((strict.status_code, strict.json()["code"]), (403, "redaction_required"))
        self.scrubber.screenshot_strict = False
        bad = client.post("/happy/sessions/s1/page-shot", json={"redact": 0})
        self.assertEqual((bad.status_code, bad.json()["code"]), (400, "bad_request"))
        self.service.manager._assert_page_allowed.side_effect = PermissionError("refused")
        refused = client.post("/happy/sessions/s1/screen/front", json={})
        self.assertEqual((refused.status_code, refused.json()["code"]), (403, "page_refused"))
        refused = client.post("/happy/sessions/s1/page-shot", json={})
        self.assertEqual((refused.status_code, refused.json()["code"]), (403, "page_refused"))


if __name__ == "__main__":
    unittest.main()
