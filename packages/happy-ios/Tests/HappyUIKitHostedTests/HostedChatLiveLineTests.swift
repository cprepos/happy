#if canImport(UIKit)
import Foundation
@testable import HappyCore
import HappyLayout
import HappyStore
import HappyWire
@testable import HappyUI
import UIKit
import UltraView
import XCTest

private struct LineOffline: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
}

private struct LineNoSocket: WebSocketConnector {
    func connect(to url: URL) async throws -> WebSocketConnection { throw URLError(.notConnectedToInternet) }
}

/// Agent `a` on a paired computer, with finished turns enough to scroll,
/// and the browser bridge behind its workspace (`BrowserDaemon`).
private actor LineComputer: AgentTransport {
    let daemon: BrowserDaemon
    let turns: Int
    /// The browser calls of a turn still running after the finished ones.
    var calls = 0

    init(daemon: BrowserDaemon, turns: Int) { self.daemon = daemon; self.turns = turns }

    func browserConnection() async throws -> any BrowserStream { try await daemon.browserConnection() }

    static func text(_ text: String) -> JSONValue { .object(["type": .string("text"), "text": .string(text)]) }

    static func message(_ id: String, role: String, _ content: [JSONValue]) -> JSONValue {
        .object(["id": .string(id), "role": .string(role), "createdAt": .number(1), "metadata": .object([:]), "content": .array(content)])
    }

    func setCalls(_ count: Int) { calls = count }

    static func call(_ index: Int) -> JSONValue {
        .object(["type": .string("tool_call"), "id": .string("live-\(index)"), "name": .string(index % 2 == 0 ? "mcp__happy-browser-bridge__browser_execute_action" : "mcp__happy-browser-bridge__browser_get_html"),
                 "status": .string("completed"), "arguments": .object(["session_id": .string("s1")]), "result": .object(["output": .string("ok")])])
    }

    /// The running turn's agent message, with `calls` browser calls.
    static func liveMessage(_ calls: Int) -> JSONValue {
        message("m-live", role: "agent", [text("Looking at the page.")] + (0..<calls).map(call))
    }

    private var live: JSONValue {
        .object(["id": .string("live"), "status": .string("running"), "startedAt": .number(1_000), "messages": .array([
            Self.message("u-live", role: "user", [Self.text("Read the page for me")]), Self.liveMessage(calls),
        ])])
    }

    private func run(_ index: Int) -> JSONValue {
        let id = "r\(index)"
        let answer = Array(repeating: "Turn \(index) looked at the page and found what it needed.", count: 3).joined(separator: " ")
        return .object([
            "id": .string(id), "status": .string("completed"), "startedAt": .number(1_000), "endedAt": .number(9_000), "reason": .string("completed"),
            "messages": .array([
                Self.message("u-\(id)", role: "user", [Self.text("Check the page, step \(index)")]),
                Self.message("m-\(id)", role: "agent", [Self.text(answer)]),
            ]),
        ])
    }

    func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) throws -> HTTP1Response {
        let value: JSONValue
        if path.contains("/agents/a/messages?") {
            value = .object(["hasMore": .bool(false), "runs": .array((0..<turns).map(run) + (calls > 0 ? [live] : []))])
        } else if path.hasSuffix("/agents/a/bootstrap") {
            value = .object(["agent": .object(["id": .string("a"), "workspaceId": .string("work1"), "status": .string(calls > 0 ? "working" : "idle")]), "pending": .array([])])
        } else if path.hasSuffix("/v0/agents/a") {
            value = .object(["agent": .object(["id": .string("a"), "workspaceId": .string("work1"), "status": .string("idle")])])
        } else {
            value = .object([:])
        }
        return .init(status: 200, body: try JSONEncoder().encode(value))
    }

    func close() {}
}

/// The red live-browser line over an agent chat's composer: the newest
/// row stands whole above it, with the keyboard up or down, and when the
/// line comes in under a transcript already showing its newest row.
@MainActor
final class HostedChatLiveLineTests: XCTestCase {
    private let link = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"

