"""Tests for happy_evidence_stamp (the date/time bar), run inside the controller image with the live
frames tests (make browser-controller-patch-test)."""

from __future__ import annotations

import hashlib
import io
import json
import os
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

os.environ.setdefault("HAPPY_LIVE_FRAMES_NO_AUTOLOAD", "1")

import happy_evidence_stamp as ev  # noqa: E402
import happy_live_frames as hlf  # noqa: E402
import test_happy_live_frames as base  # noqa: E402  (applies the patch)
from PIL import Image, ImageDraw  # noqa: E402

from app.browser.services.diagnostics import BrowserDiagnosticsService  # noqa: E402

AT = datetime(2026, 11, 11, 19, 32, 7, 123456, tzinfo=UTC)


def page_png(width: int = 640, height: int = 400, seed: int = 0) -> bytes:
    """A page-like image whose every pixel says where it is, so a moved or resampled pixel shows."""
    image = Image.new("RGB", (width, height))
    image.putdata([((x + seed) % 256, y % 256, (x * y + seed) % 256) for y in range(height) for x in range(width)])
    out = io.BytesIO()
    image.save(out, format="PNG")
    return out.getvalue()


def pixels(data: bytes | Path) -> Image.Image:
    source = Image.open(io.BytesIO(data) if isinstance(data, bytes) else data)
    source.load()
    return source


def black_box_scrubber(raw: bytes, blocks: list) -> tuple[bytes, list]:
    """A scrubber that blacks out each OCR box, as the controller's does."""
    image = pixels(raw).convert("RGB")
    draw = ImageDraw.Draw(image)
    for block in blocks:
        b = block["bbox"]
        draw.rectangle([b["x"], b["y"], b["x"] + b["width"] - 1, b["y"] + b["height"] - 1], fill=(0, 0, 0))
    out = io.BytesIO()
    image.save(out, format="PNG")
    return out.getvalue(), [{"kind": "email"}] if blocks else []


class StampTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def shot(self, width: int = 640, height: int = 400, name: str = "20261111T193207123456Z-manual.png") -> Path:
        path = self.tmp / name
        path.write_bytes(page_png(width, height))
        return path

    def test_the_canvas_grows_by_the_bar_and_the_page_is_untouched(self) -> None:
        for width, height in ((640, 400), (1920, 1113)):
            path = self.shot(width, height, name=f"20261111T193207123456Z-{width}.png")
            before = pixels(path.read_bytes())
            info = ev.stamp(path, AT, "America/Toronto")
            bar = ev.bar_px(width)
            self.assertEqual(bar, max(24, round(width * 0.035)))
            after = pixels(path)
            self.assertEqual(after.size, (width, height + bar))
            self.assertEqual(after.crop((0, bar, width, height + bar)).tobytes(), before.tobytes())
            self.assertEqual(info["bar_px"], bar)
            self.assertTrue(info["stamped"])
        self.assertEqual(ev.bar_px(1920), 67)
        self.assertEqual(ev.bar_px(320), 24)

    def test_the_bar_is_dark_with_a_line_and_text_at_its_right_end(self) -> None:
        path = self.shot(1920, 300)
        ev.stamp(path, AT, "America/Toronto")
        image = pixels(path).convert("RGB")
        bar = 67
        self.assertEqual(image.getpixel((5, 5)), ev.BAR_FILL)
        self.assertEqual(image.getpixel((5, bar - 1)), ev.BAR_LINE)
        right = image.crop((1920 - 700, 0, 1920 - bar // 2, bar - 1))
        light = [p for p in right.getdata() if min(p) > 200]
        self.assertGreater(len(light), 200, "no text drawn at the bar's right end")
        left = image.crop((0, 0, 900, bar - 1))
        self.assertEqual(set(left.getdata()), {ev.BAR_FILL}, "the bar's left part is plain")
        # The text ends near the right edge (anchor rm at W - B/2).
        xs = [x for x in range(1920 - 200, 1920) for y in range(bar - 1) if min(image.getpixel((x, y))) > 200]
        self.assertTrue(xs and 1920 - bar // 2 - 12 <= max(xs) <= 1920 - bar // 2)

    def test_the_chunk_says_what_was_stamped(self) -> None:
        path = self.shot()
        ev.stamp(path, AT, "America/Toronto")
        self.assertEqual(
            json.loads(pixels(path).text[ev.CHUNK_KEY]),
            {"bar_px": 24, "captured_at": "2026-11-11T19:32:07.123Z", "tz": "America/Toronto"},
        )
        self.assertEqual(ev.read_stamp(path)["bar_px"], 24)

    def test_stamping_twice_changes_nothing(self) -> None:
        path = self.shot()
        first = ev.stamp(path, AT, "America/Toronto")
        data = path.read_bytes()
        again = ev.stamp(path, AT + timedelta(hours=3), "UTC")
        self.assertEqual(path.read_bytes(), data)
        self.assertFalse(again["stamped"])
        self.assertEqual((again["text"], again["captured_at"]), (first["text"], first["captured_at"]))

    def test_a_missing_file_is_skipped(self) -> None:
        self.assertIsNone(ev.stamp(self.tmp / "gone.png", AT))
        self.assertEqual(list(self.tmp.iterdir()), [])

    def test_the_capture_time_comes_from_the_artifact_name(self) -> None:
        self.assertEqual(ev.captured_at_from_name("/data/artifacts/s1/20261111T193207123456Z-observe.png"), AT)
        self.assertEqual(
            ev.captured_at_from_name("20260101T000000Z-x.png"), None
        )  # no fraction: not upstream's name
        self.assertIsNone(ev.captured_at_from_name("screenshot-baseline.png"))
        self.assertIsNone(ev.captured_at_from_name("20261399T999999000000Z-x.png"))

    def test_the_text_and_its_offset(self) -> None:
        self.assertEqual(ev.stamp_text(AT, "America/Toronto"), "2026-11-11 14:32:07 EST (UTC-05:00)")
        july = datetime(2026, 7, 1, 16, 0, 0, tzinfo=UTC)
        self.assertEqual(ev.stamp_text(july, "America/Toronto"), "2026-07-01 12:00:00 EDT (UTC-04:00)")
        self.assertEqual(ev.stamp_text(AT, "UTC"), "2026-11-11 19:32:07 UTC (UTC+00:00)")
        self.assertEqual(ev.stamp_text(AT, "Asia/Kolkata"), "2026-11-12 01:02:07 IST (UTC+05:30)")
        self.assertEqual(ev.stamp_text(AT, "America/St_Johns"), "2026-11-11 16:02:07 NST (UTC-03:30)")

    def test_an_invalid_zone_is_refused(self) -> None:
        for bad in ("Mars/Olympus_Mons", "../etc/passwd", "EST5EDT/x"):
            with self.assertRaises(ev.InvalidTimeZone):
                ev.zone(bad)
            with patch.dict(os.environ, {"EVIDENCE_TZ": bad}):
                with self.assertRaises(ev.InvalidTimeZone):
                    hlf.verify()
        with patch.dict(os.environ, {"EVIDENCE_TZ": "America/Toronto"}):
            hlf.verify()
            self.assertEqual(ev.check_tz(), "America/Toronto")
        with patch.dict(os.environ, {"EVIDENCE_TZ": ""}):
            self.assertEqual(ev.check_tz(), "UTC")

    def test_clamp(self) -> None:
        lo, hi = AT, AT + timedelta(seconds=5)
        self.assertEqual(ev.clamp(None, lo, hi), lo)
        self.assertEqual(ev.clamp(AT - timedelta(days=1), lo, hi), lo)
        self.assertEqual(ev.clamp(AT + timedelta(days=1), lo, hi), hi)
        self.assertEqual(ev.clamp(AT + timedelta(seconds=2), lo, hi), AT + timedelta(seconds=2))
        self.assertEqual(ev.parse_iso("2026-11-11T19:32:07.123Z"), datetime(2026, 11, 11, 19, 32, 7, 123000, tzinfo=UTC))
        for bad in (None, 5, "", "yesterday", "2026-11-11T19:32:07"):
            self.assertIsNone(ev.parse_iso(bad))


class DiffTests(unittest.TestCase):
    def test_compute_diff_compares_pages_not_bars(self) -> None:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(__import__("shutil").rmtree, tmp)
        a, b = tmp / "20261111T193207000000Z-a.png", tmp / "20261111T203207000000Z-b.png"
        a.write_bytes(page_png())
        b.write_bytes(page_png())
        ev.stamp(a, AT, "UTC")
        ev.stamp(b, AT + timedelta(hours=1, seconds=13), "UTC")  # different text in each bar
        self.assertTrue(getattr(BrowserDiagnosticsService.compute_diff, "_happy_evidence_crop", False))
        out = BrowserDiagnosticsService.compute_diff(str(a), str(b), "/a", "/b", tmp)
        self.assertEqual((out["changed_pixels"], out["width"], out["height"]), (0, 640, 400))
        # An unstamped baseline against a stamped shot of the same page: the same.
        c = tmp / "screenshot-baseline.png"
        c.write_bytes(page_png())
        out = BrowserDiagnosticsService.compute_diff(str(c), str(b), "/c", "/b", tmp)
        self.assertEqual(out["changed_pixels"], 0)
        # A real change below the bar still shows.
        d = tmp / "20261111T203208000000Z-d.png"
        d.write_bytes(page_png(seed=7))
        out = BrowserDiagnosticsService.compute_diff(str(a), str(d), "/a", "/d", tmp)
        self.assertGreater(out["changed_pixels"], 0)


class ScreenStampTests(base.ScreenBase):
    REAL_STAMP = True

    def setUp(self) -> None:
        super().setUp()

        def scrub(raw: bytes, blocks: list) -> tuple[bytes, list]:
            self.scrubbed_blocks.append(blocks)
            return black_box_scrubber(raw, blocks)

        self.scrubber.screenshot = scrub
        self.page_word = self.word("jane@example.com", 300, 200, w=120, h=20)
        self.ocr_sizes: list[tuple[int, int]] = []

        async def ocr(path: str) -> dict:
            self.ocr_sizes.append(pixels(Path(path)).size)
            return {"available": True, "redaction_blocks": [self.page_word], "blocks": [self.page_word]}

        self.service.manager.ocr.extract_from_image = AsyncMock(side_effect=ocr)
        self.raw = page_png(640, 400)

    async def screen(self, captured_at: Any = None, redact: bool = True) -> dict:
        front = await hlf.screen_front(self.service.manager, "s1", redact=redact)
        if callable(captured_at):
            captured_at = captured_at()  # a time taken between the two steps, as the bridge's is
        return await hlf.screen_scrub(
            self.service.manager, "s1", token=front["token"], png=self.raw, label="ev", redact=redact,
            captured_at=captured_at,
        )

    async def test_stamped_after_the_scrub_with_the_boxes_where_they_were(self) -> None:
        out = await self.screen()
        bar = ev.bar_px(640)
        self.assertEqual(out["evidence_bar_px"], bar)
        self.assertEqual((out["width"], out["height"]), (640, 400 + bar))
        # OCR read the capture, not the stamped image; the scrubber got the page's own coordinates.
        # (The address-bar check reads an enlarged crop of the capture's strip after it.)
        self.assertEqual(self.ocr_sizes[0], (640, 400))
        self.assertNotIn(400 + bar, [h for _, h in self.ocr_sizes])
        self.assertEqual(self.scrubbed_blocks, [[self.page_word]])
        image = pixels(Path(out["screenshot_path"])).convert("RGB")
        # The box is black at its page position, below the bar.
        self.assertEqual(image.getpixel((300 + 5, 200 + bar + 5)), (0, 0, 0))
        self.assertEqual(image.getpixel((300 + 119, 200 + bar + 19)), (0, 0, 0))
        # And right above it is page, not box.
        expected = black_box_scrubber(self.raw, [self.page_word])[0]
        self.assertEqual(image.crop((0, bar, 640, 400 + bar)).tobytes(), pixels(expected).convert("RGB").tobytes())
        self.assertEqual(ev.read_stamp(out["screenshot_path"])["bar_px"], bar)

    async def test_the_audit_has_the_stamped_bytes_hash_and_the_text(self) -> None:
        out = await self.screen()
        data = Path(out["screenshot_path"]).read_bytes()
        [audit] = self.audits()
        self.assertEqual(audit["details"]["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(audit["details"]["stamp_text"], out["stamp_text"])
        import base64

        self.assertEqual(base64.b64decode(out["png"]), data)

    async def test_the_bridges_capture_time_is_held_between_the_front_and_now(self) -> None:
        start = datetime.now(UTC)
        # In range: taken as is.
        claims: list[str] = []
        out = await self.screen(captured_at=lambda: claims.append(ev.iso(datetime.now(UTC))) or claims[-1])
        inside = claims[0]
        self.assertEqual(out["captured_at"], inside)
        self.assertEqual(json.loads(pixels(Path(out["screenshot_path"])).text[ev.CHUNK_KEY])["captured_at"], inside)
        # Before the front step: the front step's time.
        out = await self.screen(captured_at="2020-01-01T00:00:00.000Z")
        self.assertGreaterEqual(ev.parse_iso(out["captured_at"]), start - timedelta(milliseconds=1))
        # In the future: now.
        out = await self.screen(captured_at="2099-01-01T00:00:00.000Z")
        self.assertLessEqual(ev.parse_iso(out["captured_at"]), datetime.now(UTC))
        # None, or nonsense: the front step's time.
        for claim in (None, "soon"):
            before = datetime.now(UTC)
            out = await self.screen(captured_at=claim)
            self.assertGreaterEqual(ev.parse_iso(out["captured_at"]), before - timedelta(milliseconds=1))
            self.assertLessEqual(ev.parse_iso(out["captured_at"]), datetime.now(UTC))

    async def test_the_scrub_route_passes_the_capture_time_on(self) -> None:
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        import base64

        app = FastAPI()
        hlf.install_screen_routes(app, self.service.manager)
        client = TestClient(app)
        front = client.post("/happy/sessions/s1/screen/front", json={}).json()
        inside = ev.iso(datetime.now(UTC))
        r = client.post("/happy/sessions/s1/screen/scrub", json={
            "token": front["token"], "png": base64.b64encode(self.raw).decode(), "captured_at": inside,
        })
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["captured_at"], inside)
        r = client.post("/happy/sessions/s1/screen/scrub", json={"token": "x", "png": "", "captured_at": 5})
        self.assertEqual(r.status_code, 400)

    async def test_a_shot_that_cannot_be_stamped_is_not_kept(self) -> None:
        with patch.object(ev, "stamp", side_effect=OSError("disk")):
            with self.assertRaises(hlf.ScreenRefused) as cm:
                await self.screen()
        self.assertEqual(cm.exception.code, "stamp_failed")
        self.assertEqual(self.artifact_pngs(), [])
        self.assertEqual(self.audits(), [])

    async def test_page_shot_is_stamped_at_its_capture_time(self) -> None:
        async def raw(session, label):
            path = Path(session.artifact_dir) / f"20261111T193207123456Z-{label}.png"
            path.write_bytes(page_png(640, 400))
            return {"path": str(path), "url": f"/artifacts/s1/{path.name}"}

        self.service.manager._capture_screenshot = AsyncMock(side_effect=raw)
        with patch.dict(os.environ, {"EVIDENCE_TZ": "America/Toronto"}):
            out = await hlf.page_shot(self.service.manager, "s1", label="p")
        self.assertEqual(out["captured_at"], "2026-11-11T19:32:07.123Z")
        self.assertEqual(out["stamp_text"], "2026-11-11 14:32:07 EST (UTC-05:00)")
        self.assertEqual((out["width"], out["height"], out["evidence_bar_px"]), (640, 424, 24))
        self.assertEqual(self.ocr_sizes, [(640, 400)])
        [audit] = self.audits()
        self.assertEqual(audit["details"]["sha256"], hashlib.sha256(Path(out["screenshot_path"]).read_bytes()).hexdigest())
        self.assertEqual(audit["details"]["stamp_text"], out["stamp_text"])


class ObservationStampTests(base.Base):
    def setUp(self) -> None:
        super().setUp()
        m = self.service.manager
        self.scrubber.screenshot = black_box_scrubber
        self.word = {"text": "a@b.c", "bbox": {"x": 10, "y": 10, "width": 30, "height": 10}}
        m.ocr.extract_from_image = AsyncMock(return_value={"available": True, "redaction_blocks": [self.word]})
        counter = {"n": 0}

        async def capture(session, label):
            counter["n"] += 1
            path = Path(session.artifact_dir) / f"20261111T19320{counter['n']}123456Z-{label}.png"
            path.write_bytes(page_png(320, 200))
            return {"path": str(path), "url": f"/artifacts/s1/{path.name}"}

        m._capture_screenshot = AsyncMock(side_effect=capture)
        m._shown_url = lambda page: page.url
        m._session_summary = AsyncMock(return_value={"id": "s1"})
        m._current_takeover_url = MagicMock(return_value=None)

    async def test_the_action_snapshot_is_stamped_and_its_live_frame_copy_is_not(self) -> None:
        result = await self.service.light_snapshot(self.session, label="before-click")
        frame = getattr(self.session, hlf._FRAME_ATTR)
        self.assertIsNotNone(ev.read_stamp(result["screenshot_path"]))
        self.assertEqual(pixels(Path(result["screenshot_path"])).size, (320, 224))
        self.assertIsNone(ev.read_stamp(frame.path))
        self.assertEqual(pixels(Path(frame.path)).size, (320, 200))
        # The copy is the scrubbed page.
        self.assertEqual(pixels(Path(frame.path)).convert("RGB").getpixel((15, 15)), (0, 0, 0))

    async def test_capture_screenshot_is_stamped(self) -> None:
        out = await self.service.capture_screenshot("s1", label="manual")
        meta = ev.read_stamp(out["screenshot_path"])
        self.assertEqual(meta["captured_at"], "2026-11-11T19:32:01.123Z")
        image = pixels(Path(out["screenshot_path"])).convert("RGB")
        self.assertEqual(image.getpixel((15, 15 + 24)), (0, 0, 0))  # the scrub box, below the bar

    async def test_a_share_frame_is_not_stamped(self) -> None:
        async def shot(*, path: str, full_page: bool = False, timeout: float | None = None) -> bytes:
            Path(path).write_bytes(page_png(320, 200))
            return b""

        self.page.screenshot = shot
        snap = await self.service.share_snapshot("s1")
        self.assertIsNone(ev.read_stamp(snap["screenshot_path"]))
        self.assertEqual(pixels(Path(snap["screenshot_path"])).size, (320, 200))

    async def test_an_image_that_cannot_be_stamped_is_returned_as_is(self) -> None:
        async def capture(session, label):
            path = Path(session.artifact_dir) / f"20261111T193207123456Z-{label}.png"
            path.write_bytes(b"not a png")
            return {"path": str(path), "url": f"/artifacts/s1/{path.name}"}

        self.service.manager._capture_screenshot = AsyncMock(side_effect=capture)
        self.service.manager.ocr.extract_from_image = AsyncMock(return_value={"available": True, "redaction_blocks": []})
        out = await self.service.capture_screenshot("s1", label="manual")
        self.assertEqual(Path(out["screenshot_path"]).read_bytes(), b"not a png")


if __name__ == "__main__":
    unittest.main()
