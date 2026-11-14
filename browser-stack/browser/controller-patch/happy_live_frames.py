"""Live frames while an action runs: a patch to auto-browser's controller 1.14.0.

The live view (bridge /live/<id>/frame.jpg) polls GET /share/<token>/observe, which runs
BrowserObservationService.share_snapshot. Upstream, that waits for the session lock, and an action
holds the lock from its before-snapshot to its after-snapshot, so the viewer saw nothing between an
action's start and its end: a navigation that took ten seconds was ten seconds of a frozen frame.

What this changes (share_snapshot and light_snapshot; and the scroll action, see "scroll" below):

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

A screen shot is the real X screen, as the node's capture read it: in view "desktop" the whole screen
with the desktop panel's clock (the node's own, in its TZ) across the top; in view "tab" only the
browser window's rectangle. Nothing is drawn on it or cropped from it here; the only change to the
captured pixels is the OCR PII redaction, and the result and the audit log say whether it ran.

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
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

logger = logging.getLogger("happy_live_frames")

EXPECTED_VERSION = "1.14.0"
# sha256 of the upstream files this patch replaces methods in, calls into, or must not widen.
EXPECTED_SHA256 = {
    "browser/services/observation.py": "14e63528b3bf1e9b4c7a8e4054fed59ebe7db6b37e06df1e0b3b3c1283dbf58c",
    "browser/page_read.py": "4622611ed2728a31489e160d85db1bb657149681525ffb9c62b7377a482af8ca",
    "artifacts.py": "01055666b7921868c8b2fc6aa331aee576bd09666c4cc3b54050aa9070edf5ab",
    # The share route: its token check is what keeps who can read a frame unchanged.
    "routes/share.py": "71949b2a687dc37c831ba82270987749ea1c9d8548aefbe0a19f643a9c075e42",
    # The scroll patch (see "scroll" below): actions.py has the methods it replaces; pipeline.py hands
    # verification the target dict the operation filled; browser_manager.py delegates to the service.
    "browser/services/actions.py": "861f865cf05a2c64102000decfac41f16701fde642ff898f3cb43cfe94c3a29a",
    "actions/pipeline.py": "0eed86efa2cfe54a1ea827d6a03bbceeba3914695625fd521681d9d4b1d4d31a",
    "browser_manager.py": "c5410eb4c2731102e75d575e46df6a44cbba5d39c660998936418ee1124364a3",
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


# ── the evidence time zone and view ─────────────────────────────────────────
#
# EVIDENCE_TZ: the zone the screenshot audit records (an IANA name; the browser node's TZ, which its
# panel clock shows, is set from the same value). SCREENSHOT_TIME_MODE: browser_screenshot's default
# view, "desktop" or "tab". A wrong value of either stops the controller at startup.

TZ_ENV = "EVIDENCE_TZ"
DEFAULT_TZ = "America/Toronto"
VIEW_ENV = "SCREENSHOT_TIME_MODE"
SCREENSHOT_VIEWS = ("desktop", "tab")
# Upstream's artifact names: SessionArtifactService.screenshot_target, UTC.
_NAME_STAMP = re.compile(r"^(\d{8}T\d{6}\d{1,6})Z")


class InvalidTimeZone(RuntimeError):
    pass


def tz_name() -> str:
    return os.environ.get(TZ_ENV, "").strip() or DEFAULT_TZ


def zone(name: str | None = None) -> ZoneInfo:
    name = tz_name() if name is None else name
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError, OSError) as exc:
        raise InvalidTimeZone(
            f"{TZ_ENV}={name!r} is not a time zone this controller knows (an IANA name such as America/Toronto)"
        ) from exc


def check_tz() -> str:
    """The configured zone's name; InvalidTimeZone if it is not one."""
    name = tz_name()
    zone(name)
    return name


def default_view() -> str:
    view = os.environ.get(VIEW_ENV, "").strip() or "desktop"
    if view not in SCREENSHOT_VIEWS:
        raise PatchMismatch(f"{VIEW_ENV}={view!r}: expected desktop or tab")
    return view


def iso(at: datetime) -> str:
    """UTC, milliseconds, Z: as JavaScript's toISOString."""
    at = at.astimezone(UTC)
    return at.strftime("%Y-%m-%dT%H:%M:%S.") + f"{at.microsecond // 1000:03d}Z"


