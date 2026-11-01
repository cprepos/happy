package com.slopus.happy.artifacts

import android.graphics.Bitmap
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever

/**
 * What the platform's retriever reads from a recording's first ranges: its
 * upright size, its length and its first frame (iOS's
 * `AVAssetImageGenerator` at zero). Blocking; call it off the main thread.
 * The artifact screens and a conversation's recordings both read theirs here.
 */
object VideoProbe {
    /** [size] upright, in pixels; [seconds] its length; [poster] its first frame. */
    class Info(val size: Extent?, val seconds: Double?, val poster: Bitmap?)

    /**
     * Reads [source]'s size and length, and its first frame no larger than
     * [posterPixels] on its long side when that is above 0. Null when
     * nothing in it could be read. The retriever closes [source].
     */
    fun read(source: MediaDataSource, posterPixels: Int = 0): Info? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(source)
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toDoubleOrNull()
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toDoubleOrNull()
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val millis = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDoubleOrNull()
            val size = if (width != null && height != null && width > 0 && height > 0) {
                if (rotation % 180 != 0) Extent(height, width) else Extent(width, height)
            } else null
            val poster = if (posterPixels > 0) frame(retriever, posterPixels) else null
            Info(size, millis?.div(1000)?.takeIf { it.isFinite() && it > 0 }, poster)
        } catch (_: Exception) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun frame(retriever: MediaMetadataRetriever, maxPixels: Int): Bitmap? = try {
        retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)?.let { frame ->
            val scale = minOf(1.0, maxPixels.toDouble() / maxOf(frame.width, frame.height))
            if (scale >= 1.0) frame
            else Bitmap.createScaledBitmap(frame, (frame.width * scale).toInt().coerceAtLeast(1), (frame.height * scale).toInt().coerceAtLeast(1), true)
        }
    } catch (_: Exception) {
        null
    }
}
