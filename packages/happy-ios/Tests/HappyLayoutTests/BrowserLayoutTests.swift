import Foundation
import HappyLayout
import XCTest

final class BrowserLayoutTests: XCTestCase {
    func testPageRunsUnderTheHeaderToTheBottomEdge() {
        let result = BrowserLayout(size: CGSize(width: 402, height: 874), top: 116)
        XCTAssertEqual(result.web, CGRect(x: 0, y: 0, width: 402, height: 874))
        XCTAssertEqual(result.failure, CGRect(x: 0, y: 0, width: 402, height: 874))
        XCTAssertEqual(result.progress, CGRect(x: 0, y: 116, width: 402, height: 2.5))
    }

    func testLandscapeAndTheHeaderNeverMoveThePage() {
        let landscape = BrowserLayout(size: CGSize(width: 874, height: 402), top: 68)
        XCTAssertEqual(landscape.web, CGRect(x: 0, y: 0, width: 874, height: 402))
        XCTAssertEqual(landscape.progress, CGRect(x: 0, y: 68, width: 874, height: 2.5))
        // Before the header is there, only the bar is elsewhere.
        let bare = BrowserLayout(size: CGSize(width: 402, height: 874), top: 0)
        XCTAssertEqual(bare.web, CGRect(x: 0, y: 0, width: 402, height: 874))
        XCTAssertEqual(bare.progress, CGRect(x: 0, y: 0, width: 402, height: 2.5))
        XCTAssertEqual(BrowserLayout(size: CGSize(width: 100, height: 50), top: 80).progress, CGRect(x: 0, y: 50, width: 100, height: 2.5))
    }

    func testProgressFill() {
        let bar = CGSize(width: 402, height: 2.5)
        XCTAssertEqual(BrowserLayout.progressFill(bar: bar, value: 0.25), CGRect(x: 0, y: 0, width: 100.5, height: 2.5))
        XCTAssertEqual(BrowserLayout.progressFill(bar: bar, value: 1.5), CGRect(x: 0, y: 0, width: 402, height: 2.5))
        XCTAssertEqual(BrowserLayout.progressFill(bar: bar, value: -1), CGRect(x: 0, y: 0, width: 0, height: 2.5))
        XCTAssertEqual(BrowserLayout.progressFill(bar: bar, value: .nan), CGRect(x: 0, y: 0, width: 0, height: 2.5))
    }

    private let title = Measurable { _ in CGSize(width: 250, height: 25) }
    private let message = Measurable { width in CGSize(width: width, height: 60) }

    func testFailureOnAPhone() {
        let insets = LayoutInsets(top: 116, bottom: 34)
        XCTAssertEqual(BrowserFailureLayout.textWidth(size: CGSize(width: 402, height: 874), insets: insets), 320)
        let result = BrowserFailureLayout(size: CGSize(width: 402, height: 874), insets: insets, title: title, message: message, button: CGSize(width: 140, height: 48))
        XCTAssertEqual(result.icon, CGRect(x: 175, y: 337.5, width: 52, height: 52))
        XCTAssertEqual(result.title, CGRect(x: 41, y: 405.5, width: 320, height: 25))
        XCTAssertEqual(result.message, CGRect(x: 41, y: 438.5, width: 320, height: 60))
        XCTAssertEqual(result.button, CGRect(x: 131, y: 522.5, width: 140, height: 48))
    }

    func testFailureInLandscapeCentresBetweenTheSideInsets() {
        let result = BrowserFailureLayout(size: CGSize(width: 874, height: 402), insets: LayoutInsets(top: 68, left: 62, bottom: 21, right: 62), title: title, message: message, button: CGSize(width: 140, height: 48))
        XCTAssertEqual(result.icon, CGRect(x: 411, y: 84, width: 52, height: 52))
        XCTAssertEqual(result.title, CGRect(x: 277, y: 152, width: 320, height: 25))
        XCTAssertEqual(result.message, CGRect(x: 277, y: 185, width: 320, height: 60))
        XCTAssertEqual(result.button, CGRect(x: 367, y: 269, width: 140, height: 48))
    }

    func testTallFailureStartsUnderTheHeader() {
        let long = Measurable { width in CGSize(width: width, height: 400) }
        let result = BrowserFailureLayout(size: CGSize(width: 874, height: 402), insets: LayoutInsets(top: 68, left: 62, bottom: 21, right: 62), title: title, message: long, button: CGSize(width: 140, height: 48))
        XCTAssertEqual(result.icon.minY, 68)
        XCTAssertEqual(result.button.minY, 68 + 52 + 16 + 25 + 8 + 400 + 24)
    }

    func testFailureWithoutMessageAndANarrowScreen() {
        let result = BrowserFailureLayout(size: CGSize(width: 320, height: 568), insets: LayoutInsets(top: 64), title: title, message: Measurable { _ in .zero }, button: CGSize(width: 300, height: 48))
        XCTAssertEqual(BrowserFailureLayout.textWidth(size: CGSize(width: 320, height: 568), insets: LayoutInsets(top: 64)), 256)
        // 52 + 16 + 25 + 24 + 48 = 165, centred in 504 and lifted 24.
        XCTAssertEqual(result.icon, CGRect(x: 134, y: 209.5, width: 52, height: 52))
        XCTAssertEqual(result.title, CGRect(x: 32, y: 277.5, width: 256, height: 25))
        XCTAssertEqual(result.message, CGRect(x: 32, y: 302.5, width: 256, height: 0))
        XCTAssertEqual(result.button, CGRect(x: 32, y: 326.5, width: 256, height: 48))
    }

    /// A live browser's card across a phone's column: the frame over the
    /// strip, the pill hugging its words in the frame's corner.
    func testALiveBrowserCard() {
        let size = CGSize(width: 361, height: LiveBrowserCardLayout.Metrics.height)
        let card = LiveBrowserCardLayout(size: size, pillLabel: CGSize(width: 61.3, height: 15.5))
        XCTAssertEqual(card.frame, CGRect(x: 0, y: 0, width: 361, height: 180))
        XCTAssertEqual(card.pill, CGRect(x: 8, y: 8, width: 96, height: 24))
        XCTAssertEqual(card.dot, CGRect(x: 18, y: 16, width: 8, height: 8))
        XCTAssertEqual(card.pillLabel, CGRect(x: 32, y: 12, width: 62, height: 16))
        XCTAssertEqual(card.title, CGRect(x: 12, y: 190, width: 337, height: 20))
        XCTAssertEqual(card.address, CGRect(x: 12, y: 210, width: 337, height: 16))
        XCTAssertEqual(card.message, CGRect(x: 24, y: 90, width: 313, height: 0))
    }

    func testALiveBrowserCardsSentenceAndLongPill() {
        let size = CGSize(width: 200, height: LiveBrowserCardLayout.Metrics.height)
        let card = LiveBrowserCardLayout(size: size, pillLabel: CGSize(width: 400, height: 40), message: message)
        // The pill keeps inside the frame; its words are cut to fit.
        XCTAssertEqual(card.pill, CGRect(x: 8, y: 8, width: 184, height: 24))
        XCTAssertEqual(card.pillLabel, CGRect(x: 32, y: 8, width: 150, height: 24))
        XCTAssertEqual(card.message, CGRect(x: 24, y: 60, width: 152, height: 60))
    }
}
