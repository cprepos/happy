"""Live frames while an action runs: a patch to auto-browser's controller 1.14.0.

The live view (bridge /live/<id>/frame.jpg) polls GET /share/<token>/observe, which runs
BrowserObservationService.share_snapshot. Upstream, that waits for the session lock, and an action
holds the lock from its before-snapshot to its after-snapshot, so the viewer saw nothing between an
action's start and its end: a navigation that took ten seconds was ten seconds of a frozen frame.

What this changes (share_snapshot and light_snapshot only; nothing else in the controller):

- Each session keeps its most recent PII-scrubbed frame (a PNG in its artifact directory, with the
  URL and title it was taken with). It is filled by the share poll itself, by every action's
  before/after snapshot (when those are redacted), and by the captures below.
- With the session lock free, share_snapshot takes the lock and one scrubbed frame, as upstream does.
- With the lock held (an action, an observe), it does not wait for it. It takes a frame without the
  lock, written outside the artifact tree, OCR-scrubbed through the controller's own redaction, and
  moved into the artifact directory only once scrubbed and checked. One such capture runs per session
  at a time; viewers share it. If it fails, or takes too long, the previous scrubbed frame is served.
- A frame that could not be scrubbed is never cached and never served by these paths. With
  PII_SCRUB_SCREENSHOT off, none of this runs: share_snapshot is upstream's, unchanged.

It also adds one read-only route, GET /happy/sessions/{session_id}/focus -> {"editable_focused": bool|null}:
whether the page's focus is in a field that takes typing (a text-like input, a textarea, an editable
element; not disabled or read-only), followed into shadow roots and frames. The live bridge asks it
while the person holds the browser, so the app's native viewer brings up the keyboard by itself. It
answers only that one boolean, never the field or its value; it takes no lock and changes nothing in
the page. The controller's bearer-token middleware and session ownership apply to it as to any route.

And two routes for browser_screenshot's whole-screen capture (see "the whole-screen screenshot" below):
POST /happy/sessions/{session_id}/screen/front brings the session's tab to the front and hands out a
one-use token; POST /happy/sessions/{session_id}/screen/scrub takes the PNG the bridge had the pod's
node capture, checks the page did not move, OCR-scrubs it through the controller's own redaction and
files it in the session's artifact directory, as a page screenshot is.

The share route and its token check (app/routes/share.py) are untouched; the patch refuses to load if
that file, or any file whose behaviour it relies on, is not the 1.14.0 file it was written against.

Loaded by running uvicorn on this module (happy_live_frames:app) instead of app.main:app, with this
file's directory on PYTHONPATH: see compose.browser.yml and launcher/launcher.mjs.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import hashlib
import logging
import os
import re
import secrets
import struct
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger("happy_live_frames")

EXPECTED_VERSION = "1.14.0"
# sha256 of the upstream files this patch replaces methods in, calls into, or must not widen.
EXPECTED_SHA256 = {
    "browser/services/observation.py": "14e63528b3bf1e9b4c7a8e4054fed59ebe7db6b37e06df1e0b3b3c1283dbf58c",
    "browser/page_read.py": "4622611ed2728a31489e160d85db1bb657149681525ffb9c62b7377a482af8ca",
    "artifacts.py": "01055666b7921868c8b2fc6aa331aee576bd09666c4cc3b54050aa9070edf5ab",
    # The share route: its token check is what keeps who can read a frame unchanged.
    "routes/share.py": "71949b2a687dc37c831ba82270987749ea1c9d8548aefbe0a19f643a9c075e42",
}

# A lockless capture: how long a poll waits on it before serving the previous frame, and the
# bounds on its page calls. It never touches the session lock, so these only bound the viewer.
HELD_WAIT_SECONDS = 2.0
CAPTURE_TIMEOUT_MS = 5000
TITLE_TIMEOUT_SECONDS = 2.0
# A poll that lands this soon after a lockless capture finished reuses it rather than starting another.
MIN_CAPTURE_INTERVAL_SECONDS = 0.3
PENDING_KEEP_SECONDS = 60.0

# The focus read: how long it may take, and the frames it looks into.
FOCUS_TIMEOUT_SECONDS = 1.5
FOCUS_MAX_FRAMES = 8

_FRAME_ATTR = "_happy_live_frame"
_TASK_ATTR = "_happy_live_capture"


class PatchMismatch(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(app_dir: Path | None = None) -> None:
    """Refuse to run against anything but the controller this was written for."""
    if app_dir is None:
        import app as app_package

        app_dir = Path(app_package.__file__).parent
    found = re.search(r'^__version__ = "([^"]+)"$', (app_dir / "version.py").read_text(encoding="utf-8"), re.M)
    version = found.group(1) if found else None
    if version != EXPECTED_VERSION:
        raise PatchMismatch(
            f"happy_live_frames was written for auto-browser controller {EXPECTED_VERSION}, this image is "
            f"{version}: re-port the patch (browser-stack/browser/controller-patch) or run uvicorn app.main:app"
        )
    for rel, expected in EXPECTED_SHA256.items():
        actual = _sha256(app_dir / rel)
        if actual != expected:
            raise PatchMismatch(
                f"happy_live_frames: app/{rel} is not the {EXPECTED_VERSION} file the patch was written against "
                f"(sha256 {actual}): re-port the patch or run uvicorn app.main:app"
            )


@dataclass(frozen=True)
class LiveFrame:
    path: str
    url: str
    title: str
    at: float


# ── helpers ─────────────────────────────────────────────────────────────────


def _scrubbing_on(service: Any) -> bool:
    return getattr(getattr(service.manager, "pii_scrubber", None), "screenshot_enabled", False) is True


def _cached(session: Any) -> LiveFrame | None:
    frame = getattr(session, _FRAME_ATTR, None)
    if frame is None:
        return None
    if not Path(frame.path).is_file():
        _forget(session)
        return None
    return frame


def _store(session: Any, frame: LiveFrame) -> None:
    current = getattr(session, _FRAME_ATTR, None)
    # A capture that finished after a newer one must not replace it.
    if current is not None and current.at > frame.at:
        return
    setattr(session, _FRAME_ATTR, frame)


def _forget(session: Any) -> None:
    setattr(session, _FRAME_ATTR, None)


def _frame_name(label: str) -> str:
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime())
    return f"{stamp}{int(time.time() * 1e6) % 1_000_000:06d}Z-{label}.png"


def _pending_dir(session: Any) -> Path:
    """Where a lockless capture is written before it is scrubbed: outside the artifact tree, so no
    route (/artifacts, /share/.../screenshots) can name it, on the same filesystem for os.replace."""
    artifact_dir = Path(session.artifact_dir)
    return artifact_dir.parent.parent / "live-pending" / artifact_dir.name


def _prune(session: Any, share_label: str, keep_seconds: float) -> None:
    keep = {getattr(getattr(session, _FRAME_ATTR, None), "path", None)}
    cutoff = time.time() - keep_seconds
    try:
        for path in Path(session.artifact_dir).glob(f"*-{share_label}.png"):
            if str(path) not in keep and path.stat().st_mtime < cutoff:
                path.unlink(missing_ok=True)
    except OSError as exc:
        logger.warning("live frames: prune failed: %s", type(exc).__name__)
    try:
        pending = _pending_dir(session)
        if pending.is_dir():
            pcut = time.time() - PENDING_KEEP_SECONDS
            for path in pending.iterdir():
                if path.stat().st_mtime < pcut:
                    path.unlink(missing_ok=True)
    except OSError as exc:
        logger.warning("live frames: pending prune failed: %s", type(exc).__name__)


def _publish_copy(source: str, final: Path, pending: Path) -> None:
    """Copy an already-scrubbed image into the artifact directory, whole or not at all."""
    pending.parent.mkdir(parents=True, exist_ok=True)
    tmp = pending.with_suffix(".copy")
    try:
        tmp.write_bytes(Path(source).read_bytes())
        os.replace(tmp, final)
    finally:
        tmp.unlink(missing_ok=True)


def _retrieve(task: asyncio.Future) -> None:
    # A capture nobody waited for to the end: its error is not logged as "never retrieved".
    if not task.cancelled():
        task.exception()


# ── the patched methods ─────────────────────────────────────────────────────


def build(observation_module: Any, page_read_module: Any) -> dict[str, Any]:
    """The patched methods, closed over the upstream module objects."""
    Service = observation_module.BrowserObservationService
    SHARE_FRAME_LABEL = observation_module.SHARE_FRAME_LABEL
    SHARE_FRAME_KEEP_SECONDS = observation_module.SHARE_FRAME_KEEP_SECONDS
    start_read = page_read_module.start_read
    bounded = page_read_module.bounded
    upstream_share_snapshot = Service.share_snapshot
    upstream_light_snapshot = Service.light_snapshot

    async def _redact_in_place(self: Any, session: Any, screenshot: dict[str, str]) -> bool:
        """The controller's own redaction (OCR boxes, then _scrub_screenshot_if_needed). True only if it ran."""
        if not _scrubbing_on(self):
            return False
        ocr = await self.manager.ocr.extract_from_image(screenshot["path"])
        if not isinstance(ocr, dict) or ocr.get("available", True) is False:
            return False
        await self._scrub_screenshot_if_needed(session, screenshot, ocr)
        return "pii_scrub_skipped" not in screenshot

    async def _scrubbed_capture(self: Any, session: Any) -> LiveFrame | None:
        """One scrubbed frame, with or without the session lock.

        Without it (another call holds it), this runs alongside that call's page calls, which
        Playwright allows; nothing here changes the page, its listeners, the element ids or
        session.last_screenshot. The image is written outside the artifact tree and moved in only once
        scrubbed and checked, so no route ever serves it raw. None if it could not be taken or scrubbed.
        """
        read = start_read(self.manager, session)
        pending_dir = _pending_dir(session)
        name = _frame_name(SHARE_FRAME_LABEL)
        pending = pending_dir / name
        final = Path(session.artifact_dir) / name
        try:
            await asyncio.to_thread(pending_dir.mkdir, parents=True, exist_ok=True)
            await session.page.screenshot(path=str(pending), full_page=False, timeout=CAPTURE_TIMEOUT_MS)
            shot = {"path": str(pending), "url": ""}
            if not await _redact_in_place(self, session, shot):
                pending.unlink(missing_ok=True)
                return None
            url = session.page.url
            try:
                title = await bounded(session.page.title(), seconds=TITLE_TIMEOUT_SECONDS)
            except Exception:
                title = ""  # mid-navigation the title may not answer; the frame still stands
        except Exception as exc:
            pending.unlink(missing_ok=True)
            read.refuse_raised()  # a page that moved: PermissionError, as upstream
            logger.debug("live frames: lockless capture failed: %s", type(exc).__name__)
            return None
        if read.moved():
            pending.unlink(missing_ok=True)
            raise PermissionError(page_read_module.MOVED_DETAIL)
        try:
            await asyncio.to_thread(os.replace, pending, final)
        except OSError as exc:
            pending.unlink(missing_ok=True)
            logger.debug("live frames: could not publish a frame: %s", type(exc).__name__)
            return None
        frame = LiveFrame(path=str(final), url=url, title=title, at=time.monotonic())
        _store(session, frame)
        return frame

    async def _held_snapshot(self: Any, session: Any) -> dict[str, Any]:
        # Refuse a refused page before anything, as upstream's start_read does.
        self.manager._assert_page_allowed(session)
        task = getattr(session, _TASK_ATTR, None)
        cached = _cached(session)
        if task is None or task.done():
            if cached is not None and time.monotonic() - cached.at < MIN_CAPTURE_INTERVAL_SECONDS:
                task = None
            else:
                task = asyncio.ensure_future(_scrubbed_capture(self, session))
                task.add_done_callback(_retrieve)
                setattr(session, _TASK_ATTR, task)
        frame = None
        if task is not None:
            try:
                frame = await asyncio.wait_for(asyncio.shield(task), timeout=HELD_WAIT_SECONDS)
            except PermissionError:
                _forget(session)
                raise
            except Exception:
                frame = None
        if frame is None:
            frame = _cached(session)
        if frame is None:
            raise RuntimeError("no scrubbed frame yet")
        # The page as it is now must still be one that may be read.
        self.manager._assert_page_allowed(session)
        await asyncio.to_thread(_prune, session, SHARE_FRAME_LABEL, SHARE_FRAME_KEEP_SECONDS)
        return {"url": frame.url, "title": frame.title, "screenshot_path": frame.path}

    async def share_snapshot(self: Any, session_id: str) -> dict[str, Any]:
        if not _scrubbing_on(self):
            return await upstream_share_snapshot(self, session_id)
        session = await self.manager.get_session(session_id)
        if session.lock.locked():
            return await _held_snapshot(self, session)
        # No await between the check above and this acquire: it does not wait.
        async with session.lock:
            # The same capture as with the lock held, under the lock: upstream's capture wrote the
            # raw image into the artifact directory before scrubbing it in place.
            frame = await _scrubbed_capture(self, session)
            if frame is None:
                # Not scrubbed (or not taken): nothing new is served. The last scrubbed frame stands in.
                frame = _cached(session)
                if frame is None:
                    raise RuntimeError("no scrubbed frame")
            snapshot = {"url": frame.url, "title": frame.title, "screenshot_path": frame.path}
        await asyncio.to_thread(_prune, session, SHARE_FRAME_LABEL, SHARE_FRAME_KEEP_SECONDS)
        return snapshot

    async def light_snapshot(self: Any, session: Any, *, label: str) -> dict[str, Any]:
        result = await upstream_light_snapshot(self, session, label=label)
        # Only an action snapshot that went through the redaction and was not marked unscrubbed.
        if (
            _scrubbing_on(self)
            and getattr(self.manager.settings, "pii_scrub_action_screenshots", False) is True
            and "screenshot_pii_scrub" not in result
            and result.get("screenshot_path")
        ):
            # Never at the action's expense: any failure here leaves the live frame as it was.
            try:
                name = _frame_name(SHARE_FRAME_LABEL)
                final = Path(session.artifact_dir) / name
                await asyncio.to_thread(_publish_copy, result["screenshot_path"], final, _pending_dir(session) / name)
                _store(
                    session,
                    LiveFrame(path=str(final), url=result.get("url") or "", title=result.get("title") or "", at=time.monotonic()),
                )
            except Exception as exc:
                logger.debug("live frames: could not keep an action snapshot: %s", type(exc).__name__)
        return result

    return {"share_snapshot": share_snapshot, "light_snapshot": light_snapshot}


