import XCTest
@testable import HappyLayout

/// Inside the approval bar: the summary, the reason and the page (and,
/// with Details open, every line and the script), Details, Deny and
/// Approve; and how tall the bar may grow with Details open, never over
/// the picture or the held page's controls. An iPhone 17 Pro's 402×874,
/// its 62 and 34 insets.
final class LiveBrowserApprovalBarContentTests: XCTestCase {
    typealias Bar = LiveBrowserApprovalBarLayout
    typealias Content = LiveBrowserApprovalBarLayout.Content
    let size = CGSize(width: 402, height: 874)
    let safe = LayoutInsets(top: 62, bottom: 34)

    // MARK: Inside

    func testClosedTheReasonAndThePageStandOverTheButtonsAndDetails() {
        // The chat's 386: a 3-line reason (45), the page (15).
        let content = Content(width: 386, maxHeight: 168, inline: false, asking: true, summary: 20, pieces: [45, 0, 15, 0],
                              deny: 70, approve: 80, toggle: 60)
        XCTAssertEqual(Content.textWidth(width: 386, inline: false, asking: true, deny: 70, approve: 80), 338)
        assertFrame(content.icon, rect(12, 12, 18, 20))
        assertFrame(content.summary, rect(36, 12, 338, 20))
        assertFrame(content.body, rect(36, 36, 338, 64))
        XCTAssertEqual(content.pieces, [rect(0, 0, 338, 45), rect(0, 49, 338, 15)], "a piece measuring 0 takes no gap")
        XCTAssertEqual(content.bodyHeight, 64)
        // Details on the buttons' row, at the text's start.
        assertFrame(content.toggle, rect(36, 110, 60, 36))
        assertFrame(content.deny, rect(210, 110, 76, 36))  // never under its least width
        assertFrame(content.approve, rect(294, 110, 80, 36))
        XCTAssertEqual(content.height, 158)
        XCTAssertFalse(content.toggle!.intersects(content.deny))
    }

    func testOpenTheLinesAndTheScriptScrollUnderTheTallestTheBarMayBe() {
        // The reason, another line, the page, the script's 200 in its block.
        let code = Content.codeBlock(text: 200)
        XCTAssertEqual(code, 216)
        XCTAssertEqual(Content.codeBlock(text: 0), 0, "no script, no block")
        assertFrame(Content.code(in: rect(0, 102, 338, 216)), rect(8, 110, 322, 200))
        let content = Content(width: 386, maxHeight: 360, inline: false, asking: true, summary: 20, pieces: [45, 30, 15, code],
                              deny: 70, approve: 80, toggle: 40)
        XCTAssertEqual(content.pieces, [rect(0, 0, 338, 45), rect(0, 49, 338, 30), rect(0, 83, 338, 15), rect(0, 102, 338, 216)])
        XCTAssertEqual(content.bodyHeight, 318)
        // 360 less the padding, the summary, its gap and the buttons' row.
        assertFrame(content.body, rect(36, 36, 338, 266))
        XCTAssertLessThan(content.body.height, content.bodyHeight, "the rest scrolls")
        XCTAssertEqual(content.height, 360)
        assertFrame(content.approve, rect(294, 312, 80, 36))
        XCTAssertEqual(content.body.maxY + Bar.Metrics.rowGap, content.approve.minY)
    }

    func testHeldShortTheBodyGivesWayAndTheSummaryAndButtonsStay() {
        let content = Content(width: 386, maxHeight: 100, inline: false, asking: true, summary: 20, pieces: [45, 15],
                              deny: 70, approve: 80, toggle: 60)
        assertFrame(content.body, rect(36, 36, 338, 6))
        XCTAssertEqual(content.height, 100)
        assertFrame(content.approve, rect(294, 52, 80, 36))
        let none = Content(width: 386, maxHeight: 40, inline: false, asking: true, summary: 20, pieces: [45, 15],
                           deny: 70, approve: 80, toggle: nil)
        XCTAssertEqual(none.body.height, 0, "never a negative height")
    }

