import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import HappyLayout
import XCTest

/// The legacy block with its Mode row: computer, folder, harness and mode, and
/// what happens to them on the smallest phone iOS 26 runs, the 375x667 iPhone SE,
/// when the keyboard leaves little room.
final class NewWorkLayoutModeRowTests: XCTestCase {
    private typealias M = NewWorkLayout.Metrics

    private func session(width: CGFloat = 375, top: CGFloat = 64, bottom: CGFloat, kindHeight: CGFloat? = nil, rows: Int = 4, note: Measurable? = nil) -> NewWorkLayout {
        NewWorkLayout(width: width, top: top, bottom: bottom, kindHeight: kindHeight, rows: rows, note: note, compactsWhenShort: true)
    }

    /// Four regular rows, with room: 44 high, 8 apart, 320 wide, centred.
    func testFourRowsWithRoomKeepTheirHeight() {
        let layout = session(bottom: 324)
        XCTAssertEqual(layout.rows, [
            CGRect(x: 0, y: 0, width: 320, height: 44),
            CGRect(x: 0, y: 52, width: 320, height: 44),
            CGRect(x: 0, y: 104, width: 320, height: 44),
            CGRect(x: 0, y: 156, width: 320, height: 44),
        ])
        XCTAssertEqual(layout.block, CGRect(x: 27.5, y: 94, width: 320, height: 200))
        XCTAssertTrue(layout.fits)
    }

    /// The last height at which four regular rows fit: 200 and 12 either side.
    func testFourRowsExactlyFittingStayRegular() {
        let layout = session(top: 64, bottom: 64 + 224)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.rows.count, 4)
        XCTAssertEqual(layout.rows[3], CGRect(x: 0, y: 156, width: 320, height: M.rowHeight))
        XCTAssertEqual(layout.block, CGRect(x: 27.5, y: 76, width: 320, height: 200))
    }

    /// One point less and they tighten: 36 high, 6 apart.
    func testFourRowsOnePointShortTighten() {
        let layout = session(top: 64, bottom: 64 + 223)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.rows, [
            CGRect(x: 0, y: 0, width: 320, height: 36),
            CGRect(x: 0, y: 42, width: 320, height: 36),
            CGRect(x: 0, y: 84, width: 320, height: 36),
            CGRect(x: 0, y: 126, width: 320, height: 36),
        ])
        XCTAssertEqual(layout.block.height, 162)
        XCTAssertEqual(layout.block.midY, 64 + 223.0 / 2, accuracy: 0.001)
    }

    /// Session | Bot | Task over the four rows, which needs 272 regular.
    func testTheKindAndFourRowsTightenWhereTheyWouldNotFit() throws {
        let layout = session(top: 64, bottom: 64 + 240, kindHeight: 32)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(try XCTUnwrap(layout.kind), CGRect(x: 50, y: 0, width: 220, height: 32))
        XCTAssertEqual(layout.rows.first, CGRect(x: 0, y: 40, width: 320, height: 36))
        XCTAssertEqual(layout.rows.last, CGRect(x: 0, y: 166, width: 320, height: 36))
        XCTAssertEqual(layout.block.height, 202)
    }

    /// What an iPhone SE measured with the keyboard up: the bar's foot at 74, the
    /// dock's top at 288, and a 31-high control over the four rows.
    func testTheKindAndFourRowsFitTheMeasuredIPhoneSE() throws {
        let layout = session(top: 74, bottom: 288, kindHeight: 31)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(try XCTUnwrap(layout.kind), CGRect(x: 50, y: 0, width: 220, height: 31))
        XCTAssertEqual(layout.rows, [
            CGRect(x: 0, y: 39, width: 320, height: 36),
            CGRect(x: 0, y: 81, width: 320, height: 36),
            CGRect(x: 0, y: 123, width: 320, height: 36),
            CGRect(x: 0, y: 165, width: 320, height: 36),
        ])
        XCTAssertEqual(layout.block, CGRect(x: 27.5, y: 80.5, width: 320, height: 201))
    }

    /// Tightened and still short: it doesn't show, as before.
    func testTooShortEvenTightDoesNotFit() {
        let edge = session(top: 64, bottom: 64 + 162 + 2 * M.compactMargin)
        XCTAssertTrue(edge.fits)
        let short = session(top: 64, bottom: 64 + 162 + 2 * M.compactMargin - 1)
        XCTAssertFalse(short.fits)
        XCTAssertEqual(short.block.minY, 64 + M.compactMargin)
    }

    /// `.work` doesn't ask for it: the same room leaves it at its own size,
    /// not fitting, exactly as it was.
    func testWithoutTheFlagNothingTightens() {
        let layout = NewWorkLayout(width: 375, top: 64, bottom: 64 + 223, kindHeight: nil, rows: 4, note: nil)
        XCTAssertFalse(layout.fits)
        XCTAssertEqual(layout.rows.first?.height, M.rowHeight)
        XCTAssertEqual(layout.block.height, 200)
    }
}
