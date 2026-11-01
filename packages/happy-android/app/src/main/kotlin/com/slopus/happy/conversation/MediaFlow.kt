package com.slopus.happy.conversation

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * Where pictures shown together go, and how big each one is: iOS's
 * `MediaFlow` (HappyLayout/Agents/MediaLayout.swift, desktop's
 * `mediaLayout.ts`), in dp. Nothing crops: every picture keeps its own
 * shape, so a tile is exactly its picture and its rounded corners are the
 * picture's. A plan is made once from the pictures' shapes alone, before
 * any bytes arrive, then drawn at a measure.
 *
 * Two kinds of row: [Row.Cells], equal columns, each picture at its
 * column's width and never past its own size or the row's height cap; and
 * [Row.Justified], pictures sharing one height and filling the width
 * together.
 */
object MediaFlow {
    /** What the layout knows about one picture before its bytes arrive. */
    data class Image(
        /** Intrinsic pixel size, when it is known. */
        val width: Float? = null,
        val height: Float? = null,
        /** Pixels per dp: a 2x capture is never drawn past half its pixels. */
        val scale: Float? = null,
        /** The shape the thumbhash's header carries, for a size not stated. */
        val hashedRatio: Float? = null,
    )

    /** The bounds one surface draws its pictures within. */
    data class Limits(
        /** A picture on a row of its own, and a one-column grid. */
        val singleMaxHeight: Float,
        /** A two-column grid's cells. */
        val cellMaxHeight: Float,
        /** A justified row's shared height. */
        val rowMaxHeight: Float,
    )

    /** What a tool call presents, at the transcript's full measure. */
    val tool = Limits(singleMaxHeight = 640f, cellMaxHeight = 480f, rowMaxHeight = 480f)

    /** Photos attached to a message. */
    val message = Limits(singleMaxHeight = 360f, cellMaxHeight = 320f, rowMaxHeight = 280f)

    /** A message's photos stay a bubble's width, not the transcript's. */
    const val MESSAGE_MAX_WIDTH = 560f

    /**
     * The most of a message's photos its row shows (iOS's `messageMax`);
     * the viewer pages through the rest, and the last one shown says how
     * many more there are.
     */
    const val MESSAGE_MAX = 4

    /** How many of a message's [count] photos its row shows. */
    fun messageShown(count: Int): Int = min(max(0, count), MESSAGE_MAX)

    /** How many it doesn't: the "+N" over the last one shown. */
    fun messageMore(count: Int): Int = max(0, count - MESSAGE_MAX)

    /** A recording's play button, a circle in the middle of its tile. */
    const val PLAY_SIZE = 48f
    private const val VIDEO_MAX_WIDTH = 380f
    private const val VIDEO_MAX_HEIGHT = 320f
    private const val VIDEO_MIN_WIDTH = 240f
    private const val VIDEO_FALLBACK_HEIGHT = 214f

    const val GAP = 8f

    /** The narrowest a picture is drawn because its height is capped. */
    const val MIN_WIDTH = 160f
    private const val EXTREME_WIDE = 3f
    private const val EXTREME_NARROW = 0.4f
    private const val JUSTIFIED_REFERENCE_WIDTH = 720f
    private const val JUSTIFIED_TARGET_HEIGHT = 300f
    private const val JUSTIFIED_MAX_PER_ROW = 4
    const val FALLBACK_RATIO = 4f / 3f

    data class Tile(
        val index: Int,
        /** Width over height. */
        val ratio: Float,
        /** The widest this tile is ever drawn. */
        val maxWidth: Float,
    )

    sealed interface Row {
        data class Cells(val columns: Int, val maxHeight: Float, val tiles: List<Tile>) : Row
        data class Justified(val maxHeight: Float, val tiles: List<Tile>) : Row
    }

    data class Plan(val rows: List<Row>)

    /** One tile's box, in dp from the flow's top left. */
    data class Frame(val x: Float, val y: Float, val width: Float, val height: Float) {
        val right: Float get() = x + width
        val bottom: Float get() = y + height
    }

    /** Every tile's box by index, and the height they take. */
    data class Geometry(val frames: Map<Int, Frame>, val height: Float)

    /** A picture's width over height: its stated size, else its thumbhash, else 4:3. */
    fun ratio(image: Image): Float {
        val width = image.width
        val height = image.height
        if (width != null && height != null && width > 0 && height > 0) return width / height
        return image.hashedRatio?.takeIf { it > 0 } ?: FALLBACK_RATIO
    }

    /** Its pixel size over its density, as (width, height); null when no size is known. */
    fun pointSize(image: Image): Pair<Float, Float>? {
        val width = image.width ?: return null
        val height = image.height ?: return null
        if (width <= 0 || height <= 0) return null
        val scale = image.scale?.takeIf { it > 0 } ?: 1f
        return width / scale to height / scale
    }

