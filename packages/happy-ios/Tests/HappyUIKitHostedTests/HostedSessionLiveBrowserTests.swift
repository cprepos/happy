#if canImport(UIKit)
import Foundation
@testable import HappyCore
import HappyLayout
import HappyStore
import HappyWire
@testable import HappyUI
import UIKit
import XCTest

private struct SessionBrowserOffline: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
}

private struct SessionBrowserNoSocket: WebSocketConnector {
    func connect(to url: URL) async throws -> WebSocketConnection { throw URLError(.notConnectedToInternet) }
}

/// A happy-cli session's live browser, as on an agent's chat: the tool row
/// whose result links it carries the chip, and the red line stands on the
/// composer's card, the keyboard up or down.
@MainActor
final class HostedSessionLiveBrowserTests: XCTestCase {
    private let sessionId = "browsing"
    private let linkId = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"

    override func setUp() {
        super.setUp()
        LegacyFonts.registerBundledFonts()
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func until(_ what: String, seconds: Double = 10, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "never: \(what)", file: file, line: line)
    }

    nonisolated private static func event(_ id: String, at: Int64, _ ev: JSONValue) -> JSONValue {
        .object([
            "role": .string("session"),
            "content": .object([
                "id": .string(id), "time": .number(Double(at)), "role": .string("agent"), "turn": .string("browse-turn"), "ev": ev,
            ]),
        ])
    }

    /// The seeded account's first session as `id`, a codex one whose agent
    /// called the bridge's browser_live_link and got the live view back.
    /// `path`, when given, is the folder it runs in, on prep-pro (a machine
    /// the store doesn't have, so its recorded host names it).
    nonisolated private static func seed(_ store: LocalStore, id: String, live: String, flavor: String = "codex", path: String? = nil) throws {
        try SeededAccount.seed(store)
        guard var row = try store.sessions().first else { return }
        row.id = id
        row.seq = 1
        var fields = row.metadata?.objectValue ?? [:]
        fields["flavor"] = .string(flavor)
        if let path {
            fields["path"] = .string(path)
            fields["host"] = .string("prep-pro")
            fields["machineId"] = .string("machine-prep-pro")
        }
        row.metadata = .object(fields)
        try store.upsertSessions([row])
        let at = SeededAccount.base + 1000
        let events: [JSONValue] = [
            Self.event("browse-e1", at: at, .object([
                "t": .string("tool-call-start"), "call": .string("call-1"), "name": .string("mcp__happy-browser-bridge__browser_live_link"),
                "title": .string("browser_live_link"), "description": .string(""), "args": .object(["session_id": .string("s1")]),
            ])),
            Self.event("browse-e2", at: at + 1, .object([
                "t": .string("tool-call-end"), "call": .string("call-1"), "result": .string("Live view: \(live)"),
            ])),
        ]
        let messages = events.enumerated().map { index, content in
            MessageRecord(
                id: "browse-m\(index)", sessionId: id, seq: index + 1, localId: nil, createdAt: at + Int64(index), updatedAt: at + Int64(index),
                contentCipher: "harness", content: content
            )
        }
        try store.applyMessagePage(sessionId: id, messages: messages, syncedThrough: messages.count)
    }

