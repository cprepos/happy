package com.slopus.happy.artifacts

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * iOS's `ArtifactMediaLayoutTests` and `MediaLayoutTests` (themselves
 * desktop's mediaLayout cases), in points as dp: the same phone, the same
 * frames.
 */
class ArtifactMediaLayoutTest {
    /** A phone in portrait under its navigation bar. */
    private val size = Extent(393.0, 852.0)
    private val safeArea = Insets(top = 103.0, bottom = 34.0)

    private fun image(width: Double, height: Double, scale: Double? = null) = MediaFlow.Image(width, height, scale)
    private fun picture(width: Double, height: Double) = MediaFlow.Item(isVideo = false, image = image(width, height))

    private fun near(actual: Double, expected: Double, label: String) =
        assertTrue("$label: $actual vs $expected", abs(actual - expected) < 0.01)

    private fun near(actual: Frame?, expected: Frame) {
        requireNotNull(actual)
        for ((a, b) in listOf(actual.x to expected.x, actual.y to expected.y, actual.width to expected.width, actual.height to expected.height)) {
            assertTrue("$actual != $expected", abs(a - b) < 0.0001)
        }
    }

    private fun frames(plan: List<MediaFlow.Row>, measure: Double): List<Frame> {
        val (frames, _) = MediaFlow.geometry(plan, measure)
        return frames.keys.sorted().map { frames.getValue(it) }
    }

    @Test fun onePictureFillsTheWidthCentred() {
        val layout = ArtifactMediaLayout.of(size, safeArea, listOf(picture(1200.0, 800.0)), Extent(80.0, 18.0), listOf(null))
        assertNull(layout.count)
        assertEquals(listOf(Frame(16.0, 340.0, 361.0, 241.0)), layout.tiles)
        assertEquals(listOf<Frame?>(null), layout.badges)
        assertEquals(size, layout.contentSize)
    }

    @Test fun oneSmallPictureKeepsItsSize() {
        val layout = ArtifactMediaLayout.of(size, safeArea, listOf(picture(200.0, 100.0)), null, emptyList())
        assertEquals(listOf(Frame(97.0, 411.0, 200.0, 100.0)), layout.tiles)
    }

    @Test fun oneTallPictureFitsTheHeight() {
        val layout = ArtifactMediaLayout.of(size, safeArea, listOf(picture(1000.0, 4000.0)), null, emptyList())
        // 683 tall at most: 1000 × 4000 scaled by 683 / 4000.
        assertEquals(listOf(Frame(111.0, 119.0, 171.0, 683.0)), layout.tiles)
    }

    @Test fun oneVideoOfUnknownSizeIsWideWithItsDuration() {
        val video = MediaFlow.Item(isVideo = true, image = MediaFlow.Image())
        val layout = ArtifactMediaLayout.of(size, safeArea, listOf(video), null, listOf(30.0))
        assertEquals(listOf(Frame(16.0, 359.0, 361.0, 203.0)), layout.tiles)
        assertEquals(listOf<Frame?>(Frame(22.0, 536.0, 42.0, 20.0)), layout.badges)
    }

    @Test fun fourPicturesFallIntoTwoRowsUnderTheirCount() {
        val items = List(4) { picture(1600.0, 1200.0) }
        val layout = ArtifactMediaLayout.of(size, safeArea, items, Extent(80.0, 18.0), listOf(null, null, null, null))
        assertEquals(Frame(16.0, 119.0, 80.0, 18.0), layout.count)
        // Justified rows of two: (361 − 8) / (4/3 + 4/3) tall each.
        val height = 132.375
        val width = 176.5
        near(layout.tiles[0], Frame(16.0, 149.0, width, height))
        near(layout.tiles[1], Frame(200.5, 149.0, width, height))
        near(layout.tiles[2], Frame(16.0, 289.375, width, height))
        near(layout.tiles[3], Frame(200.5, 289.375, width, height))
        assertEquals(393.0, layout.contentSize.width, 0.0)
        assertEquals(149 + 272.75 + 16 + 34, layout.contentSize.height, 0.0001)
        assertEquals(listOf<Frame?>(null, null, null, null), layout.badges)
    }

    @Test fun aPillNeverOutgrowsItsTile() {
        val items = listOf(picture(100.0, 100.0), MediaFlow.Item(isVideo = true, image = image(40.0, 40.0)))
        val layout = ArtifactMediaLayout.of(size, safeArea, items, Extent(80.0, 18.0), listOf(null, 60.0))
        val tile = layout.tiles[1]
        assertEquals(Frame(tile.x + 6, tile.maxY - 26, 28.0, 20.0), layout.badges[1])
    }

    @Test fun documentPictureInItsOwnShape() {
        assertEquals(Extent(361.0, 241.0), documentPictureSize(361.0, Extent(1200.0, 800.0)))
        assertEquals(Extent(100.0, 50.0), documentPictureSize(361.0, Extent(100.0, 50.0)))
        // Not known yet: 4:3 across the width, as iOS holds its place.
        assertEquals(Extent(361.0, 271.0), documentPictureSize(361.0, null))
    }