def parse_iso(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value or len(value) > 64:
        return None
    try:
        at = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return at.astimezone(UTC) if at.tzinfo is not None else None


def captured_at_from_name(path: str | Path) -> datetime | None:
    """The capture time an upstream artifact name carries (%Y%m%dT%H%M%S%fZ-<label>.png)."""
    found = _NAME_STAMP.match(Path(path).name)
    if not found:
        return None
    try:
        return datetime.strptime(found.group(1), "%Y%m%dT%H%M%S%f").replace(tzinfo=UTC)
    except ValueError:
        return None


def clamp(claimed: datetime | None, earliest: datetime, latest: datetime) -> datetime:
    """A claimed capture time held between two known bounds; the earliest when there is no claim."""
    if claimed is None:
        return earliest
    return max(earliest, min(claimed, latest))


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
    # The screenshot audit records times in this zone, and every shot has a view: a wrong one must not start.
    check_tz()
    default_view()


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
#   1. POST /happy/sessions/{id}/screen/front {activate, redact, view?}: the session's tab is brought to
#      the front of its window (activate false: not, while the person holding the browser looks at it),
#      and must then be the tab the window shows (document.visibilityState). -> {token, url, title,
#      view, capture_rect}. The token keeps the page and its count of refused commits, as a PageRead
#      does. view (default SCREENSHOT_TIME_MODE): "desktop", the whole X screen, the desktop panel and
#      its clock included (capture_rect null: the whole root window); "tab", the browser window alone
#      (capture_rect: the window's rectangle in screen pixels, from its geometry), with no panel and
#      no clock.
#   2. The launcher captures the pod's X screen (scripts/screen-capture.py): the whole root window,
#      or capture_rect as XGetImage's rectangle (never a crop afterwards), and reports the capture's
#      own meta: captured_at (UTC, read just before XGetImage), the node's tz, the screen size, the
#      rectangle read, the panel's height (panel_px, measured from _NET_WORKAREA), and raw_sha256,
#      the sha256 of the PNG as it came out of the capture.
#   3. POST /happy/sessions/{id}/screen/scrub {token, png (base64), raw_sha256, capture, label?,
#      redact?}: refused unless sha256(png) is raw_sha256 (400 raw_hash_mismatch), the image is the
#      rectangle the view needs (desktop: the whole screen; tab: step 1's capture_rect), and the
#      session's page is still the one step 1 saw, on the same URL, still in front, and not refused.
#      The image is written outside the artifact tree, OCR-scrubbed through the controller's own
#      redaction, and only then moved into the session's artifact directory as
#      <stamp>Z-screen-<label>.png. Nothing is drawn on it: the clock is the panel's own, captured
#      with the screen. -> {url, title, screenshot_path, screenshot_url, width, height, png,
#      pii_scrubbed, redaction, chrome_strip, view, capture_rect, panel_px, evidence_bar_px,
#      captured_at, tz, raw_sha256, filed_sha256, address_bar_scheme?, screenshot_pii_scrub?}.
#      captured_at is the capture's time, held between step 1 and now; evidence_bar_px is the height
#      of the panel at the image's top (panel_px for desktop, 0 for tab). chrome_strip and OCR are in
#      the image's own pixels. (address_bar_scheme, for an https page: whether OCR saw "https://" in
#      the address bar; see ADDRESS_BAR_SCHEME). With PII_SCRUB_SCREENSHOT
#      off the image is stored as captured, as page screenshots are; PII_SCRUB_SCREENSHOT_STRICT
#      withholds an unscrubbable one (SCREENSHOT_WITHHELD, 503) as it does those.
#
# The browser's own UI strip (tab strip, address bar, toolbar: the top of the window, above the page)
# is never redacted: the URL in the address bar is the point of the evidence. Nor is the desktop panel
# (desktop view: the image's top panel_px rows, the window's button and the clock), which shows the
# time of the evidence. OCR reads the whole image; words that lie wholly inside the strip or the panel
# are dropped from the redaction boxes, and everything
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
# there is not kept. The audit entry records the view, capture_rect, panel_px, captured_at, tz,
# raw_sha256 (the capture as it came off the screen) and filed_sha256 (the image as filed: the same
# hash unless it was redacted). With redaction on, the raw capture is not kept anywhere.
#
# POST /happy/sessions/{id}/page-shot {label?, redact?} is browser_screenshot scope "page" with the
# same redact switch: upstream's capture of the page (viewport), with redaction through the
# controller's own _capture_screenshot_redacted when redact is true, as upstream's screenshot does,
# and without it when false; the same audit event as the screen shot (filed_sha256, captured_at from
# the artifact name, tz; raw_sha256 only when unredacted: upstream does not hand out its raw capture).

SCREEN_TOKEN_ATTR = "_happy_screen_tokens"
SCREEN_TOKEN_SECONDS = 30.0
SCREEN_MAX_BYTES = 48 * 1024 * 1024
SCREEN_PAGE_TIMEOUT_SECONDS = 5.0
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# Used only when the window's geometry cannot be read or makes no sense: the top of the screen, full
# width, this many pixels tall. It is Chromium's tab strip + toolbar (address bar) at devicePixelRatio 1
# in a maximized window, as measured live on a pod (1920x1200 Xvfb, fluxbox): outerHeight - innerHeight
# = 87. Kept at the measured height, not above it: a larger strip would leave the top of the page
# unredacted, a smaller one only redacts part of the address bar.
CHROME_STRIP_FALLBACK_PX = 87
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


def chrome_strip(
    geometry: dict[str, float] | None, width: int, height: int, *, origin: tuple[int, int] = (0, 0), top: int = 0
) -> dict[str, Any]:
    """The browser's UI strip (tab strip, address bar, toolbar) in image pixels: {x, y, width, height, source}.
    origin is the image's top-left corner on the screen (a tab view's capture_rect); top is where the
    window starts in the image when its geometry cannot be read (below the desktop panel)."""
    ox, oy = origin
    if geometry is not None:
        dpr = geometry["dpr"] if 0.5 <= geometry["dpr"] <= 4 else 0.0
        top_ui = geometry["outerHeight"] - geometry["innerHeight"]
        if dpr and 0 < top_ui <= CHROME_STRIP_MAX_CSS_PX and geometry["outerWidth"] > 0:
            left = max(0, round(geometry["screenX"] * dpr) - ox)
            upper = max(0, round(geometry["screenY"] * dpr) - oy)
            right = min(width, round((geometry["screenX"] + geometry["outerWidth"]) * dpr) - ox)
            bottom = min(height, round((geometry["screenY"] + top_ui) * dpr) - oy)
            if right > left and bottom > upper:
                return {"x": left, "y": upper, "width": right - left, "height": bottom - upper, "source": "window"}
    top = max(0, min(top, height - 1))
    return {"x": 0, "y": top, "width": width, "height": min(height - top, CHROME_STRIP_FALLBACK_PX), "source": "fallback"}


def window_rect(geometry: dict[str, float] | None) -> dict[str, int] | None:
    """The browser window's rectangle in screen pixels (the tab view's capture_rect), or None."""
    if geometry is None:
        return None
    dpr = geometry["dpr"] if 0.5 <= geometry["dpr"] <= 4 else 0.0
    if not dpr:
        return None
    rect = {
        "x": round(geometry["screenX"] * dpr),
        "y": round(geometry["screenY"] * dpr),
        "width": round(geometry["outerWidth"] * dpr),
        "height": round(geometry["outerHeight"] * dpr),
    }
    if rect["x"] < 0 or rect["y"] < 0 or rect["width"] < 1 or rect["height"] < 1:
        return None
    return rect


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


def outside_strip(ocr: Any, *strips: dict[str, Any]) -> Any:
    """The OCR result without the words in the UI strip (or the panel), in both lists redaction may read."""
    if not isinstance(ocr, dict) or ocr.get("available", True) is False:
        return ocr
    out = dict(ocr)
    for key in ("redaction_blocks", "blocks"):
        if isinstance(ocr.get(key), list):
            out[key] = [b for b in ocr[key] if not any(_in_strip(b, strip) for strip in strips)]
    return out


# The address bar's scheme, a check on the evidence, never a reason to refuse it. kiosk/policy.json sets
# ShowFullUrlsInAddressBar, so an https page's address bar reads "https://host/..."; without it Chrome
# shows the host alone. For a session on an https URL the result says whether OCR saw the scheme in the
# toolbar row of the UI strip (address_bar_scheme true/false), or "unknown" when OCR is off or could not
# run. The whole-image OCR the scrub already ran is read first; when it did not run or did not see the
# scheme, the strip alone is read again, enlarged (small UI text reads better so). OCR may misread
# "https:" as "https;" or drop a slash; those still count.
ADDRESS_BAR_SCHEME = re.compile(r"\bhttps\s?[:;.,]?\s?/{1,2}", re.IGNORECASE)
# The tab strip is the top of the UI strip, the toolbar (with the address bar) below it: only words whose
# middle lies below this fraction of the strip's height count, so a tab title cannot answer for the URL.
ADDRESS_BAR_TOP_FRACTION = 0.4
ADDRESS_BAR_OCR_SCALE = 2


def scheme_seen(ocr: Any, strip: dict[str, Any]) -> bool | None:
    """Whether OCR read an https scheme in the strip's toolbar row; None when OCR did not run."""
    if not isinstance(ocr, dict) or ocr.get("available", True) is False:
        return None
    blocks = ocr.get("redaction_blocks")
    if not isinstance(blocks, list):
        blocks = ocr.get("blocks") if isinstance(ocr.get("blocks"), list) else []
    top = strip["y"] + strip["height"] * ADDRESS_BAR_TOP_FRACTION
    for block in blocks:
        if not isinstance(block, dict) or not _in_strip(block, strip):
            continue
        try:
            middle = int(block["bbox"]["y"]) + int(block["bbox"]["height"]) / 2
        except (KeyError, TypeError, ValueError):
            continue
        if middle >= top and ADDRESS_BAR_SCHEME.search(str(block.get("text") or "")):
            return True
    return False


async def _strip_ocr(manager: Any, png: bytes, strip: dict[str, Any], scratch: Path) -> tuple[Any, dict[str, Any]]:
    """OCR of the UI strip alone, enlarged: (ocr, the strip in the crop's own pixels)."""
    import io

    from PIL import Image

    scale = ADDRESS_BAR_OCR_SCALE

    def crop() -> None:
        with Image.open(io.BytesIO(png)) as image:
            box = (strip["x"], strip["y"], strip["x"] + strip["width"], strip["y"] + strip["height"])
            part = image.crop(box).convert("L")
            part.resize((part.width * scale, part.height * scale), Image.LANCZOS).save(scratch, format="PNG")

    try:
        await asyncio.to_thread(crop)
        ocr = await manager.ocr.extract_from_image(str(scratch))
    finally:
        await asyncio.to_thread(scratch.unlink, True)
    return ocr, {"x": 0, "y": 0, "width": strip["width"] * scale, "height": strip["height"] * scale}


async def address_bar_scheme(
    manager: Any, *, url: str, png: bytes, strip: dict[str, Any], ocr: Any, scratch: Path
) -> bool | str | None:
    """The result's address_bar_scheme for a session on an https URL (None, left out, for any other)."""
    if not url.lower().startswith("https://"):
        return None
    seen = scheme_seen(ocr, strip)
    if seen is not True:
        try:
            again = scheme_seen(*await _strip_ocr(manager, png, strip, scratch))
        except Exception as exc:
            logger.info("address bar scheme: the strip could not be read: %s", type(exc).__name__)
            again = None
        seen = again if again is not None else seen
    if seen is None:
        return "unknown"
    if seen is False:
        logger.warning(
            "address bar scheme: OCR did not see https:// in the address bar of a screen shot of an https page "
            "(is ShowFullUrlsInAddressBar in the browser's managed policy?)"
        )
    return seen


def _redaction(redact: bool, scrubbing: bool, shot: dict[str, Any]) -> str:
    """The result's redaction field: off_by_request, on, off_by_policy, unavailable."""
    if not redact:
        return "off_by_request"
    if not scrubbing:
        return "off_by_policy"  # PII_SCRUB_SCREENSHOT off: page screenshots are not scrubbed either
    if "pii_scrub_skipped" in shot:
        return "unavailable"  # OCR could not run; screenshot_pii_scrub says why
    return "on"


async def _audit_shot(
    manager: Any,
    session: Any,
    *,
    scope: str,
    redaction: str,
    url: str,
    screenshot_url: str,
    evidence: dict[str, Any] | None = None,
) -> None:
    """The evidence trail for one browser_screenshot: whether it was redacted, and the evidence fields
    (filed_sha256, raw_sha256, captured_at, tz, and for a screen shot view, panel_px, capture_rect). An
    unredacted shot that cannot be recorded is refused (ScreenRefused 503) before it is filed."""
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
                **(evidence or {}),
            },
        )
    except Exception as exc:
        logger.warning("evidence screenshot: audit failed: %s", type(exc).__name__)
        if redaction != "on":
            raise ScreenRefused(
                503, "audit_failed", "The unredacted screenshot could not be recorded in the audit log, so it was not kept."
            ) from None


