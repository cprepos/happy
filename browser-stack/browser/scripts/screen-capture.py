# The X screen (DISPLAY, default :99) as a PNG on stdout, with nothing the browser-node image does not
# already have: python3's ctypes and zlib and the image's libX11. The launcher runs it in a pod's node
# container (docker exec, as the browser user) for browser_screenshot scope "screen".
# Run with `python3 -I`; it reads no files.
#
# Arguments: none, the whole root window (view "desktop": the desktop panel with its clock, and the
# browser window below it); or four integers X Y W H, that rectangle of the root window and nothing
# else (view "tab": the browser window alone). The rectangle is what XGetImage reads: nothing outside
# it is ever captured, and nothing is cropped, drawn or changed afterwards. It must lie inside the
# screen.
#
# One line on stderr, before the PNG is written: "screen-capture-meta: " + JSON {captured_at (UTC,
# ISO 8601 with milliseconds, read just before XGetImage), local (the same instant in TZ, as the
# panel's clock shows it), tz (TZ, or null), screen {width, height}, rect {x, y, width, height} (what
# was read), workarea {x, y, width, height} or null, panel_px}. workarea is the window manager's
# _NET_WORKAREA: the screen less the panel's strut. panel_px is its top edge, the panel's real
# height as the window manager reserved it (0 with no panel or no _NET_WORKAREA).
import ctypes
import ctypes.util
import json
import os
import re
import struct
import sys
import time
import zlib
from datetime import datetime, timezone

ZPIXMAP = 2
XA_CARDINAL = 6
ALL_PLANES = 0xFFFFFFFF


class XImage(ctypes.Structure):
    _fields_ = [
        ("width", ctypes.c_int), ("height", ctypes.c_int), ("xoffset", ctypes.c_int),
        ("format", ctypes.c_int), ("data", ctypes.POINTER(ctypes.c_char)),
        ("byte_order", ctypes.c_int), ("bitmap_unit", ctypes.c_int), ("bitmap_bit_order", ctypes.c_int),
        ("bitmap_pad", ctypes.c_int), ("depth", ctypes.c_int), ("bytes_per_line", ctypes.c_int),
        ("bits_per_pixel", ctypes.c_int), ("red_mask", ctypes.c_ulong), ("green_mask", ctypes.c_ulong),
        ("blue_mask", ctypes.c_ulong),
    ]


def fail(msg):
    sys.stderr.write("screen-capture: %s\n" % msg)
    sys.exit(1)


def rect_args(argv, w, h):
    """The rectangle to read: the whole screen with no arguments, else X Y W H inside the screen."""
    if not argv:
        return 0, 0, w, h
    if len(argv) != 4 or not all(re.fullmatch(r"[0-9]{1,5}", a) for a in argv):
        fail("expects no arguments or four integers X Y W H")
    rx, ry, rw, rh = (int(a) for a in argv)
    if rw < 1 or rh < 1 or rx + rw > w or ry + rh > h:
        fail("rectangle %d,%d %dx%d is not inside the %dx%d screen" % (rx, ry, rw, rh, w, h))
    return rx, ry, rw, rh


def workarea(x, dpy, root):
    """_NET_WORKAREA's first desktop (x, y, width, height), or None."""
    atom = x.XInternAtom(dpy, b"_NET_WORKAREA", True)
    if not atom:
        return None
    actual_type, actual_format = ctypes.c_ulong(), ctypes.c_int()
    nitems, after = ctypes.c_ulong(), ctypes.c_ulong()
    data = ctypes.POINTER(ctypes.c_ubyte)()
    status = x.XGetWindowProperty(dpy, root, atom, 0, 4, False, XA_CARDINAL, ctypes.byref(actual_type),
                                  ctypes.byref(actual_format), ctypes.byref(nitems), ctypes.byref(after),
                                  ctypes.byref(data))
    try:
        if status != 0 or not data or actual_format.value != 32 or nitems.value < 4:
            return None
        # Format 32 comes back as C longs.
        values = ctypes.cast(data, ctypes.POINTER(ctypes.c_long))
        return tuple(int(values[i]) for i in range(4))
    finally:
        if data:
            x.XFree(data)


def main():
    lib = ctypes.util.find_library("X11") or "libX11.so.6"
    x = ctypes.CDLL(lib)
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x.XDefaultScreen.argtypes = [ctypes.c_void_p]
    x.XRootWindow.restype = ctypes.c_ulong
    x.XRootWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x.XDisplayWidth.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x.XDisplayHeight.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x.XGetImage.restype = ctypes.POINTER(XImage)
    x.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                            ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
    x.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x.XInternAtom.restype = ctypes.c_ulong
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x.XGetWindowProperty.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int,
        ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),
    ]
    x.XFree.argtypes = [ctypes.c_void_p]

    dpy = x.XOpenDisplay(os.environ.get("DISPLAY", ":99").encode())
    if not dpy:
        fail("cannot open the display")
    scr = x.XDefaultScreen(dpy)
    sw, sh = x.XDisplayWidth(dpy, scr), x.XDisplayHeight(dpy, scr)
    rx, ry, w, h = rect_args(sys.argv[1:], sw, sh)
    root = x.XRootWindow(dpy, scr)
    area = workarea(x, dpy, root)
    now = time.time()
    img = x.XGetImage(dpy, root, rx, ry, w, h, ALL_PLANES, ZPIXMAP)
    if not img:
        fail("XGetImage failed")
    im = img.contents
    if im.bits_per_pixel != 32 or im.red_mask != 0xFF0000 or im.green_mask != 0xFF00 or im.blue_mask != 0xFF or im.byte_order != 0:
        fail("unsupported pixel layout (%d bpp)" % im.bits_per_pixel)
    stride = im.bytes_per_line
    raw = ctypes.string_at(im.data, stride * h)
    x.XCloseDisplay(dpy)

    # BGRX little endian -> RGB, one filter byte (0, none) before each row.
    rows = bytearray((w * 3 + 1) * h)
    for y in range(h):
        line = raw[y * stride:y * stride + w * 4]
        rgb = bytearray(w * 3)
        rgb[0::3] = line[2::4]
        rgb[1::3] = line[1::4]
        rgb[2::3] = line[0::4]
        o = y * (w * 3 + 1)
        rows[o + 1:o + 1 + w * 3] = rgb

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
           + chunk(b"IEND", b""))
    at = datetime.fromtimestamp(now, timezone.utc)
    local = datetime.fromtimestamp(now).astimezone()
    meta = {
        "captured_at": at.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (at.microsecond // 1000),
        "local": local.isoformat(timespec="milliseconds"),
        "tz": os.environ.get("TZ") or None,
        "screen": {"width": sw, "height": sh},
        "rect": {"x": rx, "y": ry, "width": w, "height": h},
        "workarea": None if area is None else dict(zip(("x", "y", "width", "height"), area)),
        "panel_px": area[1] if area is not None and 0 <= area[1] < sh else 0,
    }
    sys.stderr.write("screen-capture-meta: " + json.dumps(meta, separators=(",", ":")) + "\n")
    sys.stderr.flush()
    sys.stdout.buffer.write(png)


main()
