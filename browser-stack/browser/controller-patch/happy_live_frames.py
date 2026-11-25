"""Live frames while an action runs: a patch to auto-browser's controller 1.14.0.

The live view (bridge /live/<id>/frame.jpg) polls GET /share/<token>/observe, which runs
BrowserObservationService.share_snapshot. Upstream, that waits for the session lock, and an action
holds the lock from its before-snapshot to its after-snapshot, so the viewer saw nothing between an
action's start and its end: a navigation that took ten seconds was ten seconds of a frozen frame.

What this changes (share_snapshot and light_snapshot; the scroll action, see "scroll" below; and a new tab
the person opens, see "a new tab the person opens" below):

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
Before it reads, it makes the tab the person has in front the session's page (see "a new tab the
person opens" below, which also lets a tab the person opens with Ctrl+T or the tab strip's "+" work).

And two routes for browser_screenshot's whole-screen capture (see "the whole-screen screenshot" below):
POST /happy/sessions/{session_id}/screen/front brings the session's tab to the front and hands out a
one-use token; POST /happy/sessions/{session_id}/screen/scrub takes the PNG the bridge had the pod's
node capture, checks the page did not move, OCR-scrubs it through the controller's own redaction and
files it in the session's artifact directory, as a page screenshot is.

A screen shot is the real X screen, as the node's capture read it: in view "desktop" the whole screen
with the desktop panel's clock (the node's own, in its TZ) across the top; in view "tab" only the
browser window's rectangle. Nothing is drawn on it or cropped from it here; the only change to the
captured pixels is the OCR PII redaction, and the result and the audit log say whether it ran.

And one route for vault_save_download (see "a download saved to the vault" below):
DELETE /happy/sessions/{session_id}/downloads/{download_id}?sha256=<hex> removes one completed download
of a live session from disk, from session.downloads and from downloads.jsonl, only when the file still
hashes to the sha256 the caller verified in the vault. It always needs the bearer token, even where
tokenless loopback is allowed.

And one route for browser_stage_upload (see "a file staged for upload" below):
POST /happy/sessions/{session_id}/uploads?name=<basename>&sha256=<hex> writes the request body, at most
UPLOAD_MAX_BYTES, as one new file in that live session's own upload directory, checked against the
sha256, so the upload action can then put it into a page (with the person's approval). It always needs
the bearer token, even where tokenless loopback is allowed.

And a completed download keeps group read and write (see "downloads the host agent can use" below), and
the controller runs with umask 0007, so the host agent's ACL entry on the downloads and uploads
directories is not cancelled by a file's mode.

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
    # New tabs (see "a new tab the person opens"): the page guard and attach_popup's hold, the provenance
    # it records, and the tab activate adopt_tab mirrors to follow the person's tab.
    "browser/services/diagnostics.py": "513ba73b6ae613e2d428a09417f5d52e328803e4ca87411f777c9912ae116adc",
    "browser/page_provenance.py": "e7f89cc529daee1cb489995388d562052400ae764d5f406d7b91c1213b2f5544",
    "browser/services/tabs.py": "04c52a6b8428c144df4b75af0618fb117e2b1c4671d057cad57b3d408d1d9daf",
    # The download delete route (see "a download saved to the vault"): the record and downloads.jsonl
    # capture writes, the persist that stores session.downloads, and the bearer credential check.
    "downloads.py": "fa807e5e65061f9e36f408c7f57119d4cd53cfeb51aa91fd8ce2d169630d2ff2",
    "browser/services/sessions.py": "ce85ac6d854c75abbbf3233bbceacfecfc98d1a2c9f2b88f89f474c8a610fa9c",
    "auth_policy.py": "42070495ddaabc914441e84d38553351a5e550cdd5452166ac527df8db5deef5",
    # The upload staging route (see "a file staged for upload"): the upload action's safe_path is what
    # accepts a file in session.upload_dir, so the path the route hands back must be one it takes.
    "browser/services/uploads.py": "9da0572f3a3ae0bad4722aec85f7b0f78360744788d576212c2b890f07541cb1",
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


# ── a download saved to the vault ───────────────────────────────────────────
#
# The secret filler's vault_save_download fetches a download's bytes from /artifacts, stores them as
# an encrypted attachment in the vault, reads the attachment back and checks its sha256. Only then does
# it call DELETE /happy/sessions/{session_id}/downloads/{download_id}?sha256=<hex>, which:
#
# - needs a bearer credential the controller knows, checked here as well as by the middleware, so a
#   controller with API_ALLOW_TOKENLESS_LOOPBACK still refuses a tokenless delete (401);
# - acts only on a live session (manager.sessions; get_session's owner check applies) and on one
#   completed record in its session.downloads (404 otherwise);
# - removes only a regular file (not a symlink) directly inside artifact_root/<session>/downloads
#   (403 otherwise), and only when the file's sha256 is the one given (409 otherwise: kept);
# - then drops the record from session.downloads and from downloads.jsonl (rewritten through a
#   temporary file and a rename), persists the session, and records a download_deleted audit event
#   with the download id, sha256 and size. It never returns or logs the file's name, bytes or source.
#
# Pinned with the rest (EXPECTED_SHA256): downloads.py, browser/services/sessions.py, auth_policy.py.

_DOWNLOAD_ID = re.compile(r"^[0-9a-f]{12}$")
_SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")


class DownloadRefused(Exception):
    def __init__(self, status: int, code: str, detail: str) -> None:
        super().__init__(detail)
        self.status, self.code, self.detail = status, code, detail


def _hash_file(path: Path) -> tuple[str, int]:
    h = hashlib.sha256()
    size = 0
    with open(path, "rb") as fh:
        while chunk := fh.read(1 << 20):
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size


def _rewrite_jsonl_without(path: Path, download_id: str) -> None:
    """downloads.jsonl without the lines whose record has this id; the rest kept byte for byte."""
    import json

    if not path.exists():
        return
    kept: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines(keepends=True):
        try:
            if json.loads(line).get("id") == download_id:
                continue
        except (ValueError, AttributeError):
            pass
        kept.append(line)
    tmp = path.with_name(f".{path.name}.{secrets.token_hex(4)}.tmp")
    tmp.write_text("".join(kept), encoding="utf-8")
    os.replace(tmp, path)


async def delete_download(manager: Any, session_id: str, download_id: str, sha256: str) -> dict[str, Any]:
    if not _DOWNLOAD_ID.match(download_id or ""):
        raise DownloadRefused(400, "bad_request", "download_id must be 12 hex characters")
    if not _SHA256_HEX.match(sha256 or ""):
        raise DownloadRefused(400, "bad_request", "sha256 must be 64 lower-case hex characters")
    try:
        session = await manager.get_session(session_id)
    except KeyError:
        raise DownloadRefused(404, "not_found", "no such live session") from None
    if manager.sessions.get(session_id) is not session:
        raise DownloadRefused(404, "not_found", "no such live session")
    record = next((d for d in session.downloads if isinstance(d, dict) and d.get("id") == download_id), None)
    if record is None or record.get("status") != "completed" or not record.get("path"):
        raise DownloadRefused(404, "not_found", "no completed download with that id in this session")
    downloads_dir = (Path(manager.settings.artifact_root) / session_id / "downloads").resolve()
    raw = Path(str(record["path"]))
    try:
        st = os.lstat(raw)
    except OSError:
        raise DownloadRefused(404, "gone", "the download is no longer on disk") from None
    import stat as stat_module

    resolved = raw.resolve()
    if not stat_module.S_ISREG(st.st_mode) or resolved.parent != downloads_dir:
        logger.warning("refusing to delete download %s: not a file in the session's downloads directory", download_id)
        raise DownloadRefused(403, "outside", "the download is not a file in this session's downloads directory")
    actual, size = await asyncio.to_thread(_hash_file, resolved)
    if not secrets.compare_digest(actual, sha256):
        raise DownloadRefused(409, "hash_mismatch", "the file on disk does not match that sha256; it was kept")
    await asyncio.to_thread(resolved.unlink)
    session.downloads[:] = [d for d in session.downloads if not (isinstance(d, dict) and d.get("id") == download_id)]
    try:
        await asyncio.to_thread(_rewrite_jsonl_without, Path(session.artifact_dir) / "downloads.jsonl", download_id)
    except OSError as exc:
        logger.warning("download %s: downloads.jsonl rewrite failed: %s", download_id, type(exc).__name__)
    try:
        await manager._persist_session(session, status="active")
    except Exception as exc:
        logger.warning("download %s: persist failed: %s", download_id, type(exc).__name__)
    try:
        await manager.audit.append(
            event_type="download_deleted",
            status="ok",
            action="delete_download",
            session_id=session_id,
            details={"download_id": download_id, "sha256": sha256, "size": size, "reason": "saved_to_vault"},
        )
    except Exception as exc:
        logger.warning("download %s: audit failed: %s", download_id, type(exc).__name__)
    return {"deleted": True, "download_id": download_id, "sha256": sha256, "size": size}


def install_download_routes(application: Any, manager: Any) -> None:
    """DELETE /happy/sessions/{session_id}/downloads/{download_id}?sha256= (see above)."""
    from fastapi import Request
    from fastapi.responses import JSONResponse

    from app.auth_policy import credentials_for, match_credential

    async def delete(session_id: str, download_id: str, request: Request) -> Any:
        if match_credential(credentials_for(manager.settings), request.headers.get("authorization", "")) is None:
            return JSONResponse(status_code=401, content={"detail": "a bearer token is required", "code": "unauthorized"})
        try:
            return await delete_download(manager, session_id, download_id, request.query_params.get("sha256", ""))
        except DownloadRefused as exc:
            return JSONResponse(status_code=exc.status, content={"detail": exc.detail, "code": exc.code})

    delete.__annotations__["request"] = Request
    application.add_api_route(
        "/happy/sessions/{session_id}/downloads/{download_id}", delete, methods=["DELETE"], include_in_schema=False
    )


# ── a file staged for upload ────────────────────────────────────────────────
#
# browser_stage_upload (the bridge's MCP server) reads a file on the agent's host, from the chat's own
# working or temp directory, and the bridge sends its bytes to this pod's controller only (the chat's
# own pod, found by chat key, never by a session id the agent names). There was no other way in for a
# file: upstream 1.14.0 has no multipart route, and agents were copying files into the controller's
# /data/uploads with docker, as root, which the launcher then could not wipe.
# POST /happy/sessions/{session_id}/uploads?name=<basename>&sha256=<hex>, body the raw bytes:
#
# - needs a bearer credential the controller knows, checked here as well as by the middleware (401);
# - acts only on a live session (manager.sessions; get_session's owner check applies; 404 otherwise);
# - takes the name as a plain basename only ([A-Za-z0-9._-], at most 128, no leading dot; 400
#   otherwise), and makes it unique in the directory (name-1.ext, name-2.ext, ...), never replacing a file;
# - writes into session.upload_dir only, which must be a real directory (not a symlink) inside
#   UPLOAD_ROOT (403 otherwise), through a descriptor of that directory and O_CREAT|O_EXCL|O_NOFOLLOW,
#   so nothing already there, a symlink included, is ever followed or overwritten; owned by the
#   controller's own user (1993), so the launcher can always wipe the slot, and mode 660: the uploads
#   directory's default ACL (browser-perms.sh, the launcher) gives the host agent (uid prep) its own
#   rwx entry, and an ACL entry counts only through the mask, which is a new file's group bits, so a
#   0600 file would shut the agent out of a file staged for it;
# - stops at UPLOAD_MAX_BYTES (413) and checks the bytes against sha256 (409); either way the partial
#   file is removed and nothing is kept;
# - records an upload_staged audit event with the name, size and sha256 (never the content), and
#   answers {file_path, name, size, sha256}: file_path is what the upload action takes.
#
# Pinned with the rest (EXPECTED_SHA256): browser/services/uploads.py, browser/services/sessions.py,
# auth_policy.py.

UPLOAD_MAX_BYTES = 50 * 1024 * 1024
UPLOAD_NAME = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$")
UPLOAD_UNIQUE_TRIES = 100


class UploadRefused(Exception):
    def __init__(self, status: int, code: str, detail: str) -> None:
        super().__init__(detail)
        self.status, self.code, self.detail = status, code, detail


def _upload_dir(manager: Any, session: Any) -> Path:
    """The session's own upload directory: a real directory inside UPLOAD_ROOT, else refused."""
    import stat as stat_module

    raw = Path(str(session.upload_dir))
    try:
        st = os.lstat(raw)
    except OSError:
        raise UploadRefused(404, "no_upload_dir", "this session has no upload directory") from None
    if not stat_module.S_ISDIR(st.st_mode):
        logger.warning("refusing to stage an upload: the session's upload directory is not a directory")
        raise UploadRefused(403, "outside", "the session's upload directory is not a plain directory")
    resolved = raw.resolve()
    root = Path(os.path.realpath(manager.settings.upload_root))
    if resolved != raw.absolute() or not resolved.is_relative_to(root) or resolved == root:
        logger.warning("refusing to stage an upload: the session's upload directory is not its own under UPLOAD_ROOT")
        raise UploadRefused(403, "outside", "the session's upload directory is not inside the upload root")
    return resolved