def _view(view: str | None) -> str:
    view = default_view() if view is None else view
    if view not in SCREENSHOT_VIEWS:
        raise ScreenRefused(400, "bad_view", "view must be desktop or tab")
    return view


def _int(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _rect(value: Any) -> dict[str, int] | None:
    if not isinstance(value, dict) or set(value) != {"x", "y", "width", "height"}:
        return None
    rect = {k: _int(value[k]) for k in ("x", "y", "width", "height")}
    if any(v is None for v in rect.values()) or rect["x"] < 0 or rect["y"] < 0 or rect["width"] < 1 or rect["height"] < 1:
        return None
    return rect  # type: ignore[return-value]


def capture_meta(capture: Any, *, view: str, expected: dict[str, int] | None, width: int, height: int) -> dict[str, Any]:
    """The launcher's account of a capture, checked against the image and the view:
    {captured_at (datetime), tz, screen, capture_rect, panel_px}. ScreenRefused 400 bad_capture if it
    does not hold."""

    def bad(why: str) -> ScreenRefused:
        return ScreenRefused(400, "bad_capture", f"The capture's meta does not hold: {why}.")

    if not isinstance(capture, dict):
        raise bad("no capture meta")
    at = parse_iso(capture.get("captured_at"))
    if at is None:
        raise bad("no captured_at")
    screen = capture.get("screen")
    sw = _int(screen.get("width")) if isinstance(screen, dict) else None
    sh = _int(screen.get("height")) if isinstance(screen, dict) else None
    if not sw or not sh or sw < 1 or sh < 1:
        raise bad("no screen size")
    rect = _rect(capture.get("capture_rect"))
    if rect is None or rect["x"] + rect["width"] > sw or rect["y"] + rect["height"] > sh:
        raise bad("capture_rect is not a rectangle of the screen")
    if (rect["width"], rect["height"]) != (width, height):
        raise bad("the image is not the size of capture_rect")
    want = {"x": 0, "y": 0, "width": sw, "height": sh} if view == "desktop" else expected
    if rect != want:
        raise bad(f"capture_rect is not the {view} view's rectangle")
    panel = _int(capture.get("panel_px"))
    if panel is None or not 0 <= panel < sh:
        raise bad("no panel_px")
    tz = capture.get("tz")
    if tz is not None and (not isinstance(tz, str) or len(tz) > 64):
        raise bad("tz is not a zone name")
    return {"captured_at": at, "tz": tz, "screen": {"width": sw, "height": sh}, "capture_rect": rect, "panel_px": panel}


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
    manager: Any, session_id: str, *, activate: bool = True, redact: bool = True, view: str | None = None
) -> dict[str, Any]:
    """Step 1: the session's tab in front of its window, and a token for step 3."""
    view = _view(view)
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
        geometry = _geometry(state)
        rect = window_rect(geometry) if view == "tab" else None
        if view == "tab" and rect is None:
            raise ScreenRefused(
                409, "no_window", "The browser window's position could not be read, so its tab view cannot be captured."
            )
        token = secrets.token_hex(16)
        _screen_tokens(session)[token] = {
            "read": read,
            "url": url,
            "geometry": geometry,
            "view": view,
            "rect": rect,
            "at": time.monotonic(),
            # The earliest the capture can be: its claimed capture time is held to this and now.
            "wall": datetime.now(UTC),
        }
        return {"token": token, "url": url, "title": title, "view": view, "capture_rect": rect}
    finally:
        session.lock.release()


