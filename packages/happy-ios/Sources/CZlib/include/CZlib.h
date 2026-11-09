#ifndef HAPPY_CZLIB_H
#define HAPPY_CZLIB_H

#include <zlib.h>

/// `inflateInit` is a macro, which Swift can't call: this is it as a function.
static inline int czlib_inflate_init(z_streamp stream) {
    return inflateInit(stream);
}

/// `deflateInit` likewise, for tests that build ZRLE rectangles.
static inline int czlib_deflate_init(z_streamp stream, int level) {
    return deflateInit(stream, level);
}

#endif
