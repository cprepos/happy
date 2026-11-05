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

    // MARK: The player

    private func dock(_ screen: ChatScreenLayout, voice: CGSize?, corner: LiveBrowserDockLayout.Corner = .bottomRight, large: Bool = false, strip: CGFloat? = nil) throws -> LiveBrowserDockLayout {
        let line = try XCTUnwrap(ChatStatusLineLayout(above: screen.card, voice: voice, browser: browser))
        return LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: screen.card,
                                           anchor: LiveBrowserDockLayout.anchor(line.frame.minY, strip), corner: corner, large: large))
    }

    func testThePlayerSitsOverTheRedLineOnTheRight() throws {
        for voice in [voice, nil] as [CGSize?] {
            let down = try dock(agentScreen(keyboardTop: 874), voice: voice)
            assertFrame(down.frame, rect(282, 648, 112, 100))
            assertFrame(down.picture, rect(0, 0, 112, 70))
            assertFrame(down.footer, rect(0, 70, 112, 30))
            assertFrame(down.close, rect(4, 4, 28, 28))
            assertFrame(down.fullScreen, rect(80, 4, 28, 28))
            assertFrame(down.resize, rect(80, 38, 28, 28))
            XCTAssertFalse(down.showsPill)

            // The keyboard up: 336 tall.
            let up = try dock(agentScreen(keyboardTop: 538), voice: voice)
            assertFrame(up.frame, rect(282, 346, 112, 100))
        }
    }

    func testTheVoiceStripPushesThePlayerUp() throws {
        let over = try dock(agentScreen(keyboardTop: 874), voice: voice, strip: 874 - 120)
        assertFrame(over.frame, rect(282, 646, 112, 100))
    }

    func testCornersAndTheLargeSize() throws {
        let screen = agentScreen(keyboardTop: 874)
        let large = try dock(screen, voice: nil, large: true)
        assertFrame(large.frame, rect(162, 573, 232, 175))
        XCTAssertTrue(large.showsPill)
        assertFrame(try dock(screen, voice: nil, corner: .topLeft).frame, rect(8, 70, 112, 100))
        assertFrame(try dock(screen, voice: nil, corner: .topRight).frame, rect(282, 70, 112, 100))
        assertFrame(try dock(screen, voice: nil, corner: .bottomLeft).frame, rect(8, 648, 112, 100))
        // With little room the large player shrinks to fit between the bars.
        let tight = LiveBrowserDockLayout(.init(size: size, safeArea: safe, card: screen.card, anchor: 200, large: true))
        assertFrame(tight.frame, rect(247, 70, 147, 122))
    }

    func testADragLandsInTheNearestCorner() {
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 50, y: 100), in: size), .topLeft)
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 300, y: 100), in: size), .topRight)
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 50, y: 700), in: size), .bottomLeft)
        XCTAssertEqual(LiveBrowserDockLayout.corner(nearest: CGPoint(x: 300, y: 700), in: size), .bottomRight)
    }
}
