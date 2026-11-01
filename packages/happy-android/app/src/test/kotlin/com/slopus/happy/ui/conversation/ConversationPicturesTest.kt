package com.slopus.happy.ui.conversation

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.DpRect
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.compose.ui.unit.width
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import coil3.ImageLoader
import coil3.test.FakeImage
import coil3.test.FakeImageLoaderEngine
import com.slopus.happy.conversation.Block
import com.slopus.happy.conversation.ConversationRow
import com.slopus.happy.conversation.ConversationRowBuilder
import com.slopus.happy.conversation.MediaItem
import com.slopus.happy.conversation.Message
import com.slopus.happy.conversation.Presentation
import com.slopus.happy.ui.PHONE
import com.slopus.happy.ui.assertDp
import com.slopus.happy.ui.chat.MessageCallbacks
import com.slopus.happy.ui.chat.MessageTags
import com.slopus.happy.ui.chat.userMessageBubblePalette
import com.slopus.happy.ui.components.LocalImageLoader
import com.slopus.happy.ui.layout.ProvideWindowLayout
import com.slopus.happy.ui.node
import com.slopus.happy.ui.setHappyContent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Pictures in a conversation: each tile is its picture's own shape from
 * the first frame (read from the bytes' header or the stated size), so it
 * sits flush at the edge the words around it use, and its rounded corners
 * are the picture's. Checked on the Fold's cover and inner widths and on a
 * tablet; each test writes its picture under build/conversation-screens.
 */
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = PHONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ConversationPicturesTest {
    @get:Rule
    val rule = createComposeRule()

    private val green = 0xFF00C853.toInt()

    /** Draws every picture as a flat green of the picture's own size, at once. */
    private fun loader(width: Int, height: Int) = ImageLoader.Builder(ApplicationProvider.getApplicationContext())
        .components { add(FakeImageLoaderEngine.Builder().default(FakeImage(width = width, height = height, color = green)).build()) }
        .build()

    private fun png(width: Int, height: Int): ByteArray = ByteArrayOutputStream().also {
        Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply { eraseColor(green) }.compress(Bitmap.CompressFormat.PNG, 100, it)
    }.toByteArray()

    private fun base64(bytes: ByteArray) = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)

    private fun actions(load: suspend () -> ByteArray = { ByteArray(0) }) =
        ConversationRowActions(legacy = MessageCallbacks(), onRetryFailure = {}, loadMedia = { load() })

    private fun rows(message: Message): List<ConversationRow> = ConversationRowBuilder.build(message, "a1", null, false)

    private fun show(width: Int, height: Int, rows: List<ConversationRow>, actions: ConversationRowActions = actions()) {
        rule.setHappyContent {
            CompositionLocalProvider(LocalImageLoader provides loader(width, height)) {
                ProvideWindowLayout {
                    // Unbounded, as the transcript's list is.
                    Column(Modifier.verticalScroll(rememberScrollState())) { rows.forEach { ConversationRowView(it, userMessageBubblePalette(null, false), actions) } }
                }
            }
        }
    }

    private fun tiles(): List<DpRect> = rule.onAllNodesWithTag(ConversationMediaTags.TILE, useUnmergedTree = true)
        .fetchSemanticsNodes().map { node ->
            with(node.layoutInfo.density) {
                val b = node.boundsInRoot
                DpRect(b.left.toDp(), b.top.toDp(), b.right.toDp(), b.bottom.toDp())
            }
        }

    private fun shot(name: String) {
        val dir = File("build/conversation-screens").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use { rule.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    /** The colour on screen at a point in dp. */
    private fun pixel(x: Float, y: Float): Int {
        val bitmap = rule.onRoot().captureToImage().asAndroidBitmap()
        val density = ApplicationProvider.getApplicationContext<android.content.Context>().resources.displayMetrics.density
        return bitmap.getPixel((x * density).toInt(), (y * density).toInt())
    }

    /** The picture fills its tile edge to edge, and the tile's corners are rounded off it. */
    private fun assertWholeAndRounded(tile: DpRect) {
        val midY = (tile.top.value + tile.bottom.value) / 2
        val midX = (tile.left.value + tile.right.value) / 2
        rule.waitUntil(5_000) { pixel(midX, midY) == green }
        assertEquals("the picture reaches the tile's left edge", green, pixel(tile.left.value + 2, midY))
        assertEquals("and its right edge", green, pixel(tile.right.value - 2, midY))
        assertEquals("and its top", green, pixel(midX, tile.top.value + 2))
        assertEquals("and its bottom", green, pixel(midX, tile.bottom.value - 2))
        assertNotEquals("the corner is rounded off", green, pixel(tile.left.value + 0.5f, tile.top.value + 0.5f))
    }

    private fun portraitMessage(text: String = "Here's the screen") =
        Message("u1", "user", 1, listOf(Block.Text(text), Block.Image("image/png", base64(png(450, 800)))))

    @Test fun `a person's portrait photo sits flush right under their bubble, whole and rounded`() {
        show(450, 800, rows(portraitMessage()))
        val bubble = rule.node(MessageTags.USER_BUBBLE).bounds()
        val tile = tiles().single()
        assertDp("bubble against the right margin", 411 - 16, bubble.right)
        assertDp("photo flush with the bubble", bubble.right, tile.right)
        assertDp("8 under the bubble", bubble.bottom + 8.dp, tile.top)
        // 450 × 800 at the message's 360 cap: 202.5 wide, its own shape.
        assertDp("height", 360, tile.height)
        assertDp("width", 202.5.dp, tile.width)
        assertWholeAndRounded(tile)
        shot("pictures-user-portrait")
    }

    @Test fun `photos sent alone hug the right edge too`() {
        val photos = Message("u2", "user", 1, listOf(Block.Image("image/png", base64(png(200, 300))), Block.Image("image/png", base64(png(200, 300)))))
        show(200, 300, rows(photos))
        val (first, second) = tiles()
        assertDp("the last against the right margin", 411 - 16, second.right)
        assertDp("8 apart", first.right + 8.dp, second.left)
        assertDp("one height", first.height, second.height)
        assertDp("their own shape", first.height * (200f / 300f), first.width)
        assertWholeAndRounded(second)
        shot("pictures-user-alone")
    }

    @Test fun `an agent's picture sits flush left with its words`() {
        val agent = Message("g1", "agent", 2, listOf(Block.Text("The page now:"), Block.Image("image/png", base64(png(600, 400)))))
        show(600, 400, rows(agent))
        val tile = tiles().single()
        assertDp("16 in, as the text", 16, tile.left)
        // 379 between the margins; 600 × 400 fills it at 3:2.
        assertDp("width", 379, tile.width)
        assertDp("height", 379.dp * (400f / 600f), tile.height)
        assertWholeAndRounded(tile)
        shot("pictures-agent")
    }

    @Test fun `a tool's pictures take their stated shapes before their bytes come`() {
        val shown = Message(
            "t1", "agent", 3,
            listOf(
                Block.ToolCall(
                    "c1", "show_media", "completed",
                    Presentation.Media(listOf(MediaItem("image", "a.png", "image/png", 1200.0, 800.0), MediaItem("image", "b.png", "image/png", 800.0, 1200.0))),
                ),
            ),
        )
        // Never answered: the tiles are already where they will be.
        show(1200, 800, rows(shown), actions { kotlinx.coroutines.awaitCancellation() })
        val (wide, tall) = tiles()
        assertDp("from the left margin", 16, wide.left)
        assertDp("one row, one height", wide.height, tall.height)
        assertDp("fills the measure", 411 - 16, tall.right)
        assertDp("wide keeps 3:2", wide.height * 1.5f, wide.width)
        shot("pictures-tool-loading")
    }

    @Test fun `a single tool picture with no stated size takes its own once read`() {
        val bytes = png(300, 600)
        val shown = Message("t2", "agent", 3, listOf(Block.ToolCall("c2", "show_media", "completed", Presentation.Media(listOf(MediaItem("image", "a.png", "image/png"))))))
        show(300, 600, rows(shown), actions { bytes })
        rule.waitUntil(5_000) { tiles().singleOrNull()?.let { it.height.value > 500 } == true }
        val tile = tiles().single()
        assertDp("16 in", 16, tile.left)
        assertDp("its own height", 600, tile.height)
        assertDp("its own width", 300, tile.width)
        assertWholeAndRounded(tile)
    }

    @Test fun `past four photos the fourth says how many more, and opens the viewer on itself`() {
        val opened = ArrayList<String>()
        val photos = Message("u4", "user", 1, List(6) { Block.Image("image/png", base64(png(400, 300))) })
        show(400, 300, rows(photos), ConversationRowActions(legacy = MessageCallbacks(), onRetryFailure = {}, loadMedia = { ByteArray(0) }, onOpenPicture = { opened += it }))
        val shown = tiles()
        assertEquals("four of six", 4, shown.size)
        // Two rows of two 4:3 photos in a bubble's width, flush right.
        assertDp("first row's top", shown[0].top, shown[1].top)
        assertDp("second row 8 under", shown[0].bottom + 8.dp, shown[2].top)
        assertDp("flush right", 411 - 16, shown[3].right)
        assertDp("one size", shown[2].width, shown[3].width)
        assertDp("8 apart", shown[2].right + 8.dp, shown[3].left)
        val more = rule.node(ConversationMediaTags.MORE).bounds()
        assertEquals("over the fourth, whole", shown[3], more)
        rule.onNodeWithText("+2", useUnmergedTree = true).assertExists()
        shot("pictures-user-more")
        rule.node(ConversationMediaTags.MORE).performClick()
        assertEquals(listOf("conversation/u4:user:3"), opened)
    }

    @Test fun `four photos or fewer say nothing more`() {
        show(400, 300, rows(Message("u5", "user", 1, List(4) { Block.Image("image/png", base64(png(400, 300))) })))
        assertEquals(4, tiles().size)
        rule.node(ConversationMediaTags.MORE).assertDoesNotExist()
    }

    @Test fun `a presented recording is a tile under the pictures, its first frame under a play circle and its length in a pill`() {
        val frame = Bitmap.createBitmap(64, 36, Bitmap.Config.ARGB_8888).apply { eraseColor(green) }
        val shown = Message(
            "t3", "agent", 3,
            listOf(
                Block.ToolCall(
                    "c3", "show_media", "completed",
                    Presentation.Media(listOf(MediaItem("video", "clip.mp4", "video/mp4", 1280.0, 720.0), MediaItem("image", "a.png", "image/png", 1200.0, 800.0))),
                ),
            ),
        )
        val bytes = png(1200, 800)
        show(
            1200, 800, rows(shown),
            ConversationRowActions(
                legacy = MessageCallbacks(),
                onRetryFailure = {},
                loadMedia = { bytes },
                loadVideo = { VideoPoster(frame, 1280f, 720f, 7.4) },
            ),
        )
        rule.waitUntil(5_000) { rule.onAllNodesWithTag(ConversationMediaTags.DURATION, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
        val (video, picture) = tiles()
        assertDp("the picture first, from the left margin", 16, picture.left)
        assertDp("the recording 8 under it", picture.bottom + 8.dp, video.top)
        assertDp("16 in", 16, video.left)
        // 1280 × 720 into 380 × 320 is 380 × 214; at the 379 measure, 379 × 213.
        assertDp("width", 379, video.width)
        assertDp("height", 213, video.height)
        val play = rule.node(ConversationMediaTags.PLAY).bounds()
        assertDp("a 48 circle", 48, play.width)
        assertDp("in the middle", (video.left + video.right) / 2, (play.left + play.right) / 2)
        val pill = rule.node(ConversationMediaTags.DURATION).bounds()
        assertDp("pill 6 in from the left", video.left + 6.dp, pill.left)
        assertDp("and from the bottom", video.bottom - 6.dp, pill.bottom)
        assertDp("20 high", 20, pill.height)
        rule.onNodeWithText("0:07", useUnmergedTree = true).assertExists()
        // The first frame fills the tile under the circle.
        assertEquals(green, pixel(video.left.value + 12, video.top.value + 12))
        shot("pictures-tool-video")
    }

    @Test
    @Config(qualifiers = "w750dp-h832dp-xxhdpi")
    fun `on the Fold's inner screen photos stay flush right, a bubble's width at most`() {
        show(4032, 3024, rows(Message("u3", "user", 1, listOf(Block.Text("Both"), Block.Image("image/png", base64(png(1008, 756)))))))
        val bubble = rule.node(MessageTags.USER_BUBBLE).bounds()
        val tile = tiles().single()
        // Medium: the 640 measure centred, so the keyline is 55 in.
        assertDp("bubble right", 750 - 55, bubble.right)
        assertDp("photo flush right", bubble.right, tile.right)
        // 640 between the keylines, 620 for photos; a 1008 × 756 photo at the 360 cap: 480 wide.
        assertDp("height", 360, tile.height)
        assertDp("width", 480, tile.width)
        shot("pictures-fold-inner")
    }

    @Test
    @Config(qualifiers = "w1280dp-h800dp-xhdpi")
    fun `on a tablet both edges are the 800 column's`() {
        show(450, 800, rows(portraitMessage()) + rows(Message("g2", "agent", 2, listOf(Block.Image("image/png", base64(png(600, 400)))))))
        val (user, agent) = tiles()
        val bubble = rule.node(MessageTags.USER_BUBBLE).bounds()
        assertDp("bubble at the column's right margin", 240 + 800 - 16, bubble.right)
        assertDp("photo flush with it", bubble.right, user.right)
        assertDp("agent picture at the column's left margin", 240 + 16, agent.left)
        assertDp("under the person's row, 6 in", rule.node(MessageTags.USER).bounds().bottom + 6.dp, agent.top)
        shot("pictures-tablet")
    }

    private fun androidx.compose.ui.test.SemanticsNodeInteraction.bounds(): DpRect = with(fetchSemanticsNode().layoutInfo.density) {
        val b = fetchSemanticsNode().boundsInRoot
        DpRect(b.left.toDp(), b.top.toDp(), b.right.toDp(), b.bottom.toDp())
    }
}