    private func session(_ computer: LineComputer) async throws -> Session {
        let controller = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil,
            agentTransport: { _ in computer },
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: LineOffline(), connector: LineNoSocket()
        )
        await controller.agentConnections.setForeground(false)
        let pairing = try await controller.agentConnections.add(
            JSONDecoder().decode(AgentConnectionCredentials.self, from: Data(#"{"address":"line-test","port":1,"deviceID":"\#(UUID().uuidString)","deviceToken":"token"}"#.utf8)),
            name: "Mac"
        )
        addTeardownBlock { @MainActor in
            Session.forget(pairing.id)
            try? await controller.agentConnections.remove(pairing.id)
        }
        let context = AppContext(account: controller, variant: .preview, version: "test")
        return try XCTUnwrap(Session.session(for: pairing.id, context: context))
    }

    private func open(_ session: Session, happySession: String? = nil) async throws -> (ChatViewController, UIWindow) {
        UserDefaults.standard.removeObject(forKey: "liveBrowserDock.agent.a")
        let chat = ChatViewController(session: session, agentId: "a", title: "Chief of Staff", spaceId: nil, intro: nil)
        chat.happySession = happySession
        let scene = try await hostedActiveScene()
        let window = hostedKeyWindow(in: scene, root: UINavigationController(rootViewController: chat))
        window.layoutIfNeeded()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return (chat, window)
    }

    private func until(_ what: String, _ seconds: Double = 8, _ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("never: \(what)", file: file, line: line)
    }

    private func find<View: UIView>(_ type: View.Type, in view: UIView) -> View? {
        if let found = view as? View { return found }
        for subview in view.subviews { if let found = find(type, in: subview) { return found } }
        return nil
    }

    private func indicator(in chat: ChatViewController) -> LiveBrowserIndicatorView? {
        find(LiveBrowserIndicatorView.self, in: chat.view)
    }

    /// The newest row on screen, in the chat's coordinates.
    private func newest(in chat: ChatViewController) -> CGRect? {
        guard let id = chat.plans.last?.id,
              let transcript = find(AgentChatUltraList.self, in: chat.view),
              let index = transcript.list.items.firstIndex(where: { $0.identity == "chat:row:\(id)" }),
              let row = transcript.list.loadedItemView(at: index) else { return nil }
        return row.convert(row.bounds, to: chat.view)
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
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
    }

    private func assertNewestClearsTheLine(_ chat: ChatViewController, _ when: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await until("the newest row on screen (\(when))") { newest(in: chat) != nil }
        let indicator = try XCTUnwrap(indicator(in: chat), file: file, line: line)
        XCTAssertFalse(indicator.isHidden, "the line shows (\(when))", file: file, line: line)
        let row = try XCTUnwrap(newest(in: chat), file: file, line: line)
        XCTAssertLessThanOrEqual(row.maxY, indicator.frame.minY + 0.5,
                                 "the newest row ends under the red line (\(when)): row \(row), line \(indicator.frame)", file: file, line: line)
    }

    /// An agent with a Happy session asks the bridge for its browser by
    /// that session's key, the one the bridge files it under; without one,
    /// by the agent's own.
    func testTheAgentPageAsksByItsHappySessionsKey() async throws {
        for happySession in ["happy-session-1", nil] {
            let daemon = BrowserDaemon()
            await daemon.setLiveStatus("watching"); await daemon.setChatLink(link)
            let session = try await session(LineComputer(daemon: daemon, turns: 1))
            let (chat, window) = try await open(session, happySession: happySession)
            let key = happySession.map { LiveBrowserLink.chatKey(happySession: $0) } ?? LiveBrowserLink.chatKey(agent: "a")
            XCTAssertEqual(chat.liveBrowserKey, key)
            XCTAssertEqual(chat.liveBrowserKey, LiveBrowserLink.chatKey(agent: "a", happySession: happySession))
            try await until("the bridge asked by \(happySession ?? "the agent")", 15) {
                await daemon.requests.contains { $0.hasPrefix("GET /live/chat/\(key)") }
            }
            try await until("the line", 15) { indicator(in: chat)?.isHidden == false }
            window.isHidden = true
        }
    }

    /// The bridge has the chat's link from the start.
    func testTheNewestRowStandsAboveTheLineWithAndWithoutTheKeyboard() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching"); await daemon.setChatLink(link)
        let session = try await session(LineComputer(daemon: daemon, turns: 8))
        let (chat, window) = try await open(session)
        try await until("the transcript") { chat.plans.count >= 16 }
        try await until("the line", 15) { indicator(in: chat)?.isHidden == false }
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        try await assertNewestClearsTheLine(chat, "keyboard down")
        try await keyboard(window, up: true)
        try await assertNewestClearsTheLine(chat, "keyboard up")
        try await keyboard(window, up: false)
        try await assertNewestClearsTheLine(chat, "keyboard down again")
    }

    /// The line comes in after the newest row is shown: the row moves up
    /// with it, rather than staying where it was, half under the line.
    func testALineThatComesInLaterPushesTheNewestRowUp() async throws {
        for keyboardUp in [false, true] {
            let daemon = BrowserDaemon()
            await daemon.setLiveStatus("watching")
            let session = try await session(LineComputer(daemon: daemon, turns: 8))
            let (chat, window) = try await open(session)
            try await until("the transcript") { chat.plans.count >= 16 }
            if keyboardUp { try await keyboard(window, up: true) }
            try await until("the newest row on screen") { newest(in: chat) != nil }
            XCTAssertTrue(indicator(in: chat)?.isHidden ?? true, "no link yet, no line")
            await daemon.setLiveStatus("watching"); await daemon.setChatLink(link)
            try await until("the line", 15) { indicator(in: chat)?.isHidden == false }
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            try await assertNewestClearsTheLine(chat, keyboardUp ? "came in with the keyboard up" : "came in with the keyboard down")
            if keyboardUp { try await keyboard(window, up: false) }
            window.isHidden = true
        }
    }

    /// A running turn's browser calls come in one by one, the line showing
    /// and the keyboard up, as the iPad had it: each newest call stands
    /// whole above the line.
    func testBrowserCallsComingInStayAboveTheLine() async throws {
        let daemon = BrowserDaemon()
        await daemon.setLiveStatus("watching"); await daemon.setChatLink(link)
        let computer = LineComputer(daemon: daemon, turns: 6)
        await computer.setCalls(1)
        let session = try await session(computer)
        let (chat, window) = try await open(session)
        try await until("the running turn") { chat.plans.contains { $0.id == "live-0" } }
        try await until("the line", 15) { indicator(in: chat)?.isHidden == false }
        try await keyboard(window, up: true)
        try await assertNewestClearsTheLine(chat, "first call")
        for count in 2...6 {
            await computer.setCalls(count)
            await session.store.externalEvent(.object(["type": .string("message.updated"), "payload": .object([
                "agentId": .string("a"), "runId": .string("live"), "message": LineComputer.liveMessage(count),
            ])]))
            try await until("call \(count)") { chat.plans.contains { $0.id == "live-\(count - 1)" } }
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            try await assertNewestClearsTheLine(chat, "call \(count), keyboard up")
        }
        try await keyboard(window, up: false)
        try await assertNewestClearsTheLine(chat, "keyboard down")
    }
}
#endif