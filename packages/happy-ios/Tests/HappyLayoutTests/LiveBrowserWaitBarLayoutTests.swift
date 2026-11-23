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

    // MARK: Minimized

    /// The pill: `Metrics.pill` square, at the bar's trailing edge, its
    /// bottom where the bar's is, inside the screen's safe area.
    private func assertPill(_ bar: Bar, _ full: CGRect, size: CGSize, safe: LayoutInsets, clear others: [CGRect], file: StaticString = #filePath, line: UInt = #line) {
        let pill = bar.minimized
        XCTAssertEqual(pill.size, CGSize(width: Bar.Metrics.pill, height: Bar.Metrics.pill), file: file, line: line)
        XCTAssertEqual(pill.maxX, full.maxX, accuracy: 0.5, "at the bar's trailing edge", file: file, line: line)
        XCTAssertEqual(pill.maxY, full.maxY, accuracy: 0.5, "its bottom where the bar's is", file: file, line: line)
        XCTAssertLessThanOrEqual(pill.maxY, size.height - safe.bottom - Bar.Metrics.margin, file: file, line: line)
        XCTAssertLessThanOrEqual(pill.maxX, size.width - safe.right, file: file, line: line)
        for other in others { XCTAssertFalse(pill.intersects(other), "\(pill) over \(other)", file: file, line: line) }
    }

    func testMinimizedHeldOnAPhoneItStaysOverTheViewersBarAndTheKeyboard() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        // The viewer's bar at the bottom, then raised over the keyboard
        // with its key row.
        for (toolbar, keys) in [(rect(0, 791, 402, 49), CGRect?.none), (rect(0, 445, 402, 49), rect(0, 494, 402, 380))] {
            let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil, floor: toolbar.minY))
            let full = bar.frame(height: 60)
            assertPill(bar, full, size: size, safe: safe, clear: [toolbar] + (keys.map { [$0] } ?? []))
            XCTAssertEqual(bar.minimized, rect(390 - 36, toolbar.minY - 12 - 36, 36, 36))
        }
    }

    func testMinimizedUprightOnAPhoneItSitsAtTheBottomOfTheRoomUnderThePicture() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: false, strip: nil))
        XCTAssertEqual(bar.mode, .belowPicture)
        let pill = bar.minimized
        XCTAssertEqual(pill, rect(390 - 36, size.height - 34 - 12 - 36, 36, 36))
        XCTAssertFalse(pill.intersects(page.content), "never over the picture")
    }

    func testMinimizedSidewaysOnAPhoneItStaysClearOfTheStripAndTheViewersBar() throws {
        let sideways = CGSize(width: 874, height: 402)
        let insets = LayoutInsets(top: 0, left: 62, bottom: 21, right: 62)
        let page = LiveBrowserFullScreenLayout(size: sideways, safeArea: insets, top: 0, phone: true, aspect: nil)
        let strip = try XCTUnwrap(page.strip)
        for held in [false, true] {
            let toolbar = rect(62, 337, 698, 44)
            let bar = Bar(size: sideways, safeArea: insets, place: .fullScreen(picture: page.content, phone: true, held: held, strip: strip,
                                                                               floor: held ? toolbar.minY : nil))
            assertPill(bar, bar.frame(height: 60), size: sideways, safe: insets, clear: [strip] + (held ? [toolbar] : []))
        }
    }

    func testMinimizedOnAnIPadItStaysOverTheViewersBarAndTheKeyboard() {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            let insets = LayoutInsets(top: 24, bottom: 20)
            let page = LiveBrowserFullScreenLayout(size: size, safeArea: insets, top: 74, phone: false, aspect: 1.6)
            let plain = Bar(size: size, safeArea: insets, place: .fullScreen(picture: page.content, phone: false, held: false, strip: nil))
            assertPill(plain, plain.frame(height: 60), size: size, safe: insets, clear: [])
            let toolbar = rect(0, size.height - 20 - 44, size.width, 44)
            let keys = rect(0, size.height - 320, size.width, 320)
            let raised = rect(0, keys.minY - 44, size.width, 44)
            for (bar, under) in [(toolbar, [toolbar]), (raised, [raised, keys])] {
                let held = Bar(size: size, safeArea: insets, place: .fullScreen(picture: page.content, phone: false, held: true, strip: nil, floor: bar.minY))
                assertPill(held, held.frame(height: 60), size: size, safe: insets, clear: under)
            }
        }
    }

    func testALongWaitIsHeldToAFloatingBarsMost() {
        let picture = rect(0, 116, 402, 674)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: picture, phone: true, held: false, strip: nil))
        XCTAssertEqual(bar.mode, .overlay, "no room under the picture")
        XCTAssertEqual(bar.frame(height: 400).height, Bar.Metrics.overlayMaxHeight)
    }
}