# ── the focus read ──────────────────────────────────────────────────────────

# In one frame: "editable" when its focused element takes typing, "frame" when the focus is in a
# child frame, "none" otherwise. Shadow roots are followed; nothing about the element leaves the page.
FOCUS_SCRIPT = """() => {
  if (document.designMode === 'on') return document.hasFocus() ? 'editable' : 'none';
  let el = document.activeElement;
  while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
  if (!el || el === document.body || el === document.documentElement) return 'none';
  const tag = el.tagName;
  if (tag === 'IFRAME' || tag === 'FRAME') return 'frame';
  if (el.isContentEditable) return 'editable';
  const off = el.disabled === true || el.readOnly === true;
  if (tag === 'TEXTAREA') return off ? 'none' : 'editable';
  if (tag === 'INPUT') {
    const texty = ['text', 'search', 'email', 'url', 'tel', 'password', 'number',
      'date', 'datetime-local', 'month', 'week', 'time'];
    return !off && texty.includes(String(el.type).toLowerCase()) ? 'editable' : 'none';
  }
  return 'none';
}"""


async def editable_focused(page: Any) -> bool | None:
    """True when the page's focus is in a field that takes typing, None when it can't be told."""
    where = await asyncio.wait_for(page.main_frame.evaluate(FOCUS_SCRIPT), timeout=FOCUS_TIMEOUT_SECONDS)
    if where != "frame":
        return where == "editable"
    # The focus is in a child frame: the one whose document has it says.
    for frame in page.frames[1 : FOCUS_MAX_FRAMES + 1]:
        try:
            focused = await asyncio.wait_for(frame.evaluate("() => document.hasFocus()"), timeout=FOCUS_TIMEOUT_SECONDS)
            if not focused:
                continue
            inner = await asyncio.wait_for(frame.evaluate(FOCUS_SCRIPT), timeout=FOCUS_TIMEOUT_SECONDS)
        except Exception:
            continue
        if inner == "editable":
            return True
        if inner == "none":
            return False
    return None