async def screen_scrub(
    manager: Any,
    session_id: str,
    *,
    token: str,
    png: bytes,
    raw_sha256: str | None = None,
    capture: Any = None,
    label: str = "manual",
    redact: bool = True,
) -> dict[str, Any]:
    """Step 3: check the capture is the one the launcher took (raw_sha256) of the rectangle the view
    needs, and the page has not moved since step 1; scrub it and file it as an artifact. The capture's
    captured_at is held between step 1's time and now."""
    from app.browser.services.observation import _scrub_disclosure

    if not redact:
        _refuse_unredacted(manager)
    if len(png) > SCREEN_MAX_BYTES:
        raise ScreenRefused(413, "too_large", "screen image too large")
    width, height = png_size(png)
    raw_hash = hashlib.sha256(png).hexdigest()
    if not isinstance(raw_sha256, str) or not secrets.compare_digest(raw_sha256.lower(), raw_hash):
        raise ScreenRefused(
            400, "raw_hash_mismatch", "The image is not the one the capture produced (its sha256 differs), so it was not kept."
        )
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
        view = entry["view"]
        meta = capture_meta(capture, view=view, expected=entry["rect"], width=width, height=height)
        rect = meta["capture_rect"]
        # The panel is in the image only in the desktop view, at its top.
        bar_px = meta["panel_px"] if view == "desktop" else 0
        strip = chrome_strip(geometry, width, height, origin=(rect["x"], rect["y"]), top=bar_px)
        keep = [strip] + ([{"x": 0, "y": 0, "width": width, "height": bar_px}] if bar_px else [])
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
        ocr: Any = None
        if scrubbing:
            # The controller's own redaction, as _capture_screenshot_redacted runs it for a page
            # screenshot, minus the words in the browser's UI strip. Strict mode deletes the image and
            # raises SCREENSHOT_WITHHELD.
            ocr = await manager.ocr.extract_from_image(str(pending))
            await manager.observation._scrub_screenshot_if_needed(session, shot, outside_strip(ocr, *keep))
        scheme = await address_bar_scheme(
            manager, url=url, png=png, strip=strip, ocr=ocr, scratch=pending_dir / (final.stem + "-strip.png")
        )
        if read.moved():
            raise _moved()
        redaction = _redaction(redact, scrubbing, shot)
        data = await asyncio.to_thread(pending.read_bytes)
        evidence = {
            "view": view,
            "capture_rect": rect,
            "panel_px": meta["panel_px"],
            "evidence_bar_px": bar_px,
            "captured_at": iso(clamp(meta["captured_at"], entry["wall"], datetime.now(UTC))),
            "tz": meta["tz"] or tz_name(),
            "raw_sha256": raw_hash,
            "filed_sha256": hashlib.sha256(data).hexdigest(),
        }
        await _audit_shot(
            manager, session, scope="screen", redaction=redaction, url=url, screenshot_url=target["url"], evidence=evidence
        )
        await asyncio.to_thread(os.replace, pending, final)
        pending = None
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
            **evidence,
            **({} if scheme is None else {"address_bar_scheme": scheme}),
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
        data = await asyncio.to_thread(Path(shot["path"]).read_bytes)
        filed = hashlib.sha256(data).hexdigest()
        evidence = {
            "evidence_bar_px": 0,
            # The capture's own time, from its artifact name.
            "captured_at": iso(captured_at_from_name(shot["path"]) or datetime.now(UTC)),
            "tz": tz_name(),
            # Upstream's redacted capture never hands out its raw image; an unredacted one is filed as is.
            **({"raw_sha256": filed} if redaction == "off_by_request" else {}),
            "filed_sha256": filed,
        }
        await _audit_shot(
            manager, session, scope="page", redaction=redaction, url=url, screenshot_url=shot["url"], evidence=evidence
        )
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
            **evidence,
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
        view = body.get("view") if isinstance(body, dict) else None
        if view is not None and view not in SCREENSHOT_VIEWS:
            return _screen_refusal(ScreenRefused(400, "bad_view", "view must be desktop or tab"))
        try:
            return await screen_front(manager, session_id, activate=activate, redact=redact, view=view)
        except (ScreenRefused, PermissionError) as exc:
            return _screen_refusal(exc)

    async def scrub(session_id: str, request: Request) -> Any:
        try:
            body = await request.json()
            token, label = body["token"], body.get("label") or "manual"
            redact = body.get("redact", True)
            raw_sha256, capture = body["raw_sha256"], body["capture"]
            if not isinstance(token, str) or not isinstance(label, str) or not isinstance(body["png"], str):
                raise TypeError
            if not isinstance(redact, bool) or not isinstance(raw_sha256, str) or not isinstance(capture, dict):
                raise TypeError
            png = base64.b64decode(body["png"], validate=True)
        except (ValueError, KeyError, TypeError, binascii.Error):
            return _screen_refusal(
                ScreenRefused(400, "bad_request", "expects {token, png (base64), raw_sha256, capture, label?, redact?}")
            )
        try:
            return await screen_scrub(
                manager, session_id, token=token, png=png, raw_sha256=raw_sha256, capture=capture, label=label, redact=redact
            )
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


