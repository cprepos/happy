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
        XCTAssertEqual(dock.indicator.frame, row.frame)
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
            XCTAssertEqual(player.frame, CGRect(x: 282, y: 656, width: 112, height: 100))
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
        try screenshot(window, name: "live-browser-dock-novnc")

        // Release control: the agent drives again, back to the player.
        dock.release(minimizing: true)
        try await until { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.id)/release HTTP/1.1") } }
        try await until { host.presentedViewController == nil }
        try await until { dock.indicator.text == Strings.LiveBrowser.indicator(Strings.LiveBrowser.watching) }
        XCTAssertNotNil(dock.player)
        XCTAssertEqual(dock.player?.accessibilityValue, "watching")
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

    func testAChatWithNoComputerSaysUnavailable() async throws {
        let host = Host()
        host.dock = LiveBrowserDock(host: host, chatKey: UUID().uuidString) { nil }
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: host)
        defer { window.isHidden = true }
        host.view.addSubview(host.dock.indicator)
        host.dock.setOnScreen(true)
        host.dock.update(link: LiveBrowserLink(id: id))
        try await until { host.dock.feed?.phase == .unavailable }
        XCTAssertEqual(host.dock.indicator.text, Strings.LiveBrowser.indicator(Strings.LiveBrowser.unavailableStatus))
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
