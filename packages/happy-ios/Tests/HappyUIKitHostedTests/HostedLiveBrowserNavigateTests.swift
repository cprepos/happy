#if canImport(UIKit)
@testable import HappyCore
@testable import HappyUI
import HappyLayout
import UIKit
import XCTest

/// Each navigate the agent makes brings the red line up, so one tap opens
/// the browser: at once, not at the bridge's next 30 s turn for a browser
/// it last said slept. The player never opens for it, and a navigate in
/// the history as the chat opens changes nothing.
@MainActor
final class HostedLiveBrowserNavigateTests: XCTestCase {
    private let id = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"
    private let newer = "7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b"
    private let key = LiveBrowserLink.chatKey(happySession: "cmhk2v9q40001ab12cd34ef56")

    override func setUp() {
        super.setUp()
        LiveBrowserDock.forgetShownBrowsers()
    }

    private final class Host: UIViewController, LiveBrowserDockHosting {
        var dock: LiveBrowserDock!
        var liveBrowserDock: LiveBrowserDock? { dock }
        let card = UIView()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            view.addSubview(card)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let size = view.bounds.size
            let cardFrame = CGRect(x: 8, y: size.height - view.safeAreaInsets.bottom - 56, width: size.width - 16, height: 56)
            card.frame = cardFrame
            let line = ChatStatusLineLayout(above: cardFrame, voice: nil, browser: dock.indicator.textSize)
            dock.indicator.place(line?.browser)
            dock.layoutPlayer(card: cardFrame, anchor: line?.frame.minY ?? cardFrame.minY)
        }
    }

    private func makeHost(_ daemon: BrowserDaemon) async throws -> (Host, UIWindow) {
        let chat = UUID().uuidString
        UserDefaults.standard.removeObject(forKey: "liveBrowserDock.\(chat)")
        let host = Host()
        let client = AgentClient(transport: daemon, token: "native-secret")
        host.dock = LiveBrowserDock(host: host, chatKey: chat) {
            LiveBrowserConnection(client: client) { "work1" }
        }
        host.dock.onLayoutChange = { [weak host] in host?.view.setNeedsLayout() }
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: host)
        host.view.addSubview(host.dock.indicator)
        host.dock.setOnScreen(true)
        host.view.layoutIfNeeded()
        return (host, window)
    }

    private func navigate(_ id: String, to link: String) -> LiveBrowserNavigate {
        LiveBrowserNavigate(id: id, link: LiveBrowserLink(id: link)!)
    }

    /// The bridge last said the browser sleeps (asked again in 30 s): a
    /// navigate wakes it, and the line shows at once with the player
    /// closed. Asleep again, then another navigate: the line again.
    func testANavigateBringsTheLineUpAgainAfterTheBrowserSlept() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("asleep")
        await daemon.setChatLink(id)
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.lookUp(key: nil); host.dock.update(link: nil) }
        let dock = host.dock!
        let link = LiveBrowserLink(id: id)
        dock.update(link: link, navigate: navigate("n0", to: id))
        dock.lookUp(key: key)
        try await until { dock.feed?.phase.dormantState != nil }
        XCTAssertTrue(dock.indicator.isHidden, "asleep: no line")
        XCTAssertEqual(dock.chatWatch?.currentInterval, LiveBrowserChatWatch.idleInterval)
        let lookups = { await daemon.requests.filter { $0.hasPrefix("GET /live/chat/") }.count }
        let before = await lookups()

        // The agent's navigate wakes the browser.
        await daemon.setLivePod("running")
        dock.update(link: link, navigate: navigate("n1", to: id))
        try await until({ dock.browserRuns && !dock.indicator.isHidden }, tries: 50)
        let asked = await lookups()
        XCTAssertGreaterThan(asked, before, "the bridge was asked at once")
        XCTAssertNil(dock.player, "a navigate never opens the player")

        // Asleep again: the line goes; the next navigate brings it back.
        await daemon.setLivePod("asleep")
        dock.chatWatch?.checkNow()
        try await until { dock.indicator.isHidden && dock.feed?.phase.dormantState != nil }
        await daemon.setLivePod("running")
        dock.update(link: link, navigate: navigate("n2", to: id))
        try await until({ dock.browserRuns && !dock.indicator.isHidden }, tries: 50)
        XCTAssertNil(dock.player)

        // The same navigate again is no new one.
        await daemon.setLivePod("asleep")
        dock.chatWatch?.checkNow()
        try await until { dock.indicator.isHidden }
        await daemon.setLivePod("running")
        dock.update(link: link, navigate: navigate("n2", to: id))
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(dock.indicator.isHidden, "seen already: the bridge's next turn says")
    }

    /// A navigate in a new browser session: its link is followed before
    /// the bridge's next answer names it, and the line shows for it.
    func testANavigateOnANewLinkShowsTheLineForIt() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("asleep")
        await daemon.setChatLink(id)
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.lookUp(key: nil); host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id), navigate: navigate("n0", to: id))
        dock.lookUp(key: key)
        try await until { dock.feed?.phase.dormantState != nil }

        await daemon.setChatLink(newer)
        await daemon.setLivePod("running")
        dock.update(link: LiveBrowserLink(id: newer), navigate: navigate("n1", to: newer))
        XCTAssertEqual(dock.feed?.link.id, newer, "followed at once")
        try await until({ dock.browserRuns && !dock.indicator.isHidden }, tries: 50)
        XCTAssertEqual(dock.feed?.link.id, newer)
        XCTAssertNil(dock.player, "a navigate never opens the player")
    }

    /// The chat opens on a history with a navigate in it while the bridge
    /// still says the browser sleeps: nothing is asked early, and no line.
    func testANavigateInTheHistoryAsTheChatOpensChangesNothing() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("asleep")
        await daemon.setChatLink(id)
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.lookUp(key: nil); host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id))
        dock.lookUp(key: key)
        try await until { dock.feed?.phase.dormantState != nil }
        let lookups = { await daemon.requests.filter { $0.hasPrefix("GET /live/chat/") }.count }
        let before = await lookups()

        // The bridge would say running now, but isn't asked till its turn.
        await daemon.setLivePod("running")
        dock.update(link: LiveBrowserLink(id: id), navigate: navigate("n-history", to: id))
        try await Task.sleep(for: .seconds(2))
        let after = await lookups()
        XCTAssertEqual(after, before, "the history's navigate asks nothing")
        XCTAssertTrue(dock.indicator.isHidden)
        XCTAssertNil(dock.player)
    }

    // MARK: Helpers

    private func until(_ condition: () async -> Bool, tries: Int = 100, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<tries {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out", file: file, line: line)
        throw BrowserError.timeout
    }
}
#endif
