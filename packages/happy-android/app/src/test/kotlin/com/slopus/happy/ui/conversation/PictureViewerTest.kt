package com.slopus.happy.ui.conversation

import android.graphics.Bitmap
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.compose.ui.unit.width
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.slopus.happy.conversation.ViewerItem
import com.slopus.happy.ui.PHONE
import com.slopus.happy.ui.assertDp
import com.slopus.happy.ui.node
import com.slopus.happy.ui.setHappyContent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * The full-screen viewer: a picture at its own size, never enlarged; swiped
 * between with the rest of the conversation's; dragged away up or down,
 * springing back when let go short; and while zoomed, neither paging nor
 * closing. Its pictures go under build/conversation-screens.
 */
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = PHONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PictureViewerTest {
    @get:Rule
    val rule = createComposeRule()

    private var closed = 0

    private fun png(width: Int, height: Int, color: Int): ByteArray = ByteArrayOutputStream().also {
        Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply { eraseColor(color) }.compress(Bitmap.CompressFormat.PNG, 100, it)
    }.toByteArray()

    private fun show() {
        rule.setHappyContent { PictureViewer(png(40, 30, android.graphics.Color.GREEN), "viewer-test", "a picture") { closed++ } }
        rule.waitForIdle()
        rule.node(PictureViewerTags.IMAGE).assertExists()
    }

    private val names = listOf("first", "second", "third")

    /** Three pictures of the conversation, opened on [index]. */
    private fun showThree(index: Int = 0) {
        val bytes = mapOf(
            "first" to png(40, 30, android.graphics.Color.GREEN),
            "second" to png(1200, 900, android.graphics.Color.BLUE),
            "third" to png(30, 60, android.graphics.Color.RED),
        )
        val source = object : ViewerSource {
            override fun cached(key: String) = bytes[key]
            override suspend fun bytes(key: String) = bytes[key]
        }
        rule.setHappyContent { PictureViewer(names.map { ViewerItem(it, it) }, index, source) { closed++ } }
        rule.waitForIdle()
    }

    /** The picture in view, by its label. */
    private fun showing(name: String) = rule.onNode(hasContentDescription(name) and hasAnyAncestor(hasTestTag(PictureViewerTags.IMAGE)), useUnmergedTree = true)

    private fun position(text: String) = rule.onNode(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, text), useUnmergedTree = true)

    @Test fun `a small picture rests at its own size, in the middle, never enlarged`() {
        show()
        val bounds = rule.node(PictureViewerTags.IMAGE).getBoundsInRoot()
        assertDp("its own width", 40, bounds.width)
        assertDp("its own height", 30, bounds.height)
        // (411 − 40) / 2, rounded as iOS rounds.
        assertDp("centred across", 186, bounds.left)
    }

    @Test fun `a large picture is fitted to the screen's width`() {
        showThree(index = 1)
        showing("second").assertExists()
        val bounds = rule.node(PictureViewerTags.IMAGE).getBoundsInRoot()
        assertDp("the screen's width", 411, bounds.width)
        assertDp("its own shape", 308, bounds.height)
    }

    @Test fun `a swipe turns to the next picture and back, and reads its place`() {
        showThree()
        showing("first").assertExists()
        position("1 of 3").assertExists()
        rule.node(PictureViewerTags.VIEWER).performTouchInput { swipeLeft() }
        rule.waitForIdle()
        showing("second").assertExists()
        val dir = File("build/conversation-screens").apply { mkdirs() }
        File(dir, "picture-viewer-paged.png").outputStream().use {
            rule.node(PictureViewerTags.VIEWER).captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        rule.node(PictureViewerTags.VIEWER).performTouchInput { swipeLeft() }
        rule.waitForIdle()
        showing("third").assertExists()
        rule.node(PictureViewerTags.VIEWER).performTouchInput { swipeRight() }
        rule.waitForIdle()
        showing("second").assertExists()
        assertEquals("paging never closes it", 0, closed)
    }

    @Test fun `zoomed in, a swipe sideways stays on the picture`() {
        showThree()
        rule.node(PictureViewerTags.VIEWER).performTouchInput { doubleClick(center) }
        rule.waitForIdle()
        // 40 × 30 at 2.5 times: 100 × 75, still inside its page.
        assertDp("zoomed", 100, rule.node(PictureViewerTags.IMAGE).getBoundsInRoot().width)
        rule.node(PictureViewerTags.VIEWER).performTouchInput { swipeLeft() }
        rule.waitForIdle()
        showing("first").assertExists()
        assertDp("still zoomed", 100, rule.node(PictureViewerTags.IMAGE).getBoundsInRoot().width)
        // Whole again, it pages.
        rule.node(PictureViewerTags.VIEWER).performTouchInput { doubleClick(center) }
        rule.waitForIdle()
        rule.node(PictureViewerTags.VIEWER).performTouchInput { swipeLeft() }
        rule.waitForIdle()
        showing("second").assertExists()
        assertEquals(0, closed)
    }

    @Test fun `a recording is a page among the pictures, with its controls, and is dragged away the same`() {
        val picture = png(40, 30, android.graphics.Color.GREEN)
        val source = object : ViewerSource {
            override fun cached(key: String) = picture
            override suspend fun bytes(key: String) = picture
            // Nothing to stream: the page says so rather than spinning.
            override fun video(key: String) = null
        }
        rule.setHappyContent { PictureViewer(listOf(ViewerItem("shot", "shot"), ViewerItem("clip", "clip.mp4", isVideo = true)), 0, source) { closed++ } }
        rule.waitForIdle()
        rule.node(PictureViewerTags.VIEWER).performTouchInput { swipeLeft() }
        rule.waitForIdle()
        rule.node(PictureViewerTags.VIDEO).assertExists()
        rule.node(PictureViewerTags.PLAY).assertExists()
        position("2 of 2").assertExists()
        rule.onNode(androidx.compose.ui.test.hasText("This file couldn’t be opened."), useUnmergedTree = true).assertExists()
        rule.node(PictureViewerTags.VIEWER).performTouchInput { swipeDown(startY = centerY - 200f, endY = centerY + 400f, durationMillis = 400) }
        rule.waitForIdle()
        assertEquals(1, closed)
    }

    @Test fun `turned to, any picture is dragged away`() {
        showThree(index = 2)
        showing("third").assertExists()
        rule.node(PictureViewerTags.VIEWER).performTouchInput { swipeDown(startY = centerY, endY = centerY + 600f, durationMillis = 400) }
        rule.waitForIdle()
        assertEquals(1, closed)
    }

    @Test fun `a long drag down puts it away`() {
        show()
        rule.node(PictureViewerTags.IMAGE).performTouchInput { swipeDown(startY = centerY, endY = centerY + 600f, durationMillis = 400) }
        rule.waitForIdle()
        assertEquals(1, closed)
    }

    @Test fun `a fling up puts it away too`() {
        show()
        rule.node(PictureViewerTags.IMAGE).performTouchInput { swipeUp(startY = centerY, endY = centerY - 200f, durationMillis = 60) }
        rule.waitForIdle()
        assertEquals(1, closed)
    }

    @Test fun `let go short and slow it springs back`() {
        show()
        val start = rule.node(PictureViewerTags.IMAGE).getBoundsInRoot()
        rule.node(PictureViewerTags.IMAGE).performTouchInput {
            down(center)
            // 60 dp over half a second: past the slop, short of 100 dp, too slow to fling.
            repeat(10) {
                advanceEventTime(50)
                moveBy(Offset(0f, 18f))
            }
            advanceEventTime(200)
            up()
        }
        rule.waitForIdle()
        assertEquals(0, closed)
        assertDp("back in place", start.top, rule.node(PictureViewerTags.IMAGE).getBoundsInRoot().top)
        rule.node(PictureViewerTags.VIEWER).assertExists()
    }

    @Test fun `held halfway, the picture follows the finger and the black is half gone`() {
        show()
        val start = rule.node(PictureViewerTags.IMAGE).getBoundsInRoot()
        rule.node(PictureViewerTags.IMAGE).performTouchInput {
            down(center)
            // 891 tall: the black is gone 445.5 down; this is about half of that.
            repeat(12) {
                advanceEventTime(40)
                moveBy(Offset(0f, 18.5f * 3))
            }
        }
        rule.waitForIdle()
        val moved = rule.node(PictureViewerTags.IMAGE).getBoundsInRoot()
        // Carried about 222 down (less the touch slop) and shrunk around the page's middle.
        assertTrue("followed the finger: ${moved.top}", moved.top > start.top + 150.dp)
        assertTrue("shrank", moved.width < start.width)
        val viewer = rule.node(PictureViewerTags.VIEWER).captureToImage().asAndroidBitmap()
        val ground = viewer.getPixel(6, 6)
        assertTrue("the black fades: ${Integer.toHexString(ground)}", android.graphics.Color.alpha(ground) in 100..170)
        val dir = File("build/conversation-screens").apply { mkdirs() }
        File(dir, "picture-viewer-dragging.png").outputStream().use { viewer.compress(Bitmap.CompressFormat.PNG, 100, it) }
        rule.node(PictureViewerTags.IMAGE).performTouchInput { up() }
        rule.waitForIdle()
        assertEquals("let go past 100 dp, it goes", 1, closed)
    }

    @Test fun `zoomed in, a drag pans instead of closing`() {
        show()
        rule.node(PictureViewerTags.IMAGE).performTouchInput { doubleClick(center) }
        rule.waitForIdle()
        rule.node(PictureViewerTags.IMAGE).performTouchInput { swipeDown(startY = centerY, endY = centerY + 600f, durationMillis = 400) }
        rule.waitForIdle()
        assertEquals(0, closed)
    }

    @Test fun `its button closes it after the fade`() {
        show()
        rule.node(PictureViewerTags.CLOSE).performClickSafely()
        rule.waitForIdle()
        assertEquals(1, closed)
    }

    private fun androidx.compose.ui.test.SemanticsNodeInteraction.performClickSafely() = performTouchInput { click(center) }
}
