import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import HappyLayout
import XCTest

/// What the keyboard covers (`KeyboardCover`): a docked keyboard, an iPad's
/// minimized bar floating over the bottom edge as a pill or a short strip,
/// and never a keyboard dragged up the screen.
final class KeyboardCoverTests: XCTestCase {
    /// A 13-inch iPad held sideways, its home indicator's safe area 20.
    private let bounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)
    private let safe: CGFloat = 20

    /// The minimized bar as a pill, `height` tall and `gap` over the edge.
    private func pill(width: CGFloat = 360, height: CGFloat = 44, gap: CGFloat = 12) -> CGRect {
        CGRect(x: (bounds.width - width) / 2, y: bounds.maxY - gap - height, width: width, height: height)
    }

    func testAPillAboveTheSafeAreaLiftsTheBox() throws {
        let pill = pill()
        let cover = try XCTUnwrap(KeyboardCover(bounds: bounds, safeBottom: safe, frame: pill))
        XCTAssertEqual(cover.top, pill.minY)
        XCTAssertEqual(cover.rect, pill)
    }

    func testAPillFiftyPointsOffTheBottomLiftsTheBox() throws {
        let pill = pill(height: 44, gap: 50)
        XCTAssertEqual(KeyboardCover(bounds: bounds, safeBottom: safe, frame: pill)?.top, pill.minY)
    }

    func testAStripShorterThanTheSafeAreaCoversNothing() {
        let strip = CGRect(x: 0, y: bounds.maxY - 16, width: bounds.width, height: 16)
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: strip))
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: nil, guideTop: bounds.maxY - safe))
    }

    func testAShortFullWidthStripLiftsTheBox() throws {
        let strip = CGRect(x: 0, y: bounds.maxY - 55, width: bounds.width, height: 55)
        XCTAssertEqual(try XCTUnwrap(KeyboardCover(bounds: bounds, safeBottom: safe, frame: strip)).top, strip.minY)
    }

    func testADockedKeyboardIsAsBefore() {
        let docked = CGRect(x: 0, y: bounds.maxY - 420, width: bounds.width, height: 420)
        XCTAssertEqual(KeyboardCover(bounds: bounds, safeBottom: safe, frame: docked)?.top, docked.minY)
    }

    func testAKeyboardDraggedUpTheScreenCoversNothing() {
        let floating = CGRect(x: 400, y: 300, width: 320, height: 260)
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: floating))
        // Its bottom just beyond the band over the edge.
        let high = pill(gap: KeyboardCover.Metrics.floatingBand + 2)
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: high))
    }

    func testAHiddenKeyboardCoversNothing() {
        let gone = CGRect(x: 0, y: bounds.maxY, width: bounds.width, height: 420)
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: gone))
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: .zero))
    }

    func testTheHigherOfTheFrameAndTheGuideWins() {
        let pill = pill()
        XCTAssertEqual(KeyboardCover(bounds: bounds, safeBottom: safe, frame: pill, guideTop: pill.minY + 10)?.top, pill.minY)
        XCTAssertEqual(KeyboardCover(bounds: bounds, safeBottom: safe, frame: pill, guideTop: pill.minY - 30)?.top, pill.minY - 30)
        // A hide heard while the guide still covers: the guide has it.
        let gone = CGRect(x: 0, y: bounds.maxY, width: bounds.width, height: 420)
        XCTAssertEqual(KeyboardCover(bounds: bounds, safeBottom: safe, frame: gone, guideTop: pill.minY)?.top, pill.minY)
    }

    func testARememberedPillCountsWithoutTheGuide() {
        let pill = pill()
        XCTAssertEqual(KeyboardCover(bounds: bounds, safeBottom: safe, frame: nil, remembered: pill)?.top, pill.minY)
    }

    func testARememberedKeyboardCountsOnlyWithTheGuide() {
        let docked = CGRect(x: 0, y: bounds.maxY - 420, width: bounds.width, height: 420)
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: nil, remembered: docked))
        XCTAssertEqual(KeyboardCover(bounds: bounds, safeBottom: safe, frame: nil, remembered: docked, guideTop: docked.minY)?.top, docked.minY)
    }

    func testAHeardFrameOutranksTheRememberedOne() {
        let gone = CGRect(x: 0, y: bounds.maxY, width: bounds.width, height: 420)
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: gone, remembered: pill()))
    }

    /// The agents' card clears the pill by the gap it keeps over a docked
    /// keyboard; across, it stays as it is.
    func testTheAgentCardClearsThePillAndKeepsItsSides() throws {
        let size = bounds.size
        let insets = LayoutInsets(top: 24, bottom: safe)
        let resting = ChatScreenLayout(size: size, safeArea: insets, keyboardTop: .greatestFiniteMagnitude, maxContentWidth: 760) { _ in 100 }
        let docked = CGRect(x: 0, y: bounds.maxY - 420, width: bounds.width, height: 420)
        let overDocked = ChatScreenLayout(size: size, safeArea: insets, keyboardTop: docked.minY, maxContentWidth: 760) { _ in 100 }
        let pill = pill(width: 300)
        let top = try XCTUnwrap(KeyboardCover(bounds: bounds, safeBottom: safe, frame: pill)).top
        let overPill = ChatScreenLayout(size: size, safeArea: insets, keyboardTop: top, maxContentWidth: 760) { _ in 100 }
        XCTAssertEqual(overPill.card.minX, resting.card.minX)
        XCTAssertEqual(overPill.card.width, resting.card.width)
        XCTAssertEqual(pill.minY - overPill.card.maxY, docked.minY - overDocked.card.maxY)
        XCTAssertLessThan(overPill.card.maxY, pill.minY)
    }

    // MARK: The guide that follows the undocked keyboard

    /// That guide with nothing up: on the safe area's bottom.
    private var undockedRest: CGRect { CGRect(x: 0, y: bounds.maxY - safe, width: bounds.width, height: safe) }

    func testTheUndockedGuidesPillLiftsTheBoxWithNothingHeard() throws {
        let pill = pill(gap: 50)
        let cover = try XCTUnwrap(KeyboardCover(bounds: bounds, safeBottom: safe, frame: nil, guideTop: bounds.maxY - safe, undocked: pill))
        XCTAssertEqual(cover.top, pill.minY)
    }

    func testTheUndockedGuideAtRestCoversNothing() {
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: nil, guideTop: bounds.maxY - safe, undocked: undockedRest))
    }

    func testTheUndockedGuidesKeyboardDraggedUpTheScreenCoversNothing() {
        let floating = CGRect(x: 400, y: 300, width: 320, height: 260)
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: nil, guideTop: bounds.maxY - safe, undocked: floating, undockedSeesBar: true))
    }

    func testOnceItHasSeenTheBarAStaleBarHeardCoversNothing() {
        let stale = pill(gap: 50)
        XCTAssertNotNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: stale, undocked: undockedRest))
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: stale, undocked: undockedRest, undockedSeesBar: true))
        XCTAssertNil(KeyboardCover(bounds: bounds, safeBottom: safe, frame: nil, remembered: stale, undocked: undockedRest, undockedSeesBar: true))
    }

    func testTheDockedKeyboardIsAsItWasWhateverTheUndockedGuideSays() {
        let docked = CGRect(x: 0, y: bounds.maxY - 320, width: bounds.width, height: 320)
        let before = KeyboardCover(bounds: bounds, safeBottom: safe, frame: docked, guideTop: docked.minY)
        XCTAssertEqual(KeyboardCover(bounds: bounds, safeBottom: safe, frame: docked, guideTop: docked.minY, undocked: docked, undockedSeesBar: true), before)
        XCTAssertEqual(KeyboardCover(bounds: bounds, safeBottom: safe, frame: docked, guideTop: docked.minY, undocked: undockedRest, undockedSeesBar: true), before)
    }

    func testTheUndockedGuidesPillWinsOverAStripUnderIt() throws {
        let strip = CGRect(x: 0, y: bounds.maxY - 40, width: bounds.width, height: 40)
        let pill = pill(gap: 50)
        XCTAssertEqual(KeyboardCover(bounds: bounds, safeBottom: safe, frame: strip, undocked: pill)?.top, pill.minY)
    }
}
