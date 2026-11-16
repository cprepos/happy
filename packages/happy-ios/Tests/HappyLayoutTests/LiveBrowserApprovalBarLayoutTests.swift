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
        XCTAssertFalse(bar.compact)
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
        XCTAssertTrue(bar.compact)
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
            XCTAssertTrue(bar.compact)
            let frame = bar.frame(height: 60)
            assertFrame(frame, rect((size.width - 520) / 2, size.height - 20 - 12 - 60, 520, 60))
        }
    }

    // Held, the native viewer's bar (Keyboard, Paste, Copy, Trackpad,
    // Right click, More) is at the bottom: the bar stands 12 over its top.

    func testHeldOverTheViewersBarOnAPhoneUprightItStandsAboveIt() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        let toolbar = rect(0, 791, 402, 49)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil, floor: toolbar.minY))
        XCTAssertEqual(bar.mode, .overlay)
        let frame = bar.frame(height: 60)
        assertFrame(frame, rect(12, 719, 378, 60))
        XCTAssertEqual(frame.maxY, toolbar.minY - Bar.Metrics.margin)
        XCTAssertFalse(frame.intersects(toolbar))
        XCTAssertFalse(bar.frame(height: 400).intersects(toolbar), "a tall bar is held, never over it")
    }

    func testTheKeyboardUpItRisesWithTheViewersBar() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        // The bar over the key row (44) over the keyboard (336).
        let toolbar = rect(0, 445, 402, 49), keys = rect(0, 494, 402, 44)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil, floor: toolbar.minY))
        assertFrame(bar.frame(height: 60), rect(12, 373, 378, 60))
        XCTAssertEqual(bar.maxHeight, Bar.Metrics.overlayMaxHeight)
        for height in [60, 400] as [CGFloat] {
            XCTAssertFalse(bar.frame(height: height).intersects(toolbar))
            XCTAssertFalse(bar.frame(height: height).intersects(keys))
        }
        // Little room left: held to it, under the safe area's top.
        let high = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil, floor: 150))
        XCTAssertEqual(high.maxHeight, 64)
        assertFrame(high.frame(height: 400), rect(12, 74, 378, 64))
    }

    func testSidewaysHeldItStandsAboveTheViewersBarClearOfTheStrip() throws {
        let sideways = CGSize(width: 874, height: 402)
        let insets = LayoutInsets(top: 0, left: 62, bottom: 21, right: 62)
        let page = LiveBrowserFullScreenLayout(size: sideways, safeArea: insets, top: 0, phone: true, aspect: nil)
        let strip = try XCTUnwrap(page.strip)
        let toolbar = rect(62, 337, 698, 44)
        let bar = Bar(size: sideways, safeArea: insets, place: .fullScreen(picture: page.content, phone: true, held: true, strip: strip, floor: toolbar.minY))
        let frame = bar.frame(height: 60)
        assertFrame(frame, rect(151, 265, 520, 60))
        XCTAssertFalse(frame.intersects(toolbar))
        XCTAssertFalse(frame.intersects(strip))
    }

    func testOnAnIPadHeldItStandsAboveTheViewersBar() {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let insets = LayoutInsets(top: 24, bottom: 20)
            let toolbar = rect(0, size.height - 20 - 50, size.width, 50)
            let bar = Bar(size: size, safeArea: insets, place: .fullScreen(picture: CGRect(origin: .zero, size: size), phone: false, held: true, strip: nil, floor: toolbar.minY))
            let frame = bar.frame(height: 60)
            assertFrame(frame, rect((size.width - 520) / 2, size.height - 20 - 50 - 12 - 60, 520, 60))
            XCTAssertFalse(frame.intersects(toolbar))
        }
    }

    func testAFloorUnderTheSafeAreasBottomChangesNothing() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil, floor: 860))
        XCTAssertEqual(bar, Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil)))
    }

    func testNoVNCsPageKeepsItsKeyboardButtonsReserveClear() throws {
        // An iPad: the page is the whole screen.
        let iPad = CGSize(width: 834, height: 1194), insets = LayoutInsets(top: 24, bottom: 20)
        let whole = CGRect(origin: .zero, size: iPad)
        let floor = try XCTUnwrap(Bar.noVNCFloor(size: iPad, safeArea: insets, page: whole))
        XCTAssertEqual(floor, 1194 - 20 - Bar.Metrics.noVNCReserve)
        let bar = Bar(size: iPad, safeArea: insets, place: .fullScreen(picture: whole, phone: false, held: true, strip: nil, floor: floor))
        assertFrame(bar.frame(height: 60), rect(157, 1046, 520, 60))
        // A sideways phone's page reaches the bottom too.
        let sideways = CGSize(width: 874, height: 402), wide = LayoutInsets(top: 0, left: 62, bottom: 21, right: 62)
        let side = LiveBrowserFullScreenLayout(size: sideways, safeArea: wide, top: 0, phone: true, aspect: nil)
        XCTAssertEqual(Bar.noVNCFloor(size: sideways, safeArea: wide, page: side.content), 325)
        // A phone upright: the page is the picture's height, the bottom clear.
        let upright = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        XCTAssertNil(Bar.noVNCFloor(size: size, safeArea: safe, page: upright.content))
    }

    func testInTheChatItStandsOnTheStatusLineAsWideAsTheCard() {
        let card = rect(8, 776, 386, 56)
        let bar = Bar(size: size, safeArea: safe, place: .chat(card: card, anchor: 756))
        XCTAssertEqual(bar.mode, .chat)
        XCTAssertFalse(bar.compact)
        assertFrame(bar.frame(height: 100), rect(8, 648, 386, 100))
        XCTAssertEqual(bar.anchor(height: 100), 648, "a bottom-corner player keeps above it")
        assertFrame(bar.frame(height: 400), rect(8, 580, 386, 168))
        // No room: nothing, never a negative height.
        let none = Bar(size: size, safeArea: safe, place: .chat(card: card, anchor: 60))
        XCTAssertEqual(none.frame(height: 100).height, 0)
    }
}
