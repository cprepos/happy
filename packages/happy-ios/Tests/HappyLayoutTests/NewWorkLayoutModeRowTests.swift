import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import HappyLayout
import XCTest

/// The legacy block with its Mode row: computer, folder, harness and mode, and
/// what happens to them on the smallest phone iOS 26 runs, the 375x667 iPhone SE,
/// when the keyboard leaves little room (`NewWorkLayout+Addons.swift`).
final class NewWorkLayoutModeRowTests: XCTestCase {
    private typealias M = NewWorkLayout.Metrics
    private let note = Measurable { CGSize(width: $0, height: 48) }

    private func session(width: CGFloat = 375, top: CGFloat = 64, bottom: CGFloat, kindHeight: CGFloat? = nil, rows: Int = 4, note: Measurable? = nil, reserve: Bool = false, compacts: Bool = true) -> NewWorkLayout {
        NewWorkLayout(width: width, top: top, bottom: bottom, kindHeight: kindHeight, givingWay: rows, note: note,
                      reserveArt: reserve, reserveRows: reserve ? 4 : 0, compactsWhenShort: compacts)
    }

    /// Four regular rows, with room: 44 high, 8 apart, upstream's 256 wide, centred.
    func testFourRowsWithRoomKeepTheirHeight() {
        let layout = session(bottom: 324)
        XCTAssertEqual(layout.rows, [
            CGRect(x: 0, y: 0, width: 256, height: 44),
            CGRect(x: 0, y: 52, width: 256, height: 44),
            CGRect(x: 0, y: 104, width: 256, height: 44),
            CGRect(x: 0, y: 156, width: 256, height: 44),
        ])
        XCTAssertEqual(layout.block, CGRect(x: 59.5, y: 94, width: 256, height: 200))
        XCTAssertTrue(layout.fits)
    }

    /// Short of room but clear of the bar, the rows keep their height and the
    /// block stands its margin over the composer, as upstream's does.
    func testShortButClearOfTheBarStaysRegular() {
        let layout = session(top: 64, bottom: 64 + 217)
        XCTAssertFalse(layout.fits)
        XCTAssertFalse(layout.underBar(top: 64))
        XCTAssertEqual(layout.rows.map(\.height), Array(repeating: M.rowHeight, count: 4))
        XCTAssertEqual(layout.block, CGRect(x: 59.5, y: 69, width: 256, height: 200))
    }

    /// What an iPhone SE measured with the keyboard up: the bar's foot at 74,
    /// the dock's top at 288, and a 31-high Session | Bot | Task over the
    /// note and the four rows. Upstream's regular rows take the kind under
    /// the bar.
    func testUpstreamsRowsTakeTheKindUnderTheBarOnAnIPhoneSE() {
        let layout = session(top: 74, bottom: 288, kindHeight: 31, note: note, reserve: true, compacts: false)
        XCTAssertTrue(layout.underBar(top: 74))
    }

    /// The same, compacted: the kind stops at the bar's foot, the rows have
    /// risen over the faded note, and the last stands its margin over the dock.
    func testTheKindAndFourRowsFitTheMeasuredIPhoneSE() throws {
        let layout = session(top: 74, bottom: 288, kindHeight: 31, note: note, reserve: true)
        XCTAssertFalse(layout.underBar(top: 74))
        let kind = try XCTUnwrap(layout.kind)
        XCTAssertEqual(layout.block.minY + kind.minY, 74)
        XCTAssertEqual(layout.rows, [
            CGRect(x: 0, y: 141, width: 256, height: 36),
            CGRect(x: 0, y: 183, width: 256, height: 36),
            CGRect(x: 0, y: 225, width: 256, height: 36),
            CGRect(x: 0, y: 267, width: 256, height: 36),
        ])
        XCTAssertEqual(layout.block, CGRect(x: 59.5, y: -19, width: 256, height: 303))
        XCTAssertEqual(layout.block.maxY, 288 - M.compactMargin)
        XCTAssertEqual(layout.noteAlpha, 0)
        XCTAssertFalse(layout.showsNote)
    }

    /// Too short even with the chip's gap closed: the closed one is kept,
    /// and the block runs on up under the bar as upstream's does.
    func testTooShortEvenTightRunsUnderTheBar() {
        let layout = session(top: 74, bottom: 200, kindHeight: 31)
        XCTAssertTrue(layout.underBar(top: 74))
        XCTAssertEqual(layout.rows.map(\.height), Array(repeating: M.compactRowHeight, count: 4))
        XCTAssertEqual(layout.rows.first?.minY, 31 + M.compactKindToRows)
        XCTAssertEqual(layout.block.maxY, 200 - M.compactMargin)
    }

    /// Our copy of upstream's `givingWay` body, at upstream's metrics, lays
    /// out what upstream's does. A failure here means upstream changed its
    /// layout: port the change into `layOutGivingWay`.
    func testTheCopyMatchesUpstreamAtUpstreamsMetrics() {
        for bottom: CGFloat in [150, 200, 288, 340, 500, 800] {
            for kindHeight: CGFloat? in [nil, 31] {
                for rows in [1, 2, 3, 4] {
                    for (note, art, reserve) in [(nil, false, false), (note, true, false), (note, false, true)] as [(Measurable?, Bool, Bool)] {
                        let upstream = NewWorkLayout(width: 375, top: 74, bottom: bottom, kindHeight: kindHeight, givingWay: rows, note: note, art: art, reserveArt: reserve, reserveRows: reserve ? 3 : 0)
                        var copy = upstream
                        copy.layOutGivingWay(width: 375, sides: .zero, top: 74, bottom: bottom, kindHeight: kindHeight, count: rows, note: note, art: art, reserveArt: reserve, reserveRows: reserve ? 3 : 0,
                                             rowHeight: M.rowHeight, rowGap: M.rowGap, kindGap: M.kindToRows, margin: M.margin)
                        XCTAssertEqual(copy, upstream, "bottom \(bottom) kind \(String(describing: kindHeight)) rows \(rows) art \(art) reserve \(reserve)")
                    }
                }
            }
        }
    }
}