def _unique_names(name: str):
    stem, dot, ext = name.partition(".") if not name.startswith(".") else (name, "", "")
    yield name
    for n in range(1, UPLOAD_UNIQUE_TRIES):
        yield f"{stem}-{n}{dot}{ext}"


def _open_new(dir_fd: int, name: str) -> tuple[int, str]:
    """A new file in the directory, never an existing one or a symlink: (fd, the name it got)."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    for candidate in _unique_names(name):
        if len(candidate) > 128:
            break
        try:
            fd = os.open(candidate, flags, 0o660, dir_fd=dir_fd)
            # Without a default ACL on the directory the umask applies: put the group bits back.
            os.fchmod(fd, 0o660)
            return fd, candidate
        except FileExistsError:
            continue
    raise UploadRefused(409, "name_taken", "too many files with that name in the upload directory; rename it")


async def stage_upload(manager: Any, session_id: str, name: str, sha256: str, chunks: Any) -> dict[str, Any]:
    if not isinstance(name, str) or not UPLOAD_NAME.match(name) or name in (".", ".."):
        raise UploadRefused(400, "bad_name", "name must be a plain file name: A-Z a-z 0-9 . _ -, no leading dot, at most 128")
    if not _SHA256_HEX.match(sha256 or ""):
        raise UploadRefused(400, "bad_request", "sha256 must be 64 lower-case hex characters")
    try:
        session = await manager.get_session(session_id)
    except KeyError:
        raise UploadRefused(404, "not_found", "no such live session") from None
    if manager.sessions.get(session_id) is not session:
        raise UploadRefused(404, "not_found", "no such live session")
    directory = _upload_dir(manager, session)
    dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
    fd = None
    final = None
    try:
        fd, final = _open_new(dir_fd, name)
        h = hashlib.sha256()
        size = 0
        async for chunk in chunks:
            if not chunk:
                continue
            size += len(chunk)
            if size > UPLOAD_MAX_BYTES:
                raise UploadRefused(413, "too_large", f"a staged file may be at most {UPLOAD_MAX_BYTES} bytes")
            h.update(chunk)
            view = memoryview(chunk)
            while view:
                view = view[os.write(fd, view):]
        if not secrets.compare_digest(h.hexdigest(), sha256):
            raise UploadRefused(409, "hash_mismatch", "the bytes received do not match that sha256; nothing was kept")
        os.fsync(fd)
        os.close(fd)
        fd = None
    except BaseException:
        if fd is not None:
            os.close(fd)
        if final is not None:
            try:
                os.unlink(final, dir_fd=dir_fd)
            except OSError:
                pass
        raise
    finally:
        os.close(dir_fd)
    try:
        await manager.audit.append(
            event_type="upload_staged",
            status="ok",
            action="stage_upload",
            session_id=session_id,
            details={"name": final, "size": size, "sha256": sha256},
        )
    except Exception as exc:
        logger.warning("staged upload: audit failed: %s", type(exc).__name__)
    return {"file_path": str(directory / final), "name": final, "size": size, "sha256": sha256}


def install_upload_routes(application: Any, manager: Any) -> None:
    """POST /happy/sessions/{session_id}/uploads?name=&sha256= (see above)."""
    from fastapi import Request
    from fastapi.responses import JSONResponse

    from app.auth_policy import credentials_for, match_credential

    async def upload(session_id: str, request: Request) -> Any:
        if match_credential(credentials_for(manager.settings), request.headers.get("authorization", "")) is None:
            return JSONResponse(status_code=401, content={"detail": "a bearer token is required", "code": "unauthorized"})
        declared = request.headers.get("content-length")
        if declared is not None and (not declared.isdigit() or int(declared) > UPLOAD_MAX_BYTES):
            return JSONResponse(
                status_code=413, content={"detail": f"a staged file may be at most {UPLOAD_MAX_BYTES} bytes", "code": "too_large"}
            )
        try:
            return await stage_upload(
                manager, session_id, request.query_params.get("name", ""), request.query_params.get("sha256", ""), request.stream()
            )
        except UploadRefused as exc:
            return JSONResponse(status_code=exc.status, content={"detail": exc.detail, "code": exc.code})

    upload.__annotations__["request"] = Request
    application.add_api_route("/happy/sessions/{session_id}/uploads", upload, methods=["POST"], include_in_schema=False)


# ── downloads the host agent can use ─────────────────────────────────────────
#
# A completed download (DownloadCaptureService.capture: the file it reserves and Playwright's save_as
# fills) is the host agent's to use directly at its host path, through the downloads directory's
# default ACL. That entry counts only through the ACL mask, which is the file's group bits, so a file
# that lands without group read and write (a save that creates it 0600) gets g+rw back here, and
# nothing else: other bits, owner and contents are left as they are. Only a regular file (never a
# symlink) inside the session's own artifacts/<session>/downloads is touched. Pinned: downloads.py.

DOWNLOAD_GROUP_BITS = 0o060


def share_download(record: Any, session: Any) -> None:
    import stat as stat_module

    if not isinstance(record, dict) or record.get("status") != "completed" or not record.get("path"):
        return
    path = Path(str(record["path"]))
    try:
        st = os.lstat(path)
        downloads_dir = (Path(str(session.artifact_dir)) / "downloads").resolve()
        if not stat_module.S_ISREG(st.st_mode) or path.resolve().parent != downloads_dir:
            return
        if st.st_mode & DOWNLOAD_GROUP_BITS != DOWNLOAD_GROUP_BITS:
            os.chmod(path, stat_module.S_IMODE(st.st_mode) | DOWNLOAD_GROUP_BITS, follow_symlinks=False)
    except (OSError, NotImplementedError) as exc:
        logger.warning("download %s: could not give it group read/write: %s", record.get("id"), type(exc).__name__)


# Each session's own artifact directory is made here, after the launcher (or browser-perms.sh) has
# named the host agent on artifacts/ itself, so its entries go on here too, the moment upstream's
# prepare_session_dir makes it: artifacts/<session> traverse only (u:A:--x: the screenshots and
# the rest stay unreadable to it), artifacts/<session>/downloads full use (u:A:rwx), with default
# entries (rwx for A and the controller, mask rwx, nothing for other) that every saved download
# inherits. A is HOST_AGENT_UID; unset, 0, or the controller's own uid, nothing is named. The
# image has no setfacl: the ACLs are written as the kernel's system.posix_acl_* xattrs. A failure
# is logged and the session goes on (only the host agent's direct access is missing). Pinned:
# artifacts.py.

HOST_AGENT_ENV = "HOST_AGENT_UID"
_ACL_VERSION = 2
_ACL_USER_OBJ, _ACL_USER, _ACL_GROUP_OBJ, _ACL_MASK, _ACL_OTHER = 0x01, 0x02, 0x04, 0x10, 0x20
_ACL_UNDEFINED_ID = 0xFFFFFFFF


def host_agent_uid() -> int | None:
    raw = os.environ.get(HOST_AGENT_ENV, "").strip()
    if not raw.isdigit():
        return None
    uid = int(raw)
    return uid if uid not in (0, os.getuid()) else None


def acl_xattr(owner: int, users: dict[int, int], group: int, mask: int, other: int) -> bytes:
    """A POSIX ACL as the system.posix_acl_access/default xattr: version, then (tag, perm, id) in
    tag-then-id order, as the kernel requires."""
    entries = [(_ACL_USER_OBJ, owner, _ACL_UNDEFINED_ID)]
    entries += [(_ACL_USER, perm, uid) for uid, perm in sorted(users.items())]
    entries += [(_ACL_GROUP_OBJ, group, _ACL_UNDEFINED_ID), (_ACL_MASK, mask, _ACL_UNDEFINED_ID), (_ACL_OTHER, other, _ACL_UNDEFINED_ID)]
    return struct.pack("<I", _ACL_VERSION) + b"".join(struct.pack("<HHI", tag, perm & 7, ident) for tag, perm, ident in entries)


def share_session_dir(artifact_dir: Path) -> None:
    agent = host_agent_uid()
    if agent is None:
        return
    import stat as stat_module

    me = os.getuid()
    try:
        st = os.lstat(artifact_dir)
        if not stat_module.S_ISDIR(st.st_mode) or st.st_uid != me:
            return
        mode = stat_module.S_IMODE(st.st_mode)
        os.setxattr(
            artifact_dir,
            "system.posix_acl_access",
            acl_xattr(mode >> 6 & 7, {agent: 1}, mode >> 3 & 7, (mode >> 3 & 7) | 1, 0),
            follow_symlinks=False,
        )
        downloads = artifact_dir / "downloads"
        st = os.lstat(downloads)
        if not stat_module.S_ISDIR(st.st_mode) or st.st_uid != me:
            return
        mode = stat_module.S_IMODE(st.st_mode)
        os.setxattr(downloads, "system.posix_acl_access", acl_xattr(7, {agent: 7}, mode >> 3 & 7, 7, 0), follow_symlinks=False)
        os.setxattr(downloads, "system.posix_acl_default", acl_xattr(7, {agent: 7, me: 7}, 7, 7, 0), follow_symlinks=False)
    except (OSError, NotImplementedError) as exc:
        logger.warning("artifact dir %s: could not name the host agent: %s", artifact_dir.name, type(exc).__name__)


def build_artifacts(artifacts_module: Any) -> dict[str, Any]:
    upstream_prepare = artifacts_module.SessionArtifactService.prepare_session_dir

    def prepare_session_dir(self: Any, session_id: str) -> Path:
        artifact_dir = upstream_prepare(self, session_id)
        share_session_dir(Path(artifact_dir))
        return artifact_dir

    prepare_session_dir._happy_upstream = upstream_prepare  # type: ignore[attr-defined]
    return {"prepare_session_dir": prepare_session_dir}


def build_downloads(downloads_module: Any) -> dict[str, Any]:
    upstream_capture = downloads_module.DownloadCaptureService.capture

    async def capture(self: Any, session: Any, download: Any) -> dict[str, Any]:
        record = await upstream_capture(self, session, download)
        share_download(record, session)
        return record

    capture._happy_upstream = upstream_capture  # type: ignore[attr-defined]
    return {"capture": capture}


def install_routes(application: Any, manager: Any) -> None:
    """GET /happy/sessions/{session_id}/focus and the screen routes, behind the controller's own auth middleware."""
    if getattr(application.state, "happy_focus_route", False):
        return

    async def focus(session_id: str) -> dict[str, Any]:
        # An unknown session, or another operator's, is a KeyError: the app's 404.
        session = await manager.get_session(session_id)
        try:
            # Asked while the person holds the browser: the session follows the tab they have in front.
            await follow_active_tab(manager, session_id)
        except Exception as exc:
            logger.debug("tab follow failed: %s", type(exc).__name__)
        try:
            manager._assert_page_allowed(session)
            return {"editable_focused": await editable_focused(session.page)}
        except Exception as exc:
            logger.debug("focus read failed: %s", type(exc).__name__)
            return {"editable_focused": None}

    application.add_api_route("/happy/sessions/{session_id}/focus", focus, methods=["GET"], include_in_schema=False)
    install_screen_routes(application, manager)
    install_download_routes(application, manager)
    install_upload_routes(application, manager)
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


