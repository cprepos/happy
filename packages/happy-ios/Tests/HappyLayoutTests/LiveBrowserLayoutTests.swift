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

    private func dock(_ screen: ChatScreenLayout, voice: CGSize?, corner: LiveBrowserDockLayout.Corner = .bottomRight, large: Bool = false, strip: CGFloat? = nil) throws -> LiveBrowserDockLayout {
        let line = try XCTUnwrap(ChatStatusLineLayout(above: screen.card, voice: voice, browser: browser))
        return LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: screen.card,
                                           anchor: LiveBrowserDockLayout.anchor(line.frame.minY, strip), corner: corner, large: large))
    }

    func testThePlayerSitsOverTheRedLineOnTheRight() throws {
        for voice in [voice, nil] as [CGSize?] {
            let down = try dock(agentScreen(keyboardTop: 874), voice: voice)
            assertFrame(down.frame, rect(282, 604, 112, 144))
            assertFrame(down.bar, rect(0, 0, 112, 44))
            assertFrame(down.picture, rect(0, 44, 112, 70))
            assertFrame(down.footer, rect(0, 114, 112, 30))
            // Narrow: close and the size on the bar; the picture opens
            // full screen, which has End browser.
            assertFrame(down.close, rect(0, 0, 44, 44))
            assertFrame(down.resize, rect(68, 0, 44, 44))
            XCTAssertNil(down.fullScreen)
            XCTAssertNil(down.menu)
            XCTAssertFalse(down.showsPill)
            assertControlsClearThePicture(down)

            // The keyboard up: 336 tall.
            let up = try dock(agentScreen(keyboardTop: 538), voice: voice)
            assertFrame(up.frame, rect(282, 302, 112, 144))
        }
    }

    func testTheVoiceStripPushesThePlayerUp() throws {
        let over = try dock(agentScreen(keyboardTop: 874), voice: voice, strip: 874 - 120)
        assertFrame(over.frame, rect(282, 602, 112, 144))
    }

    func testCornersAndTheLargeSize() throws {
        let screen = agentScreen(keyboardTop: 874)
        let large = try dock(screen, voice: nil, large: true)
        assertFrame(large.frame, rect(162, 529, 232, 219))
        assertFrame(large.picture, rect(0, 44, 232, 145))
        assertFrame(large.close, rect(0, 0, 44, 44))
        assertFrame(large.menu, rect(44, 0, 44, 44))
        assertFrame(large.fullScreen, rect(144, 0, 44, 44))
        assertFrame(large.resize, rect(188, 0, 44, 44))
        XCTAssertTrue(large.showsPill)
        assertControlsClearThePicture(large)
        assertFrame(try dock(screen, voice: nil, corner: .topLeft).frame, rect(8, 70, 112, 144))
        assertFrame(try dock(screen, voice: nil, corner: .topRight).frame, rect(282, 70, 112, 144))
        assertFrame(try dock(screen, voice: nil, corner: .bottomLeft).frame, rect(8, 604, 112, 144))
        // With little room the large player shrinks to fit between the
        // bars, and keeps only the buttons that fit.
        let tight = LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: screen.card, anchor: 200, large: true))
        assertFrame(tight.frame, rect(318, 70, 76, 122))
        assertFrame(tight.close, rect(0, 0, 44, 44))
        XCTAssertNil(tight.resize)
        XCTAssertNil(tight.menu)
        XCTAssertNil(tight.fullScreen)
        assertControlsClearThePicture(tight)
    }

    func testAPhonesSmallIsTheLargeSizeAndBigIsTheWholeWidthAtTheTop() throws {
        let screen = agentScreen(keyboardTop: 874)
        let line = try XCTUnwrap(ChatStatusLineLayout(above: screen.card, voice: nil, browser: browser))
        let anchor = LiveBrowserDockLayout.anchor(line.frame.minY, nil)
        // Small: the large size at its corner, ⤢ full screen and ⇲ big.
        let small = LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: screen.card, anchor: anchor, phone: true))
        assertFrame(small.frame, rect(162, 529, 232, 219))
        assertFrame(small.picture, rect(0, 44, 232, 145))
        assertFrame(small.close, rect(0, 0, 44, 44))
        assertFrame(small.menu, rect(44, 0, 44, 44))
        assertFrame(small.fullScreen, rect(144, 0, 44, 44))
        assertFrame(small.resize, rect(188, 0, 44, 44))
        XCTAssertFalse(small.isBig)
        XCTAssertEqual(small.radius, LiveBrowserDockLayout.Metrics.radius)
        XCTAssertEqual(small.topInset, 0)
        assertControlsClearThePicture(small)

        // Big: edge to edge under the header, the picture 402 / 1.6 tall;
        // the chat's content starts 8 under it. Its corner doesn't move it.
        for corner in LiveBrowserDockLayout.Corner.allCases {
            let big = LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: screen.card, anchor: anchor, corner: corner, large: true, phone: true))
            assertFrame(big.frame, rect(0, 62, 402, 325))
            assertFrame(big.picture, rect(0, 44, 402, 251))
            assertFrame(big.close, rect(0, 0, 44, 44))
            assertFrame(big.menu, rect(44, 0, 44, 44))
            assertFrame(big.fullScreen, rect(314, 0, 44, 44))
            assertFrame(big.resize, rect(358, 0, 44, 44))
            XCTAssertTrue(big.isBig)
            XCTAssertEqual(big.radius, 0)
            XCTAssertEqual(big.topInset, 333)
            assertControlsClearThePicture(big)
        }

        // Squeezed between the bars, small keeps only what fits.
        let tight = LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: screen.card, anchor: 200, phone: true))
        assertFrame(tight.frame, rect(318, 70, 76, 122))
        assertFrame(tight.close, rect(0, 0, 44, 44))
        XCTAssertNil(tight.resize)
        XCTAssertNil(tight.fullScreen)
        XCTAssertNil(tight.menu)
    }

    func testSidewaysBigStaysTheWindowedPlayerAtItsAspect() {
        // Turned: the header 32 tall, the composer's line at 300. Big
        // keeps its aspect in the room, centred, under the header.
        let sideways = CGSize(width: 874, height: 402)
        let insets = LayoutInsets(top: 32, left: 62, bottom: 21, right: 62)
        let card = CGRect(x: 62, y: 320, width: 750, height: 56)
        let big = LiveBrowserDockLayout(.init(size: sideways, safeArea: insets, card: card, anchor: 300, large: true, phone: true))
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
        // An iPad's small player: 176, four 44-point buttons.
        let wide = LiveBrowserDockLayout(.init(
            size: CGSize(width: 834, height: 1194), safeArea: LayoutInsets(top: 24, left: 0, bottom: 20, right: 0),
            card: CGRect(x: 12, y: 1100, width: 810, height: 56), anchor: 1080
        ))
        assertFrame(wide.frame, rect(646, 888, 176, 184))
        assertFrame(wide.close, rect(0, 0, 44, 44))
        assertFrame(wide.menu, rect(44, 0, 44, 44))
        assertFrame(wide.fullScreen, rect(88, 0, 44, 44))
        assertFrame(wide.resize, rect(132, 0, 44, 44))
        assertControlsClearThePicture(wide)
    }

    /// Every button is a 44-point target on the bar, none on the picture
    /// (the page and its title) and none on another.
    private func assertControlsClearThePicture(_ layout: LiveBrowserDockLayout, file: StaticString = #filePath, line: UInt = #line) {
        let buttons = [layout.close, layout.menu, layout.fullScreen, layout.resize].compactMap { $0 }
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

    func testADragLandsInTheNearestCorner() {
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 50, y: 100), in: size), .topLeft)
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 300, y: 100), in: size), .topRight)
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 50, y: 700), in: size), .bottomLeft)
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 300, y: 700), in: size), .bottomRight)
    }
}