    private fun cellTile(image: Image, index: Int, maxHeight: Float): Tile {
        val ratio = ratio(image)
        val native = pointSize(image)?.first ?: Float.POSITIVE_INFINITY
        return Tile(index, ratio, min(native, max(maxHeight * ratio, MIN_WIDTH)))
    }

    /** The grid the producer asked for (`columns` > 0), or justified rows. */
    fun plan(images: List<Image>, columns: Int, limits: Limits = tool): Plan =
        if (columns > 0) columnsPlan(images, columns, limits) else justifiedPlan(images, limits)

    fun columnsPlan(images: List<Image>, columns: Int, limits: Limits = tool): Plan {
        val maxHeight = if (columns == 1) limits.singleMaxHeight else limits.cellMaxHeight
        val rows = images.indices.chunked(columns).map { chunk ->
            Row.Cells(columns, maxHeight, chunk.map { cellTile(images[it], it, maxHeight) })
        }
        return Plan(rows)
    }

    /**
     * A picture of extreme shape takes a row of its own; the runs between
     * are cut into the rows whose heights land closest to the target.
     */
    fun justifiedPlan(images: List<Image>, limits: Limits = tool): Plan {
        if (images.size == 1) {
            return Plan(listOf(Row.Cells(1, limits.singleMaxHeight, listOf(cellTile(images[0], 0, limits.singleMaxHeight)))))
        }
        val rows = ArrayList<Row>()
        val run = ArrayList<Int>()
        fun flush() {
            for (row in partition(run.map { ratio(images[it]) })) {
                rows += justifiedRow(images, row.map { run[it] }, limits)
            }
            run.clear()
        }
        images.forEachIndexed { index, image ->
            val ratio = ratio(image)
            if (ratio <= EXTREME_WIDE && ratio >= EXTREME_NARROW) {
                run += index
            } else {
                flush()
                rows += Row.Cells(1, limits.singleMaxHeight, listOf(cellTile(image, index, limits.singleMaxHeight)))
            }
        }
        flush()
        return Plan(rows)
    }

    private fun justifiedRow(images: List<Image>, indexes: List<Int>, limits: Limits): Row {
        var maxHeight = limits.rowMaxHeight
        for (index in indexes) pointSize(images[index])?.let { maxHeight = min(maxHeight, it.second) }
        return Row.Justified(maxHeight, indexes.map { index ->
            val ratio = ratio(images[index])
            Tile(index, ratio, maxHeight * ratio)
        })
    }

    /**
     * The cut of [ratios], in order, into rows of at most four that
     * minimises the summed squared distance of each row's height from the target.
     */
    internal fun partition(ratios: List<Float>): List<List<Int>> {
        val count = ratios.size
        if (count == 0) return emptyList()
        val best = FloatArray(count + 1) { if (it == 0) 0f else Float.POSITIVE_INFINITY }
        val cut = IntArray(count + 1)
        for (end in 1..count) {
            var sum = 0f
            var start = end - 1
            while (start >= max(0, end - JUSTIFIED_MAX_PER_ROW)) {
                sum += ratios[start]
                val size = (end - start).toFloat()
                val height = (JUSTIFIED_REFERENCE_WIDTH - (size - 1) * GAP) / sum
                val cost = best[start] + (height - JUSTIFIED_TARGET_HEIGHT) * (height - JUSTIFIED_TARGET_HEIGHT)
                if (cost < best[end]) {
                    best[end] = cost
                    cut[end] = start
                }
                start--
            }
        }
        val rows = ArrayList<List<Int>>()
        var end = count
        while (end > 0) {
            rows.add(0, (cut[end] until end).toList())
            end = cut[end]
        }
        return rows
    }