    @Test fun twoColumnsKeepEveryShape() {
        val wide = image(1440.0, 900.0)
        val flat = image(1400.0, 200.0)
        val narrow = image(300.0, 900.0)
        val plan = MediaFlow.plan(listOf(wide, flat, narrow, wide), columns = 2)
        val (_, height) = MediaFlow.geometry(plan, 720.0)
        val tiles = frames(plan, 720.0)
        val column = (720.0 - 8) / 2
        near(tiles[0].width, column, "wide fills its column")
        near(tiles[0].height, column / 1.6, "wide keeps 16:10")
        near(tiles[1].x, column + 8, "second column after the gap")
        near(tiles[1].height, column / 7, "the strip whole")
        near(tiles[2].width, 160.0, "narrow narrows to the cap")
        near(tiles[2].height, 480.0, "narrow capped")
        near(tiles[2].y, tiles[0].height + 8, "second row under the taller")
        near(tiles[3].y, tiles[2].y, "a row shares its top")
        near(height, column / 1.6 + 8 + 480, "grid height")
    }

    @Test fun density() {
        val retina = image(1040.0, 720.0, scale = 2.0)
        near(frames(MediaFlow.plan(listOf(retina), columns = 1), 900.0)[0].width, 520.0, "one column stops at 520")
        near(frames(MediaFlow.plan(listOf(retina), columns = 0), 900.0)[0].width, 520.0, "alone at its point size")
        near(MediaFlow.geometry(MediaFlow.plan(listOf(retina, retina), columns = 0), 1400.0).second, 360.0, "row capped at its point height")
    }

    @Test fun justifiedRows() {
        val pair = MediaFlow.plan(listOf(image(3680.0, 2392.0), image(3456.0, 2168.0)), columns = 0)
        assertEquals(1, pair.size)
        val tiles = frames(pair, 720.0)
        near(tiles[0].height, tiles[1].height, "one height")
        near(tiles[0].width + 8 + tiles[1].width, 720.0, "fills the measure")

        val wide = image(1440.0, 900.0)
        val square = image(1024.0, 1024.0)
        val portrait = image(1024.0, 1536.0)
        val many = listOf(wide, square, portrait, wide, square, wide, portrait, square, wide)
        val plan = MediaFlow.plan(many, columns = 0)
        val (geometry, _) = MediaFlow.geometry(plan, 720.0)
        val order = mutableListOf<Int>()
        for (row in plan) {
            val justified = row as MediaFlow.Row.Justified
            assertTrue(justified.tiles.size <= 4)
            order += justified.tiles.map { it.index }
            near(geometry.getValue(justified.tiles.last().index).maxX, 720.0, "ends at the measure")
        }
        assertEquals((0 until 9).toList(), order)

        val small = frames(MediaFlow.plan(listOf(image(100.0, 100.0), image(150.0, 100.0)), columns = 0), 720.0)
        near(small[0].height, 100.0, "held at their own height")
        near(small[1].width, 150.0, "second at its own width")
        assertEquals(listOf(Frame(0.0, 0.0, 300.0, 200.0)), frames(MediaFlow.plan(listOf(image(300.0, 200.0)), columns = 0), 720.0))
    }

    @Test fun recordingsFollowThePicturesAtTheirBox() {
        assertEquals(Extent(380.0, 214.0), MediaFlow.videoBox(null, null))
        assertEquals(Extent(380.0, 214.0), MediaFlow.videoBox(1920.0, 1080.0))
        assertEquals(Extent(240.0, 320.0), MediaFlow.videoBox(1080.0, 1920.0))
        assertEquals(Extent(320.0, 240.0), MediaFlow.videoBox(320.0, 240.0))

        // A phone's 358: a picture, then a 16:9 recording scaled to fit.
        val items = listOf(MediaFlow.Item(isVideo = true, image = image(1920.0, 1080.0)), picture(600.0, 400.0))
        val (frames, extent) = MediaFlow.layout(358.0, items)
        val tall = 358 / 1.5
        assertEquals(listOf(Frame(0.0, tall + 8, 358.0, 202.0), Frame(0.0, 0.0, 358.0, tall)), frames)
        assertEquals(Extent(358.0, tall + 8 + 202), extent)
    }

    @Test fun countsAndDurations() {
        val files = listOf(
            ArtifactFile("a.png", "image/png", 1),
            ArtifactFile("b.jpg", "image/jpeg", 1),
            ArtifactFile("c.mp4", "video/mp4", 1),
        )
        assertEquals(2 to 1, mediaCounts(files))
        assertEquals("0:00", formatDuration(0.0))
        assertEquals("0:07", formatDuration(6.6))
        assertEquals("12:30", formatDuration(750.0))
        assertEquals("1:02:03", formatDuration(3723.0))
        assertEquals("0:00", formatDuration(-4.0))
    }
}