# ── a new tab the person opens ──────────────────────────────────────────────
#
# While the person holds the browser, Ctrl+T (or the "+" in the tab strip) opened a tab that upstream
# refused for good, and sent back to about:blank on every navigation:
#
# - The context reports it like a popup (diagnostics.attach_popup), which holds it as opener_pending
#   until its opener's "popup" event judges it. A tab the browser opened itself has no opener and gets
#   no such event, so it was never judged, and stayed refused (PageProvenance.refused).
# - Its first commit is Chromium's new-tab page, chrome://newtab/, and _assert_runtime_url_allowed
#   refuses every scheme but http(s), about:, data:, blob: and chrome-error:. The page guard sent it to
#   about:blank, and while it was open on a non-http page, held for a verdict, it counted as refused for
#   the session (counts_for_its_session), so the session's own tab's commits were refused too.
# - The frame view, /nav and the agent follow session.page only, so the new tab was never seen.
#
# What this changes:
#
# - _assert_runtime_url_allowed (BrowserManager) accepts exactly the new-tab page's URLs, NEW_TAB_URLS,
#   the ones the kiosk policy's URLAllowlist lets past its chrome://* block. Every other chrome:// URL
#   stays refused. The agent's own target URLs go through _assert_url_allowed, which is unchanged and
#   accepts http(s) only, so the agent cannot navigate to the new-tab page.
# - _on_frame_navigated (the diagnostics service) first: a page whose top frame commits a new-tab URL,
#   with no opener, held only for its opener's verdict (nothing tainted it, no refused hop, no birth
#   verdict being judged), is recorded as one the controller opened (opened_by_controller, as tabs.open
#   does). Then upstream judges the commit as before. That runs for the replay attach_popup makes of a
#   reported page's first commit too, so the provenance is set before that first commit is judged.
#   Only a commit of the new-tab page clears the hold, never the lack of an opener alone: a window a
#   refused page opens and then closes itself also reaches the controller with no opener, and it is on
#   about:blank (scriptable by that page), which stays refused. Web content cannot open chrome:// URLs,
#   and the new-tab page's document has a chrome:// origin no web page shares, so nothing the session's
#   pages ran can be in it. What the person types next is judged as any navigation is (the URL list,
#   the gate, the session's taint).
# - follow_active_tab, called by GET /happy/sessions/{id}/focus (which the bridge asks only while the
#   person holds the browser, as often as the app polls /state): when the person has another of the
#   session's tabs in front, that tab becomes session.page through adopt_tab: the controller's own tab
#   activate (BrowserTabService.activate) without its bring_to_front, which would take the keyboard
#   focus from the address bar. It refuses a refused tab as activate does for the agent. The tab in front
#   is the one the person last used: the latest of the moment the person opened it (the new-tab commit
#   above) and the last trusted click, key, wheel or touch in it. document.visibilityState and
#   document.hasFocus() cannot tell: Playwright's focus emulation keeps every page of the browser
#   visible and focused. Input is recorded in an isolated world (Page.createIsolatedWorld), whose
#   listener and record a page's script can neither read nor write, and only for trusted events
#   (event.isTrusted), which a script cannot make. A refused tab is not read at all. A tab switched to
#   with the keyboard or the tab strip is followed once the person clicks or types in it. No polling of
#   its own: it runs only when the focus route is asked.

