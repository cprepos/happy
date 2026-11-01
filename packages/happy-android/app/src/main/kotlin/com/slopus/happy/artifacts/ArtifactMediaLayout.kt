package com.slopus.happy.artifacts

import java.util.Locale
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** A frame in dp, as iOS's `CGRect`: origin and size. */
data class Frame(val x: Double, val y: Double, val width: Double, val height: Double) {
    val maxX get() = x + width
    val maxY get() = y + height
    fun contains(px: Double, py: Double) = px >= x && px < maxX && py >= y && py < maxY
    fun offset(dx: Double, dy: Double) = Frame(x + dx, y + dy, width, height)

    companion object {
        val Zero = Frame(0.0, 0.0, 0.0, 0.0)
    }
}

data class Extent(val width: Double, val height: Double)

data class Insets(val top: Double = 0.0, val bottom: Double = 0.0, val left: Double = 0.0, val right: Double = 0.0) {
    val horizontal get() = left + right
}

/** Swift's `rounded()`: half away from zero. */
internal fun Double.rounded(): Double = if (this >= 0) floor(this + 0.5) else -floor(-this + 0.5)

/**
 * iOS's `MediaFlow` (desktop's `mediaLayout.ts`): where pictures shown
 * together go, and how big each one is. Nothing crops: every picture keeps
 * its own shape. `cells` rows are equal columns; `justified` rows share one
 * height and fill the width together.
 */
object MediaFlow {
    /** What the layout knows about one picture before its bytes arrive: its pixels, once known. */
    data class Image(val width: Double? = null, val height: Double? = null, val scale: Double? = null, val hashedRatio: Double? = null)

    data class Limits(val singleMaxHeight: Double, val cellMaxHeight: Double, val rowMaxHeight: Double)

    /** What a tool call presents, at the transcript's full measure. */
    val tool = Limits(640.0, 480.0, 480.0)

    const val GAP = 8.0
    /** A recording's play button, a circle in the middle of its tile. */
    const val PLAY_SIZE = 48.0
    /** The narrowest a picture is drawn because its height is capped. */
    const val MIN_WIDTH = 160.0
    private const val EXTREME_WIDE = 3.0
    private const val EXTREME_NARROW = 0.4
    private const val JUSTIFIED_REFERENCE_WIDTH = 720.0
    private const val JUSTIFIED_TARGET_HEIGHT = 300.0
    private const val JUSTIFIED_MAX_PER_ROW = 4
    private const val FALLBACK_RATIO = 4.0 / 3

    data class Tile(val index: Int, val ratio: Double, val maxWidth: Double)

    sealed interface Row {
        data class Cells(val columns: Int, val maxHeight: Double, val tiles: List<Tile>) : Row
        data class Justified(val maxHeight: Double, val tiles: List<Tile>) : Row
    }

    /** A picture's width over height: its stated size, else its thumbhash, else 4:3. */
    fun ratio(image: Image): Double {
        val w = image.width
        val h = image.height
        if (w != null && h != null && w > 0 && h > 0) return w / h
        return image.hashedRatio ?: FALLBACK_RATIO
    }

    /** Its pixel size over its density; null when no size was stated. */
    fun pointSize(image: Image): Extent? {
        val w = image.width ?: return null
        val h = image.height ?: return null
        if (w <= 0 || h <= 0) return null
        val scale = image.scale?.takeIf { it > 0 } ?: 1.0
        return Extent(w / scale, h / scale)
    }

    private fun cellTile(image: Image, index: Int, maxHeight: Double): Tile {
        val ratio = ratio(image)
        val native = pointSize(image)?.width ?: Double.POSITIVE_INFINITY
        return Tile(index, ratio, min(native, max(maxHeight * ratio, MIN_WIDTH)))
    }

    /** The grid the producer asked for (`columns` > 0), or justified rows. */
    fun plan(images: List<Image>, columns: Int, limits: Limits = tool): List<Row> =
        if (columns > 0) columnsPlan(images, columns, limits) else justifiedPlan(images, limits)

    private fun columnsPlan(images: List<Image>, columns: Int, limits: Limits): List<Row> {
        val maxHeight = if (columns == 1) limits.singleMaxHeight else limits.cellMaxHeight
        return images.indices.chunked(columns).map { chunk -> Row.Cells(columns, maxHeight, chunk.map { cellTile(images[it], it, maxHeight) }) }
    }

    /** A picture of extreme shape takes a row of its own; the runs between are cut into the rows whose heights land closest to the target. */
    private fun justifiedPlan(images: List<Image>, limits: Limits): List<Row> {
        if (images.size == 1) return listOf(Row.Cells(1, limits.singleMaxHeight, listOf(cellTile(images[0], 0, limits.singleMaxHeight))))
        val rows = ArrayList<Row>()
        val run = ArrayList<Int>()
        fun flush() {
            for (row in partition(run.map { ratio(images[it]) })) rows += justifiedRow(images, row.map { run[it] }, limits)
            run.clear()
        }
        for ((index, image) in images.withIndex()) {
            val ratio = ratio(image)
            if (ratio <= EXTREME_WIDE && ratio >= EXTREME_NARROW) {
                run += index
                continue
            }
            flush()
            rows += Row.Cells(1, limits.singleMaxHeight, listOf(cellTile(image, index, limits.singleMaxHeight)))
        }
        flush()
        return rows
    }