# ── the whole-screen screenshot ─────────────────────────────────────────────
#
# browser_screenshot's default scope, "screen": the browser window as the live view shows it (tab
# strip, address bar, dialogs). The X screen lives in the pod's browser node, which the controller
# cannot read, so the bridge runs three steps for one chat's own pod:
#   1. POST /happy/sessions/{id}/screen/front {activate}: the session's tab is brought to the front of
#      its window (activate false: not, while the person holding the browser looks at it), and must
#      then be the tab the window shows (document.visibilityState). -> {token, url, title}. The token
#      keeps the page and its count of refused commits, as a PageRead does.
#   2. The launcher captures the pod's X screen (scripts/screen-capture.py).
#   3. POST /happy/sessions/{id}/screen/scrub {token, png (base64), label}: refused unless the
#      session's page is still the one step 1 saw, on the same URL, still in front, and not refused.
#      The image is written outside the artifact tree, OCR-scrubbed through the controller's own
#      redaction, and only then moved into the session's artifact directory as
#      <stamp>Z-screen-<label>.png. -> {url, title, screenshot_path, screenshot_url, width, height,
#      png, pii_scrubbed, redaction, chrome_strip, screenshot_pii_scrub?}. With PII_SCRUB_SCREENSHOT
#      off the image is stored as captured, as page screenshots are; PII_SCRUB_SCREENSHOT_STRICT
#      withholds an unscrubbable one (SCREENSHOT_WITHHELD, 503) as it does those.
#
# The browser's own UI strip (tab strip, address bar, toolbar: the top of the window, above the page)
# is never redacted: the URL in the address bar is the point of the evidence. OCR reads the whole
# image; words that lie wholly inside that strip are dropped from the redaction boxes, and everything
# else (the page, any other window or dialog) is scrubbed as a page screenshot is. The strip comes
# from the window's own geometry, read from the page at both steps: screenX/screenY (where the window
# is), outerWidth, and outerHeight - innerHeight (the browser UI above the page), times
# devicePixelRatio. Steps 1 and 3 must agree on it, or the window moved and the shot is refused.
#
# redact (both steps, default true): false is the explicit opt-in for full-fidelity evidence: the
# capture is filed as it was on screen, unscrubbed, and the result says so (pii_scrubbed false,
# redaction "off_by_request"). PII_SCRUB_SCREENSHOT_STRICT makes
# scrubbing mandatory: with it on, redact false is refused (403 redaction_required), never quietly
# scrubbed or quietly not. Every shot, redacted or not, is written to the controller's audit log
# (event evidence_screenshot, with redacted true/false); an unredacted one that cannot be recorded
# there is not kept.
#
# POST /happy/sessions/{id}/page-shot {label?, redact?} is browser_screenshot scope "page" with the
# same redact switch: upstream's capture of the page (viewport), with redaction through the
# controller's own _capture_screenshot_redacted when redact is true, as upstream's screenshot does,
# and without it when false; the same result fields and audit event as the screen shot.

