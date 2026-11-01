package com.slopus.happy.conversation

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** iOS's MediaLayoutTests (desktop's mediaLayout.test.tsx), and the phone's own frames. */
class MediaFlowTest {
    private fun image(width: Float, height: Float, scale: Float? = null) = MediaFlow.Image(width, height, scale)

    private val wide = image(1440f, 900f)
    private val flat = image(1400f, 200f)
    private val narrow = image(300f, 900f)
    private val square = image(1024f, 1024f)
    private val portrait = image(1024f, 1536f)
    private val page = image(1440f, 7200f)

    private fun near(actual: Float, expected: Float, label: String) = assertEquals(label, expected, actual, 0.01f)

    private fun frames(plan: MediaFlow.Plan, measure: Float, alignEnd: Boolean = false): List<MediaFlow.Frame> {
        val geometry = MediaFlow.geometry(plan, measure, alignEnd)
        return geometry.frames.keys.sorted().map { geometry.frames.getValue(it) }
    }

    @Test fun `two columns keep every shape`() {
        val plan = MediaFlow.columnsPlan(listOf(wide, flat, narrow, wide), columns = 2)
        val geometry = MediaFlow.geometry(plan, 720f)
        val tiles = frames(plan, 720f)
        val column = (720f - 8) / 2
        near(tiles[0].width, column, "wide fills its column")
        near(tiles[0].height, column / 1.6f, "wide keeps 16:10")
        near(tiles[1].x, column + 8, "second column after the gap")
        near(tiles[1].height, column / 7, "the strip whole")
        near(tiles[2].width, 160f, "narrow narrows to the cap")
        near(tiles[2].height, 480f, "narrow capped")
        near(tiles[2].y, tiles[0].height + 8, "second row under the taller")
        near(tiles[3].y, tiles[2].y, "a row shares its top")
        near(geometry.height, column / 1.6f + 8 + 480, "grid height")
    }

    @Test fun `a page capture letterboxes`() {
        val tile = frames(MediaFlow.columnsPlan(listOf(page), columns = 2), 720f)[0]
        near(tile.height, 480f, "capped")
        near(tile.width, 160f, "held at the minimum width")
    }

    @Test fun `one column never past its own pixels`() {
        val tiles = frames(MediaFlow.columnsPlan(listOf(wide, square, portrait, image(120f, 80f)), columns = 1), 720f)
        near(tiles[0].width, 720f, "landscape fills")
        near(tiles[1].width, 640f, "square to the 640 cap")
        near(tiles[2].height, 640f, "portrait capped")
        near(tiles[2].width, 640f / 1.5f, "portrait keeps its shape")
        near(tiles[3].width, 120f, "a small picture is not blown up")
    }

    @Test fun density() {
        val retina = image(1040f, 720f, scale = 2f)
        near(frames(MediaFlow.columnsPlan(listOf(retina), columns = 1), 900f)[0].width, 520f, "one column stops at 520")
        near(frames(MediaFlow.justifiedPlan(listOf(retina)), 900f)[0].width, 520f, "alone at its point size")
        near(frames(MediaFlow.columnsPlan(listOf(image(2880f, 1800f, scale = 2f)), columns = 1), 720f)[0].width, 720f, "a wider capture fills")
        near(MediaFlow.geometry(MediaFlow.justifiedPlan(listOf(retina, retina)), 1400f).height, 360f, "row capped at its point height")
    }

