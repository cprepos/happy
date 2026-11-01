package com.slopus.happy.conversation

import com.slopus.happy.conversation.PictureViewing.Gesture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The viewer's own rules (iOS's PictureViewerLayout, PicturePagerLayout and PictureViewController's gesture gates). */
class PictureViewingTest {
    private val phone = PictureViewing.Insets(top = 24f, bottom = 48f)

    @Test fun `a small picture rests at its own size, centred in the safe area`() {
        // 411 × 891 with 24 above and 48 below: the area is 411 × 819, its middle at y 433.5.
        val frame = PictureViewing.fitted(411f, 891f, phone, 40f to 30f)
        assertEquals(MediaFlow.Frame(186f, 419f, 40f, 30f), frame)
    }

    @Test fun `a large one is fitted inside the safe area, keeping its shape`() {
        val wide = PictureViewing.fitted(411f, 891f, phone, 4032f to 3024f)
        assertEquals(411f, wide.width)
        assertEquals(308f, wide.height)
        assertEquals(0f, wide.x)
        val tall = PictureViewing.fitted(411f, 891f, phone, 1000f to 4000f)
        assertEquals(819f, tall.height)
        assertEquals(24f, tall.y)
        assertEquals(205f, tall.width)
    }

    @Test fun `never enlarged, however much room there is`() {
        for (size in listOf(1f to 1f, 100f to 50f, 1280f to 800f)) {
            val frame = PictureViewing.fitted(1280f, 800f, PictureViewing.Insets(), size)
            assertEquals(size.first, frame.width)
            assertEquals(size.second, frame.height)
        }
    }

    @Test fun `not known yet, it takes the safe area`() {
        assertEquals(MediaFlow.Frame(0f, 24f, 411f, 819f), PictureViewing.fitted(411f, 891f, phone, null))
        assertEquals(MediaFlow.Frame(0f, 24f, 411f, 819f), PictureViewing.fitted(411f, 891f, phone, 0f to 10f))
    }

    @Test fun `before the bytes, a stated size, else the thumbhash's shape filling the area`() {
        assertEquals(40f to 30f, PictureViewing.restingSize(ViewerItem("k", null, width = 40f, height = 30f), 2f, 891f))
        val hashed = PictureViewing.restingSize(ViewerItem("k", null), 0.5f, 891f)!!
        assertEquals(0.5f, hashed.first / hashed.second, 0.0001f)
        val fitted = PictureViewing.fitted(411f, 891f, phone, hashed)
        assertEquals(819f, fitted.height)
        assertEquals(409.5f, fitted.width, 0.51f)
        assertNull(PictureViewing.restingSize(ViewerItem("k", null), null, 891f))
    }

    @Test fun `a gesture waits for the slop, then goes by its direction`() {
        assertNull(PictureViewing.decide(1, 1f, 3f, 4f, slop = 8f, zoomed = false))
        assertEquals(Gesture.Dismiss, PictureViewing.decide(1, 1f, 3f, 9f, slop = 8f, zoomed = false))
        assertEquals(Gesture.Dismiss, PictureViewing.decide(1, 1f, 0f, -9f, slop = 8f, zoomed = false))
        assertEquals(Gesture.Page, PictureViewing.decide(1, 1f, -9f, 3f, slop = 8f, zoomed = false))
        // Exactly diagonal is the pager's: a dismissal is mostly up or down.
        assertEquals(Gesture.Page, PictureViewing.decide(1, 1f, 7f, 7f, slop = 8f, zoomed = false))
    }

    @Test fun `zoomed in, a drag only moves the picture, never pages or dismisses`() {
        assertEquals(Gesture.Transform, PictureViewing.decide(1, 1f, -40f, 2f, slop = 8f, zoomed = true))
        assertEquals(Gesture.Transform, PictureViewing.decide(1, 1f, 0f, 40f, slop = 8f, zoomed = true))
        assertFalse(PictureViewing.pages(zoomed = true, dismissing = false))
    }

    @Test fun `a second finger or a pinch zooms at once, where the page zooms`() {
        assertEquals(Gesture.Transform, PictureViewing.decide(2, 1f, 0f, 0f, slop = 8f, zoomed = false))
        assertEquals(Gesture.Transform, PictureViewing.decide(1, 1.1f, 0f, 0f, slop = 8f, zoomed = false))
        // A recording doesn't zoom: two fingers decide nothing, one still drags it away or pages.
        assertNull(PictureViewing.decide(2, 1.1f, 0f, 40f, slop = 8f, zoomed = false, zoomable = false))
        assertEquals(Gesture.Dismiss, PictureViewing.decide(1, 1f, 0f, 40f, slop = 8f, zoomed = false, zoomable = false))
        assertEquals(Gesture.Page, PictureViewing.decide(1, 1f, 40f, 0f, slop = 8f, zoomed = false, zoomable = false))
    }

    @Test fun `the pager turns only on a whole picture that isn't being dragged away`() {
        assertTrue(PictureViewing.pages(zoomed = false, dismissing = false))
        assertFalse(PictureViewing.pages(zoomed = false, dismissing = true))
        assertFalse(PictureViewing.pages(zoomed = true, dismissing = true))
    }

    @Test fun `a zoomed picture moves only as far as it overhangs its page`() {
        assertEquals(0f to 0f, PictureViewing.panLimit(40f, 30f, 2.5f, 411f, 891f))
        assertEquals(205.5f to 0f, PictureViewing.panLimit(411f, 308f, 2f, 411f, 891f))
        assertEquals(822f to 1602f, PictureViewing.panLimit(411f, 819f, 5f, 411f, 891f))
    }

    @Test fun `its position reads N of M, and nothing alone`() {
        assertEquals(2 to 5, PictureViewing.position(1, 5))
        assertNull(PictureViewing.position(0, 1))
        assertNull(PictureViewing.position(5, 5))
    }

    @Test fun `the pages are the conversation's media, oldest first, every photo of a message included`() {
        val photos = List(6) { Block.Image("image/png", "AA$it") }
        val clip = MediaRef("c1", 0, MediaItem("video", "clip.mp4", "video/mp4", 1280.0, 720.0, thumbhash = "hash"))
        val shot = MediaRef("c1", 1, MediaItem("image", "", "image/png"))
        val doc = MediaRef("c1", 2, MediaItem("file", "notes.pdf", "application/pdf"))
        // Newest first, as the transcript holds them.
        val rows = listOf(
            ConversationRow.Picture("g1:0", Block.Image("image/png", "BB")),
            ConversationRow.Media("t1:0", listOf(clip, shot, doc)),
            ConversationRow.Text("t0:0", "words", emptyList()),
            ConversationRow.User("u1:0", "u1", "", emptyList(), photos, Delivery.Sent),
        )
        val entries = ConversationViewing.entries(rows, "Picture", "Video")
        assertEquals(
            (0 until 6).map { "conversation/u1:0:$it" } + listOf("conversation/media/c1/0", "conversation/media/c1/1", "conversation/g1:0:0"),
            entries.map { it.item.key },
        )
        assertEquals(photos[5], entries[5].inline)
        val video = entries[6]
        assertTrue(video.item.isVideo)
        assertEquals("clip.mp4", video.item.label)
        assertEquals(1280f, video.item.width)
        assertEquals("hash", video.item.thumbhash)
        assertEquals(clip, video.presented)
        assertEquals("Picture", entries[7].item.label)
        assertFalse(entries[7].item.isVideo)
    }
}