    func testInlineTheButtonsSitAtTheRightAndDetailsGoesUnderTheText() {
        // A floating bar 520 wide: compact, its buttons beside the text.
        let content = Content(width: 520, maxHeight: 132, inline: true, asking: true, summary: 20, pieces: [15, 15],
                              deny: 70, approve: 80, toggle: 60)
        XCTAssertEqual(Content.textWidth(width: 520, inline: true, asking: true, deny: 70, approve: 80), 296)
        assertFrame(content.summary, rect(36, 12, 296, 20))
        assertFrame(content.body, rect(36, 36, 296, 34))
        assertFrame(content.toggle, rect(36, 74, 60, 24))
        XCTAssertEqual(content.height, 110)
        assertFrame(content.approve, rect(428, 37, 80, 36))
        assertFrame(content.deny, rect(344, 37, 76, 36))
        XCTAssertLessThan(content.summary.maxX, content.deny.minX)
        // Just the summary: centred on the buttons' row.
        let short = Content(width: 520, maxHeight: 132, inline: true, asking: true, summary: 20, pieces: [],
                            deny: 70, approve: 80, toggle: nil)
        XCTAssertEqual(short.height, 60)
        assertFrame(short.summary, rect(36, 20, 296, 20))
        XCTAssertNil(short.toggle)
    }

    func testANoticeIsItsSummaryAlone() {
        let notice = Content(width: 386, maxHeight: 168, inline: true, asking: false, summary: 18, pieces: [],
                             deny: 70, approve: 80, toggle: nil)
        XCTAssertEqual(Content.textWidth(width: 386, inline: true, asking: false, deny: 70, approve: 80), 338)
        assertFrame(notice.summary, rect(36, 12, 338, 20))
        XCTAssertEqual(notice.height, 44)
        XCTAssertEqual(notice.bodyHeight, 0)
        XCTAssertNil(notice.toggle)
    }

    // MARK: The agent's words, closed

    /// The tallest closed bar: "The agent says it will:" (14), a reason at
    /// its four lines (4 × 19), a two-line kind line (30) and the page (15).
    let tallest = (label: CGFloat(14), title: CGFloat(76), kind: CGFloat(30), page: CGFloat(15))

    func testTheLabelStandsOverTheTitleAndTheIconBesideIt() {
        let content = Content(width: 386, maxHeight: 232, inline: false, asking: true, label: 14, summary: 76, pieces: [15, 15],
                              deny: 70, approve: 80, toggle: nil)
        assertFrame(content.icon, rect(12, 12, 18, 20))
        assertFrame(content.label, rect(36, 12, 338, 14))
        assertFrame(content.summary, rect(36, 28, 338, 76))  // under the label and its gap of 2
        assertFrame(content.body, rect(36, 108, 338, 34))
        XCTAssertEqual(content.bodyHeight, 34)
        assertFrame(content.deny, rect(210, 152, 76, 36))
        XCTAssertEqual(content.height, 200)
        // No label: no gap for one, and the title starts at the top.
        let none = Content(width: 386, maxHeight: 232, inline: false, asking: true, summary: 76, pieces: [15, 15],
                           deny: 70, approve: 80, toggle: nil)
        XCTAssertEqual(none.label.height, 0)
        assertFrame(none.summary, rect(36, 12, 338, 76))
        XCTAssertEqual(none.height, 184)
    }

