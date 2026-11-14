#if canImport(UIKit)
@testable import HappyCore
@testable import HappyUI
import HappyLayout
import UIKit
import XCTest

/// A bridge with a browser per chat, as the dock shows it: the chat finds
/// its browser by its session with no link in the transcript, an asleep
/// browser is calm rather than unreachable, and Take control waits for it
/// to wake.
@MainActor
final class HostedLiveBrowserPodTests: XCTestCase {
    private let id = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"
    private let key = LiveBrowserLink.chatKey(happySession: "cmhk2v9q40001ab12cd34ef56")

    /// These drive noVNC's web page: the native viewer is the default,
    /// so the fallback is chosen for them, and put back after.
    private var usedWebViewer = false

    override func setUp() {
        super.setUp()
        usedWebViewer = LiveBrowserViewerSetting.usesWebViewer
        LiveBrowserViewerSetting.usesWebViewer = true
    }

    override func tearDown() {
        LiveBrowserViewerSetting.usesWebViewer = usedWebViewer
        super.tearDown()
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

        // As the chats do: the dock reads while the chat shows.
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            dock?.setOnScreen(true)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            dock?.setOnScreen(false)
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

    func testTheChatFindsItsBrowserWithNoLinkInTheTranscript() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("running")
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.lookUp(key: nil) }
        let dock = host.dock!
        dock.lookUp(key: key)
        try await until { await daemon.requests.contains { $0.hasPrefix("GET /live/chat/\(self.key) ") } }
        XCTAssertTrue(dock.indicator.isHidden, "the chat never had a browser: no line")

        // The agent starts one: the line comes, though no link was posted.
        await daemon.setChatLink(id)
        try await until { dock.indicator.text == Strings.LiveBrowser.indicator(Strings.LiveBrowser.clickToWatch) }
        XCTAssertFalse(dock.indicator.isHidden)
        XCTAssertEqual(dock.feed?.link.id, id)
        try await until { await daemon.requests.contains { $0.hasPrefix("GET /live/\(self.id)/state") } }

