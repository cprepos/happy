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
    nonisolated private static func seed(_ store: LocalStore, id: String, live: String) throws {
        try SeededAccount.seed(store)
        guard var row = try store.sessions().first else { return }
        row.id = id
        row.seq = 1
        var fields = row.metadata?.objectValue ?? [:]
        fields["flavor"] = .string("codex")
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
    private func chat() async throws -> (LegacyChatViewController, UIWindow) {
        let controller = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil,
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: SessionBrowserOffline(), connector: SessionBrowserNoSocket()
        )
        try await controller.signIn(Credentials(token: "t", secret: Data(repeating: 13, count: 32)))
        let account = try XCTUnwrap(controller.session)
        let store = account.store
        let id = sessionId
        let live = "\(LiveBrowserLink.origin)/live/\(linkId)"
        try Self.seed(store, id: id, live: live)
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
}
#endif