NEW_TAB_URLS = frozenset({"chrome://newtab/", "chrome://new-tab-page/"})
# The world the active-tab read runs in, and its bounds.
TAB_FOCUS_WORLD = "happy_tab_focus"
# Installs the listener once per world (one per document), and answers the last trusted input's time (ms).
TAB_FOCUS_SCRIPT = """(() => {
  if (!window.__happyTabInput) {
    const seen = (window.__happyTabInput = { at: 0 });
    const mark = (event) => { if (event.isTrusted) seen.at = Date.now(); };
    for (const type of ['pointerdown', 'keydown', 'wheel', 'touchstart']) {
      window.addEventListener(type, mark, { capture: true, passive: true });
    }
  }
  return window.__happyTabInput.at;
})()"""
TAB_FOCUS_TIMEOUT_SECONDS = 1.0
# /focus waits this long for an activation it started; one that takes longer finishes in the background.
TAB_FOLLOW_WAIT_SECONDS = 1.0
_CDP_ATTR = "_happy_tab_focus_cdp"
_FOLLOW_ATTR = "_happy_tab_follow"
_OPENED_ATTR = "_happy_person_opened_at"


def is_new_tab_url(url: Any) -> bool:
    return isinstance(url, str) and url in NEW_TAB_URLS


def has_opener(page: Any) -> bool:
    """Whether Playwright knows an opener for the page (closed or not). Unknown counts as having one.

    Page.opener() is a coroutine that only reads this attribute (and answers None for a closed opener,
    which is not what is asked here), set when Playwright first reported the page.
    """
    impl = getattr(page, "_impl_obj", page)
    if not hasattr(impl, "_opener"):
        return True
    return impl._opener is not None


