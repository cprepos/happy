#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Our plugins' compact rows for `NewWorkLayout`, kept out of
/// NewWorkLayout.swift so upstream merges do not conflict there.
///
/// A legacy account's block asks the computer (when it has more than one),
/// folder, harness and mode, so on a small phone with the keyboard up it may
/// tighten before it gives up (`compactsWhenShort`). The initializer here
/// lays the block out as upstream's `givingWay` does, and only when that
/// does not fit lays it out again with the compact rows.
extension NewWorkLayout.Metrics {
    /// `compactsWhenShort`'s, when the regular ones don't fit.
    public static let compactRowHeight: CGFloat = 36
    public static let compactRowGap: CGFloat = 6
    public static let compactKindToRows: CGFloat = 8
    /// The least room over and under the tightened block: a dock's padding
    /// already sits under it, and Session | Bot | Task over four rows on a
    /// 375x667 phone has 214 for 201.
    public static let compactMargin: CGFloat = 4
}

extension NewWorkLayout {
    /// Upstream's `init(…givingWay:…)`; with `compactsWhenShort`, when even
    /// its closed gaps do not fit, the rows shorten (`compactRowHeight`),
    /// first keeping the gap the status chip clears, then closing it too.
    /// With four rows (computer, folder, harness, mode) and the kind on a
    /// 375x667 phone, it comes to that.
    public init(width: CGFloat, sides: LayoutInsets = .zero, top: CGFloat, bottom: CGFloat, kindHeight: CGFloat?, givingWay count: Int, note: Measurable?, art: Bool = false, compactsWhenShort: Bool) {
        self.init(width: width, sides: sides, top: top, bottom: bottom, kindHeight: kindHeight, givingWay: count, note: note, art: art)
        guard compactsWhenShort, !fits else { return }
        typealias M = Metrics
        let room = bottom - top
        let attempts = [M.tightKindToRows, M.compactKindToRows].map { kindGap in
            Self.compactStack(width: block.width, art: art, kindHeight: kindHeight, kindGap: kindGap, count: count, noteHeight: nil)
        }
        let chosen = attempts.first { room >= $0.height + 2 * M.compactMargin } ?? attempts[attempts.count - 1]
        place(chosen, top: top, bottom: bottom)
    }

    private typealias Stack = (art: CGRect?, kind: CGRect?, rows: [CGRect], note: CGRect?, height: CGFloat)

    /// The block in compact rows, `blockWidth` wide: the picture, the kind
    /// `kindGap` over the rows, the rows, and the note when it has a height.
    private static func compactStack(width blockWidth: CGFloat, art: Bool, kindHeight: CGFloat?, kindGap: CGFloat, count: Int, noteHeight: CGFloat?) -> Stack {
        typealias M = Metrics
        var y: CGFloat = 0
        var picture: CGRect?
        if art {
            picture = CGRect(x: (blockWidth - M.art) / 2, y: 0, width: M.art, height: M.art)
            y = M.art + M.artToKind
        }
        var kind: CGRect?
        if let kindHeight {
            let kindWidth = min(M.kindWidth, blockWidth)
            kind = CGRect(x: (blockWidth - kindWidth) / 2, y: y, width: kindWidth, height: kindHeight)
            y += kindHeight + kindGap
        }
        var rows: [CGRect] = []
        for index in 0..<max(0, count) {
            if index > 0 { y += M.compactRowGap }
            rows.append(CGRect(x: 0, y: y, width: blockWidth, height: M.compactRowHeight))
            y += M.compactRowHeight
        }
        var note: CGRect?
        if let noteHeight {
            y += M.rowsToNote
            note = CGRect(x: 0, y: y, width: blockWidth, height: noteHeight)
            y += noteHeight
        }
        return (picture, kind, rows, note, y)
    }

    /// Lays out `stack` between `top` and `bottom` as upstream does, with
    /// `compactMargin`; the block keeps its width and its place across.
    private mutating func place(_ stack: Stack, top: CGFloat, bottom: CGFloat) {
        typealias M = Metrics
        let room = bottom - top
        art = stack.art
        kind = stack.kind
        rows = stack.rows
        note = stack.note
        showsNote = stack.note != nil
        fits = room >= stack.height + 2 * M.compactMargin
        let origin = fits ? top + (room - stack.height) / 2 : bottom - M.compactMargin - stack.height
        block = CGRect(x: block.minX, y: origin, width: block.width, height: stack.height)
    }
}