        // Off screen, nothing is asked.
        dock.setOnScreen(false)
        try await Task.sleep(for: .milliseconds(300))
        let asked = await daemon.requests.count
        try await Task.sleep(for: .seconds(5))
        let after = await daemon.requests.count
        XCTAssertEqual(after, asked, "nothing asked while the chat doesn't show")
    }

    func testAnAsleepBrowserIsCalmAndHasNoLine() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("asleep")
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id))
        try await until { dock.feed?.phase.state?.asleep == true }
        XCTAssertNotEqual(dock.feed?.phase, .unreachable)
        XCTAssertTrue(dock.indicator.isHidden, "asleep: no red line")
        dock.openPlayer()
        let player = try XCTUnwrap(dock.player)
        XCTAssertEqual(player.accessibilityLabel, [Strings.LiveBrowser.title, Strings.LiveBrowser.asleepStatus].joined(separator: ", "))
        let requests = await daemon.requests
        XCTAssertFalse(requests.contains { $0.hasPrefix("GET /live/\(self.id)/frame.jpg") }, "an asleep browser isn't asked for frames")
        try screenshot(window, name: "live-browser-dock-asleep")
    }

    /// The chat's lookup answers at the LAN bridge while the transcript's
    /// chip names localhost: a tap on the chip still opens the player.
    func testAChipAtTheOtherOriginOpensThePlayer() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("asleep")
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id, origin: LiveBrowserLink.lanOrigin))
        try await until { dock.feed?.phase.state?.asleep == true }

        dock.open(try XCTUnwrap(LiveBrowserLink(id: "0123456789abcdef0123456789abcdef")))
        XCTAssertNil(dock.player, "another browser's chip opens nothing")

        dock.open(try XCTUnwrap(LiveBrowserLink(id: id, origin: LiveBrowserLink.localOrigin)))
        XCTAssertNotNil(dock.player, "the same browser at another origin opens")
    }

    func testTakeControlWaitsForTheBrowserToWake() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("asleep")
        await daemon.setWakingTakes(2)
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id))
        try await until { dock.feed?.phase.state?.asleep == true }
        dock.presentFullScreen(taking: true)
        try await until { (host.presentedViewController as? UINavigationController)?.viewControllers.count == 2 }
        let takes = await daemon.requests.filter { $0.hasPrefix("POST /live/\(self.id)/take ") }
        XCTAssertEqual(takes.count, 3, "two 202s while it woke, then the 200")
        let navigation = try XCTUnwrap(host.presentedViewController as? UINavigationController)
        let noVNC = try XCTUnwrap(navigation.viewControllers.last as? LiveBrowserFullScreenItems)
        let scaled = BrowserDaemon.chatNoVNC.replacingOccurrences(of: "resize=remote", with: "resize=scale")
        XCTAssertEqual(noVNC.browser.originalURL.absoluteString, dock.isPhone ? scaled : BrowserDaemon.chatNoVNC)
        try await until { dock.indicator.text == Strings.LiveBrowser.indicator(Strings.LiveBrowser.youHaveControl) }
        dock.minimize()
        try await until { host.presentedViewController == nil }
    }

    // MARK: The player keeps reading

    /// The picture keeps coming: more frames read, the player polling
    /// and showing one.
    private func assertPictureComing(_ daemon: BrowserDaemon, _ dock: LiveBrowserDock, _ what: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = await daemon.frameReads
        try await until({ await daemon.frameReads >= before + 2 }, file: file, line: line)
        XCTAssertTrue(dock.feed?.isPolling == true, what, file: file, line: line)
        XCTAssertNotNil(dock.player?.shownImage, what, file: file, line: line)
        XCTAssertNotEqual(dock.feed?.phase, .unreachable, what, file: file, line: line)
    }

    private func openWatching(_ daemon: BrowserDaemon) async throws -> (Host, UIWindow) {
        await daemon.setLiveStatus("watching")
        let (host, window) = try await makeHost(daemon)
        host.dock.update(link: LiveBrowserLink(id: id))
        host.dock.openPlayer()
        try await until { host.dock.player?.shownImage != nil }
        return (host, window)
    }

    /// Take control, Release, then back to the player: the feed went on
    /// reading after Release, where two polls and silence had left it
    /// saying Connecting…, a frame read stalling as it went.
    func testReleaseBackToThePlayerKeepsThePictureComing() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await openWatching(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        let feed = try XCTUnwrap(dock.feed)
        feed.requestTimeout = .seconds(1)
        dock.presentFullScreen(taking: true)
        try await until { (host.presentedViewController as? UINavigationController)?.viewControllers.count == 2 }
        try await until { dock.holdsControl }
        await daemon.setStalledFrames(1)
        dock.release()
        try await until { (host.presentedViewController as? UINavigationController)?.viewControllers.count == 1 }
        dock.minimize()
        try await until { host.presentedViewController == nil }
        XCTAssertTrue(dock.isOnScreen, "the chat shows again")
        try await assertPictureComing(daemon, dock, "after Release and minimize")
        try await Task.sleep(for: .seconds(3))
        try await assertPictureComing(daemon, dock, "a while after")
    }

    /// A frame read that never answers, past every deadline: X and the
    /// player again starts the feed over.
    func testReopeningAfterXRestartsAStalledFeed() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await openWatching(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        let feed = try XCTUnwrap(dock.feed)
        // This read's deadline is a minute; the stall is told by a shorter one.
        feed.requestTimeout = .seconds(60)
        let reads = await daemon.frameReads
        await daemon.setStalledFrames(1)
        try await until { await daemon.frameReads > reads }
        feed.requestTimeout = .milliseconds(300)
        try await until { feed.isStalled }
        let stalled = await daemon.frameReads
        try await Task.sleep(for: .milliseconds(500))
        let still = await daemon.frameReads
        XCTAssertEqual(still, stalled, "stalled: nothing more read")
        dock.closePlayer(animated: false)
        dock.openPlayer()
        try await assertPictureComing(daemon, dock, "reopened after X")
    }

    /// The bridge said asleep, and the next lookup is 30 s off; the agent
    /// woke it meanwhile. Opening the player asks the bridge at once and
    /// shows the picture, with no trip to full screen and back.
    func testOpeningThePlayerOnAWokenBrowserShowsThePicture() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("asleep")
        await daemon.setChatLink(id)
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.lookUp(key: nil); host.dock.update(link: nil) }
        let dock = host.dock!
        dock.lookUp(key: key)
        try await until { dock.feed?.phase.dormantState != nil }
        XCTAssertEqual(dock.chatWatch?.currentInterval, LiveBrowserChatWatch.idleInterval)
        await daemon.setLivePod("running")
        dock.openPlayer()
        XCTAssertEqual(dock.chatWatch?.eager, true)
        try await until { dock.player?.shownImage != nil }
        XCTAssertNil(host.presentedViewController, "nothing presented")
        try await assertPictureComing(daemon, dock, "opened on a woken browser")
        dock.closePlayer(animated: false)
        XCTAssertEqual(dock.chatWatch?.eager, false)
    }

    /// A feed that stopped responding reads again when the player opens,
    /// not only from its Retry button.
    func testOpeningThePlayerRetriesAFeedNotResponding() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id))
        let feed = try XCTUnwrap(dock.feed)
        feed.requestTimeout = .milliseconds(300)
        feed.stuckLimit = .seconds(1)
        await daemon.setStalledFrames(1000)
        dock.openPlayer()
        try await until { feed.phase == .notResponding }
        XCTAssertFalse(feed.isPolling)
        dock.closePlayer(animated: false)
        await daemon.setStalledFrames(0)
        let reads = await daemon.frameReads
        dock.openPlayer()
        try await until { await daemon.frameReads > reads }
        try await until { dock.player?.shownImage != nil }
        XCTAssertNotEqual(feed.phase, .notResponding)
        try await assertPictureComing(daemon, dock, "retried on open")
    }

    /// Bigger and smaller, again and again, during the animation too.
    func testTogglingSizeKeepsThePictureComing() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await openWatching(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        let player = try XCTUnwrap(dock.player)
        for round in 0..<3 {
            player.onResize?()
            try await Task.sleep(for: .milliseconds(80))
            player.onResize?()
            try await Task.sleep(for: .milliseconds(80))
            player.onResize?()
            host.view.layoutIfNeeded()
            try await assertPictureComing(daemon, dock, "round \(round)")
            XCTAssertGreaterThan(player.bounds.width, 0)
            XCTAssertNotNil(player.window)
        }
        player.onResize?()
        try await assertPictureComing(daemon, dock, "back to where it was")
    }

    // MARK: The line comes back

    /// The bridge marked the link done (a controller restarted), then the
    /// agent's next call revived the same id: the line shows again, with
    /// no new dock.
    func testALinkThatEndsAndComesBackLiveWithTheSameIdShowsTheLineAgain() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("running")
        await daemon.setChatLink(id)
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.lookUp(key: nil); host.dock.update(link: nil) }
        let dock = host.dock!
        // At the origin the lookup answers at: the same link as its.
        dock.update(link: LiveBrowserLink(id: id, origin: LiveBrowserLink.lanOrigin))
        dock.lookUp(key: key)
        try await until { dock.browserRuns }
        let ended = try XCTUnwrap(dock.feed)

        // The feed reads done before the lookup says so (the lookup
        // answers no link meanwhile, the transcript's link kept): it is over.
        await daemon.setChatLink(nil)
        try await until { dock.chatWatch?.answer == .noLink }
        await daemon.setLiveStatus("done")
        try await until { ended.phase.isOver }
        try await until { dock.indicator.isHidden }

        await daemon.setLiveStatus("watching")
        await daemon.setChatLink(id)
        // The next lookup, now rather than in 30 s.
        dock.chatWatch?.checkNow()
        try await until { dock.browserRuns && !dock.indicator.isHidden }
        XCTAssertFalse(dock.feed === ended, "a fresh feed for the revived link")
        XCTAssertEqual(dock.feed?.link.id, id)
        XCTAssertEqual(dock.indicator.text, Strings.LiveBrowser.indicator(Strings.LiveBrowser.clickToWatch))
    }

    /// The feed read a 404 (the tunnel's, not the bridge's) and gave up,
    /// while the bridge goes on saying the browser runs: two answers
    /// later it reads again, and the line shows.
    func testAFeedThatSawA404ReadsAgainWhenTheBridgeSaysRunning() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("running")
        await daemon.setChatLink(id)
        await daemon.setStateMissing(true)
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.lookUp(key: nil); host.dock.update(link: nil) }
        let dock = host.dock!
        dock.lookUp(key: key)
        try await until { dock.feed?.phase.isOver == true }
        XCTAssertTrue(dock.indicator.isHidden)
        XCTAssertEqual(dock.chatWatch?.answer.chat?.running, true)

        await daemon.setStateMissing(false)
        try await until({ dock.browserRuns && !dock.indicator.isHidden }, tries: 200)
        XCTAssertEqual(dock.feed?.link.id, id)
    }

    /// Back from the background, the bridge is asked at once, not at the
    /// next 30 s turn.
    func testComingToTheForegroundAsksTheBridgeAtOnce() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("asleep")
        await daemon.setChatLink(id)
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.lookUp(key: nil); host.dock.update(link: nil) }
        let dock = host.dock!
        dock.lookUp(key: key)
        try await until { dock.feed?.phase.dormantState != nil }
        XCTAssertEqual(dock.chatWatch?.currentInterval, LiveBrowserChatWatch.idleInterval)
        let lookups = { await daemon.requests.filter { $0.hasPrefix("GET /live/chat/") }.count }
        let before = await lookups()

        await daemon.setLivePod("running")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await until({ await lookups() > before }, tries: 30)
        try await until { dock.browserRuns && !dock.indicator.isHidden }
    }

    /// The bridge had no link for the chat when it was first routed: once
    /// that has gone on long enough, the next route works the chat's
    /// computer and keys out again, and a link that comes is shown.
    func testAChatWithNoComputerAtFirstRoutesAgainLater() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLivePod("running")
        let (host, window) = try await makeHost(daemon)
        let routeAgain = LiveBrowserDock.routeAgainAfterNoLink
        LiveBrowserDock.routeAgainAfterNoLink = .seconds(1)
        defer {
            LiveBrowserDock.routeAgainAfterNoLink = routeAgain
            window.isHidden = true
            host.dock.lookUp(key: nil)
        }
        let dock = host.dock!
        let client = AgentClient(transport: daemon, token: "native-secret")
        let identity = LiveBrowserChatIdentity.agent(id: "agent-1", happySession: "cmhk2v9q40001ab12cd34ef56")
        dock.route(identity, through: .client(client, happy: nil))
        try await until { dock.routing == nil && dock.chatWatch?.answer == .noLink }
        XCTAssertEqual(dock.routedKeys.first, key)

        // Too soon: decided once, nothing decided again.
        dock.route(identity, through: .client(client, happy: nil))
        XCTAssertNil(dock.routing)

        try await Task.sleep(for: .milliseconds(1200))
        dock.route(identity, through: .client(client, happy: nil))
        XCTAssertNotNil(dock.routing, "no link for long enough: worked out again")
        try await until { dock.routing == nil }

        await daemon.setChatLink(id)
        dock.chatWatch?.checkNow()
        try await until { dock.browserRuns && !dock.indicator.isHidden }
    }

    // MARK: Click to watch

    /// Minimized, the line asks to be clicked; while the player shows it,
    /// it says Watching.
    func testTheLineSaysClickToWatchUntilThePlayerOpens() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id))
        let click = Strings.LiveBrowser.indicator(Strings.LiveBrowser.clickToWatch)
        let watching = Strings.LiveBrowser.indicator(Strings.LiveBrowser.watching)
        try await until { dock.indicator.text == click }
        XCTAssertEqual(dock.indicator.accessibilityLabel, click)

        dock.openPlayer()
        XCTAssertEqual(dock.indicator.text, watching)
        XCTAssertEqual(dock.indicator.accessibilityLabel, watching)

        dock.closePlayer(animated: false)
        XCTAssertEqual(dock.indicator.text, click)
        XCTAssertEqual(dock.indicator.accessibilityLabel, click)
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

    private func screenshot(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["HAPPY_PREVIEW_DIR"] {
            try image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
#endif