def build_new_tab(manager_module: Any, diagnostics_module: Any) -> tuple[dict[str, Any], dict[str, Any]]:
    Manager = manager_module.BrowserManager
    Diagnostics = diagnostics_module.BrowserDiagnosticsService
    upstream_runtime_check = Manager._assert_runtime_url_allowed
    upstream_frame_navigated = Diagnostics._on_frame_navigated

    def _assert_runtime_url_allowed(self: Any, url: str) -> None:
        if is_new_tab_url(url):
            return
        upstream_runtime_check(self, url)

    def _on_frame_navigated(self: Any, session: Any, page: Any, frame: Any, *, reported: bool = False) -> None:
        if frame.parent_frame is None and is_new_tab_url(frame.url):
            provenance = self.manager.page_provenance
            if provenance.held_for_verdict(page) and not self.birth_pending(page) and not has_opener(page):
                provenance.opened_by_controller(page)
                # Ctrl+T and the tab strip's "+" bring the tab to the front: the person is on it now.
                try:
                    setattr(page, _OPENED_ATTR, time.time() * 1000)
                except AttributeError:
                    pass
        upstream_frame_navigated(self, session, page, frame, reported=reported)

    return (
        {"_assert_runtime_url_allowed": _assert_runtime_url_allowed},
        {"_on_frame_navigated": _on_frame_navigated},
    )