# ── scroll ──────────────────────────────────────────────────────────────────
#
# Upstream's scroll action (app/browser/services/actions.py, BrowserActionService.scroll) is
# ``page.mouse.wheel(delta_x, delta_y)`` and nothing else, so:
#
# - The wheel goes wherever the mouse happens to be: (0, 0) on a page nothing has clicked yet. A page
#   whose document does not scroll, and which scrolls an inner container instead (an app shell with a
#   sidebar and an ``overflow: auto`` main pane, as most single-page apps are), gets its wheel over
#   the sidebar or the header, and nothing moves.
# - The action's x/y are dropped (_dispatch_decision passes only the deltas), so pointing the wheel at
#   the container does not help either.
# - Verification looks for a changed URL, title, focus or text excerpt; the text excerpt is the start
#   of ``document.body.innerText``, which a scroll does not change. A scroll that worked was reported
#   as ``verified: false`` too, on any page.
#
# What this changes (BrowserActionService.scroll, _dispatch_decision for scroll only, and
# action_verification for scroll only; nothing else):
#
# - The wheel is sent at a point: the action's x/y when given (clamped into the viewport); otherwise
#   the viewport's centre when the document itself can scroll that way, or else the centre of the
#   visible part of the largest element that can.
# - The scroll offsets of every scroller under that point (its scrollable ancestors, through shadow
#   roots, and the document) are read before and after. If the wheel moved none of them, the nearest
#   one that can scroll that way is scrolled by script, by the same deltas. A point inside a frame is
#   left to the wheel: the frame's own scrollers are not read from here.
# - What moved is recorded in the action's target as ``scroll`` (the point, how it was chosen, wheel
#   or script, and each scroller's offsets before and after), and verification counts a moved
#   scroller as the signal ``scroll_position_changed``.
#
# The page scripts run in the page's main world, read-only but for the fallback's ``scrollBy``; they
# set nothing on the page (the scrollers are held through a JS handle, disposed after).
#
# Pinned with the rest (EXPECTED_SHA256): actions.py, pipeline.py, browser_manager.py.