    /// A session whose agent opened the browser and shared its live view.
    /// With `computer`, prep-pro is paired, answering as `computer` does,
    /// and the session runs in `path` on it.
    private func chat(computer: BrowserDaemon? = nil, flavor: String = "codex", path: String? = nil) async throws -> (LegacyChatViewController, UIWindow) {
        let controller = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil,
            agentConnectionCredentialStore: InMemoryAgentConnectionCredentialStore(),
            agentTransport: { [computer] _ in computer ?? BrowserDaemon() },
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: SessionBrowserOffline(), connector: SessionBrowserNoSocket()
        )
        try await controller.signIn(Credentials(token: "t", secret: Data(repeating: 13, count: 32)))
        if computer != nil {
            await controller.agentConnections.setForeground(false)
            let pairing = try await controller.agentConnections.add(
                JSONDecoder().decode(AgentConnectionCredentials.self, from: Data(#"{"address":"prep-pro-test","port":1,"deviceID":"\#(UUID().uuidString)","deviceToken":"token"}"#.utf8)),
                name: "prep-pro"
            )
            addTeardownBlock { @MainActor in Session.forget(pairing.id) }
        }
        let account = try XCTUnwrap(controller.session)
        let store = account.store
        let id = sessionId
        let live = "\(LiveBrowserLink.origin)/live/\(linkId)"
        try Self.seed(store, id: id, live: live, flavor: flavor, path: path)
        let context = AppContext(account: controller, variant: .production, version: "test")
        let chat = LegacyChatViewController(context: context, session: account, sessionId: id)
        let navigation = UINavigationController(rootViewController: chat)
        let scene = try await hostedActiveScene()
        let window = hostedKeyWindow(in: scene, root: navigation)
        addTeardownBlock { @MainActor in
            chat.liveBrowserDock?.update(link: nil)
            window.isHidden = true
        }
        window.layoutIfNeeded()
        try await until("the transcript") { chat.contentInstalled }
        return (chat, window)
    }

    private func screenshot(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["HAPPY_PREVIEW_DIR"] {
            try image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func keyboard(_ window: UIWindow, up: Bool) async throws {
        let bounds = window.screen.bounds
        let shown = CGRect(x: 0, y: bounds.maxY - 336, width: bounds.width, height: 336)
        let hidden = shown.offsetBy(dx: 0, dy: 336)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
            UIResponder.keyboardFrameBeginUserInfoKey: NSValue(cgRect: up ? hidden : shown),
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: up ? shown : hidden),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
            UIResponder.keyboardAnimationCurveUserInfoKey: 7,
        ])
        if !up { NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil) }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        window.layoutIfNeeded()
    }

    /// The browser tool's row is a "Browser" row, and carries the live
    /// view's chip under it.
    func testTheToolRowThatLinksTheBrowserCarriesItsChip() async throws {
        let (chat, window) = try await chat()
        try await until("the chip") { descendants(chat.view).contains { $0 is LiveBrowserChipView } }
        let chip = try XCTUnwrap(descendants(chat.view).compactMap { $0 as? LiveBrowserChipView }.first)
        XCTAssertEqual(chip.link?.id, linkId)
        XCTAssertEqual(chip.bounds.height, LiveBrowserChipView.height)
        XCTAssertFalse(chip.isHidden)
        XCTAssertEqual(descendants(chat.view).filter { $0 is LiveBrowserChipView }.count, 1, "one chip for one browser")
        try screenshot(window, name: "session-live-browser-chip")
    }

    /// The red line stands on the composer's card, its dot at the card's
    /// right edge, outside the composer: with the keyboard down, up, and
    /// down again.
    func testTheRedLineStandsOnTheComposersCard() async throws {
        let (chat, window) = try await chat()
        let dock = try XCTUnwrap(chat.liveBrowserDock)
        let link = try XCTUnwrap(LiveBrowserLink(id: linkId))
        dock.update(link: link)
        let composer = try XCTUnwrap(descendants(chat.view).compactMap { $0 as? SessionComposerView }.first)
        let indicator = dock.indicator
        XCTAssertFalse(descendants(composer).contains { $0 === indicator }, "the line is no longer inside the composer")

        for (when, up) in [("keyboard down", false), ("keyboard up", true), ("keyboard down again", false)] {
            if when != "keyboard down" { try await keyboard(window, up: up) }
            try await until("the line (\(when))") { chat.view.layoutIfNeeded(); return !indicator.isHidden && indicator.window != nil }
            try await Task.sleep(for: .milliseconds(300))
            chat.view.layoutIfNeeded()
            let line = indicator.convert(indicator.bounds, to: chat.view)
            let card = composer.convert(composer.liveBrowserAnchor.card, to: chat.view)
            XCTAssertEqual(line.height, 20, accuracy: 0.5, when)
            XCTAssertEqual(line.maxY, card.minY, accuracy: 0.5, "the line stands on the card (\(when)): line \(line), card \(card)")
            XCTAssertEqual(line.maxX, card.maxX, accuracy: 0.5, "the line ends at the card's right edge (\(when))")
            XCTAssertGreaterThanOrEqual(line.minX, card.minX - 0.5, when)
            try screenshot(window, name: "session-live-browser-line-\(up ? "keyboard" : "down")")
        }
    }

    // MARK: The workspace the chat runs in

    /// prep-pro as its Happy Agent lists it: two host workspaces, `happy`
    /// and `Home`, neither naming its computer, beside a runner's and a
    /// container's that cover the same folders and are never used.
    nonisolated static let prepProWorkspaces = #"""
    {"workspaces":[
      {"id":"runnerws","status":"active","orderKey":"0","compute":{"type":"host","runnerId":"r1","path":"/Users/cprepos/happy"}},
      {"id":"dockerws","status":"active","orderKey":"0","compute":{"type":"docker","path":"/Users/cprepos/happy"}},
      {"id":"happyws","status":"active","orderKey":"a1","compute":{"type":"host","path":"/Users/cprepos/happy"}},
      {"id":"homews","status":"active","orderKey":"a2","compute":{"type":"host","path":"/Users/cprepos"}}
    ]}
    """#

    /// The bridge's per-chat noVNC, served under the live origin.
    private var bridgeNoVNC: String {
        "http://localhost:6090/live/\(linkId)/vnc/vnc.html?autoconnect=true&resize=remote&path=live/\(linkId)/vnc/websockify#password=s3cr%2Bt"
    }

    private func prepPro() async -> BrowserDaemon {
        let daemon = BrowserDaemon()
        await daemon.setNodeName("prep-pro")
        await daemon.setWorkspaces(Self.prepProWorkspaces)
        await daemon.setChatLink(linkId)
        await daemon.setTakeNoVNC(bridgeNoVNC)
        return daemon
    }

    /// The mini view: the bridge is asked for the chat's browser by its
    /// key, and the feed's frames come, both through `workspace`.
    private func miniView(_ chat: LegacyChatViewController, _ daemon: BrowserDaemon, through workspace: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let key = LiveBrowserLink.chatKey(happySession: sessionId)
        try await waitFor("the lookup", file: file, line: line) { await daemon.requests.contains { $0.hasPrefix("GET /live/chat/\(key)") } }
        try await waitFor("a frame", file: file, line: line) { await daemon.requests.contains { $0.hasPrefix("GET /live/\(self.linkId)/frame.jpg") } }
        let tunnelled = await daemon.tunnelledWorkspaces
        XCTAssertEqual(tunnelled, [workspace], file: file, line: line)
        XCTAssertNotNil(chat.liveBrowserDock?.feed, file: file, line: line)
    }

    /// A tapped link opens through `workspace`, and the browser goes back.
    private func tapLink(_ chat: LegacyChatViewController, _ daemon: BrowserDaemon, through workspace: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let list = try XCTUnwrap(descendants(chat.view).compactMap { $0 as? ChatListView }.first, file: file, line: line)
        chat.chatList(list, openLink: "http://localhost:5173/")
        let navigation = try XCTUnwrap(chat.navigationController, file: file, line: line)
        try await waitFor("the browser", file: file, line: line) { navigation.topViewController is BrowserViewController }
        try await waitFor("the page", file: file, line: line) { await daemon.pageHeads.contains { $0.host == "localhost:5173" } }
        let tunnelled = await daemon.tunnelledWorkspaces
        XCTAssertEqual(tunnelled, [workspace], "the link goes the live view's way", file: file, line: line)
        navigation.popViewController(animated: false)
        try await waitFor("back on the chat", file: file, line: line) { navigation.topViewController === chat }
    }

    private func waitFor(_ what: String, seconds: Double = 15, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("never: \(what)", file: file, line: line)
        throw BrowserError.timeout
    }

    /// A session under ~/happy on prep-pro: the mini view, a link, Take
    /// control and Release all go through `happy`, for every flavor.
    func testASessionInHappyGoesThroughHappysWorkspace() async throws {
        for flavor in ["claude", "codex", "gemini", "opencode"] {
            let daemon = await prepPro()
            let (chat, window) = try await chat(computer: daemon, flavor: flavor, path: "/Users/cprepos/happy/.dev/worktree/bright-bridge")
            defer { window.isHidden = true }
            try await miniView(chat, daemon, through: "happyws")
            try await tapLink(chat, daemon, through: "happyws")

            // Take control: `/take`, then noVNC at the bridge's address,
            // through the same workspace.
            let dock = try XCTUnwrap(chat.liveBrowserDock)
            dock.presentFullScreen(taking: true)
            try await waitFor("take (\(flavor))") { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.linkId)/take HTTP/1.1") } }
            let presenter: UIViewController = chat.navigationController ?? chat
            try await waitFor("noVNC (\(flavor))") { (presenter.presentedViewController as? UINavigationController)?.viewControllers.count == 2 }
            let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
            let noVNC = try XCTUnwrap(navigation.viewControllers.last as? LiveBrowserFullScreenItems)
            XCTAssertTrue(noVNC.isNoVNC)
            XCTAssertEqual(noVNC.browser.originalURL.absoluteString, bridgeNoVNC, "the address the bridge answered, port and all")
            try await waitFor("the noVNC page (\(flavor))") { await daemon.pageHeads.contains { $0.line.contains("/live/\(self.linkId)/vnc/vnc.html") } }
            let tunnelled = await daemon.tunnelledWorkspaces
            XCTAssertEqual(tunnelled, ["happyws"], flavor)
            if flavor == "claude" { try screenshot(window, name: "session-live-browser-novnc") }

            // Release: the agent drives again.
            dock.release()
            try await waitFor("release (\(flavor))") { await daemon.requests.contains { $0.hasPrefix("POST /live/\(self.linkId)/release HTTP/1.1") } }
            try await waitFor("back to the frames (\(flavor))") { navigation.viewControllers.count == 1 }
            dock.minimize()
            try await waitFor("minimized (\(flavor))") { presenter.presentedViewController == nil }
            let after = await daemon.tunnelledWorkspaces
            XCTAssertEqual(after, ["happyws"], flavor)
            dock.update(link: nil)
        }
    }

    /// A session in ~/Downloads is under no project but Home's folder: its
    /// mini view and its links go through `Home`.
    func testASessionInDownloadsGoesThroughHome() async throws {
        let daemon = await prepPro()
        let (chat, window) = try await chat(computer: daemon, path: "/Users/cprepos/Downloads")
        defer { window.isHidden = true }
        try await miniView(chat, daemon, through: "homews")
        try await tapLink(chat, daemon, through: "homews")
    }
}
#endif