SCREEN_TOKEN_ATTR = "_happy_screen_tokens"
SCREEN_TOKEN_SECONDS = 30.0
SCREEN_MAX_BYTES = 48 * 1024 * 1024
SCREEN_PAGE_TIMEOUT_SECONDS = 5.0
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# Used only when the window's geometry cannot be read or makes no sense: the top of the screen, full
# width, this many pixels tall. It is Chromium's tab strip + toolbar (address bar) + the "controlled
# by automated software" info bar at devicePixelRatio 1 in a maximized window, as measured on the
# browser node (1920x1200 Xvfb, fluxbox). Larger than that only ever spares a few page pixels at the top.
CHROME_STRIP_FALLBACK_PX = 130
# The browser UI above the page is never taller than this many CSS pixels; geometry saying so is wrong.
CHROME_STRIP_MAX_CSS_PX = 400
WINDOW_SCRIPT = """() => ({
  visibility: document.visibilityState,
  screenX: window.screenX, screenY: window.screenY,
  outerWidth: window.outerWidth, outerHeight: window.outerHeight,
  innerWidth: window.innerWidth, innerHeight: window.innerHeight,
  dpr: window.devicePixelRatio,
})"""


class ScreenRefused(Exception):
    def __init__(self, status: int, code: str, detail: str) -> None:
        super().__init__(detail)
        self.status = status
        self.code = code
        self.detail = detail


