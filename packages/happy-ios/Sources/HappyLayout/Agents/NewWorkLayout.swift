import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// New work's empty conversation, on both homes: what it will be, as one
/// block centred between the bar and the composer. The composer moves with
/// the keyboard, and the block, laid out against it, moves with it.
///
/// Happy Agent's asks Task or Bot over an optional name; a legacy account's
/// asks the computer (when it has more than one), folder, harness and mode.
/// Either is an optional control over field-high rows and a line saying what it
/// is. A legacy account's can ask for all of it on a small phone with the
/// keyboard up, so it may tighten before it gives up (`compactsWhenShort`).
///
///     bar ─────────────────────────
///               [ Task | Bot ]          kind, optional
///          |24| [ Name (optional) ] |24|   rows, at most 320 wide
///               what a task is          note, optional
///     composer ────────────────────
public struct NewWorkLayout: Equatable, Sendable {
    public enum Metrics {
        public static let side: CGFloat = 24
        public static let maxWidth: CGFloat = 320
        public static let kindWidth: CGFloat = 220
        public static let kindToRows: CGFloat = 16
        public static let rowHeight: CGFloat = 44
        public static let rowGap: CGFloat = 8
        public static let rowsToNote: CGFloat = 10
        /// `compactsWhenShort`'s, when the regular ones don't fit.
        public static let compactRowHeight: CGFloat = 36
        public static let compactRowGap: CGFloat = 6
        public static let compactKindToRows: CGFloat = 8
        /// The least room over and under the tightened block: a dock's padding
        /// already sits under it, and Session | Bot | Task over four rows on a
        /// 375x667 phone has 214 for 201.
        public static let compactMargin: CGFloat = 4
        /// The least room kept over and under the block; with less it
        /// doesn't show.
        public static let margin: CGFloat = 12
    }

    /// The block, in the screen.
    public var block: CGRect
    /// In the block.
    public var kind: CGRect?
    public var rows: [CGRect]
    public var note: CGRect?
    /// There is room for the block between the bar and the composer.
    public var fits: Bool

    /// `top` is the bar's foot and `bottom` the composer's top, in the
    /// screen; `kindHeight` is the control's, nil for none; `note` wraps,
    /// centred, at the block's width. `compactsWhenShort` tightens the rows
    /// and their gaps when the regular ones would not fit.
    public init(width: CGFloat, top: CGFloat, bottom: CGFloat, kindHeight: CGFloat?, rows count: Int, note: Measurable?, compactsWhenShort: Bool = false) {
        typealias M = Metrics
        let blockWidth = max(0, min(M.maxWidth, width - 2 * M.side))
        let noteHeight = note?.size(fitting: blockWidth).height
        let room = bottom - top
        func stack(rowHeight: CGFloat, rowGap: CGFloat, kindToRows: CGFloat) -> (kind: CGRect?, rows: [CGRect], note: CGRect?, height: CGFloat) {
            var y: CGFloat = 0
            var kind: CGRect?
            if let kindHeight {
                let kindWidth = min(M.kindWidth, blockWidth)
                kind = CGRect(x: (blockWidth - kindWidth) / 2, y: 0, width: kindWidth, height: kindHeight)
                y = kindHeight + kindToRows
            }
            var rows: [CGRect] = []
            for index in 0..<max(0, count) {
                if index > 0 { y += rowGap }
                rows.append(CGRect(x: 0, y: y, width: blockWidth, height: rowHeight))
                y += rowHeight
            }
            var note: CGRect?
            if let noteHeight {
                y += M.rowsToNote
                note = CGRect(x: 0, y: y, width: blockWidth, height: noteHeight)
                y += noteHeight
            }
            return (kind, rows, note, y)
        }
        var stacked = stack(rowHeight: M.rowHeight, rowGap: M.rowGap, kindToRows: M.kindToRows)
        var margin = M.margin
        if compactsWhenShort, room < stacked.height + 2 * margin {
            stacked = stack(rowHeight: M.compactRowHeight, rowGap: M.compactRowGap, kindToRows: M.compactKindToRows)
            margin = M.compactMargin
        }
        kind = stacked.kind
        rows = stacked.rows
        self.note = stacked.note
        fits = room >= stacked.height + 2 * margin
        let origin = fits ? top + (room - stacked.height) / 2 : top + margin
        block = CGRect(x: (width - blockWidth) / 2, y: origin, width: blockWidth, height: stacked.height)
    }
}
