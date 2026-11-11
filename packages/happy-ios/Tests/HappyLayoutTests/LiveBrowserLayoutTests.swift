import XCTest
@testable import HappyLayout

/// An iPhone 17 Pro's 402×874, its 62 and 34 insets.
final class LiveBrowserLayoutTests: XCTestCase {
    let size = CGSize(width: 402, height: 874)
    let safe = LayoutInsets(top: 62, bottom: 34)
    let voice = CGSize(width: 180, height: 16)
    let browser = CGSize(width: 118, height: 16)

    private func agentScreen(keyboardTop: CGFloat) -> ChatScreenLayout {
        ChatScreenLayout(size: size, safeArea: safe, keyboardTop: keyboardTop) { _ in 56 }
    }

    // MARK: The status line

    func testTheRedLineEndsOnTheCardsRightEdgeOppositeTheBlueOne() throws {
        let screen = agentScreen(keyboardTop: 874)
        assertFrame(screen.card, rect(8, 776, 386, 56))
        let line = try XCTUnwrap(ChatStatusLineLayout(above: screen.card, voice: voice, browser: browser))
        assertFrame(line.frame, rect(8, 756, 386, 20))
        assertFrame(line.voice?.dot, rect(24, 761.5, 6, 6))
        assertFrame(line.voice?.text, rect(34, 756, 180, 16))
        assertFrame(line.browser?.text, rect(266, 756, 118, 16))
        assertFrame(line.browser?.dot, rect(388, 761.5, 6, 6))
        assertFrame(line.browser?.frame, rect(266, 756, 128, 20))
        XCTAssertEqual(line.browser?.dot.maxX, screen.card.maxX)
        XCTAssertEqual(line.browser?.text.midY, line.voice?.text.midY, "one baseline")
    }

    func testTheVoiceTextGivesWayFirst() throws {
        let line = try XCTUnwrap(ChatStatusLineLayout(x: 8, y: 0, width: 386, voice: CGSize(width: 400, height: 16), browser: browser))
        assertFrame(line.voice?.text, rect(34, 0, 220, 16))
        assertFrame(line.browser?.text, rect(266, 0, 118, 16))
        XCTAssertEqual(try XCTUnwrap(line.browser?.text.minX) - (try XCTUnwrap(line.voice?.text.maxX)), 12)
    }

    func testWithVoiceOffTheRedLineKeepsItsPlace() throws {
        let on = try XCTUnwrap(ChatStatusLineLayout(above: rect(8, 776, 386, 56), voice: voice, browser: browser))
        let off = try XCTUnwrap(ChatStatusLineLayout(above: rect(8, 776, 386, 56), voice: nil, browser: browser))
        XCTAssertNil(off.voice)
        XCTAssertEqual(off.frame, on.frame)
        XCTAssertEqual(off.browser, on.browser)
        XCTAssertNil(ChatStatusLineLayout(above: rect(8, 776, 386, 56), voice: nil, browser: nil))
    }

    func testTheSessionComposerCarriesBothOnItsStatusRow() {
        let both = AgentInputLayout(.init(
            width: 402, statusText: voice, card: .init(width: 0, textContentHeight: 22, hasText: false), browserText: browser
        ))
        assertFrame(both.status?.frame, rect(8, 8, 386, 20))
        assertFrame(both.status?.dot, rect(24, 13.5, 6, 6))
        assertFrame(both.status?.text, rect(34, 8, 180, 16))
        assertFrame(both.browser?.text, rect(266, 8, 118, 16))
        assertFrame(both.browser?.dot, rect(388, 13.5, 6, 6))
        XCTAssertEqual(both.browser?.dot.maxX, both.card.maxX)
        XCTAssertEqual(both.card.minY, 28)

        let off = AgentInputLayout(.init(
            width: 402, card: .init(width: 0, textContentHeight: 22, hasText: false), browserText: browser
        ))
        XCTAssertNil(off.status)
        XCTAssertEqual(off.browser, both.browser)
        XCTAssertEqual(off.card, both.card)

        let voiceOnly = AgentInputLayout(.init(width: 402, statusText: voice, card: .init(width: 0, textContentHeight: 22, hasText: false)))
        XCTAssertNil(voiceOnly.browser)
        assertFrame(voiceOnly.status?.text, rect(34, 8, 180, 16))
    }