# How long to wait for the wheel's scroll (smooth scrolling animates it) before the script fallback,
# and how often to look.
SCROLL_WHEEL_WAIT_SECONDS = 1.0
SCROLL_POLL_SECONDS = 0.05
SCROLL_SIGNAL = "scroll_position_changed"


# Picks the point and collects the scrollers under it. Returns an object held as a JS handle:
# { x, y, point, frame, scrollers: [Element|null] } (null stands for the document's own scroll).
SCROLL_PICK_SCRIPT = r"""
({ dx, dy, x, y }) => {
  const vw = window.innerWidth, vh = window.innerHeight;
  const doc = document.scrollingElement || document.documentElement;
  const style = (el) => getComputedStyle(el);
  const scrollsY = (el) => el.scrollHeight > el.clientHeight + 1 && /(auto|scroll|overlay)/.test(style(el).overflowY);
  const scrollsX = (el) => el.scrollWidth > el.clientWidth + 1 && /(auto|scroll|overlay)/.test(style(el).overflowX);
  // The viewport takes the root's overflow, or the body's when the root's is visible; the body then
  // does not scroll on its own (and does when the root's is not visible).
  const rootStyle = style(document.documentElement), bodyStyle = document.body ? style(document.body) : null;
  const viewportOverflow = (prop) => rootStyle[prop] !== 'visible' ? rootStyle[prop] : (bodyStyle ? bodyStyle[prop] : 'visible');
  const bodyOwn = !!document.body && document.body !== doc && rootStyle.overflowY !== 'visible';
  const docScrolls = (axis) => {
    const v = viewportOverflow(axis === 'y' ? 'overflowY' : 'overflowX');
    if (v === 'hidden' || v === 'clip') return false;
    return axis === 'y' ? doc.scrollHeight > vh + 1 : doc.scrollWidth > vw + 1;
  };
  const room = (el) => {
    if (el === null) {
      return {
        y: docScrolls('y') && (dy > 0 ? window.scrollY + vh < doc.scrollHeight - 1 : dy < 0 && window.scrollY > 0),
        x: docScrolls('x') && (dx > 0 ? window.scrollX + vw < doc.scrollWidth - 1 : dx < 0 && window.scrollX > 0),
      };
    }
    return {
      y: scrollsY(el) && (dy > 0 ? el.scrollTop + el.clientHeight < el.scrollHeight - 1 : dy < 0 && el.scrollTop > 0),
      x: scrollsX(el) && (dx > 0 ? el.scrollLeft + el.clientWidth < el.scrollWidth - 1 : dx < 0 && el.scrollLeft > 0),
    };
  };
  const canGo = (el) => { const r = room(el); return (dy !== 0 && r.y) || (dx !== 0 && r.x); };
  const parentOf = (el) => el.parentElement || (el.parentNode && el.parentNode.host) || null;
  const deepAt = (px, py) => {
    let el = document.elementFromPoint(px, py);
    while (el && el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(px, py);
      if (!inner || inner === el) break;
      el = inner;
    }
    return el;
  };
  const contains = (outer, el) => { for (let e = el; e; e = parentOf(e)) if (e === outer) return true; return false; };
  const clamp = (v, hi) => Math.min(Math.max(0, v), Math.max(0, hi - 1));

  let px, py, point;
  if (typeof x === 'number' && typeof y === 'number') {
    px = clamp(x, vw); py = clamp(y, vh); point = 'given';
  } else if (canGo(null)) {
    px = vw / 2; py = vh / 2; point = 'viewport_centre';
  } else {
    let best = null, bestArea = 0;
    for (const el of document.querySelectorAll('*')) {
      if (el === document.documentElement || el === doc || (el === document.body && !bodyOwn)) continue;
      if (el.scrollHeight <= el.clientHeight + 1 && el.scrollWidth <= el.clientWidth + 1) continue;
      if (!canGo(el)) continue;
      const r = el.getBoundingClientRect();
      const w = Math.min(r.right, vw) - Math.max(r.left, 0), h = Math.min(r.bottom, vh) - Math.max(r.top, 0);
      if (w <= 0 || h <= 0) continue;
      if (w * h > bestArea) { best = { el, l: Math.max(r.left, 0), t: Math.max(r.top, 0), w, h }; bestArea = w * h; }
    }
    if (best) {
      point = 'largest_scroller';
      const tries = [[0.5, 0.5], [0.5, 0.25], [0.5, 0.75], [0.25, 0.5], [0.75, 0.5]];
      [px, py] = [best.l + best.w / 2, best.t + best.h / 2];
      for (const [fx, fy] of tries) {
        const cx = best.l + best.w * fx, cy = best.t + best.h * fy;
        if (contains(best.el, deepAt(cx, cy))) { px = cx; py = cy; break; }
      }
    } else {
      px = vw / 2; py = vh / 2; point = 'viewport_centre';
    }
  }
  px = Math.round(px); py = Math.round(py);

  const hit = deepAt(px, py);
  const frame = !!hit && /^(IFRAME|FRAME|EMBED|OBJECT)$/.test(hit.tagName);
  const scrollers = [];
  for (let el = hit; el; el = parentOf(el)) {
    if (el === document.documentElement || el === doc || (el === document.body && !bodyOwn)) continue;
    if (scrollsY(el) || scrollsX(el)) scrollers.push(el);
  }
  scrollers.push(null);
  return { x: px, y: py, point, frame, scrollers, canGo, room };
}
"""