def png_size(data: bytes) -> tuple[int, int]:
    """Width and height from a PNG's IHDR; ScreenRefused if it is not a PNG."""
    if len(data) < 24 or not data.startswith(PNG_SIGNATURE) or data[12:16] != b"IHDR":
        raise ScreenRefused(400, "bad_image", "not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    if not (0 < width <= 16384 and 0 < height <= 16384):
        raise ScreenRefused(400, "bad_image", "PNG size out of range")
    return width, height


def _page_read() -> Any:
    from app.browser import page_read

    return page_read


async def _window_state(session: Any) -> dict[str, Any]:
    """Whether the tab is the one its window shows, and where the window and its UI strip are."""
    state = await _page_read().bounded(session.page.evaluate(WINDOW_SCRIPT), seconds=SCREEN_PAGE_TIMEOUT_SECONDS)
    return state if isinstance(state, dict) else {}


def _geometry(state: dict[str, Any]) -> dict[str, float] | None:
    """The window geometry from a _window_state, or None if any of it is missing or not a number."""
    keys = ("screenX", "screenY", "outerWidth", "outerHeight", "innerWidth", "innerHeight", "dpr")
    values = {k: state.get(k) for k in keys}
    if not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in values.values()):
        return None
    return {k: float(v) for k, v in values.items()}


def chrome_strip(geometry: dict[str, float] | None, width: int, height: int) -> dict[str, Any]:
    """The browser's UI strip (tab strip, address bar, toolbar) in image pixels: {x, y, width, height, source}."""
    if geometry is not None:
        dpr = geometry["dpr"] if 0.5 <= geometry["dpr"] <= 4 else 0.0
        top_ui = geometry["outerHeight"] - geometry["innerHeight"]
        if dpr and 0 < top_ui <= CHROME_STRIP_MAX_CSS_PX and geometry["outerWidth"] > 0:
            left = max(0, round(geometry["screenX"] * dpr))
            top = max(0, round(geometry["screenY"] * dpr))
            right = min(width, round((geometry["screenX"] + geometry["outerWidth"]) * dpr))
            bottom = min(height, round((geometry["screenY"] + top_ui) * dpr))
            if right > left and bottom > top:
                return {"x": left, "y": top, "width": right - left, "height": bottom - top, "source": "window"}
    return {"x": 0, "y": 0, "width": width, "height": min(height, CHROME_STRIP_FALLBACK_PX), "source": "fallback"}


def _in_strip(block: Any, strip: dict[str, Any]) -> bool:
    """Whether an OCR word lies wholly inside the UI strip (2 px of slack for OCR's box edges)."""
    try:
        box = block["bbox"]
        x, y, w, h = (int(box[k]) for k in ("x", "y", "width", "height"))
    except (KeyError, TypeError, ValueError):
        return False  # a word without a usable box stays in the redaction
    slack = 2
    return (
        x >= strip["x"] - slack
        and y >= strip["y"] - slack
        and x + w <= strip["x"] + strip["width"] + slack
        and y + h <= strip["y"] + strip["height"] + slack
    )


