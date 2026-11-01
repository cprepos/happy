package com.slopus.happy.fixture

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.slopus.happy.ui.components.avatar.AvatarPlaceholder
import com.slopus.happy.ui.components.avatar.AvatarShader
import com.slopus.happy.ui.components.avatar.AvatarShaderProgram
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

/**
 * The AGSL avatar shader on this device's GPU, as the rows draw it: every
 * placeholder's frame at its phase, drawn [DRAWN] pixels across and scaled
 * down to [PIXELS], against its still picture (happy-ios's
 * AvatarShaderRendererTests). Writes the sheet (shader left, picture right)
 * and the numbers to `device-evidence/`.
 */
@RunWith(AndroidJUnit4::class)
class AvatarShaderDeviceTest {
    @get:Rule
    val rule = createAndroidComposeRule<ComponentActivity>()

    private val app = InstrumentationRegistry.getInstrumentation().targetContext
    private val evidence = File(app.filesDir, "device-evidence").apply { mkdirs() }

    @Test
    fun everyFirstFrameIsItsPicture() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
        // Built before the first draw, as a row asks before it draws.
        assumeTrue("AGSL builds here", rule.runOnIdle { AvatarShaderProgram.available })
        rule.setContent {
            val side = with(LocalDensity.current) { DRAWN.toDp() }
            val index = current.intValue
            Box(Modifier.size(side).testTag("frame")) {
                Canvas(Modifier.size(side)) {
                    val parameters = AvatarShader.parameters(index)
                    drawIntoCanvas { AvatarShaderProgram.draw(it.nativeCanvas, parameters, parameters.phase, size.width, false) }
                }
            }
        }
        val results = (0 until AvatarPlaceholder.COUNT).map { index -> index to compare(index, frame(index)) }
        val byEffect = results.groupBy { AvatarShader.parameters(it.first).effect }.mapValues { (_, v) -> "%.2f".format(v.map { it.second }.average()) }
        val mean = results.map { it.second }.average()
        val (worst, max) = results.maxBy { it.second }
        val report = "GPU frames vs pictures at $PIXELS px: mean ${"%.2f".format(mean)}/255, worst ${"%.2f".format(max)}/255 (placeholder ${worst + 1}); by effect $byEffect"
        Log.i("AvatarShaderDeviceTest", report)
        File(evidence, "avatar-shader-frames.txt").writeText(report + "\n" + results.joinToString("\n") { (i, d) -> "${i + 1} ${AvatarShader.parameters(i).effect} ${"%.2f".format(d)}" })
        assertTrue(report, mean < 6)
        assertTrue(report, max < 16)
    }

    private val current = mutableIntStateOf(0)

    private fun frame(index: Int): Bitmap {
        rule.runOnIdle { current.intValue = index }
        rule.waitForIdle()
        val bitmap = rule.onNodeWithTag("frame").captureToImage().asAndroidBitmap().copy(Bitmap.Config.ARGB_8888, false)
        if (index % 40 < 3) File(evidence, "avatar-shader-${index + 1}.png").outputStream().use { out ->
            val picture = app.assets.open(AvatarPlaceholder.asset(index)).use { BitmapFactory.decodeStream(it) }
            val sheet = Bitmap.createBitmap(DRAWN * 2, DRAWN, Bitmap.Config.ARGB_8888)
            android.graphics.Canvas(sheet).apply {
                drawBitmap(bitmap, 0f, 0f, null)
                drawBitmap(Bitmap.createScaledBitmap(picture, DRAWN, DRAWN, true), DRAWN.toFloat(), 0f, null)
            }
            sheet.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        return bitmap
    }

    private fun compare(index: Int, frame: Bitmap): Double {
        val picture = app.assets.open(AvatarPlaceholder.asset(index)).use { BitmapFactory.decodeStream(it) }
        val a = Bitmap.createScaledBitmap(frame, PIXELS, PIXELS, true)
        val b = Bitmap.createScaledBitmap(picture, PIXELS, PIXELS, true)
        var total = 0L
        for (y in 0 until PIXELS) for (x in 0 until PIXELS) {
            val p = a.getPixel(x, y)
            val q = b.getPixel(x, y)
            total += abs(Color.red(p) - Color.red(q)) + abs(Color.green(p) - Color.green(q)) + abs(Color.blue(p) - Color.blue(q))
        }
        return total / (PIXELS * PIXELS * 3.0)
    }

    private companion object {
        const val PIXELS = 24
        const val DRAWN = 192
    }
}
