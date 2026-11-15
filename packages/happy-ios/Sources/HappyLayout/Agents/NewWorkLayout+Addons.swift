#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Our addons' compact rows for `NewWorkLayout`, kept out of
/// NewWorkLayout.swift so upstream merges do not conflict there.
///
/// A legacy account's block asks the computer, folder, harness and, our
/// addon, the harness's mode: four rows. Upstream's `givingWay` block never
/// shrinks: short of room its first control stops at the bar's foot and
/// the rows rise over the note, and only past that does it run on up under
/// the bar. With the Mode row, Session | Bot | Task over four rows on a
/// 375x667 phone with the keyboard up comes to that, and the kind goes
/// under the bar. With `compactsWhenShort` the block is laid out as
/// upstream's, and only when its first control would go under the bar is
/// it laid out again with compact rows (`compactRowHeight`), first keeping
/// the gap the computer's status chip clears, then closing it too.
extension NewWorkLayout.Metrics {
    /// `compactsWhenShort`'s, when the regular ones don't fit.
    public static let compactRowHeight: CGFloat = 36
    public static let compactRowGap: CGFloat = 6
    /// The kind's, the note's and the rows' gap, still clearing the
    /// computer's status chip (`NewWorkStatusLayout.overhang`).
    public static let compactChipKindToRows: CGFloat = NewWorkStatusLayout.overhang + 5
    public static let compactKindToRows: CGFloat = 8
    /// The least room over and under the tightened block: a dock's padding
    /// already sits under it.
    public static let compactMargin: CGFloat = 4
}

extension NewWorkLayout {
    /// Upstream's `init(…givingWay:…)`; with `compactsWhenShort`, when its
    /// first control would go under the bar, the rows shorten.
    public init(width: CGFloat, sides: LayoutInsets = .zero, top: CGFloat, bottom: CGFloat, kindHeight: CGFloat?, givingWay count: Int, note: Measurable?, art: Bool = false, reserveArt: Bool = false, reserveRows: Int = 0, compactsWhenShort: Bool) {
        self.init(width: width, sides: sides, top: top, bottom: bottom, kindHeight: kindHeight, givingWay: count, note: note, art: art, reserveArt: reserveArt, reserveRows: reserveRows)
        guard compactsWhenShort, underBar(top: top) else { return }
        typealias M = Metrics
        for kindGap in [M.compactChipKindToRows, M.compactKindToRows] {
            layOutGivingWay(width: width, sides: sides, top: top, bottom: bottom, kindHeight: kindHeight, count: count, note: note, art: art, reserveArt: reserveArt, reserveRows: reserveRows,
                            rowHeight: M.compactRowHeight, rowGap: M.compactRowGap, kindGap: kindGap, margin: M.compactMargin)
            if !underBar(top: top) { return }
        }
    }

    /// The first control (the kind, else the first row) is over `top`, the
    /// bar's foot.
    public func underBar(top: CGFloat) -> Bool {
        guard let first = kind?.minY ?? rows.first?.minY else { return false }
        return block.minY + first < top - 0.5
    }

    /// A copy of upstream's `init(…givingWay:…)` body (NewWorkLayout.swift,
    /// 1b8d6f543 and c212e5624), its row height and gaps as parameters.
    /// `testTheCopyMatchesUpstreamAtUpstreamsMetrics` warns when upstream's
    /// drifts from it.
    public mutating func layOutGivingWay(width: CGFloat, sides: LayoutInsets, top: CGFloat, bottom: CGFloat, kindHeight: CGFloat?, count: Int, note: Measurable?, art: Bool, reserveArt: Bool, reserveRows: Int,
                                  rowHeight: CGFloat, rowGap: CGFloat, kindGap: CGFloat, margin: CGFloat) {
        typealias M = Metrics
        let band = sides.sides(of: CGSize(width: width, height: 0))
        let blockWidth = max(0, min(M.givingWayMaxWidth, band.width - 2 * M.side))
        let room = bottom - top
        let rowCount = max(count, reserveRows)
        var y: CGFloat = 0
        let side: CGFloat? = art || reserveArt ? M.givingWayArt : nil
        if let side { y = side + M.artToKind }
        var gap: CGFloat = 0
        var kind: CGRect?
        if let kindHeight {
            let kindWidth = min(M.kindWidth, blockWidth)
            kind = CGRect(x: (blockWidth - kindWidth) / 2, y: y, width: kindWidth, height: kindHeight)
            y += kindHeight
            gap = kindGap
        }
        var noteFrame: CGRect?
        if let note {
            y += gap
            let height = ceil(note.size(fitting: blockWidth).height)
            noteFrame = CGRect(x: 0, y: y, width: blockWidth, height: height)
            y += height
            gap = kindGap
        }
        var rows: [CGRect] = []
        for index in 0..<max(0, rowCount) {
            y += index > 0 ? rowGap : gap
            if index < count { rows.append(CGRect(x: 0, y: y, width: blockWidth, height: rowHeight)) }
            y += rowHeight
        }
        fits = room >= y + 2 * margin
        var origin = fits ? top + (room - y) / 2 : bottom - margin - y
        var rise: CGFloat = 0
        if let first = kind?.minY ?? rows.first?.minY, origin + first < top {
            origin = top - first
            let over = origin + y - (bottom - margin)
            let noteRoom = noteFrame.map { $0.height + kindGap } ?? 0
            rise = min(max(0, over), noteRoom)
            noteAlpha = max(0, 1 - rise / kindGap)
            origin -= max(0, over - rise)
        } else {
            noteAlpha = 1
        }
        self.art = art ? side.map { CGRect(x: (blockWidth - $0) / 2, y: 0, width: $0, height: $0) } : nil
        self.kind = kind
        self.rows = rows.map { $0.offsetBy(dx: 0, dy: -rise) }
        self.note = noteFrame
        showsNote = noteFrame != nil && noteAlpha > 0
        block = CGRect(x: band.minX + (band.width - blockWidth) / 2, y: origin, width: blockWidth, height: y - rise)
    }
}