async def _tab_input_at(page: Any) -> float | None:
    """When the person last clicked, typed, scrolled or touched in the page's top document (ms since the
    epoch, 0 for never), read in an isolated world; None when it can't be told."""
    state = getattr(page, _CDP_ATTR, None)
    if state is None:
        state = {"cdp": await page.context.new_cdp_session(page), "doc": None, "ctx": None}
        setattr(page, _CDP_ATTR, state)
    cdp = state["cdp"]
    tree = await cdp.send("Page.getFrameTree")
    top = tree["frameTree"]["frame"]
    doc = (top["id"], top.get("loaderId"))
    if state["doc"] != doc:
        # One world per document: a new document drops the old one's.
        world = await cdp.send("Page.createIsolatedWorld", {"frameId": top["id"], "worldName": TAB_FOCUS_WORLD})
        state["doc"], state["ctx"] = doc, world["executionContextId"]
    try:
        result = await cdp.send(
            "Runtime.evaluate", {"expression": TAB_FOCUS_SCRIPT, "contextId": state["ctx"], "returnByValue": True}
        )
    except Exception:
        state["doc"] = None  # the world went with its document: made again on the next read
        raise
    value = result.get("result", {}).get("value")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


async def _last_used(page: Any) -> float | None:
    """The later of the person opening the tab and their last input in it; None when neither can be told."""
    try:
        at = await asyncio.wait_for(_tab_input_at(page), timeout=TAB_FOCUS_TIMEOUT_SECONDS)
    except Exception as exc:
        logger.debug("tab input read failed: %s", type(exc).__name__)
        at = None
    opened = getattr(page, _OPENED_ATTR, None)
    known = [v for v in (at, opened) if isinstance(v, (int, float))]
    return max(known) if known else None