# The scrollers' offsets now: [{ element, left, top }], the document as "document".
SCROLL_READ_SCRIPT = r"""
(held) => held.scrollers.map((el) => {
  if (el === null) return { element: 'document', left: Math.round(window.scrollX), top: Math.round(window.scrollY) };
  let name = el.tagName.toLowerCase();
  if (el.id) name += '#' + el.id;
  const cls = typeof el.className === 'string' ? el.className.trim().split(/\s+/)[0] : '';
  if (cls) name += '.' + cls;
  return { element: name.slice(0, 80), left: Math.round(el.scrollLeft), top: Math.round(el.scrollTop), gone: !el.isConnected };
})
"""

# The fallback: the nearest scroller under the point that can scroll that way, by the deltas.
# Returns its index in held.scrollers, or -1 when none can.
SCROLL_FALLBACK_SCRIPT = r"""
(held, [dx, dy]) => {
  const i = held.scrollers.findIndex((el) => (el === null || el.isConnected) && held.canGo(el));
  if (i < 0) return -1;
  const el = held.scrollers[i];
  if (el === null) window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
  else el.scrollBy({ left: dx, top: dy, behavior: 'instant' });
  return i;
}
"""

SCROLL_INFO_SCRIPT = "(held) => ({ x: held.x, y: held.y, point: held.point, frame: held.frame })"