def outside_strip(ocr: Any, strip: dict[str, Any]) -> Any:
    """The OCR result without the words in the UI strip, in both lists redaction may read."""
    if not isinstance(ocr, dict) or ocr.get("available", True) is False:
        return ocr
    out = dict(ocr)
    for key in ("redaction_blocks", "blocks"):
        if isinstance(ocr.get(key), list):
            out[key] = [b for b in ocr[key] if not _in_strip(b, strip)]
    return out


def _redaction(redact: bool, scrubbing: bool, shot: dict[str, Any]) -> str:
    """The result's redaction field: off_by_request, on, off_by_policy, unavailable."""
    if not redact:
        return "off_by_request"
    if not scrubbing:
        return "off_by_policy"  # PII_SCRUB_SCREENSHOT off: page screenshots are not scrubbed either
    if "pii_scrub_skipped" in shot:
        return "unavailable"  # OCR could not run; screenshot_pii_scrub says why
    return "on"


async def _audit_shot(manager: Any, session: Any, *, scope: str, redaction: str, url: str, screenshot_url: str) -> None:
    """The evidence trail for one browser_screenshot: whether it was redacted. An unredacted shot that
    cannot be recorded is refused (ScreenRefused 503) before it is filed."""
    try:
        await manager.audit.append(
            event_type="evidence_screenshot",
            status="ok",
            action="browser_screenshot",
            session_id=session.id,
            details={
                "scope": scope,
                "redacted": redaction == "on",
                "redaction": redaction,
                "url": url,
                "screenshot_url": screenshot_url,
            },
        )
    except Exception as exc:
        logger.warning("evidence screenshot: audit failed: %s", type(exc).__name__)
        if redaction != "on":
            raise ScreenRefused(
                503, "audit_failed", "The unredacted screenshot could not be recorded in the audit log, so it was not kept."
            ) from None


def _strict(manager: Any) -> bool:
    return getattr(manager.pii_scrubber, "screenshot_strict", False) is True


def _refuse_unredacted(manager: Any) -> None:
    if _strict(manager):
        raise ScreenRefused(
            403,
            "redaction_required",
            "This deployment requires screenshots to be PII-scrubbed (PII_SCRUB_SCREENSHOT_STRICT is on), "
            "so redact: false is refused. Take the screenshot with redaction.",
        )


async def _screen_title(session: Any) -> str:
    try:
        return await _page_read().bounded(session.page.title(), seconds=SCREEN_PAGE_TIMEOUT_SECONDS)
    except Exception:
        return ""  # mid-navigation the title may not answer


async def _acquire(session: Any) -> None:
    try:
        await asyncio.wait_for(session.lock.acquire(), timeout=_page_read().READ_LOCK_TIMEOUT_SECONDS)
    except TimeoutError:
        raise ScreenRefused(409, "busy", "The session is busy with another call. Try again.") from None


def _screen_tokens(session: Any) -> dict[str, Any]:
    tokens = getattr(session, SCREEN_TOKEN_ATTR, None)
    if tokens is None:
        tokens = {}
        setattr(session, SCREEN_TOKEN_ATTR, tokens)
    cutoff = time.monotonic() - SCREEN_TOKEN_SECONDS
    for key in [k for k, v in tokens.items() if v["at"] < cutoff]:
        tokens.pop(key, None)
    return tokens


def _moved() -> PermissionError:
    return PermissionError(_page_read().MOVED_DETAIL)


async def screen_front(
    manager: Any, session_id: str, *, activate: bool = True, redact: bool = True
) -> dict[str, Any]:
    """Step 1: the session's tab in front of its window, and a token for step 3."""
    if not redact:
        _refuse_unredacted(manager)
    # An unknown session, or another operator's, is a KeyError: the app's 404.
    session = await manager.get_session(session_id)
    manager._assert_page_allowed(session)
    await _acquire(session)
    try:
        read = _page_read().start_read(manager, session)
        if activate:
            await _page_read().bounded(session.page.bring_to_front(), seconds=SCREEN_PAGE_TIMEOUT_SECONDS)
        state = await _window_state(session)
        if state.get("visibility") != "visible":
            raise ScreenRefused(
                409,
                "not_in_front",
                "This session's tab is not the one the browser window shows"
                + ("" if activate else " (the person holding the browser has another tab in front)")
                + ", so a screen capture would not show it.",
            )
        if read.moved():
            raise _moved()
        url = manager._shown_url(session.page)
        title = await _screen_title(session)
        token = secrets.token_hex(16)
        _screen_tokens(session)[token] = {"read": read, "url": url, "geometry": _geometry(state), "at": time.monotonic()}
        return {"token": token, "url": url, "title": title}
    finally:
        session.lock.release()


