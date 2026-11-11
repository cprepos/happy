#if canImport(UIKit)
@testable import HappyCore
@testable import HappyUI
import HappyLayout
import UIKit
import WebKit
import XCTest

/// One chat's live browser, as `LiveBrowserDock` shows it: the red line on
/// the card, the player over the composer, full screen with Take control
/// and Release control, the chips, and the voice sheet's strip.
@MainActor
final class HostedLiveBrowserTests: XCTestCase {
    private let id = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"
    private let newer = "7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b"

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

    /// A chat screen with only what a dock needs: a card to stand on.
    private final class Host: UIViewController, LiveBrowserDockHosting {
        var dock: LiveBrowserDock!
        var liveBrowserDock: LiveBrowserDock? { dock }
        let card = UIView()
        var cardFrame = CGRect.zero
        var line: ChatStatusLineLayout?
        var layouts = 0

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            card.backgroundColor = .secondarySystemBackground
            view.addSubview(card)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            layouts += 1
            // As the agent chat does: the card 8 in, 56 tall, on the safe area.
            let size = view.bounds.size
            cardFrame = CGRect(x: 8, y: size.height - view.safeAreaInsets.bottom - 56, width: size.width - 16, height: 56)
            card.frame = cardFrame
            line = ChatStatusLineLayout(above: cardFrame, voice: nil, browser: dock.indicator.textSize)
            dock.indicator.place(line?.browser)
            dock.layoutPlayer(card: cardFrame, anchor: line?.frame.minY ?? cardFrame.minY)
        }
    }

    private func makeHost(_ daemon: BrowserDaemon, chat: String = UUID().uuidString) async throws -> (Host, UIWindow) {
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

    func testTheLineThePlayerAndTakeAndRelease() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        XCTAssertTrue(dock.indicator.isHidden, "no link, no line")

        let link = try XCTUnwrap(LiveBrowserLink(id: id))
        dock.update(link: link)
        // Needs you: the line says so, and the player comes up on its own.
        try await until { dock.indicator.text == Strings.LiveBrowser.indicator(Strings.LiveBrowser.needsYou) }
        XCTAssertFalse(dock.indicator.isHidden)
        try await until { dock.player != nil }
        host.view.layoutIfNeeded()

        // The line: its dot at the card's right edge, on the card.
        let line = try XCTUnwrap(host.line)
        let row = try XCTUnwrap(line.browser)
        // The same frame, to a rounding: the line lays its row out from
        // the composer's width, the indicator from its own.
        for (a, b) in zip([dock.indicator.frame.minX, dock.indicator.frame.minY, dock.indicator.frame.width, dock.indicator.frame.height],
                          [row.frame.minX, row.frame.minY, row.frame.width, row.frame.height]) {
            XCTAssertEqual(a, b, accuracy: 0.01)
        }
        XCTAssertEqual(row.dot.maxX, host.cardFrame.maxX)
        XCTAssertEqual(line.frame.maxY, host.cardFrame.minY)
        XCTAssertEqual(line.frame.height, 20)
        // The player: at the bottom right, 8 over the line, its right edge the card's.
        let player = try XCTUnwrap(dock.player)
        let expected = LiveBrowserDockLayout(.init(
            size: host.view.bounds.size, safeArea: LayoutInsets(host.view.safeAreaInsets), card: host.cardFrame, anchor: line.frame.minY,
            idiom: dock.isPhone ? .phone : .pad, aspect: dock.frameAspect
        ))
        XCTAssertEqual(player.frame, expected.frame)
        XCTAssertEqual(player.frame.maxX, host.cardFrame.maxX)
        XCTAssertEqual(player.frame.maxY, line.frame.minY - 8)
        if host.view.bounds.size == CGSize(width: 402, height: 874) {
            XCTAssertEqual(host.cardFrame, CGRect(x: 8, y: 784, width: 386, height: 56))
            // Small is 60% of the card, ⇲ and full screen both on its bar.
            XCTAssertEqual(player.frame, CGRect(x: 162, y: 537, width: 232, height: 219))
            for id in ["live-browser-player-resize", "live-browser-player-full-screen", "live-browser-player-menu", "live-browser-player-close"] {
                XCTAssertNotNil(player.subviews.first { $0.accessibilityIdentifier == id && !$0.isHidden }, id)
            }
        }
        // Its buttons stand on the bar, none on the picture, each a 44-point target.
        let picture = try XCTUnwrap(player.subviews.first { $0.accessibilityIdentifier == "live-browser-picture" })
        let buttons = player.subviews.compactMap { $0 as? UIButton }.filter { !$0.isHidden && $0.accessibilityIdentifier != "live-browser-player-action" }
        XCTAssertGreaterThanOrEqual(buttons.count, 2)
        for button in buttons {
            XCTAssertFalse(button.frame.intersects(picture.frame), "\(button.accessibilityIdentifier ?? "") covers the picture")
            XCTAssertGreaterThanOrEqual(min(button.frame.width, button.frame.height), 44)
        }
        try await until { await daemon.requests.contains { $0.hasPrefix("GET /live/\(self.id)/frame.jpg") } }
        let requests = await daemon.requests
        XCTAssertTrue(requests.contains { $0.hasPrefix("CONNECT /v0/workspaces/work1/proxy") }, "through the chat's own workspace")
        try screenshot(window, name: "live-browser-dock-needs-you")

        // Closed, the line stays; the line opens it again.
        dock.closePlayer(animated: false)
        XCTAssertNil(dock.player)
        XCTAssertFalse(dock.indicator.isHidden)
        dock.indicator.sendActions(for: .touchUpInside)
        XCTAssertNotNil(dock.player)

        // Take over: full screen, control taken, then noVNC at the address
        // the bridge answered, not a fixed port.
        dock.presentFullScreen(taking: true)
        try await until { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.id)/take HTTP/1.1") } }
        try await until { (host.presentedViewController as? UINavigationController)?.viewControllers.count == 2 }
        let navigation = try XCTUnwrap(host.presentedViewController as? UINavigationController)
        let noVNC = try XCTUnwrap(navigation.viewControllers.last as? LiveBrowserFullScreenItems)
        // noVNC's page scales the remote screen on a phone, never resizes it.
        let scaled = BrowserDaemon.chatNoVNC.replacingOccurrences(of: "resize=remote", with: "resize=scale")
        XCTAssertEqual(noVNC.browser.originalURL.absoluteString, dock.isPhone ? scaled : BrowserDaemon.chatNoVNC)
        try await until { dock.indicator.text == Strings.LiveBrowser.indicator(Strings.LiveBrowser.youHaveControl) }
        try await until { navigation.transitionCoordinator == nil && noVNC.isViewLoaded }
        let control = try XCTUnwrap(noVNC.navigationItem.rightBarButtonItems?.first)
        XCTAssertEqual(control.accessibilityIdentifier, "live-browser-control")
        XCTAssertEqual(control.title, Strings.LiveBrowser.releaseControl)
        XCTAssertEqual(noVNC.navigationItem.leftBarButtonItem?.accessibilityIdentifier, "live-browser-minimize")
        // noVNC has every touch: the page neither scrolls, bounces nor
        // zooms, and no swipe back or pull to dismiss is under it.
        let scroll = try XCTUnwrap(noVNC.browser.web?.scrollView)
        XCTAssertTrue(noVNC.browser.isRemoteScreen)
        XCTAssertFalse(scroll.isScrollEnabled)
        XCTAssertFalse(scroll.bounces)
        XCTAssertFalse(scroll.bouncesZoom)
        XCTAssertEqual(scroll.maximumZoomScale, 1)
        XCTAssertNotEqual(scroll.pinchGestureRecognizer?.isEnabled, true)
        XCTAssertFalse(noVNC.browser.web?.allowsBackForwardNavigationGestures ?? true)
        XCTAssertTrue(noVNC.holdsGestures)
        XCTAssertNotEqual(navigation.interactivePopGestureRecognizer?.isEnabled, true)
        XCTAssertTrue(navigation.isModalInPresentation)
        XCTAssertFalse(dock.allowsInteractiveDismiss)
        try screenshot(window, name: "live-browser-dock-novnc")

        // Release control: the agent drives again, back to the frame view.
        dock.release()
        try await until { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.id)/release HTTP/1.1") } }
        try await until { navigation.viewControllers.count == 1 }
        try await until { dock.indicator.text == Strings.LiveBrowser.indicator(Strings.LiveBrowser.watching) }
        // With noVNC gone, the gestures are back as they were.
        try await until { navigation.transitionCoordinator == nil }
        XCTAssertFalse(noVNC.holdsGestures)
        XCTAssertFalse(navigation.isModalInPresentation)
        XCTAssertTrue(dock.allowsInteractiveDismiss)
        XCTAssertNotNil(dock.player)
        XCTAssertEqual(dock.player?.accessibilityValue, "watching")
        dock.minimize()
        try await until { host.presentedViewController == nil }
    }

    // MARK: noVNC

    /// Taken: the noVNC page up, the full screen's navigation and its page.
    private func takeOver(_ host: Host, _ daemon: BrowserDaemon) async throws -> (UINavigationController, LiveBrowserFullScreenItems) {
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id))
        try await until { dock.feed?.phase.state != nil }
        dock.presentFullScreen(taking: true)
        try await until { (host.presentedViewController as? UINavigationController)?.viewControllers.count == 2 }
        let navigation = try XCTUnwrap(host.presentedViewController as? UINavigationController)
        let noVNC = try XCTUnwrap(navigation.viewControllers.last as? LiveBrowserFullScreenItems)
        try await until { navigation.transitionCoordinator == nil && noVNC.isViewLoaded }
        XCTAssertTrue(noVNC.isNoVNC)
        return (navigation, noVNC)
    }

    /// The bar's views showing `title`, on screen in the bar.
    private func shown(_ title: String, in bar: UINavigationBar) -> Bool {
        func walk(_ view: UIView) -> Bool {
            guard !view.isHidden, view.alpha > 0.01 else { return false }
            let says = (view as? UILabel)?.text == title || (view as? UIButton)?.currentTitle == title
                || (view.accessibilityLabel == title && !(view is UINavigationBar))
            if says {
                let frame = view.convert(view.bounds, to: bar)
                if frame.width > 0, bar.bounds.intersects(frame) { return true }
            }
            return view.subviews.contains(where: walk)
        }
        return walk(bar)
    }

    func testReleaseShowsOnTheNoVNCHeader() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let (navigation, noVNC) = try await takeOver(host, daemon)
        // Control alone at the far right, Minimize at the left, no back
        // button that would leave control held: nothing pushes Release
        // into the overflow menu. The native viewer is in the More menu
        // of the bar under the header.
        XCTAssertEqual(noVNC.navigationItem.rightBarButtonItems?.map(\.accessibilityIdentifier), ["live-browser-control"])
        let viewerActions = noVNC.viewerMenu.menu?.children.compactMap { ($0 as? UIAction)?.identifier.rawValue }
        // Yolo is in that menu too (deferred, read as it opens).
        XCTAssertTrue(noVNC.viewerMenu.menu?.children.contains { $0 is UIDeferredMenuElement } ?? false)
        XCTAssertEqual(viewerActions, ["live-browser-native-viewer"])
        XCTAssertTrue(noVNC.viewerMenu.isDescendant(of: noVNC.view))
        XCTAssertEqual(noVNC.navigationItem.rightBarButtonItems?.first, noVNC.control)
        XCTAssertTrue(noVNC.navigationItem.hidesBackButton)
        XCTAssertEqual(noVNC.control.title, Strings.LiveBrowser.releaseControl)
        XCTAssertTrue(noVNC.control.isEnabled)
        navigation.navigationBar.layoutIfNeeded()
        try await until { self.shown(Strings.LiveBrowser.releaseControl, in: navigation.navigationBar) }
        // The full screen keeps the state read while the chat is under it.
        let before = await daemon.requests.filter { $0.hasPrefix("GET /live/\(self.id)/state") }.count
        try await until { await daemon.requests.filter { $0.hasPrefix("GET /live/\(self.id)/state") }.count > before }
        try screenshot(window, name: "live-browser-novnc-release")
    }

    func testReleaseOnTheNoVNCPageGoesBackToTheFrameView() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let (navigation, noVNC) = try await takeOver(host, daemon)
        XCTAssertNotNil(noVNC.browser.web)
        let action = try XCTUnwrap(noVNC.control.primaryAction)
        action.performWithSender(nil, target: nil)
        try await until { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.id)/release HTTP/1.1") } }
        try await until { navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil }
        let frame = try XCTUnwrap(navigation.viewControllers.first as? LiveBrowserFullScreenItems)
        XCTAssertFalse(frame.isNoVNC)
        XCTAssertEqual(frame.control.title, Strings.LiveBrowser.takeControl)
        // Its web view and tunnel went with it.
        try await until { noVNC.browser.web == nil && noVNC.parent == nil }
        try await until { host.dock.indicator.text == Strings.LiveBrowser.indicator(Strings.LiveBrowser.watching) }
        XCTAssertNotNil(host.presentedViewController, "still full screen, no close and reopen")
    }

    /// noVNC dropping its connection is leaving noVNC: back to the frame
    /// view, and control goes back with it, no exemption.
    func testANoVNCDisconnectGoesBackToTheFrameViewAndReleases() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let (navigation, noVNC) = try await takeOver(host, daemon)
        try await until { noVNC.browser.web?.isLoading == false && noVNC.browser.web?.url != nil }
        let web = try XCTUnwrap(noVNC.browser.web)
        // As noVNC's UI does: connected, then neither connected nor connecting.
        _ = try await web.evaluateJavaScript("""
            document.documentElement.classList.add('noVNC_connected');
            setTimeout(function () { document.documentElement.classList.remove('noVNC_connected'); }, 100);
            true
            """)
        try await until { navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil }
        let frame = try XCTUnwrap(navigation.viewControllers.first as? LiveBrowserFullScreenItems)
        XCTAssertFalse(frame.isNoVNC)
        try await until { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.id)/release HTTP/1.1") } }
        try await until { frame.control.title == Strings.LiveBrowser.takeControl }
        XCTAssertTrue(frame.control.isEnabled, "Take control again, one tap")
        let releases = await daemon.requests.filter { $0.hasPrefix("POST /live/\(self.id)/release ") }
        XCTAssertEqual(releases.count, 1, "handed back once")
    }

    // MARK: End browser

    /// The sheet `confirmEnd` put up, over whatever is topmost.
    private func endSheet(_ host: Host) async throws -> UIAlertController {
        var sheet: UIAlertController?
        try await until {
            var top: UIViewController = host
            while let next = top.presentedViewController { top = next }
            sheet = top as? UIAlertController
            return sheet != nil && top.transitionCoordinator == nil
        }
        return try XCTUnwrap(sheet)
    }

    func testEndBrowserIsInThePlayersMenuAsksFirstAndTheLineGoes() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id))
        try await until { dock.player != nil && dock.feed?.phase.state != nil }
        host.view.layoutIfNeeded()
        let player = try XCTUnwrap(dock.player)
        // Behind the menu on the bar's left, beside close, away from Take
        // over: every idiom's small player has room for it.
        XCTAssertFalse(player.menuButton.isHidden)
        XCTAssertTrue(player.menuButton.showsMenuAsPrimaryAction)
        let menu = player.menuButton.frame
        XCTAssertLessThan(menu.midX, player.bounds.midX)
        XCTAssertEqual(menu.minY, 0)
        XCTAssertGreaterThanOrEqual(menu.height, 44)
        // Sleep browser first, then End browser, the destructive one.
        let actions = (player.menuButton.menu?.children ?? []).compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), [Strings.LiveBrowser.sleepBrowser, Strings.LiveBrowser.endBrowser])
        XCTAssertFalse(actions.first?.attributes.contains(.destructive) ?? true)
        let item = try XCTUnwrap(actions.last)
        XCTAssertEqual(item.title, Strings.LiveBrowser.endBrowser)
        XCTAssertTrue(item.attributes.contains(.destructive))

        // Asked first: nothing is sent until the person says End browser.
        item.performWithSender(nil, target: nil)
        let sheet = try await endSheet(host)
        XCTAssertEqual(sheet.preferredStyle, .actionSheet)
        XCTAssertEqual(sheet.title, "End this browser?")
        XCTAssertEqual(sheet.message, "Logins are kept; it starts fresh next time.")
        XCTAssertEqual(sheet.actions.map(\.title), [Strings.LiveBrowser.endBrowser, Strings.LiveBrowser.cancel])
        XCTAssertEqual(sheet.actions.map(\.style), [.destructive, .cancel])
        try screenshot(window, name: "live-browser-end-confirm")
        let posted = await daemon.requests.contains { $0.contains("/end ") }
        XCTAssertFalse(posted)
        sheet.dismiss(animated: false)

        dock.end()
        try await until { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.id)/end HTTP/1.1") } }
        XCTAssertEqual(dock.feed?.phase.state?.reason, "user_ended")
        try await until { dock.indicator.isHidden && dock.player == nil }
        let polls = dock.feed?.polls ?? 0
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(dock.feed?.polls ?? 0, polls, "an ended browser is read no more")
    }

    func testEndBrowserOnTheFullScreenHeaderIsAtTheLeftAndClosesIt() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let (navigation, noVNC) = try await takeOver(host, daemon)
        // Minimize and End browser at the left; Release control alone at
        // the right.
        XCTAssertEqual(noVNC.navigationItem.leftBarButtonItems?.map(\.accessibilityIdentifier), ["live-browser-minimize", "live-browser-end", "live-browser-sleep"])
        XCTAssertEqual(noVNC.navigationItem.rightBarButtonItems?.map(\.accessibilityIdentifier), ["live-browser-control"])
        XCTAssertEqual(noVNC.navigationItem.rightBarButtonItems?.first, noVNC.control)
        XCTAssertTrue(noVNC.endItem.isEnabled)
        let frame = try XCTUnwrap(navigation.viewControllers.first as? LiveBrowserFullScreenItems)
        frame.loadViewIfNeeded()
        // End at the left with Sleep beside it, then yolo.
        XCTAssertEqual(frame.navigationItem.leftBarButtonItems?.suffix(3).map { $0 }, [frame.endItem, frame.sleepItem, frame.yoloItem])
        XCTAssertFalse(frame.navigationItem.rightBarButtonItems?.contains(frame.endItem) ?? true)

        noVNC.endItem.primaryAction?.performWithSender(nil, target: nil)
        let sheet = try await endSheet(host)
        XCTAssertEqual(sheet.title, Strings.LiveBrowser.endConfirm)
        sheet.dismiss(animated: false)
        try await until { navigation.presentedViewController == nil }

        host.dock.end()
        try await until { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.id)/end HTTP/1.1") } }
        try await until { host.presentedViewController == nil }
        try await until { host.dock.indicator.isHidden }
    }

    func testOnlyNeedsYouOpensThePlayer() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id))
        try await until { dock.indicator.text == Strings.LiveBrowser.indicator(Strings.LiveBrowser.clickToWatch) }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(dock.player, "watching: the line only")
        await daemon.setLiveStatus("takeover")
        try await until { dock.player != nil }
        // Closed while it still needs the person: it stays closed.
        dock.closePlayer(animated: false)
        try await Task.sleep(for: .milliseconds(2500))
        XCTAssertNil(dock.player)
        XCTAssertFalse(dock.indicator.isHidden)
    }

    func testAnExpiredLinkHasNoLine() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: "0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e"))
        try await until { dock.feed?.phase == .expired }
        XCTAssertTrue(dock.indicator.isHidden)
        XCTAssertNil(host.line, "no line: the card keeps its place")
    }

    /// No computer: the player says unavailable, and with no browser the
    /// bridge says is live there is no red line.
    func testAChatWithNoComputerIsUnavailableWithNoLine() async throws {
        let host = Host()
        host.dock = LiveBrowserDock(host: host, chatKey: UUID().uuidString) { nil }
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: host)
        defer { window.isHidden = true }
        host.view.addSubview(host.dock.indicator)
        host.dock.setOnScreen(true)
        host.dock.update(link: LiveBrowserLink(id: id))
        try await until { host.dock.feed?.phase == .unavailable }
        XCTAssertEqual(LiveBrowserDock.status(.unavailable), Strings.LiveBrowser.unavailableStatus)
        XCTAssertFalse(host.dock.browserRuns)
        XCTAssertTrue(host.dock.indicator.isHidden, "not live: no red line")
    }

    func testAChipOpensItsChatsPlayerAndAnOlderOneSaysReplaced() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        let link = try XCTUnwrap(LiveBrowserLink(id: id))
        dock.update(link: link)
        let chip = LiveBrowserChipView()
        chip.frame = CGRect(x: 16, y: 160, width: 361, height: LiveBrowserChipView.height)
        host.view.addSubview(chip)
        chip.apply(link)
        try await until { chip.accessibilityValue == Strings.LiveBrowser.watching }
        XCTAssertFalse(chip.isReplaced)
        chip.sendActions(for: .touchUpInside)
        XCTAssertNotNil(dock.player, "the chip opens the chat's player")
        try screenshot(window, name: "live-browser-chip")

        // The chat linked a newer browser: the old chip says so, and opens nothing.
        dock.update(link: LiveBrowserLink(id: newer))
        XCTAssertTrue(chip.isReplaced)
        XCTAssertEqual(chip.accessibilityValue, "replaced")
        XCTAssertNil(dock.player)
        chip.sendActions(for: .touchUpInside)
        XCTAssertNil(dock.player)
    }

    func testTheChatPlansAChip() throws {
        let link = try XCTUnwrap(LiveBrowserLink(id: id))
        let item = ChatItem(id: "m1", role: .agent, pieces: [.text("Watch:"), .liveBrowser(id: id, url: link.url)], delivery: .sent)
        let plan = ChatPlanner.plan(item, key: ChatPlanner.Key(width: 393, maxContentWidth: 10_000, environment: nil), copied: false, syntax: CodeSyntaxService())
        let view = ChatPlanView(frame: CGRect(origin: .zero, size: plan.size))
        view.apply(plan)
        view.layoutIfNeeded()
        let chips = view.subviews.compactMap { $0 as? LiveBrowserChipView }
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(chips.first?.link, link)
        XCTAssertEqual(chips.first?.frame.height, 44)
    }

    // MARK: The voice strip

    func testTheVoiceSheetMinimizesToAStrip() async throws {
        let host = UIViewController()
        host.view.backgroundColor = .systemBackground
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: host)
        defer { window.isHidden = true }
        let voice = VoiceCoordinator.shared
        voice.show(from: host)
        try await until { host.presentedViewController != nil && host.presentedViewController?.isBeingPresented == false }
        let navigation = try XCTUnwrap(host.presentedViewController as? UINavigationController)
        let sheet = try XCTUnwrap(navigation.sheetPresentationController)
        XCTAssertEqual(sheet.detents.map(\.identifier), [.voiceStrip, .medium, .large])
        XCTAssertEqual(sheet.largestUndimmedDetentIdentifier, .voiceStrip, "the chat under the strip stays live")
        XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)

        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: .voiceSheetChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { changes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        voice.minimizeSheet()
        XCTAssertEqual(sheet.selectedDetentIdentifier, .voiceStrip)
        XCTAssertGreaterThan(changes, 0)
        try await Task.sleep(for: .milliseconds(600))
        let top = try XCTUnwrap(voice.sheetTop(in: host.view))
        XCTAssertEqual(top, host.view.bounds.maxY - host.view.safeAreaInsets.bottom - VoiceStatusViewController.stripHeight, accuracy: 0.5)
        XCTAssertEqual(navigation.presentationController?.presentedView?.frame.minY ?? 0, top, accuracy: 40, "the strip is where it says")
        try screenshot(window, name: "voice-strip")

        // The strip's tap: half height again.
        voice.expandSheet()
        XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)
        host.dismiss(animated: false)
        try await until { host.presentedViewController == nil }
        XCTAssertNil(voice.sheetTop(in: host.view))
    }

    func testTheVoiceStripStaysUnderThePlayer() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let voice = VoiceCoordinator.shared
        voice.show(from: host)
        try await until { host.presentedViewController?.isBeingPresented == false }
        let sheet = try XCTUnwrap(host.presentedViewController?.sheetPresentationController)
        host.dock.update(link: LiveBrowserLink(id: id))
        try await until { host.dock.indicator.text != nil && host.dock.indicator.isHidden == false }
        // The player opened: the sheet down to its strip, the player above it.
        host.dock.openPlayer()
        XCTAssertEqual(sheet.selectedDetentIdentifier, .voiceStrip)
        try await Task.sleep(for: .milliseconds(600))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let strip = try XCTUnwrap(voice.sheetTop(in: host.view))
        let player = try XCTUnwrap(host.dock.player)
        XCTAssertEqual(player.frame.maxY, min(strip, host.line?.frame.minY ?? .greatestFiniteMagnitude) - 8, accuracy: 0.5)
        try screenshot(window, name: "voice-strip-player")
        host.dismiss(animated: false)
        try await until { host.presentedViewController == nil }
    }

    // MARK: The big player

    /// Every idiom: ⇲ and the picture go between small and big, the full
    /// screen button alone opens full screen. A phone's big is the whole
    /// width; an iPad's or a Mac's is 75% of it, centred.
    func testExpandMakesTheWholeWidthPlayerInTheChatAndShrinkPutsItBack() async throws {
        let daemon = BrowserDaemon()
        let chat = UUID().uuidString
        let (host, window) = try await makeHost(daemon, chat: chat)
        defer { window.isHidden = true; host.dock.update(link: nil); UserDefaults.standard.removeObject(forKey: "liveBrowserDock.\(chat)") }
        let dock = host.dock!
        turnUpright()
        dock.update(link: LiveBrowserLink(id: id))
        try await until { dock.player != nil && dock.feed?.phase.state != nil }
        host.view.layoutIfNeeded()
        let player = try XCTUnwrap(dock.player)
        func button(_ id: String) throws -> UIButton {
            try XCTUnwrap(player.subviews.first { $0.accessibilityIdentifier == id && !$0.isHidden } as? UIButton, id)
        }
        let small = player.frame
        XCTAssertLessThan(small.width, host.view.bounds.width)
        XCTAssertEqual(dock.topInset(in: host.view), 0)
        XCTAssertEqual(try button("live-browser-player-resize").accessibilityLabel, Strings.LiveBrowser.bigger)

        // ⇲: big, edge to edge under the header at the frame's aspect
        // (an iPad's capped and centred), the chat's content under it;
        // kept for the chat. No full screen.
        try button("live-browser-player-resize").sendActions(for: .touchUpInside)
        try await until { player.layer.animationKeys()?.isEmpty ?? true }
        host.view.layoutIfNeeded()
        let width = player.frame.width
        XCTAssertEqual(dock.isPhone, UIDevice.current.userInterfaceIdiom == .phone && !ProcessInfo.processInfo.isiOSAppOnMac)
        if dock.isPhone {
            XCTAssertEqual(player.frame.minX, 0)
            XCTAssertEqual(width, host.view.bounds.width, "a phone's big is the chat's whole width")
        } else {
            XCTAssertEqual(width, (host.view.bounds.width * 0.75).rounded(.down), "upright, an iPad's big is 75% of the pane")
            XCTAssertGreaterThan(width, small.width)
            XCTAssertEqual(player.frame.midX, host.view.bounds.midX, accuracy: 0.5)
        }
        XCTAssertEqual(player.frame.minY, host.view.safeAreaInsets.top)
        let picture = try XCTUnwrap(player.subviews.first { $0.accessibilityIdentifier == "live-browser-picture" })
        XCTAssertEqual(picture.frame.width, width)
        XCTAssertEqual(picture.frame.height, (width / 1.6).rounded())
        XCTAssertEqual(dock.topInset(in: host.view), player.frame.height + 8)
        XCTAssertTrue(dock.riders.isEmpty, "big stays at the top over the keyboard")
        XCTAssertNil(host.presentedViewController)
        XCTAssertTrue(LiveBrowserDock.kept(chat).big)
        XCTAssertEqual(try button("live-browser-player-resize").accessibilityLabel, Strings.LiveBrowser.smaller)
        for id in ["live-browser-player-close", "live-browser-player-menu", "live-browser-player-full-screen"] { _ = try button(id) }
        try screenshot(window, name: dock.isPhone ? "live-browser-phone-big" : "live-browser-pad-big")

        // Turned sideways, big stays the windowed player, at its aspect.
        try await turn(window, to: .landscapeRight)
        host.view.layoutIfNeeded()
        XCTAssertNil(host.presentedViewController, "landscape is full screen's, asked for only by its button")
        XCTAssertEqual(picture.frame.width / picture.frame.height, 1.6, accuracy: 0.02)
        XCTAssertEqual(player.frame.minY, host.view.safeAreaInsets.top)
        try await turn(window, to: .portrait)
        host.view.layoutIfNeeded()
        XCTAssertEqual(player.frame.width, width)

        // The picture tapped: as ⤢, back to small where it was.
        player.onTap?()
        try await until { player.layer.animationKeys()?.isEmpty ?? true }
        host.view.layoutIfNeeded()
        XCTAssertEqual(player.frame, small)
        XCTAssertEqual(dock.topInset(in: host.view), 0)
        XCTAssertFalse(LiveBrowserDock.kept(chat).big)
        XCTAssertNil(host.presentedViewController, "the picture never opens full screen")
        player.onTap?()
        try await until { dock.topInset(in: host.view) > 0 }

        // Full screen: its own button, from big.
        try button("live-browser-player-full-screen").sendActions(for: .touchUpInside)
        try await until { (host.presentedViewController as? UINavigationController)?.transitionCoordinator == nil && host.presentedViewController != nil }
        dock.minimize()
        try await until { host.presentedViewController == nil }
    }

    /// Records what the haptics played.
    private final class HapticsRecorder: Haptics.Player {
        var played: [Haptics.Feedback] = []
        func prepare(_ feedback: Haptics.Feedback) {}
        func play(_ feedback: Haptics.Feedback) { played.append(feedback) }
    }

    /// A grip flush in each bottom corner resizes the player as a pan goes, at the
    /// frame's aspect, its docked corner held; a tick at each limit; the
    /// size kept for the chat; VoiceOver steps it; ⤢ snaps to big and drops
    /// it; big grows from its middle, the chat's content following. Take
    /// control stands in the bar's middle.
    func testDraggingTheGripResizesThePlayerAndKeepsTheSize() async throws {
        let daemon = BrowserDaemon()
        let chat = UUID().uuidString
        let (host, window) = try await makeHost(daemon, chat: chat)
        let haptics = Haptics.player
        let recorder = HapticsRecorder()
        Haptics.player = recorder
        defer {
            Haptics.player = haptics
            window.isHidden = true; host.dock.update(link: nil); UserDefaults.standard.removeObject(forKey: "liveBrowserDock.\(chat)")
        }
        let dock = host.dock!
        turnUpright()
        dock.update(link: LiveBrowserLink(id: id))
        try await until { dock.player != nil && dock.feed?.phase.state != nil }
        try await until { dock.player?.layer.animationKeys()?.isEmpty ?? true }
        host.view.layoutIfNeeded()
        let player = try XCTUnwrap(dock.player)
        let feed = try XCTUnwrap(dock.feed)

        // Take control in the bar's middle.
        let action = try XCTUnwrap(player.subviews.first { $0.accessibilityIdentifier == "live-browser-player-action" })
        XCTAssertEqual(action.frame.midX, player.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(action.frame.minY, 0)

        // Small at the bottom right: a grip flush in each bottom corner.
        let corners: [LiveBrowserDockLayout.Corner] = [.bottomLeft, .bottomRight]
        let grips = player.gripViews.filter { !$0.isHidden }
        XCTAssertEqual(grips.map(\.corner), corners)
        XCTAssertEqual(grips.filter(\.isAccessibilityElement).count, 1, "one for VoiceOver")
        for grip in grips { XCTAssertTrue(player.bounds.contains(grip.frame), "inside the box") }
        let grip = try XCTUnwrap(grips.last)
        XCTAssertEqual(grip.corner, .bottomRight)
        XCTAssertEqual(grip.accessibilityIdentifier, "live-browser-player-grip")
        XCTAssertEqual(grip.accessibilityLabel, Strings.LiveBrowser.resizePlayer)
        XCTAssertTrue(grip.accessibilityTraits.contains(.adjustable))
        let voiceOver = try XCTUnwrap(grips.first(where: \.isAccessibilityElement))
        let start = player.frame
        XCTAssertEqual(grip.frame.maxX, player.bounds.maxX)
        XCTAssertEqual(grip.frame.maxY, player.bounds.maxY)

        // Down and right along the aspect: 40 wider, the bottom right held.
        player.onGrip?(.bottomRight, .began, .zero)
        XCTAssertTrue(player.isResizing)
        player.onGrip?(.bottomRight, .changed, CGPoint(x: 40, y: 25))
        XCTAssertEqual(player.frame.width, start.width + 40)
        XCTAssertEqual(player.frame.maxX, start.maxX)
        XCTAssertEqual(player.frame.maxY, start.maxY)
        let picture = try XCTUnwrap(player.subviews.first { $0.accessibilityIdentifier == "live-browser-picture" })
        XCTAssertEqual(picture.frame.height, (player.frame.width / 1.6).rounded())
        let size = try XCTUnwrap(player.subviews.first { $0.accessibilityIdentifier == "live-browser-player-size" } as? UILabel)
        XCTAssertFalse(size.isHidden, "the size shows as it goes")
        XCTAssertEqual(size.text, Strings.LiveBrowser.size(width: Int(picture.frame.width), height: Int(picture.frame.height)))
        XCTAssertTrue(recorder.played.isEmpty)
        XCTAssertTrue(feed.frame == nil || player.shownImage != nil, "the picture stays")

        // Past the most: held at the card's width, one tick however far.
        player.onGrip?(.bottomRight, .changed, CGPoint(x: 1000, y: 625))
        let most = player.frame.width
        XCTAssertLessThanOrEqual(most, host.cardFrame.width)
        XCTAssertEqual(player.frame.maxX, start.maxX)
        XCTAssertGreaterThanOrEqual(player.frame.minY, host.view.safeAreaInsets.top)
        player.onGrip?(.bottomRight, .changed, CGPoint(x: 1200, y: 750))
        XCTAssertEqual(player.frame.width, most)
        XCTAssertEqual(recorder.played, [.impact(.rigid)])
        // Past the least: the old mini player's, a second tick.
        player.onGrip?(.bottomRight, .changed, CGPoint(x: -1000, y: -625))
        XCTAssertEqual(player.frame.width, dock.isPhone ? 112 : 176)
        XCTAssertEqual(recorder.played, [.impact(.rigid), .impact(.rigid)])
        player.onGrip?(.bottomRight, .changed, CGPoint(x: 40, y: 25))
        player.onGrip?(.bottomRight, .ended, CGPoint(x: 40, y: 25))
        XCTAssertFalse(player.isResizing)
        XCTAssertTrue(size.isHidden)
        let dragged = player.frame.width
        XCTAssertEqual(dragged, start.width + 40)
        XCTAssertEqual(LiveBrowserDock.kept(chat).width, dragged, "kept for the chat")
        XCTAssertFalse(LiveBrowserDock.kept(chat).big)
        // Laid out again, it stays.
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertEqual(player.frame.width, dragged)

        // VoiceOver's decrement: a step narrower, kept.
        voiceOver.accessibilityDecrement()
        XCTAssertEqual(player.frame.width, dragged - 40)
        XCTAssertEqual(LiveBrowserDock.kept(chat).width, dragged - 40)
        voiceOver.accessibilityIncrement()
        XCTAssertEqual(player.frame.width, dragged)

        // ⤢: big, its preset; the dragged size gone.
        player.onTap?()
        try await until { player.layer.animationKeys()?.isEmpty ?? true }
        host.view.layoutIfNeeded()
        XCTAssertTrue(LiveBrowserDock.kept(chat).big)
        XCTAssertNil(LiveBrowserDock.kept(chat).width)
        let big = player.frame
        XCTAssertEqual(big.midX, host.view.bounds.midX, accuracy: 0.5)

        // Big's grips: the same corners, inside the box. The right one 20
        // in and up: 40 narrower, still centred, the chat's content under it.
        let bigGrips = player.gripViews.filter { !$0.isHidden }
        XCTAssertEqual(bigGrips.map(\.corner), corners)
        XCTAssertEqual(bigGrips.filter(\.isAccessibilityElement).count, 1, "one for VoiceOver")
        for grip in bigGrips { XCTAssertTrue(player.bounds.contains(grip.frame), "inside the box") }
        player.onGrip?(.bottomRight, .began, .zero)
        player.onGrip?(.bottomRight, .changed, CGPoint(x: -20, y: -25))
        host.view.layoutIfNeeded()
        XCTAssertEqual(player.frame.width, big.width - 40)
        XCTAssertEqual(player.frame.midX, host.view.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(player.frame.minY, big.minY)
        XCTAssertEqual(dock.topInset(in: host.view), player.frame.height + 8, "the chat follows the live height")
        player.onGrip?(.bottomRight, .ended, CGPoint(x: -20, y: -25))
        XCTAssertEqual(LiveBrowserDock.kept(chat).width, big.width - 40)
        XCTAssertTrue(LiveBrowserDock.kept(chat).big)

        // ⤢ again: small's preset.
        player.onTap?()
        try await until { player.layer.animationKeys()?.isEmpty ?? true }
        host.view.layoutIfNeeded()
        XCTAssertEqual(player.frame, start)
        XCTAssertNil(LiveBrowserDock.kept(chat).width)
    }

    // MARK: A phone turned sideways

    /// The scene turned as the person turns the phone (the test asks; the
    /// app never does), and the window laid out at the new size.
    private func turn(_ window: UIWindow, to mask: UIInterfaceOrientationMask) async throws {
        let scene = try XCTUnwrap(window.windowScene)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in XCTFail("\(error)") }
        let wide = mask != .portrait
        try await until { (window.bounds.width > window.bounds.height) == wide }
        window.layoutIfNeeded()
    }

    private func turnUpright() {
        addTeardownBlock { @MainActor in
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene, scene.interfaceOrientation != .portrait else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            let deadline = ContinuousClock.now + .seconds(5)
            while scene.interfaceOrientation != .portrait, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        }
    }

    /// The views with `id` showing in `root`, nothing above them hidden.
    private func showing(_ id: String, in root: UIView) -> [UIView] {
        func walk(_ view: UIView) -> [UIView] {
            guard !view.isHidden, view.alpha > 0.01 else { return [] }
            return (view.accessibilityIdentifier == id ? [view] : []) + view.subviews.flatMap(walk)
        }
        return walk(root)
    }

    /// Upright: the header with its controls, no strip, the page's picture
    /// edge to edge under the header at the frame's aspect.
    private func assertUpright(_ page: LiveBrowserFullScreenItems, _ navigation: UINavigationController, dock: LiveBrowserDock,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        try await until { !page.stripShown && !navigation.isNavigationBarHidden && page.view.bounds.width < page.view.bounds.height }
        page.view.layoutIfNeeded()
        XCTAssertTrue(page.strip.isHidden, file: file, line: line)
        XCTAssertNotNil(page.navigationItem.leftBarButtonItems?.first { $0.accessibilityIdentifier == "live-browser-sleep" }, file: file, line: line)
        XCTAssertEqual(page.navigationItem.rightBarButtonItems?.first, page.control, file: file, line: line)
        let picture = try XCTUnwrap(page.browser?.view.frame, file: file, line: line)
        let width = page.view.bounds.width
        XCTAssertEqual(picture.minX, 0, file: file, line: line)
        XCTAssertEqual(picture.width, width, "edge to edge", file: file, line: line)
        XCTAssertGreaterThanOrEqual(picture.minY, page.view.safeAreaInsets.top, "under the header", file: file, line: line)
        XCTAssertEqual(picture.height, (width / (dock.frameAspect ?? 1.6)).rounded(), accuracy: 1, file: file, line: line)
    }

    /// Sideways: the header hidden, its controls once each in the strip at
    /// the trailing edge, the picture the whole height beside it.
    private func assertSideways(_ page: LiveBrowserFullScreenItems, _ navigation: UINavigationController, ids: [String],
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        try await until { page.stripShown && navigation.isNavigationBarHidden && page.view.bounds.width > page.view.bounds.height }
        page.view.layoutIfNeeded()
        XCTAssertFalse(page.strip.isHidden, file: file, line: line)
        let bounds = page.view.bounds
        let strip = page.strip.frame
        XCTAssertEqual(strip.maxX, bounds.width - page.view.safeAreaInsets.right, accuracy: 0.5, "at the trailing safe edge", file: file, line: line)
        let picture = try XCTUnwrap(page.browser?.view.frame, file: file, line: line)
        XCTAssertEqual(picture.height, bounds.height, "the picture has the height", file: file, line: line)
        XCTAssertLessThanOrEqual(picture.maxX, strip.minX, file: file, line: line)
        for id in ids {
            let found = showing(id, in: page.view)
            XCTAssertEqual(found.count, 1, "\(id) once", file: file, line: line)
            XCTAssertTrue(found.first?.isDescendant(of: page.strip) ?? false, "\(id) in the strip", file: file, line: line)
        }
    }

    /// The idiom is the device's, before the chat is in a window too, and
    /// an older "large" is a phone's big but an iPad's small.
    func testTheIdiomIsTheDevicesAndAnOlderLargeIsAPhonesBig() {
        let phone = UIDevice.current.userInterfaceIdiom == .phone && !ProcessInfo.processInfo.isiOSAppOnMac
        let host = UIViewController()
        let chat = UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "liveBrowserDock.\(chat)") }
        UserDefaults.standard.set("topLeft|large", forKey: "liveBrowserDock.\(chat)")
        let dock = LiveBrowserDock(host: host, chatKey: chat) { nil }
        XCTAssertNil(host.viewIfLoaded?.window)
        XCTAssertEqual(dock.isPhone, phone)
        XCTAssertEqual(LiveBrowserDock.kept(chat, phone: true).big, true)
        XCTAssertEqual(LiveBrowserDock.kept(chat, phone: false).big, false)
        XCTAssertEqual(LiveBrowserDock.kept(chat).corner, .topLeft)
    }

    func testOnAPhoneTheFrameViewTurnsWithTheDeviceToTheStrip() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        try XCTSkipUnless(dock.isPhone, "an iPhone's full screen; an iPad's and the Mac's are as they were")
        turnUpright()
        dock.update(link: LiveBrowserLink(id: id))
        try await until { dock.player != nil && dock.feed?.phase.state != nil }
        dock.presentFullScreen(taking: false)
        // It opens once the page is found: presented, then settled.
        try await until {
            guard let navigation = host.presentedViewController as? UINavigationController else { return false }
            return navigation.transitionCoordinator == nil
        }
        let navigation = try XCTUnwrap(host.presentedViewController as? UINavigationController)
        let frame = try XCTUnwrap(navigation.viewControllers.first as? LiveBrowserFullScreenItems)
        try await until { frame.isViewLoaded }
        XCTAssertFalse(frame.isNoVNC)
        // Nothing asks for a side: it turns as the phone does.
        XCTAssertTrue(navigation.supportedInterfaceOrientations.contains(.landscape))
        XCTAssertTrue(frame.supportedInterfaceOrientations.contains(.landscape))
        try await assertUpright(frame, navigation, dock: dock)
        try screenshot(window, name: "live-browser-phone-upright")

        try await turn(window, to: .landscapeRight)
        try await assertSideways(frame, navigation, ids: ["live-browser-minimize", "live-browser-end", "live-browser-sleep", "browser-reload", "live-browser-strip-yolo", "live-browser-control"])
        let control = try XCTUnwrap(showing("live-browser-control", in: frame.strip).first)
        XCTAssertEqual(control.accessibilityLabel, Strings.LiveBrowser.takeControl)
        try screenshot(window, name: "live-browser-phone-sideways")

        try await turn(window, to: .portrait)
        try await assertUpright(frame, navigation, dock: dock)
        dock.minimize()
        try await until { host.presentedViewController == nil }
    }

    func testOnAPhoneTakeControlTurnsWithTheDeviceToTheStrip() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        try XCTSkipUnless(dock.isPhone, "an iPhone's full screen; an iPad's and the Mac's are as they were")
        turnUpright()
        let (navigation, noVNC) = try await takeOver(host, daemon)
        XCTAssertTrue(noVNC.supportedInterfaceOrientations.contains(.landscape))
        try await assertUpright(noVNC, navigation, dock: dock)
        let back = showing("live-browser-back", in: noVNC.view)
        XCTAssertEqual(back.count, 1, "back on noVNC's own row")
        XCTAssertFalse(back.first?.isDescendant(of: noVNC.strip) ?? true)

        try await turn(window, to: .landscapeLeft)
        try await assertSideways(noVNC, navigation, ids: [
            "live-browser-minimize", "live-browser-end", "live-browser-sleep", "live-browser-back", "live-browser-forward",
            "live-browser-reload", "live-browser-viewer-menu", "live-browser-control",
        ])
        let release = try XCTUnwrap(showing("live-browser-control", in: noVNC.strip).first as? UIButton)
        XCTAssertEqual(release.accessibilityLabel, Strings.LiveBrowser.releaseControl)
        XCTAssertTrue(release.isEnabled)
        // noVNC still has every touch on its side.
        XCTAssertTrue(noVNC.holdsGestures)
        XCTAssertTrue(navigation.isModalInPresentation)
        try screenshot(window, name: "live-browser-phone-novnc-sideways")

        // Upright again: the header and noVNC's row are back.
        try await turn(window, to: .portrait)
        try await assertUpright(noVNC, navigation, dock: dock)
        XCTAssertEqual(showing("live-browser-back", in: noVNC.view).count, 1)

        // Release from the strip, sideways: back to the frame view, which
        // keeps the strip.
        try await turn(window, to: .landscapeRight)
        try await until { noVNC.stripShown }
        release.sendActions(for: .touchUpInside)
        try await until { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.id)/release HTTP/1.1") } }
        try await until { navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil }
        let frame = try XCTUnwrap(navigation.viewControllers.first as? LiveBrowserFullScreenItems)
        try await assertSideways(frame, navigation, ids: ["live-browser-control"])
        try await turn(window, to: .portrait)
        dock.minimize()
        try await until { host.presentedViewController == nil }
    }

    /// A phone's live page is its picture: the footer's Take control,
    /// Release and Sleep are the header's and the strip's, once each.
    func testOnAPhoneTheLivePageIsItsPictureAlone() async throws {
        let configuration = WKWebViewConfiguration()
        LiveBrowserDock.pictureOnly(in: configuration)
        let window = hostedKeyWindow(in: try await hostedActiveScene())
        defer { window.isHidden = true }
        // Under the header, as full screen places it: clear of the safe
        // area's top, which would otherwise come off the page's 100dvh.
        let web = WKWebView(frame: CGRect(x: 0, y: window.safeAreaInsets.top, width: 402, height: 251), configuration: configuration)
        window.addSubview(web)
        web.loadHTMLString("""
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body{margin:0;display:flex;flex-direction:column;min-height:100dvh} footer{display:flex}
            main{padding:12px} #box{width:100%;aspect-ratio:1.6;max-height:calc(100dvh - 170px);border:1px solid;border-radius:10px}</style>
            <header>Title</header><main><div id="box"></div></main>
            <footer><a id="take">Take control</a><button id="sleep">Sleep</button></footer>
            """, baseURL: nil)
        try await until { web.isLoading == false && web.url != nil }
        var result: [String]?
        try await until {
            result = try? await web.evaluateJavaScript("""
                [getComputedStyle(document.querySelector('footer')).display,
                 getComputedStyle(document.querySelector('header')).display,
                 String(Math.round(document.querySelector('#box').getBoundingClientRect().height))]
                """) as? [String]
            return result?.first == "none"
        }
        XCTAssertEqual(result, ["none", "none", "251"])
    }

    /// An iPad's and the Mac's live page loses only its footer: Take
    /// control, Release and Sleep are the header's. The page's header,
    /// its title and address, stays.
    func testOnAnIPadTheLivePageLosesOnlyItsFooter() async throws {
        let configuration = WKWebViewConfiguration()
        LiveBrowserDock.withoutFooter(in: configuration)
        let window = hostedKeyWindow(in: try await hostedActiveScene())
        defer { window.isHidden = true }
        let web = WKWebView(frame: CGRect(x: 0, y: window.safeAreaInsets.top, width: 820, height: 600), configuration: configuration)
        window.addSubview(web)
        web.loadHTMLString("""
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body{margin:0;display:flex;flex-direction:column;min-height:100dvh} header{display:flex} footer{display:flex}
            main{padding:12px} #box{width:100%;aspect-ratio:1.6;border:1px solid}</style>
            <header>Title</header><main><div id="box"></div></main>
            <footer><a id="take">Take control</a><button id="sleep">Sleep</button></footer>
            """, baseURL: nil)
        try await until { web.isLoading == false && web.url != nil }
        var result: [String]?
        try await until {
            result = try? await web.evaluateJavaScript("""
                [getComputedStyle(document.querySelector('footer')).display,
                 getComputedStyle(document.querySelector('header')).display,
                 getComputedStyle(document.querySelector('main')).paddingTop]
                """) as? [String]
            return result?.first == "none"
        }
        XCTAssertEqual(result, ["none", "flex", "12px"])
    }

    // MARK: Approvals and yolo

    /// An approval waits: the bar asks over the composer, with no alert
    /// and no player opened; Approve posts it, and the bar goes. In full
    /// screen the bar asks there too, the picture where it was.
    func testAnApprovalAsksInTheBarNotAnAlert() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching")
        await daemon.setLiveApproval("a1")
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id))
        try await until { dock.approvalBar.approval?.id == "a1" }
        host.view.layoutIfNeeded()
        let bar = dock.approvalBar
        XCTAssertNil(dock.player, "no player opened for it")
        XCTAssertNil(host.presentedViewController, "no alert")
        XCTAssertTrue(bar.isDescendant(of: host.view))
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.frame.minX, host.cardFrame.minX)
        XCTAssertEqual(bar.frame.width, host.cardFrame.width)
        XCTAssertLessThanOrEqual(bar.frame.maxY, host.line?.frame.minY ?? host.cardFrame.minY)
        XCTAssertFalse(bar.approve.isHidden)
        try screenshot(window, name: "live-browser-approval-bar-chat")

        // Full screen: the bar there too, clear of the picture upright on
        // a phone.
        dock.presentFullScreen(taking: false)
        try await until { (host.presentedViewController as? UINavigationController)?.viewControllers.first is LiveBrowserFullScreenItems }
        let navigation = try XCTUnwrap(host.presentedViewController as? UINavigationController)
        let items = try XCTUnwrap(navigation.viewControllers.first as? LiveBrowserFullScreenItems)
        try await until { navigation.transitionCoordinator == nil && items.isViewLoaded && items.approvalBar.approval?.id == "a1" }
        items.view.layoutIfNeeded()
        XCTAssertFalse(items.approvalBar.isHidden)
        XCTAssertTrue(items.approvalBar.isDescendant(of: items.view))
        XCTAssertLessThanOrEqual(items.approvalBar.frame.maxY, items.view.bounds.height - items.view.safeAreaInsets.bottom)
        try screenshot(window, name: "live-browser-approval-bar-full-screen")

        items.approvalBar.approve.sendActions(for: .touchUpInside)
        try await until { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.id)/approve HTTP/1.1") } }
        let body = await daemon.bodies.last { !$0.isEmpty && String(decoding: $0, as: UTF8.self).contains("approval_id") }
        XCTAssertEqual(body.map { String(decoding: $0, as: UTF8.self) }, #"{"approval_id":"a1"}"#)
        try await until { items.approvalBar.approval == nil && dock.approvalBar.approval == nil }
        navigation.dismiss(animated: false)
    }

    /// Yolo: the player's menu turns it on (`POST /auto`), the bridge's
    /// word is what shows ("Yolo" over the picture), and what it approves
    /// by itself is said for a moment in the bar.
    func testBrowserYoloIsTheBridgesAndSaysWhatItApproved() async throws {
        let daemon = BrowserDaemon()
        let (host, window) = try await makeHost(daemon)
        defer { window.isHidden = true; host.dock.update(link: nil) }
        let dock = host.dock!
        dock.update(link: LiveBrowserLink(id: id))
        try await until { dock.player != nil && dock.feed?.phase.state != nil }
        host.view.layoutIfNeeded()
        let player = try XCTUnwrap(dock.player)
        XCTAssertFalse(dock.yoloOn, "off by default")
        XCTAssertTrue(player.yoloBadge.isHidden)
        XCTAssertEqual(Strings.LiveBrowser.yoloMenu, "Yolo mode")
        XCTAssertEqual(Strings.LiveBrowser.yoloOn, "Yolo mode is on")
        XCTAssertEqual(Strings.LiveBrowser.yoloOff, "Yolo mode is off")
        XCTAssertEqual(Strings.LiveBrowser.yoloBadge, "Yolo")

        await daemon.setLiveApproval("a2")
        try await until { dock.approvalBar.approval?.id == "a2" }
        dock.setYolo(true)
        try await until { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.id)/auto HTTP/1.1") } }
        let body = await daemon.bodies.last { String(decoding: $0, as: UTF8.self).contains("\"on\"") }
        XCTAssertEqual(body.map { String(decoding: $0, as: UTF8.self) }, #"{"on":true}"#)
        let on = await daemon.liveAuto
        XCTAssertTrue(on)
        // On approves what waited: the bar goes; the badge shows.
        try await until { dock.yoloOn && dock.approvalBar.approval == nil && !player.yoloBadge.isHidden }
        XCTAssertEqual(player.yoloBadge.text, Strings.LiveBrowser.yoloBadge)

        await daemon.setLiveAutoApproved(#"[{"id":"a3","summary":"Click Save","at":2}]"#)
        try await until { dock.approvalBar.notice == Strings.LiveBrowser.yoloApproved("Click Save") }
        try screenshot(window, name: "live-browser-yolo-approved")

        dock.setYolo(false)
        try await until { !dock.yoloOn && player.yoloBadge.isHidden }
        let off = await daemon.liveAuto
        XCTAssertFalse(off)
    }

    // MARK: Helpers

    private func until(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
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