def _scroll_moved(before: list[dict[str, Any]], after: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out = []
    for b, a in zip(before, after):
        if (b["left"], b["top"]) != (a["left"], a["top"]):
            out.append({"element": b["element"], "from": [b["left"], b["top"]], "to": [a["left"], a["top"]]})
    return out


async def _scroll_until_moved(held: Any, before: list[dict[str, Any]], wait_s: float) -> list[dict[str, Any]]:
    """The offsets once they have moved and come to rest, or as they are after wait_s if nothing moved."""
    deadline = time.monotonic() + wait_s
    now = await held.evaluate(SCROLL_READ_SCRIPT)
    while not _scroll_moved(before, now) and time.monotonic() < deadline:
        await asyncio.sleep(SCROLL_POLL_SECONDS)
        now = await held.evaluate(SCROLL_READ_SCRIPT)
    if _scroll_moved(before, now):
        # Smooth scrolling animates: read until two reads agree (bounded by the same wait).
        rest_deadline = time.monotonic() + wait_s
        while time.monotonic() < rest_deadline:
            await asyncio.sleep(SCROLL_POLL_SECONDS * 2)
            again = await held.evaluate(SCROLL_READ_SCRIPT)
            if again == now:
                break
            now = again
    return now


async def scroll_page(
    page: Any,
    delta_x: float,
    delta_y: float,
    x: float | None = None,
    y: float | None = None,
    *,
    settle: Any = None,
    wheel_wait_s: float = SCROLL_WHEEL_WAIT_SECONDS,
) -> dict[str, Any]:
    """Wheel at a point that scrolls, fall back to scrolling the scroller under it; report what moved."""
    held = await page.evaluate_handle(SCROLL_PICK_SCRIPT, {"dx": delta_x, "dy": delta_y, "x": x, "y": y})
    try:
        info = await held.evaluate(SCROLL_INFO_SCRIPT)
        before = await held.evaluate(SCROLL_READ_SCRIPT)
        await page.mouse.move(info["x"], info["y"])
        await page.mouse.wheel(delta_x, delta_y)
        after = await _scroll_until_moved(held, before, wheel_wait_s)
        method = "wheel"
        if not _scroll_moved(before, after) and not info["frame"]:
            index = await held.evaluate(SCROLL_FALLBACK_SCRIPT, [delta_x, delta_y])
            if index >= 0:
                method = "script"
                after = await _scroll_until_moved(held, before, wheel_wait_s)
        if settle is not None:
            await settle()
        final = await held.evaluate(SCROLL_READ_SCRIPT)
        moved = _scroll_moved(before, final)
        if not moved and method == "script":
            moved = _scroll_moved(before, after)
    finally:
        try:
            await held.dispose()
        except Exception:  # the page went away (a scroll that navigated): nothing to free
            pass
    report: dict[str, Any] = {
        "x": info["x"],
        "y": info["y"],
        "point": info["point"],
        "method": method if moved else "none",
        "moved": bool(moved),
        "scrolled": moved,
    }
    if info["frame"]:
        # The wheel went into a frame, whose scrollers are not read from the top document.
        report["into_frame"] = True
        if not moved:
            report["moved"] = None
            report["method"] = "wheel"
    elif not moved:
        report["reason"] = "nothing under the point could scroll further that way"
    return report


def build_scroll(actions_module: Any) -> dict[str, Any]:
    Service = actions_module.BrowserActionService
    upstream_dispatch = Service._dispatch_decision
    upstream_verification = Service.action_verification  # the plain function (staticmethod unwrapped)

    async def scroll(
        self: Any,
        session_id: str,
        delta_x: float,
        delta_y: float,
        x: float | None = None,
        y: float | None = None,
    ) -> dict[str, Any]:
        session = await self.manager.get_session(session_id)
        target: dict[str, Any] = {"delta_x": delta_x, "delta_y": delta_y}
        if x is not None and y is not None:
            target["x"], target["y"] = x, y

        async def operation() -> None:
            target["scroll"] = await scroll_page(
                session.page, delta_x, delta_y, x, y, settle=lambda: self.manager._settle(session.page)
            )

        return await self.manager._run_action(session, "scroll", target, operation)

    async def _dispatch_decision(self: Any, session_id: str, decision: Any, *, approval_id: str | None) -> dict[str, Any]:
        if decision.action == "scroll":
            return await self.scroll(session_id, decision.delta_x, decision.delta_y, x=decision.x, y=decision.y)
        return await upstream_dispatch(self, session_id, decision, approval_id=approval_id)

    def action_verification(
        action_name: str,
        target: dict[str, Any],
        before: dict[str, Any],
        after: dict[str, Any],
    ) -> dict[str, Any]:
        result = upstream_verification(action_name, target, before, after)
        if action_name == "scroll" and isinstance(target.get("scroll"), dict) and target["scroll"].get("moved"):
            result = {**result, "signals": [*result["signals"], SCROLL_SIGNAL], "verified": True}
        return result

    return {
        "scroll": scroll,
        "_dispatch_decision": _dispatch_decision,
        "action_verification": staticmethod(action_verification),
    }


def apply() -> None:
    from app.browser import page_read
    from app.browser.services import observation

    Service = observation.BrowserObservationService
    if getattr(Service, "_happy_live_frames", False):
        return
    for name, fn in build(observation, page_read).items():
        setattr(Service, name, fn)
    Service._happy_live_frames = True
    from app.browser.services import actions

    for name, fn in build_scroll(actions).items():
        setattr(actions.BrowserActionService, name, fn)
    logger.warning(
        "happy_live_frames: patched auto-browser %s share_snapshot/light_snapshot and scroll; screenshot audit in %s, default view %s",
        EXPECTED_VERSION,
        tz_name(),
        default_view(),
    )


if os.environ.get("HAPPY_LIVE_FRAMES_NO_AUTOLOAD") != "1":
    verify()
    apply()
    from app.main import app, manager  # noqa: E402 - what uvicorn serves

    install_routes(app, manager)