    func testALongReasonAtItsFourLinesLeavesTheKindLineAndThePageShowingClosed() {
        XCTAssertEqual(Bar.Metrics.titleLines, 4, "a long reason is cut at four lines")
        let t = tallest
        // The chat, a phone held upright (floating, 378), an iPad (floating, inline at 520).
        let chat = Bar(size: size, safeArea: safe, place: .chat(card: rect(8, 776, 386, 56), anchor: 756))
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        let held = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil, floor: 791))
        for (bar, what) in [(chat, "chat"), (held, "held")] {
            let content = Content(width: bar.width, maxHeight: bar.maxHeight, inline: bar.inline, asking: true, label: t.label, summary: t.title,
                                  pieces: [t.kind, t.page], deny: 70, approve: 80, toggle: nil)
            XCTAssertEqual(content.body.height, content.bodyHeight, "the kind line and the page show whole, unscrolled, \(what)")
            XCTAssertEqual(content.pieces.last?.maxY, content.body.height, what)
            XCTAssertLessThanOrEqual(content.height, bar.maxHeight, what)
            XCTAssertNil(content.toggle, "no script, no other lines: no Details, \(what)")
        }
        let inline = Content(width: 520, maxHeight: Bar.Metrics.overlayMaxHeight, inline: true, asking: true, label: t.label, summary: t.title,
                             pieces: [t.kind, t.page], deny: 70, approve: 80, toggle: nil)
        XCTAssertEqual(inline.body.height, inline.bodyHeight)
        XCTAssertNil(inline.toggle)
        XCTAssertEqual(inline.height, 12 + 14 + 2 + 76 + 4 + 49 + 12)
    }

    func testDetailsIsThereOnlyForAScriptOrOtherLines() {
        let t = tallest
        let without = Content(width: 386, maxHeight: 232, inline: false, asking: true, label: t.label, summary: t.title, pieces: [t.kind, t.page],
                              deny: 70, approve: 80, toggle: nil)
        XCTAssertNil(without.toggle)
        let with = Content(width: 386, maxHeight: 232, inline: false, asking: true, label: t.label, summary: t.title, pieces: [t.kind, t.page],
                           deny: 70, approve: 80, toggle: 60)
        assertFrame(with.toggle, rect(36, with.deny.minY, 60, 36))
        XCTAssertEqual(with.height, without.height, "Details shares the buttons' row")
        XCTAssertEqual(with.body, without.body)
    }

    // MARK: Details open, outside

    func testInTheChatItGrowsUpToTheExpandedMost() {
        let bar = Bar(size: size, safeArea: safe, place: .chat(card: rect(8, 776, 386, 56), anchor: 756))
        XCTAssertEqual(bar.maxHeight(expanded: false), 232)
        XCTAssertEqual(bar.maxHeight(expanded: true), Bar.Metrics.expandedMaxHeight)
        assertFrame(bar.frame(height: 400, expanded: true), rect(8, 388, 386, 360))
        XCTAssertEqual(bar.anchor(height: 400, expanded: true), 388, "a bottom-corner player keeps above it")
        XCTAssertEqual(bar.frame(height: 400), bar.frame(height: 400, expanded: false), "closed, as before")
        // The keyboard up: no higher than the safe area's top allows.
        let up = Bar(size: size, safeArea: safe, place: .chat(card: rect(8, 400, 386, 56), anchor: 380))
        assertFrame(up.frame(height: 400, expanded: true), rect(8, 70, 386, 302))
    }

    func testUnderThePictureItKeepsToTheRoomThere() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: false, strip: nil))
        XCTAssertEqual(bar.mode, .belowPicture)
        XCTAssertEqual(bar.expandedMaxHeight, bar.maxHeight)
        let open = bar.frame(height: 2000, expanded: true)
        XCTAssertFalse(open.intersects(page.content), "never over the picture")
        XCTAssertEqual(open.maxY, size.height - safe.bottom - Bar.Metrics.margin)
    }

    func testHeldOpenItStaysOverTheViewersBar() {
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        let toolbar = rect(0, 791, 402, 49)
        let bar = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil, floor: toolbar.minY))
        XCTAssertEqual(bar.maxHeight(expanded: true), 360)
        let open = bar.frame(height: 400, expanded: true)
        assertFrame(open, rect(12, 419, 378, 360))
        XCTAssertEqual(open.maxY, toolbar.minY - Bar.Metrics.margin)
        XCTAssertFalse(open.intersects(toolbar))
        // The keyboard up: the floor rises, the open bar held under the
        // safe area's top and still over the key row.
        let bar445 = rect(0, 445, 402, 49), keys = rect(0, 494, 402, 44)
        let up = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil, floor: bar445.minY))
        XCTAssertEqual(up.maxHeight(expanded: true), 359)
        let raised = up.frame(height: 400, expanded: true)
        assertFrame(raised, rect(12, 74, 378, 359))
        XCTAssertFalse(raised.intersects(bar445))
        XCTAssertFalse(raised.intersects(keys))
        // Little room: no more than closed.
        let high = Bar(size: size, safeArea: safe, place: .fullScreen(picture: page.content, phone: true, held: true, strip: nil, floor: 150))
        XCTAssertEqual(high.maxHeight(expanded: true), 64)
        assertFrame(high.frame(height: 400, expanded: true), rect(12, 74, 378, 64))
    }

    func testOnAnIPadWithNoVNCOpenItKeepsTheKeyboardButtonsReserve() throws {
        let iPad = CGSize(width: 834, height: 1194), insets = LayoutInsets(top: 24, bottom: 20)
        let whole = CGRect(origin: .zero, size: iPad)
        let floor = try XCTUnwrap(Bar.noVNCFloor(size: iPad, safeArea: insets, page: whole))
        let bar = Bar(size: iPad, safeArea: insets, place: .fullScreen(picture: whole, phone: false, held: true, strip: nil, floor: floor))
        XCTAssertTrue(bar.compact)
        XCTAssertTrue(bar.inline)
        assertFrame(bar.frame(height: 500, expanded: true), rect(157, 746, 520, 360))
        XCTAssertLessThanOrEqual(bar.frame(height: 500, expanded: true).maxY, floor - Bar.Metrics.margin)
    }
}
