import XCTest
@testable import HappyLayout

/// The full screen's wait bar takes the approval bar's place
/// (`LiveBrowserApprovalBarLayout`): under a phone's upright picture,
/// floating over the bottom elsewhere, never over the picture or a
/// sideways phone's strip. A one-line bar with its button, 60 high.
final class LiveBrowserWaitBarLayoutTests: XCTestCase {
    typealias Bar = LiveBrowserApprovalBarLayout
    let size = CGSize(width: 402, height: 874)
    let safe = LayoutInsets(top: 62, bottom: 34)

    func testUprightOnAPhoneItStandsUnderThePicture() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: false, strip: nil))
        XCTAssertEqual(bar.mode, .belowPicture)
        let frame = bar.frame(height: 60)
        assertFrame(frame, rect(12, page.content.maxY + 12, 378, 60))
        XCTAssertFalse(frame.intersects(page.content), "never over the picture")
    }

    func testHeldOnAPhoneItFloatsOverTheBottom() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil))
        XCTAssertEqual(bar.mode, .overlay)
        assertFrame(bar.frame(height: 60), rect(12, 768, 378, 60))
    }

    func testSidewaysOnAPhoneItFloatsClearOfTheStrip() throws {
        let sideways = CGSize(width: 874, height: 402)
        let insets = LayoutInsets(top: 0, left: 62, bottom: 21, right: 62)
        let page = LiveBrowserFullScreenLayout(size: sideways, safeArea: insets, top: 0, phone: true, aspect: nil)
        let strip = try XCTUnwrap(page.strip)
        let bar = Bar(size: sideways, safeArea: insets, place: .fullScreen(picture: page.content, phone: true, held: false, strip: strip))
        XCTAssertEqual(bar.mode, .overlay)
        let frame = bar.frame(height: 60)
        XCTAssertFalse(frame.intersects(strip))
        XCTAssertEqual(frame.maxY, sideways.height - insets.bottom - Bar.Metrics.margin)
        XCTAssertLessThanOrEqual(frame.width, Bar.Metrics.maxWidth)
    }

    func testOnAnIPadEitherWayItFloatsCentredOverTheBottom() {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let insets = LayoutInsets(top: 24, bottom: 20)
            let page = LiveBrowserFullScreenLayout(size: size, safeArea: insets, top: 74, phone: false, aspect: 1.6)
            let bar = Bar(size: size, safeArea: insets, place: .fullScreen(picture: page.content, phone: false, held: false, strip: nil))
            XCTAssertEqual(bar.mode, .overlay)
            assertFrame(bar.frame(height: 60), rect((size.width - 520) / 2, size.height - 20 - 12 - 60, 520, 60))
        }
    }

    func testHeldItStandsAboveTheViewersBarAndRisesWithTheKeyboard() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        for toolbar in [rect(0, 791, 402, 49), rect(0, 445, 402, 49)] {
            let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil, floor: toolbar.minY))
            let frame = bar.frame(height: 60)
            assertFrame(frame, rect(12, toolbar.minY - 12 - 60, 378, 60))
            XCTAssertFalse(frame.intersects(toolbar))
        }
    }

    func testSidewaysHeldItStandsAboveTheViewersBar() throws {
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

    func testOnNoVNCsPageOnAnIPadItKeepsTheReserveClear() throws {
        let iPad = CGSize(width: 1194, height: 834), insets = LayoutInsets(top: 24, bottom: 20)
        let whole = CGRect(origin: .zero, size: iPad)
        let floor = try XCTUnwrap(Bar.noVNCFloor(size: iPad, safeArea: insets, page: whole))
        let bar = Bar(size: iPad, safeArea: insets, place: .fullScreen(picture: whole, phone: false, held: true, strip: nil, floor: floor))
        assertFrame(bar.frame(height: 60), rect(337, 834 - 20 - 56 - 12 - 60, 520, 60))
    }

    func testALongWaitIsHeldToAFloatingBarsMost() {
        let picture = rect(0, 116, 402, 674)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: picture, phone: true, held: false, strip: nil))
        XCTAssertEqual(bar.mode, .overlay, "no room under the picture")
        XCTAssertEqual(bar.frame(height: 400).height, Bar.Metrics.overlayMaxHeight)
    }
}