    // MARK: A session's red line

    /// A session chat's screen: the composer's card 28 down (its status
    /// row above it), the dock on the safe area or the keyboard.
    private func sessionScreen(
        size: CGSize? = nil, safeArea: LayoutInsets? = nil, keyboardTop: CGFloat? = nil, accessories: [LegacyChatScreenLayout.Accessory] = [],
        composerHeight: CGFloat = 84, card: CGRect = rect(8, 28, 386, 56), browser: CGSize?, docked: Bool = false
    ) -> LegacyChatScreenLayout {
        LegacyChatScreenLayout(.init(
            size: size ?? self.size, safeArea: safeArea ?? safe, keyboardTop: keyboardTop, accessories: accessories,
            composerHeight: composerHeight, composerCardOffset: card.minY, composerCard: card, browser: browser, docked: docked
        ))
    }

    func testInASessionTheRedLineStandsOnTheComposersCard() throws {
        let screen = sessionScreen(browser: browser)
        assertFrame(screen.dock, rect(0, 756, 402, 84))
        assertFrame(screen.composer, rect(0, 0, 402, 84))
        // In the dock: the agent chat's line over a card 28 down.
        let line = try XCTUnwrap(screen.browser)
        assertFrame(line.frame, rect(266, 8, 128, 20))
        assertFrame(line.text, rect(266, 8, 118, 16))
        assertFrame(line.dot, rect(388, 13.5, 6, 6))
        XCTAssertEqual(line.dot.maxX, 394, "on the card's right edge")
        XCTAssertEqual(line.frame.maxY, screen.composer.minY + 28, "down to the card")
        // The same row the composer keeps for it.
        let composer = AgentInputLayout(.init(width: 402, card: .init(width: 0, textContentHeight: 22, hasText: false), browserText: browser))
        XCTAssertEqual(composer.card.minY, 28)
        assertFrame(composer.browser?.frame, line.frame)
    }

    func testTheRedLineRidesTheKeyboardWithTheDock() throws {
        let down = sessionScreen(browser: browser)
        let up = sessionScreen(keyboardTop: 538, browser: browser)
        assertFrame(up.dock, rect(0, 454, 402, 84))
        XCTAssertEqual(up.browser, down.browser, "in the dock's coordinates")
        assertFrame(try XCTUnwrap(up.browser).frame.offsetBy(dx: 0, dy: up.dock.minY), rect(266, 462, 128, 20))
    }

    func testOverAccessoriesTheRedLineStaysOnTheCard() throws {
        let screen = sessionScreen(accessories: [.inset(block(height: 60))], browser: browser)
        assertFrame(screen.composer, rect(0, 60, 402, 84))
        assertFrame(screen.dock, rect(0, 696, 402, 144))
        assertFrame(screen.browser?.frame, rect(266, 68, 128, 20))
        assertFrame(screen.browser?.dot, rect(388, 73.5, 6, 6))
    }

    func testOnAnIPadTheRedLineEndsOnTheWideCard() throws {
        let screen = sessionScreen(
            size: CGSize(width: 664, height: 768), safeArea: LayoutInsets(top: 74, left: 0, bottom: 20, right: 0),
            card: rect(8, 28, 648, 56), browser: browser, docked: true
        )
        assertFrame(screen.dock, rect(0, 664, 664, 84))
        assertFrame(screen.browser?.frame, rect(528, 8, 128, 20))
        assertFrame(screen.browser?.text, rect(528, 8, 118, 16))
        assertFrame(screen.browser?.dot, rect(650, 13.5, 6, 6))
        let up = sessionScreen(
            size: CGSize(width: 664, height: 768), safeArea: LayoutInsets(top: 74, left: 0, bottom: 20, right: 0), keyboardTop: 420,
            card: rect(8, 28, 648, 56), browser: browser, docked: true
        )
        assertFrame(up.dock, rect(0, 336, 664, 84))
        XCTAssertEqual(up.browser, screen.browser)
    }

    func testWithNoRoomAboveTheCardTheDockMakesIt() throws {
        let screen = sessionScreen(composerHeight: 56, card: rect(8, 0, 386, 56), browser: browser)
        assertFrame(screen.composer, rect(0, 20, 402, 56))
        assertFrame(screen.dock, rect(0, 764, 402, 76))
        assertFrame(screen.browser?.frame, rect(266, 0, 128, 20))
        assertFrame(screen.browser?.dot, rect(388, 5.5, 6, 6))
    }

