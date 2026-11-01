package com.slopus.happy.attachments

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import com.slopus.happy.attachments.ImageNormalizer.applyOrientation
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import kotlin.math.min

/**
 * A picked picture as a profile photo is sent (iOS's ProfileSource.prepare
 * and ProfilePhotoCrop): upright, its middle square, at most [MAX_SIDE]
 * pixels across and never enlarged, JPEG at quality 0.85.
 */
object ProfilePhoto {
    const val MAX_SIDE = 512
    private const val QUALITY = 85

    /** The square [width] x [height] is cut to and the side it is drawn at. */
    data class Crop(val x: Int, val y: Int, val side: Int, val target: Int)

    fun crop(width: Int, height: Int, maxSide: Int = MAX_SIDE): Crop {
        val side = min(width, height)
        return Crop((width - side) / 2, (height - side) / 2, side, min(side, maxSide))
    }

    /** [open] is called more than once (bounds, orientation, pixels). Throws [IOException] when the bytes aren't an image. */
    fun prepare(open: () -> InputStream): ByteArray {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        open().use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw IOException("Not an image")
        val orientation = try {
            open().use { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) }
        } catch (_: IOException) {
            ExifInterface.ORIENTATION_NORMAL
        }
        var sample = 1
        while (min(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_SIDE) sample *= 2
        val decoded = open().use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
            ?: throw IOException("Not an image")
        val crop = crop(decoded.width, decoded.height)
        val scale = crop.target.toFloat() / crop.side
        val matrix = Matrix().apply {
            postScale(scale, scale)
            applyOrientation(orientation)
        }
        val output = Bitmap.createBitmap(decoded, crop.x, crop.y, crop.side, crop.side, matrix, true)
        val bytes = ByteArrayOutputStream().use { stream ->
            if (!output.compress(Bitmap.CompressFormat.JPEG, QUALITY, stream)) throw IOException("JPEG encode failed")
            stream.toByteArray()
        }
        if (output !== decoded) output.recycle()
        decoded.recycle()
        return bytes
    }
}
