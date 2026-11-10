#if canImport(UIKit)
@testable import HappyCore
@testable import HappyUI
import HappyLayout
import UIKit
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
            size: host.view.bounds.size, safeArea: LayoutInsets(host.view.safeAreaInsets), card: host.cardFrame, anchor: line.frame.minY
        ))
        XCTAssertEqual(player.frame, expected.frame)
        XCTAssertEqual(player.frame.maxX, host.cardFrame.maxX)
        XCTAssertEqual(player.frame.maxY, line.frame.minY - 8)
        if host.view.bounds.size == CGSize(width: 402, height: 874) {
            XCTAssertEqual(host.cardFrame, CGRect(x: 8, y: 784, width: 386, height: 56))
            XCTAssertEqual(player.frame, CGRect(x: 282, y: 612, width: 112, height: 144))
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
        XCTAssertEqual(noVNC.browser.originalURL.absoluteString, BrowserDaemon.chatNoVNC)
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
        var player = try XCTUnwrap(dock.player)
        // Behind the menu on the bar's left, beside close, away from Take
        // over; a phone's narrow player has it once it is made larger.
        if player.menuButton.isHidden {
            try XCTUnwrap(player.subviews.first { $0.accessibilityIdentifier == "live-browser-player-resize" } as? UIButton)
                .sendActions(for: .touchUpInside)
            host.view.layoutIfNeeded()
            player = try XCTUnwrap(dock.player)
        }
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
        // End at the left with Sleep beside it.
        XCTAssertEqual(frame.navigationItem.leftBarButtonItems?.suffix(2).map { $0 }, [frame.endItem, frame.sleepItem])
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
        try await until { dock.indicator.text == Strings.LiveBrowser.indicator(Strings.LiveBrowser.watching) }
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
