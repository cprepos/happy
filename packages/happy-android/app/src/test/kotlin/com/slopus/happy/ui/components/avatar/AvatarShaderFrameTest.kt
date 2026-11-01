package com.slopus.happy.ui.components.avatar

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.math.abs

/**
 * The AGSL port draws what the pictures were made from (happy-ios's
 * AvatarShaderRendererTests): each placeholder's first frame, at its
 * phase, is its still picture. Drawn by Skia on the CPU here;
 * `AvatarShaderDeviceTest` checks the same on a device's GPU.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [36])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AvatarShaderFrameTest {
    @Test
    fun everyFirstFrameIsItsPicture() {
        assumeTrue("AGSL builds here", AvatarShaderProgram.available)
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val worst = (0 until AvatarPlaceholder.COUNT).map { index ->
            // Drawn large and scaled down as the pictures were, so the grain averages out as it did in them.
            val frame = AvatarShaderProgram.frame(index, DRAWN)?.let { Bitmap.createScaledBitmap(it, PIXELS, PIXELS, true) }
            assertNotNull(frame)
            val picture = context.assets.open(AvatarPlaceholder.asset(index)).use { BitmapFactory.decodeStream(it) }
            index to meanDifference(frame!!, Bitmap.createScaledBitmap(picture, PIXELS, PIXELS, true))
        }
        val mean = worst.map { it.second }.average()
        println("by effect: " + worst.groupBy { AvatarShader.parameters(it.first).effect }.mapValues { (_, v) -> "%.2f".format(v.map { it.second }.average()) })
        val (index, max) = worst.maxBy { it.second }
        println("avatar shader vs pictures at $PIXELS px: mean ${"%.2f".format(mean)}/255, worst ${"%.2f".format(max)}/255 (placeholder ${index + 1})")
        // Skia's CPU pipeline rounds a little differently from a GPU, and the
        // noise magnifies it: topography's fine contours come out elsewhere
        // here (on a device's GPU they match, AvatarShaderDeviceTest). Every
        // other effect is its picture.
        val effects = worst.groupBy { AvatarShader.parameters(it.first).effect }.mapValues { (_, v) -> v.map { it.second }.average() }
        for ((effect, difference) in effects) if (effect != AvatarShader.Effect.Topography) assertTrue("$effect differs by $difference/255", difference < 8)
        assertTrue("mean channel difference $mean/255", mean < 12)
    }

    /** Moving on from its phase, a placeholder changes. */
    @Test
    fun theClockMovesIt() {
        assumeTrue("AGSL builds here", AvatarShaderProgram.available)
        for (index in listOf(0, 50, 100, 150, 199)) {
            val phase = AvatarShader.parameters(index).phase
            val now = AvatarShaderProgram.frame(index, PIXELS)!!
            val later = AvatarShaderProgram.frame(index, PIXELS, phase + 20f)!!
            assertTrue("placeholder ${index + 1} moves", meanDifference(now, later) > 1.0)
        }
    }

    companion object {
        const val PIXELS = 24
        const val DRAWN = 192

        fun meanDifference(a: Bitmap, b: Bitmap): Double {
            var total = 0L
            for (y in 0 until PIXELS) for (x in 0 until PIXELS) {
                val p = a.getPixel(x, y)
                val q = b.getPixel(x, y)
                total += abs(Color.red(p) - Color.red(q)) + abs(Color.green(p) - Color.green(q)) + abs(Color.blue(p) - Color.blue(q))
            }
            return total / (PIXELS * PIXELS * 3.0)
        }
    }
}
