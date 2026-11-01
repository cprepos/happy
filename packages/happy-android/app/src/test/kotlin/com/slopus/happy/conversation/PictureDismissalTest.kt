package com.slopus.happy.conversation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS's ChatViewingLayoutTests for the viewer's drag away. */
class PictureDismissalTest {
    @Test fun `a drag down fades the ground and shrinks the picture`() {
        val rest = PictureDismissal.of(0f, 0f, 874f)
        assertEquals(1f, rest.groundAlpha)
        assertEquals(1f, rest.scale)
        assertFalse(rest.closes)

        val half = PictureDismissal.of(218.5f, 0f, 874f)
        assertEquals(0.5f, half.progress, 0.0001f)
        assertEquals(0.5f, half.groundAlpha, 0.0001f)
        assertEquals(0.9f, half.scale, 0.0001f)
        assertTrue(half.closes)

        val far = PictureDismissal.of(-600f, 0f, 874f)
        assertEquals(0f, far.groundAlpha)
        assertEquals(0.8f, far.scale, 0.0001f)
        assertTrue("up closes too", far.closes)
    }

    @Test fun `let go short it stays unless flung`() {
        assertFalse(PictureDismissal.of(60f, 200f, 874f).closes)
        assertTrue(PictureDismissal.of(40f, 1200f, 874f).closes)
        assertFalse("a tap's wobble", PictureDismissal.of(5f, 1200f, 874f).closes)
        assertFalse("flung back", PictureDismissal.of(160f, -1200f, 874f).closes)
    }
}