    private fun justifiedRow(images: List<Image>, indexes: List<Int>, limits: Limits): Row {
        var maxHeight = limits.rowMaxHeight
        for (index in indexes) pointSize(images[index])?.let { maxHeight = min(maxHeight, it.height) }
        return Row.Justified(maxHeight, indexes.map { Tile(it, ratio(images[it]), maxHeight * ratio(images[it])) })
    }

    /** The cut of [ratios], in order, into rows of at most four that minimises the summed squared distance of each row's height from the target. */
    internal fun partition(ratios: List<Double>): List<List<Int>> {
        val count = ratios.size
        if (count == 0) return emptyList()
        val best = DoubleArray(count + 1) { if (it == 0) 0.0 else Double.POSITIVE_INFINITY }
        val cut = IntArray(count + 1)
        for (end in 1..count) {
            var sum = 0.0
            var start = end - 1
            while (start >= max(0, end - JUSTIFIED_MAX_PER_ROW)) {
                sum += ratios[start]
                val size = (end - start).toDouble()
                val height = (JUSTIFIED_REFERENCE_WIDTH - (size - 1) * GAP) / sum
                val cost = best[start] + (height - JUSTIFIED_TARGET_HEIGHT) * (height - JUSTIFIED_TARGET_HEIGHT)
                if (cost < best[end]) {
                    best[end] = cost
                    cut[end] = start
                }
                start -= 1
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

    /** Every tile's box with the plan drawn at [measure], by index, and the height it takes. */
    fun geometry(plan: List<Row>, measure: Double): Pair<Map<Int, Frame>, Double> {
        val frames = HashMap<Int, Frame>()
        var y = 0.0
        for ((rowIndex, row) in plan.withIndex()) {
            if (rowIndex > 0) y += GAP
            var rowHeight = 0.0
            when (row) {
                is Row.Cells -> {
                    val column = (measure - (row.columns - 1) * GAP) / row.columns
                    for ((cell, tile) in row.tiles.withIndex()) {
                        val width = min(column, tile.maxWidth)
                        val height = min(width / tile.ratio, row.maxHeight)
                        frames[tile.index] = Frame(cell * (column + GAP), y, width, height)
                        rowHeight = max(rowHeight, height)
                    }
                }
                is Row.Justified -> {
                    val free = measure - (row.tiles.size - 1) * GAP
                    val sum = row.tiles.sumOf { it.ratio }
                    rowHeight = min(free / sum, row.maxHeight)
                    var x = 0.0
                    for (tile in row.tiles) {
                        val width = rowHeight * tile.ratio
                        frames[tile.index] = Frame(x, y, width, rowHeight)
                        x += width + GAP
                    }
                }
            }
            y += rowHeight
        }
        return frames to y
    }

    /** The box a recording is drawn in, from its intrinsic size alone: scaled down into 380 × 320, never up; 380 × 214 when none was stated. */
    fun videoBox(width: Double?, height: Double?): Extent {
        if (width == null || height == null || width <= 0 || height <= 0) return Extent(380.0, 214.0)
        val ratio = width / height
        val boxWidth = min(width, 380.0)
        val boxHeight = boxWidth / ratio
        if (boxHeight <= 320) return Extent(boxWidth.rounded(), boxHeight.rounded())
        return Extent(min(max(320 * ratio, 240.0), boxWidth).rounded(), 320.0)
    }

    /** One item of a flow: a picture or a recording, and what is known of its shape. */
    data class Item(val isVideo: Boolean, val image: Image)

    /**
     * iOS's `MediaLayout`: every picture first, together, as one flow; then
     * each recording at its own box, no wider than [width]. One frame per
     * item, in the items' order, and the size they take.
     */
    fun layout(width: Double, items: List<Item>, columns: Int = 0, limits: Limits = tool): Pair<List<Frame>, Extent> {
        val frames = MutableList(items.size) { Frame.Zero }
        val pictures = items.indices.filter { !items[it].isVideo }
        var y = 0.0
        if (pictures.isNotEmpty()) {
            val (flow, height) = geometry(plan(pictures.map { items[it].image }, columns, limits), width)
            for ((position, index) in pictures.withIndex()) frames[index] = flow[position] ?: Frame.Zero
            y = height
        }
        for (index in items.indices) {
            if (!items[index].isVideo) continue
            if (y > 0) y += GAP
            var box = videoBox(items[index].image.width, items[index].image.height)
            if (box.width > width && box.width > 0) box = Extent(width, (box.height * width / box.width).rounded())
            frames[index] = Frame(0.0, y, box.width, box.height)
            y += box.height
        }
        return frames to Extent(frames.maxOfOrNull { it.maxX } ?: 0.0, y)
    }
}

/**
 * iOS's `ArtifactMediaLayout`: an image, image series or video artifact on
 * its own screen. One item shows large, fitted inside the safe area less
 * the padding, never past its own size, centred. Several stand under a
 * line that counts them, in the conversation's media flow (justified rows)
 * across the width; a recording's duration sits in a pill at its tile's
 * bottom left. Frames are in the screen's coordinates; the grid scrolls.
 */
data class ArtifactMediaLayout(
    /** The count line; null for a single item. */
    val count: Frame?,
    /** One frame per item, in the items' order. */
    val tiles: List<Frame>,
    /** The duration pill over each item that has one. */
    val badges: List<Frame?>,
    val contentSize: Extent,
) {
    companion object {
        const val PADDING = 16.0
        const val COUNT_GAP = 12.0
        const val BADGE_INSET = 6.0
        const val BADGE_HEIGHT = 20.0
        const val BADGE_PADDING = 6.0

        /** [count] is the count line's size, [badges] each pill's text width (null: none). */
        fun of(size: Extent, safeArea: Insets, items: List<MediaFlow.Item>, count: Extent?, badges: List<Double?>): ArtifactMediaLayout {
            val area = Frame(
                safeArea.left + PADDING,
                safeArea.top + PADDING,
                max(0.0, size.width - safeArea.horizontal - 2 * PADDING),
                max(0.0, size.height - safeArea.top - safeArea.bottom - 2 * PADDING),
            )
            val countFrame: Frame?
            val tiles: List<Frame>
            val content: Extent
            if (items.size == 1) {
                countFrame = null
                tiles = listOf(fitted(items[0], area))
                content = size
            } else {
                var top = area.y
                countFrame = count?.let { Frame(area.x, top, min(it.width, area.width), it.height) }
                if (countFrame != null) top = countFrame.maxY + COUNT_GAP
                val (frames, flow) = MediaFlow.layout(area.width, items)
                tiles = frames.map { it.offset(area.x, top) }
                content = Extent(size.width, top + flow.height + PADDING + safeArea.bottom)
            }
            val pills = tiles.indices.map { index ->
                val text = badges.getOrNull(index) ?: return@map null
                val tile = tiles[index]
                val width = min(text + 2 * BADGE_PADDING, max(0.0, tile.width - 2 * BADGE_INSET))
                Frame(tile.x + BADGE_INSET, tile.maxY - BADGE_INSET - BADGE_HEIGHT, width, BADGE_HEIGHT)
            }
            return ArtifactMediaLayout(countFrame, tiles, pills, content)
        }

        /** The item as large as [area] lets it be in its own shape, never past its size; a shape not known yet is 4:3, a recording's 16:9. */
        internal fun fitted(item: MediaFlow.Item, area: Frame): Frame {
            val natural = MediaFlow.pointSize(item.image) ?: run {
                val ratio = if (item.isVideo && item.image.hashedRatio == null) 16.0 / 9 else MediaFlow.ratio(item.image)
                Extent(area.width, area.width / ratio)
            }
            val midX = area.x + area.width / 2
            val midY = area.y + area.height / 2
            if (natural.width <= 0 || natural.height <= 0 || area.width <= 0 || area.height <= 0) return Frame(midX, midY, 0.0, 0.0)
            val scale = minOf(1.0, area.width / natural.width, area.height / natural.height)
            val w = (natural.width * scale).rounded()
            val h = (natural.height * scale).rounded()
            return Frame((midX - w / 2).rounded(), (midY - h / 2).rounded(), w, h)
        }
    }
}

/**
 * A document's picture in its own shape (iOS's `MarkdownLayout` picture):
 * as wide as it is, never wider than [available], its height by its shape;
 * a shape not known yet is 4:3 across the whole width.
 */
fun documentPictureSize(available: Double, pixels: Extent?): Extent {
    if (pixels == null || pixels.width <= 0 || pixels.height <= 0) return Extent(available, (available * 3 / 4).rounded())
    val width = min(available, pixels.width)
    return Extent(width.rounded(), (width * pixels.height / pixels.width).rounded())
}

/** What a grid of pictures and recordings holds, by kind: (images, videos). */
fun mediaCounts(files: List<ArtifactFile>): Pair<Int, Int> {
    val videos = files.count { it.isVideo }
    return (files.size - videos) to videos
}

/** A recording's length, as its pill shows it: "0:07", "12:30", "1:02:03". */
fun formatDuration(seconds: Double): String {
    val total = max(0L, seconds.rounded().toLong())
    val hours = total / 3600
    val minutes = total / 60 % 60
    val rest = total % 60
    return if (hours > 0) String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, rest) else String.format(Locale.ROOT, "%d:%02d", minutes, rest)
}