async def screen_scrub(
    manager: Any, session_id: str, *, token: str, png: bytes, label: str = "manual", redact: bool = True
) -> dict[str, Any]:
    """Step 3: check the page has not moved since step 1, scrub the capture, file it as an artifact."""
    from app.browser.services.observation import _scrub_disclosure

    if not redact:
        _refuse_unredacted(manager)
    if len(png) > SCREEN_MAX_BYTES:
        raise ScreenRefused(413, "too_large", "screen image too large")
    width, height = png_size(png)
    session = await manager.get_session(session_id)
    manager._assert_page_allowed(session)
    await _acquire(session)
    pending: Path | None = None
    try:
        entry = _screen_tokens(session).pop(token, None)
        if entry is None:
            raise ScreenRefused(409, "stale", "The screen capture's token is unknown or expired. Take it again.")
        read = entry["read"]
        if read.moved():
            raise _moved()
        url = manager._shown_url(session.page)
        if url != entry["url"]:
            raise ScreenRefused(409, "moved", "The page navigated while the screen was captured. Take it again.")
        state = await _window_state(session)
        if state.get("visibility") != "visible":
            raise ScreenRefused(409, "not_in_front", "This session's tab left the front while the screen was captured.")
        geometry = _geometry(state)
        if geometry != entry.get("geometry"):
            raise ScreenRefused(409, "moved", "The browser window moved or changed size while the screen was captured. Take it again.")
        strip = chrome_strip(geometry, width, height)
        title = await _screen_title(session)

        safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "-", label or "manual").strip(".-")[:100] or "manual"
        target = manager.artifacts.screenshot_target(session, "screen-" + safe_label)
        final = Path(target["path"])
        pending_dir = _pending_dir(session)
        pending = pending_dir / final.name
        await asyncio.to_thread(pending_dir.mkdir, parents=True, exist_ok=True)
        await asyncio.to_thread(pending.write_bytes, png)
        shot: dict[str, Any] = {"path": str(pending), "url": target["url"]}
        scrubbing = redact and getattr(manager.pii_scrubber, "screenshot_enabled", False) is True
        if scrubbing:
            # The controller's own redaction, as _capture_screenshot_redacted runs it for a page
            # screenshot, minus the words in the browser's UI strip. Strict mode deletes the image and
            # raises SCREENSHOT_WITHHELD.
            ocr = outside_strip(await manager.ocr.extract_from_image(str(pending)), strip)
            await manager.observation._scrub_screenshot_if_needed(session, shot, ocr)
        if read.moved():
            raise _moved()
        redaction = _redaction(redact, scrubbing, shot)
        await _audit_shot(manager, session, scope="screen", redaction=redaction, url=url, screenshot_url=target["url"])
        await asyncio.to_thread(os.replace, pending, final)
        pending = None
        data = await asyncio.to_thread(final.read_bytes)
        width, height = png_size(data)
        return {
            "url": url,
            "title": title,
            "screenshot_path": str(final),
            "screenshot_url": target["url"],
            "width": width,
            "height": height,
            "png": base64.b64encode(data).decode("ascii"),
            "pii_scrubbed": scrubbing and "pii_scrub_skipped" not in shot,
            "redaction": redaction,
            "chrome_strip": strip,
            **_scrub_disclosure(shot),
        }
    finally:
        if pending is not None:
            pending.unlink(missing_ok=True)
        session.lock.release()


async def page_shot(manager: Any, session_id: str, *, label: str = "manual", redact: bool = True) -> dict[str, Any]:
    """browser_screenshot scope "page" with the redact switch: the viewport, filed as an artifact."""
    from app.browser.services.observation import _scrub_disclosure

    if not redact:
        _refuse_unredacted(manager)
    session = await manager.get_session(session_id)
    manager._assert_page_allowed(session)
    await _acquire(session)
    shot: dict[str, Any] | None = None
    try:
        read = _page_read().start_read(manager, session)
        safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "-", label or "manual").strip(".-")[:100] or "manual"
        scrubbing = redact and getattr(manager.pii_scrubber, "screenshot_enabled", False) is True
        if redact:
            # Upstream's own path for browser.screenshot (strict mode withholds what it cannot scrub).
            shot = await manager.observation._capture_screenshot_redacted(session, safe_label)
        else:
            shot = await manager._capture_screenshot(session, safe_label)
        url = manager._shown_url(session.page)
        if read.moved():
            raise _moved()
        title = await _screen_title(session)
        redaction = _redaction(redact, scrubbing, shot)
        await _audit_shot(manager, session, scope="page", redaction=redaction, url=url, screenshot_url=shot["url"])
        data = await asyncio.to_thread(Path(shot["path"]).read_bytes)
        width, height = png_size(data)
        result = {
            "url": url,
            "title": title,
            "screenshot_path": shot["path"],
            "screenshot_url": shot["url"],
            "width": width,
            "height": height,
            "png": base64.b64encode(data).decode("ascii"),
            "pii_scrubbed": scrubbing and "pii_scrub_skipped" not in shot,
            "redaction": redaction,
            **_scrub_disclosure(shot),
        }
        shot = None
        return result
    finally:
        if shot is not None and shot.get("path"):
            # Refused after the capture: the image is not kept where a route could serve it.
            Path(shot["path"]).unlink(missing_ok=True)
        session.lock.release()


