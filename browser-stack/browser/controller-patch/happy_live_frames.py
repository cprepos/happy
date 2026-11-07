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

The route and its token check (app/routes/share.py) are untouched; the patch refuses to load if
that file, or any file whose behaviour it relies on, is not the 1.14.0 file it was written against.

Loaded by running uvicorn on this module (happy_live_frames:app) instead of app.main:app, with this
file's directory on PYTHONPATH: see compose.browser.yml and launcher/launcher.mjs.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import re
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
    from app.main import app  # noqa: E402,F401 - what uvicorn serves