def front_tab(current: Any, states: list[tuple[Any, float | None]]) -> Any:
    """The tab the person last used, when it is not the current one and was used after it; else None."""
    used = [(at, page) for page, at in states if at]
    if not used:
        return None
    at, target = max(used, key=lambda item: item[0])
    if target is current:
        return None
    current_at = next((a for page, a in states if page is current), None) or 0
    return target if at > current_at else None


async def adopt_tab(manager: Any, session_id: str, target: Any) -> int | None:
    """BrowserTabService.activate for a tab the person already has in front, minus its bring_to_front.

    bring_to_front moves the keyboard focus into the page: the person typing a URL into a new tab's
    address bar would type into the page instead. Everything else is activate's: the birth verdict
    waited for, the session lock, the page's URL and provenance checked (a refused tab raises
    PermissionError and the session stays where it was), its listeners, session.page, the session
    persisted. None when the tab closed meanwhile.
    """
    session = await manager.get_session(session_id)
    await manager.diagnostics.birth_judged(target)
    async with session.lock:
        if await manager.get_session(session_id) is not session:
            return None
        pages = manager.tabs.pages(session)
        index = next((i for i, page in enumerate(pages) if page is target), None)
        if index is None or target.is_closed():
            return None
        manager._assert_page_object_allowed(target)
        manager._attach_page_listeners(target, session)
        session.page = target
        await manager._persist_session(session, status="active")
        return index