def _screen_refusal(exc: Exception) -> Any:
    from fastapi.responses import JSONResponse

    if isinstance(exc, ScreenRefused):
        return JSONResponse(status_code=exc.status, content={"detail": exc.detail, "code": exc.code})
    return JSONResponse(status_code=403, content={"detail": _page_read().MOVED_DETAIL, "code": "page_refused"})


def install_screen_routes(application: Any, manager: Any) -> None:
    """POST /happy/sessions/{session_id}/screen/front and .../screen/scrub (see above)."""
    from fastapi import Request

    async def front(session_id: str, request: Request) -> Any:
        try:
            body = await request.json()
        except Exception:
            body = {}
        activate = not (isinstance(body, dict) and body.get("activate") is False)
        redact = not (isinstance(body, dict) and body.get("redact") is False)
        try:
            return await screen_front(manager, session_id, activate=activate, redact=redact)
        except (ScreenRefused, PermissionError) as exc:
            return _screen_refusal(exc)

    async def scrub(session_id: str, request: Request) -> Any:
        try:
            body = await request.json()
            token, label = body["token"], body.get("label") or "manual"
            redact = body.get("redact", True)
            if not isinstance(token, str) or not isinstance(label, str) or not isinstance(body["png"], str):
                raise TypeError
            if not isinstance(redact, bool):
                raise TypeError
            png = base64.b64decode(body["png"], validate=True)
        except (ValueError, KeyError, TypeError, binascii.Error):
            return _screen_refusal(ScreenRefused(400, "bad_request", "expects {token, png (base64), label?, redact?}"))
        try:
            return await screen_scrub(manager, session_id, token=token, png=png, label=label, redact=redact)
        except (ScreenRefused, PermissionError) as exc:
            return _screen_refusal(exc)

    async def page(session_id: str, request: Request) -> Any:
        try:
            body = await request.json()
            if not isinstance(body, dict):
                raise TypeError
            label, redact = body.get("label") or "manual", body.get("redact", True)
            if not isinstance(label, str) or not isinstance(redact, bool):
                raise TypeError
        except (ValueError, TypeError):
            return _screen_refusal(ScreenRefused(400, "bad_request", "expects {label?, redact?}"))
        try:
            return await page_shot(manager, session_id, label=label, redact=redact)
        except (ScreenRefused, PermissionError) as exc:
            return _screen_refusal(exc)

    # This module's annotations are strings (from __future__), resolved in its globals, where
    # Request is not: without these FastAPI would take `request` for a query parameter.
    for handler in (front, scrub, page):
        handler.__annotations__["request"] = Request
    application.add_api_route("/happy/sessions/{session_id}/screen/front", front, methods=["POST"], include_in_schema=False)
    application.add_api_route("/happy/sessions/{session_id}/screen/scrub", scrub, methods=["POST"], include_in_schema=False)
    application.add_api_route("/happy/sessions/{session_id}/page-shot", page, methods=["POST"], include_in_schema=False)


def install_routes(application: Any, manager: Any) -> None:
    """GET /happy/sessions/{session_id}/focus and the screen routes, behind the controller's own auth middleware."""
    if getattr(application.state, "happy_focus_route", False):
        return

    async def focus(session_id: str) -> dict[str, Any]:
        # An unknown session, or another operator's, is a KeyError: the app's 404.
        session = await manager.get_session(session_id)
        try:
            manager._assert_page_allowed(session)
            return {"editable_focused": await editable_focused(session.page)}
        except Exception as exc:
            logger.debug("focus read failed: %s", type(exc).__name__)
            return {"editable_focused": None}

    application.add_api_route("/happy/sessions/{session_id}/focus", focus, methods=["GET"], include_in_schema=False)
    install_screen_routes(application, manager)
    application.state.happy_focus_route = True


def apply() -> None:
    from app.browser import page_read
    from app.browser.services import observation

    Service = observation.BrowserObservationService
    if getattr(Service, "_happy_live_frames", False):
        return
    for name, fn in build(observation, page_read).items():
        setattr(Service, name, fn)
    Service._happy_live_frames = True
    logger.warning("happy_live_frames: patched auto-browser %s share_snapshot/light_snapshot", EXPECTED_VERSION)


if os.environ.get("HAPPY_LIVE_FRAMES_NO_AUTOLOAD") != "1":
    verify()
    apply()
    from app.main import app, manager  # noqa: E402 - what uvicorn serves

    install_routes(app, manager)