    /**
     * Every tile's box with the plan drawn at [measure], by index, and the
     * height it takes. [alignEnd] pushes short rows and cells to the right,
     * as a person's own photos are.
     */
    fun geometry(plan: Plan, measure: Float, alignEnd: Boolean = false): Geometry {
        val frames = HashMap<Int, Frame>()
        var y = 0f
        plan.rows.forEachIndexed { rowIndex, row ->
            if (rowIndex > 0) y += GAP
            var rowHeight = 0f
            when (row) {
                is Row.Cells -> {
                    val column = (measure - (row.columns - 1) * GAP) / row.columns
                    // At the end, the row's cells sit against the right edge.
                    val shift = if (alignEnd) measure - (row.tiles.size * (column + GAP) - GAP) else 0f
                    row.tiles.forEachIndexed { cell, tile ->
                        val width = min(column, tile.maxWidth)
                        val height = min(width / tile.ratio, row.maxHeight)
                        var x = cell * (column + GAP) + shift
                        if (alignEnd) x += column - width
                        frames[tile.index] = Frame(x, y, width, height)
                        rowHeight = max(rowHeight, height)
                    }
                }
                is Row.Justified -> {
                    val free = measure - (row.tiles.size - 1) * GAP
                    val sum = row.tiles.sumOf { it.ratio.toDouble() }.toFloat()
                    rowHeight = min(free / sum, row.maxHeight)
                    val used = row.tiles.sumOf { (rowHeight * it.ratio).toDouble() }.toFloat() + (row.tiles.size - 1) * GAP
                    var x = if (alignEnd) measure - used else 0f
                    for (tile in row.tiles) {
                        val width = rowHeight * tile.ratio
                        frames[tile.index] = Frame(x, y, width, rowHeight)
                        x += width + GAP
                    }
                }
            }
            y += rowHeight
        }
        return Geometry(frames, y)
    }

    /** Frames in the images' order, and the flow's size: the measure when aligned to the end, else what the tiles use. */
    fun layout(images: List<Image>, measure: Float, columns: Int = 0, limits: Limits = tool, alignEnd: Boolean = false): Layout =
        mediaLayout(images.map { Item(false, it) }, measure, columns, limits, alignEnd)

    data class Layout(val frames: List<Frame>, val width: Float, val height: Float)

    /** One item of a flow: a picture or a recording, and what is known of its shape. */
    data class Item(val isVideo: Boolean, val image: Image)

    /**
     * The box a recording is drawn in, from its intrinsic size alone (iOS's
     * `videoBox`): scaled down into 380 × 320, never up; 380 × 214 when none
     * was stated. (width, height).
     */
    fun videoBox(width: Float?, height: Float?): Pair<Float, Float> {
        if (width == null || height == null || width <= 0 || height <= 0) return VIDEO_MAX_WIDTH to VIDEO_FALLBACK_HEIGHT
        val ratio = width / height
        val boxWidth = min(width, VIDEO_MAX_WIDTH)
        val boxHeight = boxWidth / ratio
        if (boxHeight <= VIDEO_MAX_HEIGHT) return rounded(boxWidth) to rounded(boxHeight)
        return rounded(min(max(VIDEO_MAX_HEIGHT * ratio, VIDEO_MIN_WIDTH), boxWidth)) to VIDEO_MAX_HEIGHT
    }

    /**
     * Pictures and recordings shown together, as iOS's `MediaLayout`: every
     * picture first, together, as one flow; then each recording at its own
     * box ([videoBox]), no wider than [measure], against the right edge
     * with [alignEnd]. Frames in the items' order, and the flow's size as
     * [layout] gives it.
     */
    fun mediaLayout(items: List<Item>, measure: Float, columns: Int = 0, limits: Limits = tool, alignEnd: Boolean = false): Layout {
        if (items.isEmpty() || measure <= 0f) return Layout(items.map { Frame(0f, 0f, 0f, 0f) }, 0f, 0f)
        val frames = MutableList(items.size) { Frame(0f, 0f, 0f, 0f) }
        val pictures = items.indices.filter { !items[it].isVideo }
        var y = 0f
        if (pictures.isNotEmpty()) {
            val geometry = geometry(plan(pictures.map { items[it].image }, columns, limits), measure, alignEnd)
            pictures.forEachIndexed { position, index -> geometry.frames[position]?.let { frames[index] = it } }
            y = geometry.height
        }
        for (index in items.indices) {
            if (!items[index].isVideo) continue
            if (y > 0) y += GAP
            var (width, height) = videoBox(items[index].image.width, items[index].image.height)
            if (width > measure && width > 0) {
                height = rounded(height * measure / width)
                width = measure
            }
            frames[index] = Frame(if (alignEnd) measure - width else 0f, y, width, height)
            y += height
        }
        val used = frames.maxOf { it.right }
        return Layout(frames, if (alignEnd) measure else used, y)
    }

    /** Swift's `rounded()`: half away from zero (sizes here are never negative). */
    private fun rounded(value: Float): Float = floor(value + 0.5f)

    /**
     * The room a person's photos are laid out in, from the room their
     * message has (16 in from each side): as wide as the bubble may be, 36
     * clear at the left (the bubble's own limit), and never past 560.
     */
    fun messageMeasure(inner: Float): Float = max(0f, min(inner - BUBBLE_LEADING + MARGIN_H, MESSAGE_MAX_WIDTH))

    /** iOS's `MessageLayout.Metrics`: the least room left of a person's bubble and pictures, and the sides' inset. */
    private const val BUBBLE_LEADING = 36f
    private const val MARGIN_H = 16f
}