async def follow_active_tab(manager: Any, session_id: str) -> None:
    """Make the tab the person has in front the session's page (see "a new tab the person opens")."""
    session = await manager.get_session(session_id)
    running = getattr(session, _FOLLOW_ATTR, None)
    if running is not None and not running.done():
        await asyncio.wait({running}, timeout=TAB_FOLLOW_WAIT_SECONDS)
        return
    pages = [page for page in manager.tabs.pages(session) if not page.is_closed()]
    if len(pages) < 2:
        return
    # A refused tab is not read (nor activated: activate refuses it).
    readable = [page for page in pages if not manager._page_refused(page)]
    states = list(zip(readable, await asyncio.gather(*(_last_used(page) for page in readable))))
    if not any(page is session.page for page in readable):
        states.append((session.page, None))
    target = front_tab(session.page, states)
    if target is None:
        return

    async def activate() -> None:
        try:
            index = await adopt_tab(manager, session_id, target)
        except PermissionError as exc:
            logger.debug("tab in front not followed: %s", type(exc).__name__)
            return
        if index is not None:
            logger.info("happy_live_frames: session %s follows the tab in front (index %d)", session_id, index)

    task = asyncio.ensure_future(activate())
    task.add_done_callback(_retrieve)
    setattr(session, _FOLLOW_ATTR, task)
    await asyncio.wait({task}, timeout=TAB_FOLLOW_WAIT_SECONDS)


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
    from app import browser_manager
    from app.browser.services import diagnostics

    manager_patches, diagnostics_patches = build_new_tab(browser_manager, diagnostics)
    for name, fn in manager_patches.items():
        setattr(browser_manager.BrowserManager, name, fn)
    for name, fn in diagnostics_patches.items():
        setattr(diagnostics.BrowserDiagnosticsService, name, fn)
    from app import downloads

    for name, fn in build_downloads(downloads).items():
        setattr(downloads.DownloadCaptureService, name, fn)
    from app import artifacts

    for name, fn in build_artifacts(artifacts).items():
        setattr(artifacts.SessionArtifactService, name, fn)
    logger.warning(
        "happy_live_frames: patched auto-browser %s share_snapshot/light_snapshot, scroll and new tabs; screenshot audit in %s, default view %s",
        EXPECTED_VERSION,
        tz_name(),
        default_view(),
    )


if os.environ.get("HAPPY_LIVE_FRAMES_NO_AUTOLOAD") != "1":
    # Files the controller makes (downloads, staged uploads, artifacts) keep group read/write, so the
    # ACL mask leaves the host agent's entry in force (see "downloads the host agent can use").
    os.umask(0o007)
    verify()
    apply()
    from app.main import app, manager  # noqa: E402 - what uvicorn serves

    install_routes(app, manager)