    @Test fun `justified rows`() {
        val pair = MediaFlow.justifiedPlan(listOf(image(3680f, 2392f), image(3456f, 2168f)))
        assertEquals(1, pair.rows.size)
        val tiles = frames(pair, 720f)
        near(tiles[0].height, tiles[1].height, "one height")
        near(tiles[0].width + 8 + tiles[1].width, 720f, "fills the measure")

        val extremes = MediaFlow.justifiedPlan(listOf(wide, flat, square, narrow, portrait))
        assertEquals(5, extremes.rows.size)
        near(frames(extremes, 720f)[1].width, 720f, "the strip spans the measure")

        val many = listOf(wide, square, portrait, wide, square, wide, portrait, square, wide)
        val plan = MediaFlow.justifiedPlan(many)
        val geometry = MediaFlow.geometry(plan, 720f)
        val order = ArrayList<Int>()
        for (row in plan.rows) {
            row as MediaFlow.Row.Justified
            assertTrue(row.tiles.size <= 4)
            order += row.tiles.map { it.index }
            near(geometry.frames.getValue(row.tiles.last().index).right, 720f, "ends at the measure")
        }
        assertEquals((0 until 9).toList(), order)

        val small = frames(MediaFlow.justifiedPlan(listOf(image(100f, 100f), image(150f, 100f))), 720f)
        near(small[0].height, 100f, "held at their own height")
        near(small[1].width, 150f, "second at its own width")
        assertEquals(listOf(MediaFlow.Frame(0f, 0f, 300f, 200f)), frames(MediaFlow.justifiedPlan(listOf(image(300f, 200f))), 720f))
    }

    @Test fun `a person's photos hug the right edge in a bubble's width`() {
        // iOS's 390 wide phone: 358 between the 16 margins, 338 for the photos (36 clear at the left).
        assertEquals(338f, MediaFlow.messageMeasure(358f))
        val photo = MediaFlow.layout(listOf(image(4032f, 3024f)), MediaFlow.messageMeasure(358f), limits = MediaFlow.message, alignEnd = true)
        assertEquals(listOf(MediaFlow.Frame(0f, 0f, 338f, 253.5f)), photo.frames)
        assertEquals(338f, photo.width)

        // Justified at their own 200 height, pushed to the right edge.
        val pair = MediaFlow.layout(listOf(image(100f, 200f), image(100f, 200f)), 338f, limits = MediaFlow.message, alignEnd = true)
        assertEquals(listOf(MediaFlow.Frame(130f, 0f, 100f, 200f), MediaFlow.Frame(238f, 0f, 100f, 200f)), pair.frames)

        // A narrow photo alone sits against the right too, not centred in its column.
        val tall = MediaFlow.layout(listOf(image(900f, 1600f)), 338f, limits = MediaFlow.message, alignEnd = true)
        near(tall.frames[0].right, 338f, "flush right")
        near(tall.frames[0].height, 360f, "capped at 360")
        near(tall.frames[0].width, 360f * 900 / 1600, "its own shape")

        // Wide screens: never past 560.
        assertEquals(560f, MediaFlow.messageMeasure(768f))
    }

    @Test fun `an agent's picture sits at the left at its own size`() {
        val layout = MediaFlow.layout(listOf(image(300f, 200f)), 358f)
        assertEquals(listOf(MediaFlow.Frame(0f, 0f, 300f, 200f)), layout.frames)
        assertEquals(300f, layout.width)
        assertEquals(200f, layout.height)
    }

    @Test fun `a shape not stated is the thumbhash's, else 4 to 3`() {
        assertEquals(4f / 3f, MediaFlow.ratio(MediaFlow.Image()))
        assertEquals(0.5f, MediaFlow.ratio(MediaFlow.Image(hashedRatio = 0.5f)))
        assertEquals(2f, MediaFlow.ratio(MediaFlow.Image(200f, 100f, hashedRatio = 0.5f)))
        val unknown = MediaFlow.layout(listOf(MediaFlow.Image()), 379f)
        near(unknown.frames[0].width, 379f, "across the measure")
        near(unknown.frames[0].height, 379f * 3 / 4, "at 4:3")
    }

    @Test fun `no width or no pictures lays out nothing`() {
        assertEquals(0f, MediaFlow.layout(emptyList(), 300f).height)
        assertEquals(0f, MediaFlow.layout(listOf(square), 0f).height)
    }

    @Test fun `a media presentation reads its grid, scale and thumbhash`() {
        fun parse(json: String) = Presentation.parse(Json.parseToJsonElement(json)) as Presentation.Media
        val grid = parse("""{"type":"media","layout":{"type":"columns","columns":2},"items":[{"kind":"image","name":"a.png","mimeType":"image/png","width":2880,"height":1800,"scale":2,"thumbhash":"1QcSHQRnh493V4dIh4eXh1h4kJUI"}]}""")
        assertEquals(2, grid.columns)
        assertEquals(2.0, grid.items[0].scale)
        assertEquals("1QcSHQRnh493V4dIh4eXh1h4kJUI", grid.items[0].thumbhash)
        assertEquals(0, parse("""{"type":"media","layout":{"type":"columns","columns":3},"items":[]}""").columns)
        assertEquals(0, parse("""{"type":"media","items":[]}""").columns)
    }

