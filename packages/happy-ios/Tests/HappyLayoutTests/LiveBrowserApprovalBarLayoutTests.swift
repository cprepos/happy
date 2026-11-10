import XCTest
@testable import HappyLayout

/// The approval bar: under a phone's upright picture, floating compact
/// elsewhere in full screen, over the composer in the chat. An iPhone 17
/// Pro's 402×874, its 62 and 34 insets.
final class LiveBrowserApprovalBarLayoutTests: XCTestCase {
    typealias Bar = LiveBrowserApprovalBarLayout
    let size = CGSize(width: 402, height: 874)
    let safe = LayoutInsets(top: 62, bottom: 34)

    func testUprightOnAPhoneItStandsInTheRoomUnderThePicture() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: false, strip: nil))
        XCTAssertEqual(bar.mode, .belowPicture)
        XCTAssertTrue(bar.showsDetails)
        XCTAssertFalse(bar.inline)
        let frame = bar.frame(height: 110)
        assertFrame(frame, rect(12, 379, 378, 110))
        XCTAssertFalse(frame.intersects(page.content), "never over the picture")
        XCTAssertEqual(frame.minY, page.content.maxY + Bar.Metrics.margin)
        // Taller content is held to the room above the safe area.
        let tall = bar.frame(height: 2000)
        XCTAssertEqual(tall.maxY, size.height - safe.bottom - Bar.Metrics.margin)
        // The picture is the layout's alone: the bar never changes it.
        XCTAssertEqual(page, LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil))
    }

    func testNoRoomUnderThePictureFloatsItOverTheBottom() {
        let picture = rect(0, 116, 402, 674)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: picture, phone: true, held: false, strip: nil))
        XCTAssertEqual(bar.mode, .overlay)
        assertFrame(bar.frame(height: 60), rect(12, 768, 378, 60))
    }

    func testHeldItFloatsCompactOverTheBottom() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil))
        XCTAssertEqual(bar.mode, .overlay)
        XCTAssertFalse(bar.showsDetails)
        assertFrame(bar.frame(height: 60), rect(12, 768, 378, 60))
        // Never taller than a floating bar's most.
        XCTAssertEqual(bar.frame(height: 400).height, Bar.Metrics.overlayMaxHeight)
        XCTAssertEqual(bar.frame(height: 400).maxY, 828)
    }

    func testSidewaysOnAPhoneItFloatsClearOfTheStrip() throws {
        let sideways = CGSize(width: 874, height: 402)
        let insets = LayoutInsets(top: 0, left: 62, bottom: 21, right: 62)
        let page = LiveBrowserFullScreenLayout(size: sideways, safeArea: insets, top: 0, phone: true, aspect: nil)
        let strip = try XCTUnwrap(page.strip)
        let bar = Bar(size: sideways, safeArea: insets, place: .fullScreen(picture: page.content, phone: true, held: false, strip: strip))
        XCTAssertEqual(bar.mode, .overlay)
        XCTAssertTrue(bar.inline, "wide enough for its buttons on the summary's row")
        let frame = bar.frame(height: 60)
        assertFrame(frame, rect(151, 309, 520, 60))
        XCTAssertFalse(frame.intersects(strip))
        XCTAssertEqual(frame.midX, (insets.left + strip.minX) / 2, accuracy: 0.5)
    }

    func testOnAnIPadOrAMacItFloatsCentredOverTheBottom() {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let insets = LayoutInsets(top: 24, bottom: 20)
            let page = LiveBrowserFullScreenLayout(size: size, safeArea: insets, top: 74, phone: false, aspect: 1.6)
            let bar = Bar(size: size, safeArea: insets, place: .fullScreen(picture: page.content, phone: false, held: false, strip: nil))
            XCTAssertEqual(bar.mode, .overlay)
            XCTAssertFalse(bar.showsDetails)
            let frame = bar.frame(height: 60)
            assertFrame(frame, rect((size.width - 520) / 2, size.height - 20 - 12 - 60, 520, 60))
        }
    }

    func testInTheChatItStandsOnTheStatusLineAsWideAsTheCard() {
        let card = rect(8, 776, 386, 56)
        let bar = Bar(size: size, safeArea: safe, place: .chat(card: card, anchor: 756))
        XCTAssertEqual(bar.mode, .chat)
        XCTAssertTrue(bar.showsDetails)
        assertFrame(bar.frame(height: 100), rect(8, 648, 386, 100))
        XCTAssertEqual(bar.anchor(height: 100), 648, "a bottom-corner player keeps above it")
        assertFrame(bar.frame(height: 400), rect(8, 580, 386, 168))
        // No room: nothing, never a negative height.
        let none = Bar(size: size, safeArea: safe, place: .chat(card: card, anchor: 60))
        XCTAssertEqual(none.frame(height: 100).height, 0)
    }
}
