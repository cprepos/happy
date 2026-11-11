"""The evidence stamp: a date/time bar across the top of every screenshot the controller hands out.

For audit evidence (SOC2) each screenshot carries the moment it was captured, drawn into the image
itself like a desktop menu bar: a dark strip B px tall above the page, with the capture time at its
right end, e.g. "2026-11-11 14:32:07 EST (UTC-05:00)", in EVIDENCE_TZ (an IANA zone; UTC when unset).

- The page's pixels are not touched: the image is the page pasted at (0, B) on a canvas B px
  taller, no resampling. B = max(24, round(width * 0.035)).
- The time is the capture's, not the stamp's: a page shot's comes from its artifact file name
  (upstream names them %Y%m%dT%H%M%S%fZ-<label>.png, in UTC); a whole-screen shot's from the
  bridge, checked by happy_live_frames.screen_scrub.
- It is drawn after OCR, redaction and the page-moved check, so redaction boxes and OCR coordinates
  stay page coordinates (page y = image y - B) and OCR never reads the bar.
- The PNG carries a tEXt chunk "happy-evidence-stamp" = {"bar_px", "captured_at", "tz"}: stamping
  an image that has one is a no-op, and the screenshot diff crops the bar off by it.
- Not stamped: the live view's frames (share_snapshot, and the live-frame copy light_snapshot makes).

Loaded by happy_live_frames.apply(); nothing here touches the controller by itself.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import tempfile
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

logger = logging.getLogger("happy_evidence_stamp")

CHUNK_KEY = "happy-evidence-stamp"
TZ_ENV = "EVIDENCE_TZ"
DEFAULT_TZ = "UTC"
FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
BAR_FILL = (0x1C, 0x1C, 0x1E)
BAR_LINE = (0x3A, 0x3A, 0x3C)
BAR_TEXT = (0xF2, 0xF2, 0xF7)
PNG_COMPRESS_LEVEL = 3
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


def bar_px(width: int) -> int:
    return max(24, round(width * 0.035))


def _offset(local: datetime) -> str:
    seconds = int((local.utcoffset() or timedelta(0)).total_seconds())
    sign = "-" if seconds < 0 else "+"
    minutes = abs(seconds) // 60
    return f"{sign}{minutes // 60:02d}:{minutes % 60:02d}"


def stamp_text(captured_at: datetime, name: str | None = None) -> str:
    """'2026-11-11 14:32:07 EST (UTC-05:00)' for a UTC (or aware) capture time."""
    if captured_at.tzinfo is None:
        captured_at = captured_at.replace(tzinfo=UTC)
    local = captured_at.astimezone(zone(name))
    return f"{local:%Y-%m-%d %H:%M:%S} {local.tzname()} (UTC{_offset(local)})"


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


def read_stamp(path: str | Path) -> dict[str, Any] | None:
    """The stamp chunk of a PNG, or None if it has none (or is not a readable PNG)."""
    from PIL import Image

    try:
        with Image.open(path) as image:
            raw = getattr(image, "text", {}).get(CHUNK_KEY)
    except Exception:
        return None
    if not raw:
        return None
    try:
        meta = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(meta, dict) or not isinstance(meta.get("bar_px"), int):
        return None
    return meta


def _font(size: int) -> Any:
    from PIL import ImageFont

    try:
        return ImageFont.truetype(FONT_PATH, size)
    except OSError:
        return ImageFont.load_default(size)


def _info(meta: dict[str, Any], stamped: bool) -> dict[str, Any]:
    at = parse_iso(meta.get("captured_at"))
    name = meta.get("tz") or DEFAULT_TZ
    text = stamp_text(at, name) if at is not None else None
    return {**meta, "text": text, "stamped": stamped}


def stamp(path: str | Path, captured_at_utc: datetime, name: str | None = None) -> dict[str, Any] | None:
    """Stamp the PNG at path in place. -> {bar_px, captured_at, tz, text, stamped}; None if the file
    is missing. An image already stamped is left as it is (stamped False, its own stamp's values)."""
    from PIL import Image, ImageDraw
    from PIL.PngImagePlugin import PngInfo

    path = Path(path)
    if not path.is_file():
        return None
    name = tz_name() if name is None else name
    with Image.open(path) as source:
        existing = getattr(source, "text", {}).get(CHUNK_KEY)
        if existing:
            meta = read_stamp(path)
            if meta is not None:
                return _info(meta, False)
        source.load()
        page = source if source.mode in ("RGB", "RGBA") else source.convert("RGBA" if "transparency" in source.info else "RGB")
        width, height = page.size
        bar = bar_px(width)
        fill = BAR_FILL + ((255,) if page.mode == "RGBA" else ())
        canvas = Image.new(page.mode, (width, height + bar), fill)
        canvas.paste(page, (0, bar))
    text = stamp_text(captured_at_utc, name)
    draw = ImageDraw.Draw(canvas)
    draw.line([(0, bar - 1), (width - 1, bar - 1)], fill=BAR_LINE, width=1)
    draw.text((width - bar // 2, bar // 2), text, font=_font(round(bar * 0.6)), fill=BAR_TEXT, anchor="rm")
    meta = {"bar_px": bar, "captured_at": iso(captured_at_utc), "tz": name}
    info = PngInfo()
    info.add_text(CHUNK_KEY, json.dumps(meta, separators=(",", ":")))
    tmp = path.with_name(path.name + ".stamping")
    try:
        canvas.save(tmp, format="PNG", compress_level=PNG_COMPRESS_LEVEL, pnginfo=info)
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)
    return {**meta, "text": text, "stamped": True}


async def stamp_evidence(path: str | Path, captured_at_utc: datetime) -> dict[str, Any] | None:
    """stamp() off the event loop."""
    return await asyncio.to_thread(stamp, path, captured_at_utc)


async def stamp_artifact(path: str | Path | None) -> dict[str, Any] | None:
    """An upstream artifact screenshot, at the time its name carries. Never fails its caller: a
    screenshot that cannot be stamped is returned as it is, and the failure is logged."""
    if not path:
        return None
    at = captured_at_from_name(path) or datetime.now(UTC)
    try:
        return await stamp_evidence(path, at)
    except Exception as exc:
        logger.warning("evidence stamp: could not stamp %s: %s", Path(path).name, type(exc).__name__)
        return None


# ── the screenshot diff ─────────────────────────────────────────────────────


def _without_bar(path: str, scratch: str, tag: str) -> str:
    """path itself when it has no bar, else a copy of its page region (below the bar) in scratch."""
    from PIL import Image

    meta = read_stamp(path)
    if meta is None:
        return path
    bar = meta["bar_px"]
    with Image.open(path) as image:
        if not 0 < bar < image.height:
            return path
        out = Path(scratch) / f"{tag}.png"
        image.crop((0, bar, image.width, image.height)).save(out, format="PNG", compress_level=1)
    return str(out)


def wrap_compute_diff(upstream: Any) -> Any:
    """BrowserDiagnosticsService.compute_diff comparing pages, not bars: a stamped input is cropped."""

    def compute_diff(a_path: str, b_path: str, a_url: str, b_url: str, artifact_dir: Path) -> dict[str, Any]:
        with tempfile.TemporaryDirectory(prefix="evidence-diff-") as scratch:
            try:
                a = _without_bar(a_path, scratch, "a")
                b = _without_bar(b_path, scratch, "b")
            except Exception as exc:
                logger.warning("evidence stamp: diff crop failed: %s", type(exc).__name__)
                a, b = a_path, b_path
            return upstream(a, b, a_url, b_url, artifact_dir)

    compute_diff._happy_evidence_crop = True  # type: ignore[attr-defined]
    return compute_diff


def apply_diff(diagnostics_module: Any) -> None:
    Service = diagnostics_module.BrowserDiagnosticsService
    current = Service.compute_diff
    if getattr(current, "_happy_evidence_crop", False):
        return
    Service.compute_diff = staticmethod(wrap_compute_diff(current))