    @Test fun `a message shows four of its photos and counts the rest`() {
        // iOS's `messageMax`: the row takes the first four; the viewer pages through the rest.
        assertEquals(4, MediaFlow.MESSAGE_MAX)
        assertEquals(listOf(0, 1, 2, 3, 4, 4, 4), listOf(0, 1, 2, 3, 4, 5, 9).map(MediaFlow::messageShown))
        assertEquals(listOf(0, 0, 0, 0, 0, 1, 5), listOf(0, 1, 2, 3, 4, 5, 9).map(MediaFlow::messageMore))
        assertEquals(0, MediaFlow.messageShown(-1))
    }

    @Test fun `four photos of six lay out as four, in two justified rows of a bubble's width`() {
        val six = List(6) { image(1200f, 900f) }
        val shown = six.take(MediaFlow.messageShown(six.size))
        val layout = MediaFlow.layout(shown, 338f, limits = MediaFlow.message, alignEnd = true)
        assertEquals(4, layout.frames.size)
        // 4:3 photos at 720 cut into two rows of two, each 338 wide together.
        near(layout.frames[0].y, layout.frames[1].y, "first row shares its top")
        near(layout.frames[2].y, layout.frames[0].bottom + 8, "second row under it")
        near(layout.frames[1].right, 338f, "flush right")
        near(layout.frames[3].right, 338f, "flush right")
        near(layout.frames[0].width, (338f - 8) / 2, "half the measure each")
        // The same four as the first four of six: what is cut never moves what stays.
        assertEquals(MediaFlow.layout(six.take(4), 338f, limits = MediaFlow.message, alignEnd = true), layout)
    }

    @Test fun `a recording's box is its own size into 380 by 320, never enlarged`() {
        assertEquals(380f to 214f, MediaFlow.videoBox(null, null))
        assertEquals(320f to 180f, MediaFlow.videoBox(320f, 180f))
        assertEquals(380f to 214f, MediaFlow.videoBox(1920f, 1080f))
        // Portrait: 320 high, as wide as its shape gives, at least 240.
        assertEquals(240f to 320f, MediaFlow.videoBox(1080f, 1920f))
        assertEquals(320f to 320f, MediaFlow.videoBox(1000f, 1000f))
    }

    @Test fun `pictures flow first and each recording follows at its own box`() {
        val items = listOf(
            MediaFlow.Item(true, image(1920f, 1080f)),
            MediaFlow.Item(false, image(300f, 200f)),
            MediaFlow.Item(true, MediaFlow.Image()),
        )
        val layout = MediaFlow.mediaLayout(items, 379f)
        assertEquals(MediaFlow.Frame(0f, 0f, 300f, 200f), layout.frames[1])
        assertEquals(MediaFlow.Frame(0f, 208f, 379f, 213f), layout.frames[0])
        assertEquals(MediaFlow.Frame(0f, 429f, 379f, 213f), layout.frames[2])
        near(layout.height, 642f, "one under another, 8 apart")
        near(layout.width, 379f, "the widest")

        // A person's are pushed to the right edge.
        val sent = MediaFlow.mediaLayout(listOf(MediaFlow.Item(true, image(320f, 180f))), 338f, alignEnd = true)
        assertEquals(MediaFlow.Frame(18f, 0f, 320f, 180f), sent.frames.single())
    }

    @Test fun `a presented item says its length in bytes`() {
        val item = MediaItem.parse(Json.parseToJsonElement("""{"kind":"video","name":"a.mp4","mimeType":"video/mp4","size":28560,"width":1280,"height":720}"""))!!
        assertEquals(28560.0, item.size)
        assertEquals(null, MediaItem.parse(Json.parseToJsonElement("""{"kind":"video","name":"a.mp4","mimeType":"video/mp4"}"""))!!.size)
    }
}