    func testAHiddenLineTakesNoRoom() {
        let screen = sessionScreen(composerHeight: 56, card: rect(8, 0, 386, 56), browser: nil)
        XCTAssertNil(screen.browser)
        assertFrame(screen.composer, rect(0, 0, 402, 56))
        assertFrame(screen.dock, rect(0, 784, 402, 56))
        XCTAssertNil(LegacyChatScreenLayout(.init(size: size, safeArea: safe, keyboardTop: nil, composerHeight: 84, browser: browser)).browser, "no card, no line")
    }

    // MARK: The player

    private func dock(_ screen: ChatScreenLayout, voice: CGSize?, corner: LiveBrowserDockLayout.Corner = .bottomRight, big: Bool = false, strip: CGFloat? = nil) throws -> LiveBrowserDockLayout {
        let line = try XCTUnwrap(ChatStatusLineLayout(above: screen.card, voice: voice, browser: browser))
        return LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: screen.card,
                                           anchor: LiveBrowserDockLayout.anchor(line.frame.minY, strip), corner: corner, big: big))
    }

    func testThePlayerSitsOverTheRedLineOnTheRight() throws {
        for voice in [voice, nil] as [CGSize?] {
            // Small: 60% of the card, ⤢ full screen and ⇲ big on its bar.
            let down = try dock(agentScreen(keyboardTop: 874), voice: voice)
            assertFrame(down.frame, rect(162, 529, 232, 219))
            assertFrame(down.bar, rect(0, 0, 232, 44))
            assertFrame(down.picture, rect(0, 44, 232, 145))
            assertFrame(down.footer, rect(0, 189, 232, 30))
            assertFrame(down.close, rect(0, 0, 44, 44))
            assertFrame(down.menu, rect(44, 0, 44, 44))
            assertFrame(down.fullScreen, rect(144, 0, 44, 44))
            assertFrame(down.resize, rect(188, 0, 44, 44))
            // Take control in the bar's middle, between the sides.
            assertFrame(down.control, rect(88, 0, 56, 44))
            XCTAssertTrue(down.showsPill)
            XCTAssertFalse(down.isBig)
            XCTAssertEqual(down.radius, LiveBrowserDockLayout.Metrics.radius)
            XCTAssertEqual(down.topInset, 0)
            assertControlsClearThePicture(down)

            // The keyboard up: 336 tall.
            let up = try dock(agentScreen(keyboardTop: 538), voice: voice)
            assertFrame(up.frame, rect(162, 227, 232, 219))
        }
    }

    func testTheVoiceStripPushesThePlayerUp() throws {
        let over = try dock(agentScreen(keyboardTop: 874), voice: voice, strip: 874 - 120)
        assertFrame(over.frame, rect(162, 527, 232, 219))
    }

    func testCornersAndATightRoom() throws {
        let screen = agentScreen(keyboardTop: 874)
        assertFrame(try dock(screen, voice: nil, corner: .topLeft).frame, rect(8, 70, 232, 219))
        assertFrame(try dock(screen, voice: nil, corner: .topRight).frame, rect(162, 70, 232, 219))
        assertFrame(try dock(screen, voice: nil, corner: .bottomLeft).frame, rect(8, 529, 232, 219))
        // Squeezed between the bars, small shrinks to fit and keeps only
        // the buttons that fit.
        let tight = LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: screen.card, anchor: 200))
        assertFrame(tight.frame, rect(318, 70, 76, 122))
        assertFrame(tight.close, rect(0, 0, 44, 44))
        XCTAssertNil(tight.resize)
        XCTAssertNil(tight.menu)
        XCTAssertNil(tight.fullScreen)
        XCTAssertNil(tight.control, "no room on the bar: the footer has it")
        assertControlsClearThePicture(tight)
    }

    func testAPhonesBigIsTheWholeWidthAtTheTop() throws {
        let screen = agentScreen(keyboardTop: 874)
        let line = try XCTUnwrap(ChatStatusLineLayout(above: screen.card, voice: nil, browser: browser))
        let anchor = LiveBrowserDockLayout.anchor(line.frame.minY, nil)
        // Big: edge to edge under the header, the picture 402 / 1.6 tall;
        // the chat's content starts 8 under it. Its corner doesn't move it.
        for corner in LiveBrowserDockLayout.Corner.allCases {
            let big = LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: screen.card, anchor: anchor, corner: corner, big: true, idiom: .phone))
            assertFrame(big.frame, rect(0, 62, 402, 325))
            assertFrame(big.picture, rect(0, 44, 402, 251))
            assertFrame(big.close, rect(0, 0, 44, 44))
            assertFrame(big.menu, rect(44, 0, 44, 44))
            assertFrame(big.fullScreen, rect(314, 0, 44, 44))
            assertFrame(big.resize, rect(358, 0, 44, 44))
            assertFrame(big.control, rect(88, 0, 226, 44))
            XCTAssertEqual(big.control?.midX, big.bar.midX)
            XCTAssertTrue(big.isBig)
            XCTAssertEqual(big.radius, 0)
            XCTAssertEqual(big.topInset, 333)
            assertControlsClearThePicture(big)
        }
    }

    // MARK: An iPad's (and the Mac's) player

    /// An iPad Air's 820×1180 chat, its header 74 tall, the card 16 in.
    private func pad(width: CGFloat = 820, height: CGFloat = 1180, big: Bool) -> LiveBrowserDockLayout {
        let card = CGRect(x: 16, y: height - 20 - 76, width: width - 32, height: 56)
        return LiveBrowserDockLayout(.init(size: CGSize(width: width, height: height), safeArea: LayoutInsets(top: 74, bottom: 20),
                                           card: card, anchor: card.minY - 20, big: big, idiom: .pad))
    }

    func testAnIPadsSmallIsItsOldLargeSize() {
        let small = pad(big: false)
        // 60% of the 788 card, at most 420, over the line at the right.
        assertFrame(small.frame, rect(384, 719, 420, 337))
        assertFrame(small.picture, rect(0, 44, 420, 263))
        assertFrame(small.fullScreen, rect(332, 0, 44, 44))
        assertFrame(small.resize, rect(376, 0, 44, 44))
        XCTAssertFalse(small.isBig)
        XCTAssertEqual(small.topInset, 0)
        assertControlsClearThePicture(small)
    }

    func testAnIPadsBigIsThreeQuartersOfThePaneCentred() {
        // Upright: 75% of the 820 pane, 615 wide and 384 tall at the
        // frame's aspect, centred under the header.
        let big = pad(big: true)
        assertFrame(big.frame, rect(103, 74, 615, 458))
        assertFrame(big.picture, rect(0, 44, 615, 384))
        assertFrame(big.fullScreen, rect(527, 0, 44, 44))
        assertFrame(big.resize, rect(571, 0, 44, 44))
        XCTAssertTrue(big.isBig)
        XCTAssertEqual(big.radius, 0)
        XCTAssertEqual(big.topInset, 466)
        XCTAssertGreaterThan(big.frame.width, pad(big: false).frame.width)
        assertControlsClearThePicture(big)
    }

    func testAnIPadsBigBesideTheSidebarIsThreeQuartersOfThePane() {
        // A 500-wide chat pane beside the sidebar: 375 wide, centred.
        let big = pad(width: 500, big: true)
        assertFrame(big.frame, rect(63, 74, 375, 308))
        assertFrame(big.picture, rect(0, 44, 375, 234))
        XCTAssertEqual(big.topInset, 316)
    }

    func testAnIPadsBigTurnedSidewaysLeavesTheChatRoom() {
        // Sideways, 75% (885) would be taller than the 622 between the
        // header and the composer less 120 for the chat: 684 wide,
        // centred, at its aspect.
        let big = pad(width: 1180, height: 820, big: true)
        assertFrame(big.frame, rect(248, 74, 684, 502))
        assertFrame(big.picture, rect(0, 44, 684, 428))
        XCTAssertEqual(big.topInset, 510)
        XCTAssertGreaterThanOrEqual(696 - big.frame.maxY, 120)
    }

    func testAnIPadsBigInATightWindowIsNeverSmallerThanSmall() {
        // 402 of room: leaving the chat 120 would make big 332 wide, under
        // small's 420, so it keeps small's size, centred under the header.
        let big = pad(width: 1180, height: 600, big: true)
        assertFrame(big.frame, rect(380, 74, 420, 337))
        XCTAssertEqual(pad(width: 1180, height: 600, big: false).frame.size, big.frame.size)
        XCTAssertEqual(big.topInset, 345)
    }

    func testSidewaysBigStaysTheWindowedPlayerAtItsAspect() {
        // Turned: the header 32 tall, the composer's line at 300. Big
        // keeps its aspect in the room, centred, under the header.
        let sideways = CGSize(width: 874, height: 402)
        let insets = LayoutInsets(top: 32, left: 62, bottom: 21, right: 62)
        let card = CGRect(x: 62, y: 320, width: 750, height: 56)
        let big = LiveBrowserDockLayout(.init(size: sideways, safeArea: insets, card: card, anchor: 300, big: true, idiom: .phone))
        assertFrame(big.frame, rect(289, 32, 297, 260))
        assertFrame(big.picture, rect(0, 44, 297, 186))
        XCTAssertTrue(big.isBig)
        XCTAssertEqual(big.topInset, 268)
        assertControlsClearThePicture(big)
    }

    // MARK: Full screen

    func testUprightOnAPhoneThePictureIsEdgeToEdgeAtItsAspect() {
        // Under a 54-point header below the 62 inset.
        let page = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: nil)
        assertFrame(page.content, rect(0, 116, 402, 251))
        XCTAssertNil(page.strip)
        XCTAssertFalse(LiveBrowserFullScreenLayout.usesStrip(phone: true, size: size))
        // The frame's own aspect when one came.
        let wide = LiveBrowserFullScreenLayout(size: size, safeArea: safe, top: 116, phone: true, aspect: 16.0 / 9.0)
        assertFrame(wide.content, rect(0, 116, 402, 226))
        // No room under a tall header: no taller than what is left.
        let short = LiveBrowserFullScreenLayout(size: CGSize(width: 402, height: 500), safeArea: safe, top: 300, phone: true, aspect: nil)
        XCTAssertNil(short.strip)
        assertFrame(short.content, rect(0, 300, 402, 200))
    }

    func testSidewaysOnAPhoneTheStripTakesTheTrailingEdge() throws {
        let sideways = CGSize(width: 874, height: 402)
        let insets = LayoutInsets(top: 0, left: 62, bottom: 21, right: 62)
        XCTAssertTrue(LiveBrowserFullScreenLayout.usesStrip(phone: true, size: sideways))
        let page = LiveBrowserFullScreenLayout(size: sideways, safeArea: insets, top: 0, phone: true, aspect: nil)
        let strip = try XCTUnwrap(page.strip)
        assertFrame(strip, rect(760, 0, 52, 381))
        assertFrame(page.content, rect(62, 0, 698, 402))
        XCTAssertEqual(page.content.height, sideways.height, "the picture has the height")
        XCTAssertFalse(strip.intersects(page.content))
        XCTAssertGreaterThanOrEqual(strip.width, LiveBrowserFullScreenLayout.Metrics.button)
    }

    func testOffAPhoneFullScreenIsTheWholePage() {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            XCTAssertFalse(LiveBrowserFullScreenLayout.usesStrip(phone: false, size: size))
            let page = LiveBrowserFullScreenLayout(size: size, safeArea: LayoutInsets(top: 24, bottom: 20), top: 74, phone: false, aspect: 1.6)
            assertFrame(page.content, rect(0, 0, size.width, size.height))
            XCTAssertNil(page.strip)
        }
    }

    func testAWidePlayerHasEveryButtonOnTheBar() throws {
        // An iPad's narrowest player (dragged down to 176): four 44-point buttons.
        let wide = LiveBrowserDockLayout(.init(
            size: CGSize(width: 834, height: 1194), safeArea: LayoutInsets(top: 24, left: 0, bottom: 20, right: 0),
            card: CGRect(x: 12, y: 1100, width: 810, height: 56), anchor: 1080, idiom: .pad, width: 176
        ))
        XCTAssertEqual(wide.limits.lowerBound, 176)
        assertFrame(wide.frame, rect(646, 888, 176, 184))
        assertFrame(wide.close, rect(0, 0, 44, 44))
        assertFrame(wide.menu, rect(44, 0, 44, 44))
        assertFrame(wide.fullScreen, rect(88, 0, 44, 44))
        assertFrame(wide.resize, rect(132, 0, 44, 44))
        XCTAssertNil(wide.control, "no room between them: Take control is the footer's")
        assertControlsClearThePicture(wide)
    }

    /// Every button is a 44-point target on the bar, none on the picture
    /// (the page and its title) and none on another.
    private func assertControlsClearThePicture(_ layout: LiveBrowserDockLayout, file: StaticString = #filePath, line: UInt = #line) {
        let buttons = [layout.close, layout.menu, layout.fullScreen, layout.resize].compactMap { $0 }
        if let control = layout.control {
            XCTAssertTrue(layout.bar.contains(control), file: file, line: line)
            XCTAssertEqual(control.midX, layout.bar.midX, "Take control is centred", file: file, line: line)
            for button in buttons { XCTAssertFalse(control.intersects(button), "\(control) overlaps \(button)", file: file, line: line) }
        }
        for (index, button) in buttons.enumerated() {
            XCTAssertGreaterThanOrEqual(button.width, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.height, 44, file: file, line: line)
            XCTAssertTrue(layout.bar.contains(button), "\(button) on the bar \(layout.bar)", file: file, line: line)
            XCTAssertFalse(button.intersects(layout.picture), "\(button) covers the picture", file: file, line: line)
            XCTAssertFalse(button.intersects(layout.footer), file: file, line: line)
            for other in buttons[(index + 1)...] {
                XCTAssertFalse(button.intersects(other), "\(button) overlaps \(other)", file: file, line: line)
            }
        }
    }

    // MARK: Dragged sizes

    /// The phone's chat at rest: the card at 776, the red line at 756.
    private func phone(corner: LiveBrowserDockLayout.Corner = .bottomRight, big: Bool = false, width: CGFloat?) -> LiveBrowserDockLayout {
        LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: rect(8, 776, 386, 56), anchor: 756,
                                    corner: corner, big: big, idiom: .phone, width: width))
    }

    /// An iPad's chat, as `pad(big:)`, a dragged width asked for.
    private func pad(width: CGFloat = 820, height: CGFloat = 1180, big: Bool, dragged: CGFloat?) -> LiveBrowserDockLayout {
        let card = CGRect(x: 16, y: height - 20 - 76, width: width - 32, height: 56)
        return LiveBrowserDockLayout(.init(size: CGSize(width: width, height: height), safeArea: LayoutInsets(top: 74, bottom: 20),
                                           card: card, anchor: card.minY - 20, big: big, idiom: .pad, width: dragged))
    }

    func testADraggedWidthIsHeldBetweenTheMiniPlayerAndTheCard() {
        // A phone's floating player: 112 (the old mini) to the card's 386.
        XCTAssertEqual(phone(width: nil).limits, 112...386)
        XCTAssertEqual(phone(width: 50).frame.width, 112)
        XCTAssertEqual(phone(width: 1000).frame.width, 386)
        let dragged = phone(width: 300)
        assertFrame(dragged.frame, rect(94, 486, 300, 262))
        assertFrame(dragged.picture, rect(0, 44, 300, 188))
        XCTAssertEqual(dragged.clamp(20), 112)
        XCTAssertEqual(dragged.clamp(999), 386)
        XCTAssertEqual(dragged.clamp(250), 250)
        // A width in between is rounded to a point.
        XCTAssertEqual(phone(width: 250.4).frame.width, 250)
        assertControlsClearThePicture(phone(width: 112))

        // An iPad's: 176 to its card's 788, leaving the chat 120.
        XCTAssertEqual(pad(big: false, dragged: nil).limits, 176...788)
        XCTAssertEqual(pad(big: false, dragged: 100).frame.width, 176)
        XCTAssertEqual(pad(big: false, dragged: 2000).frame.width, 788)
        // Squeezed between the bars, never taller than the room.
        let tight = LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: rect(8, 776, 386, 56), anchor: 200, width: 300))
        XCTAssertEqual(tight.limits, 76...76)
        XCTAssertEqual(tight.frame.width, 76)
    }

    func testAFloatingPlayerKeepsItsCornerAndGrowsTowardTheChat() {
        for width in [150, 232, 300, 386] as [CGFloat] {
            let right = phone(width: width)
            XCTAssertEqual(right.frame.maxX, 394, "on the card's right edge")
            XCTAssertEqual(right.frame.maxY, 748, "8 over the red line")
            let left = phone(corner: .topLeft, width: width)
            XCTAssertEqual(left.frame.minX, 8)
            XCTAssertEqual(left.frame.minY, 70, "8 under the safe area")
            XCTAssertEqual(left.frame.size, right.frame.size)
        }
        // A phone's grips: flush in both bottom corners, whatever corner.
        for corner in LiveBrowserDockLayout.Corner.allCases {
            for big in [false, true] {
                let layout = phone(corner: corner, big: big, width: 300)
                let bounds = CGRect(origin: .zero, size: layout.frame.size)
                XCTAssertEqual(layout.grips, [.init(corner: .bottomLeft, frame: rect(0, bounds.height - 44, 44, 44)),
                                              .init(corner: .bottomRight, frame: rect(256, bounds.height - 44, 44, 44))])
                for grip in layout.grips { XCTAssertTrue(bounds.contains(grip.frame), "inside the box") }
            }
        }
        // An iPad's or a Mac's: one in each bottom corner, inside the box.
        for big in [false, true] {
            let layout = pad(big: big, dragged: nil)
            let size = layout.frame.size
            XCTAssertEqual(layout.grips, [.init(corner: .bottomLeft, frame: rect(0, size.height - 44, 44, 44)),
                                          .init(corner: .bottomRight, frame: rect(size.width - 44, size.height - 44, 44, 44))])
        }
    }

    func testADraggedBigStaysCentredUnderTheHeader() {
        // A phone's: 112 to the whole width, centred, the chat under it.
        XCTAssertEqual(phone(big: true, width: nil).limits, 112...402)
        let big = phone(big: true, width: 300)
        assertFrame(big.frame, rect(51, 62, 300, 262))
        XCTAssertTrue(big.isBig)
        XCTAssertEqual(big.topInset, 270, "the chat follows its height")
        XCTAssertEqual(big.grips, [.init(corner: .bottomLeft, frame: rect(0, 218, 44, 44)),
                                   .init(corner: .bottomRight, frame: rect(256, 218, 44, 44))])
        XCTAssertEqual(phone(big: true, width: 1000).frame, phone(big: true, width: nil).frame)
        // Its corner doesn't move it.
        XCTAssertEqual(phone(corner: .topLeft, big: true, width: 300).frame, big.frame)

        // An iPad's: past its 75% up to the pane's width.
        XCTAssertEqual(pad(big: true, dragged: nil).limits, 176...820)
        let wider = pad(big: true, dragged: 700)
        assertFrame(wider.frame, rect(60, 74, 700, 512))
        XCTAssertEqual(wider.topInset, 520)
        assertFrame(pad(big: true, dragged: 900).frame, rect(0, 74, 820, 587))
        XCTAssertEqual(pad(big: true, dragged: 10).frame.width, 176)
        // Sideways no wider than leaves the chat 120 under it: its preset.
        let sideways = pad(width: 1180, height: 820, big: true, dragged: 900)
        XCTAssertEqual(sideways.limits, 176...684)
        assertFrame(sideways.frame, rect(248, 74, 684, 502))
        XCTAssertGreaterThanOrEqual(696 - sideways.frame.maxY, 120)
    }

    func testAGripDragIsReadAlongItsDiagonal() {
        // The bottom-right grip, down and right at its aspect: exactly as
        // much wider as the hand went across; up and left, narrower.
        let floating = phone(width: nil)
        XCTAssertEqual(floating.width(dragging: .bottomRight, from: 232, by: CGPoint(x: 40, y: 25)), 272, accuracy: 0.001)
        XCTAssertEqual(floating.width(dragging: .bottomRight, from: 232, by: CGPoint(x: -40, y: -25)), 192, accuracy: 0.001)
        // Down alone grows it, up alone shrinks it, smoothly.
        let down = floating.width(dragging: .bottomRight, from: 232, by: CGPoint(x: 0, y: 25))
        XCTAssertGreaterThan(down, 232)
        XCTAssertLessThan(down, 272)
        XCTAssertLessThan(floating.width(dragging: .bottomRight, from: 232, by: CGPoint(x: 0, y: -25)), 232)
        // The bottom-left grip grows out to the left, a phone's as an iPad's.
        XCTAssertEqual(floating.width(dragging: .bottomLeft, from: 232, by: CGPoint(x: -40, y: 25)), 272, accuracy: 0.001)
        XCTAssertEqual(pad(big: false, dragged: nil).width(dragging: .bottomLeft, from: 420, by: CGPoint(x: -40, y: 25)), 460, accuracy: 0.001)
        // Big grows from its middle: a grip 20 out is 40 wider.
        let big = phone(big: true, width: 300)
        XCTAssertEqual(big.width(dragging: .bottomRight, from: 300, by: CGPoint(x: 20, y: 25)), 340, accuracy: 0.001)
        XCTAssertEqual(big.width(dragging: .bottomLeft, from: 300, by: CGPoint(x: -20, y: 25)), 340, accuracy: 0.001)
        XCTAssertEqual(big.width(dragging: .bottomLeft, from: 300, by: CGPoint(x: 20, y: -25)), 260, accuracy: 0.001)
    }

    func testTheSizeShowsOverThePicturesMiddle() {
        let small = phone(width: nil)
        assertFrame(small.badge(CGSize(width: 60, height: 14)), rect(76, 105, 80, 24))
        // Never wider than the picture, less 8 a side.
        XCTAssertEqual(phone(width: 112).badge(CGSize(width: 400, height: 14)).width, 96)
    }

    // MARK: Where it was left

    func testWhereThePlayerWasLeftReadsOldAndNewValues() {
        typealias Kept = LiveBrowserDockLayout.Kept
        XCTAssertEqual(Kept(stored: nil, phone: true), Kept())
        XCTAssertEqual(Kept(stored: "", phone: false), Kept(corner: .bottomRight, big: false))
        XCTAssertEqual(Kept(stored: "topLeft|small", phone: true), Kept(corner: .topLeft, big: false))
        XCTAssertEqual(Kept(stored: "topRight|big", phone: false), Kept(corner: .topRight, big: true))
        // An older "large" was a phone's big, an iPad's bigger small.
        XCTAssertEqual(Kept(stored: "topLeft|large", phone: true), Kept(corner: .topLeft, big: true))
        XCTAssertEqual(Kept(stored: "topLeft|large", phone: false), Kept(corner: .topLeft, big: false))
        XCTAssertEqual(Kept(stored: "bottomLeft", phone: true), Kept(corner: .bottomLeft))
        XCTAssertEqual(Kept(stored: "nowhere|big", phone: true), Kept(corner: .bottomRight, big: true))
        // A dragged width after them.
        XCTAssertEqual(Kept(stored: "bottomLeft|big|480", phone: true), Kept(corner: .bottomLeft, big: true, width: 480))
        XCTAssertEqual(Kept(stored: "topRight|small|300.5", phone: false), Kept(corner: .topRight, big: false, width: 300.5))
        for bad in ["topRight|small|", "topRight|small|wide", "topRight|small|-5", "topRight|small|0", "topRight|small|inf", "topRight|small|nan"] {
            XCTAssertNil(Kept(stored: bad, phone: true).width, bad)
        }

        XCTAssertEqual(Kept().stored, "bottomRight|small")
        XCTAssertEqual(Kept(corner: .topLeft, big: true).stored, "topLeft|big")
        XCTAssertEqual(Kept(corner: .topLeft, big: true, width: 480.4).stored, "topLeft|big|480")
        for kept in [Kept(), Kept(corner: .topRight, big: true), Kept(corner: .bottomLeft, big: false, width: 300)] {
            XCTAssertEqual(Kept(stored: kept.stored, phone: true), kept, "read back as kept")
            XCTAssertEqual(Kept(stored: kept.stored, phone: false), kept)
        }
        // What an older reader takes: the corner and small or big.
        XCTAssertEqual(Kept(corner: .topLeft, big: true, width: 480).stored.split(separator: "|").prefix(2), ["topLeft", "big"])
    }

    func testADragLandsInTheNearestCorner() {
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 50, y: 100), in: size), .topLeft)
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 300, y: 100), in: size), .topRight)
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 50, y: 700), in: size), .bottomLeft)
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 300, y: 700), in: size), .bottomRight)
    }
}
