# The whole X screen (DISPLAY, default :99) as a PNG on stdout, with nothing the browser-node image
# does not already have: python3's ctypes and zlib and the image's libX11. The launcher runs it in a
# pod's node container (docker exec, as the browser user) for browser_screenshot scope "screen".
# Run with `python3 -I`; it reads no files and takes no arguments.
import ctypes
import ctypes.util
import os
import struct
import sys
import zlib

ZPIXMAP = 2
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

    dpy = x.XOpenDisplay(os.environ.get("DISPLAY", ":99").encode())
    if not dpy:
        fail("cannot open the display")
    scr = x.XDefaultScreen(dpy)
    w, h = x.XDisplayWidth(dpy, scr), x.XDisplayHeight(dpy, scr)
    img = x.XGetImage(dpy, x.XRootWindow(dpy, scr), 0, 0, w, h, ALL_PLANES, ZPIXMAP)
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
    sys.stdout.buffer.write(png)


main()
