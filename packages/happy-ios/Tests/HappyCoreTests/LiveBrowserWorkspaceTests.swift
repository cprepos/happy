import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

final class LiveBrowserWorkspaceTests: XCTestCase {
    /// prep-pro's real listing: one Happy Agent, two host workspaces, and
    /// neither names its computer; `compute` says only type and path.
    static let prepPro = #"""
    {"workspaces":[
      {"id":"happy","status":"active","orderKey":"a1","compute":{"type":"host","path":"/Users/cprepos/happy"}},
      {"id":"Home","status":"active","orderKey":"a0","compute":{"type":"host","path":"/Users/cprepos"}}
    ]}
    """#

    private func listing(_ json: String = LiveBrowserWorkspaceTests.prepPro) throws -> BrowserHostWorkspaces {
        try JSONDecoder().decode(BrowserHostWorkspaces.self, from: Data(json.utf8))
    }

    private func host(_ id: String, _ path: String?, order: String? = nil, status: String = "active", type: String = "host", runner: String? = nil) -> BrowserHostWorkspaces.Workspace {
        .init(id: id, status: status, orderKey: order, compute: .init(type: type, runnerId: runner, path: path))
    }

    func testTheChatsFolderPicksItsWorkspace() throws {
        let list = try listing()
        XCTAssertEqual(try list.pick(path: "/Users/cprepos/happy"), "happy")
        XCTAssertEqual(try list.pick(path: "/Users/cprepos/happy/.dev/worktree/x"), "happy")
        XCTAssertEqual(try list.pick(path: "/Users/cprepos/Downloads"), "Home")
        XCTAssertEqual(try list.pick(path: "/Users/cprepos"), "Home")
        XCTAssertEqual(try list.choose(path: "/Users/cprepos/Downloads").matched, true)
    }

    func testWholeFolderNamesOnly() throws {
        XCTAssertEqual(try listing().pick(path: "/Users/cprepos/happy2"), "Home", "happy2 is not inside happy")
        XCTAssertEqual(try listing().pick(path: "/Users/cprepos/happy2/src"), "Home")
    }

    func testATrailingSlashOrCaseStillMatches() throws {
        let list = try listing()
        XCTAssertEqual(try list.pick(path: "/Users/cprepos/happy/"), "happy")
        XCTAssertEqual(try list.pick(path: "/users/CPREPOS/Happy/sources"), "happy")
        XCTAssertEqual(try list.pick(path: "/Users/cprepos/./happy//x/../y"), "happy")
        let slashed = BrowserHostWorkspaces(workspaces: [host("home", "/Users/cprepos/"), host("happy", "/USERS/cprepos/HAPPY/")])
        XCTAssertEqual(try slashed.pick(path: "/Users/cprepos/happy"), "happy")
        XCTAssertEqual(try slashed.pick(path: "/Users/cprepos/Music"), "home")
    }

    func testNoMatchTakesTheFirstByOrderKey() throws {
        let list = try listing()
        let other = try list.choose(path: "/Volumes/data/project")
        XCTAssertEqual(other.id, "Home", "a0 is before a1")
        XCTAssertFalse(other.matched)
        XCTAssertEqual(try list.pick(path: nil), "Home")
        XCTAssertEqual(try list.pick(path: ""), "Home")
        let ties = BrowserHostWorkspaces(workspaces: [host("b", "/x"), host("a", "/y"), host("c", "/z", order: "0")])
        XCTAssertEqual(try ties.pick(path: "/elsewhere"), "a", "no order key sorts first, then by id")
    }

    func testNoCandidatesThrows() throws {
        let none = BrowserHostWorkspaces(workspaces: [
            host("r", "/Users/cprepos/happy", runner: "runner-1"),
            host("d", "/Users/cprepos/happy", type: "docker"),
            host("old", "/Users/cprepos/happy", status: "stopped"),
            host("nopath", nil),
        ])
        XCTAssertThrowsError(try none.pick(path: "/Users/cprepos/happy")) { XCTAssertEqual($0 as? BrowserError, .unavailable) }
        XCTAssertThrowsError(try BrowserHostWorkspaces(workspaces: []).pick(path: nil))
    }

    func testRunnerAndDockerWorkspacesAreExcluded() throws {
        let list = BrowserHostWorkspaces(workspaces: [
            host("runner", "/Users/cprepos/happy", order: "0", runner: "runner-1"),
            host("docker", "/Users/cprepos/happy", order: "0", type: "docker"),
            host("Home", "/Users/cprepos", order: "1"),
        ])
        XCTAssertEqual(try list.pick(path: "/Users/cprepos/happy"), "Home")
    }

    func testDecodesTheListing() throws {
        let json = #"{"workspaces":[{"id":"w","status":"active","compute":{"type":"host","path":"/p"},"extra":1}]}"#
        let list = try listing(json)
        XCTAssertEqual(list.workspaces.first?.compute.path, "/p")
        XCTAssertNil(list.workspaces.first?.orderKey)
    }

    // MARK: One route for links and the live view

    private actor PrepPro: AgentTransport {
        var paths: [String] = []
        func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) async throws -> HTTP1Response {
            paths.append(path)
            return HTTP1Response(status: 200, body: Data((path == "/v0/workspaces" ? LiveBrowserWorkspaceTests.prepPro : "{}").utf8))
        }
        func close() {}
    }

    private func session(_ id: String, path: String?) -> SessionRecord {
        var fields: [String: JSONValue] = ["host": .string("prep-pro"), "machineId": .string("m-pro")]
        if let path { fields["path"] = .string(path) }
        return SessionRecord(
            id: id, seq: 0, createdAt: 1, updatedAt: 100, active: true, activeAt: 100, projectId: nil,
            metadataVersion: 1, metadataCipher: "c", metadata: .object(fields), agentStateVersion: 1,
            agentStateCipher: "c", agentState: nil, dataKeyCipher: "key", decryptable: true)
    }

    func testLinksAndTheLiveViewShareTheRoute() async throws {
        let settings = LocalSettings(storage: InMemoryKeyValueStore())
        let computers = [LegacyLinkComputer(id: "air", name: "Prep Air"), LegacyLinkComputer(id: "pro", name: "Prep Pro")]
        let client = AgentClient(transport: PrepPro(), token: "t")
        for (path, expected) in [("/Users/cprepos/happy/.dev/worktree/x", "happy"), ("/Users/cprepos/Downloads", "Home")] {
            let record = session("s-\(expected)", path: path)
            let route = LegacyBrowserRoute.resolve(session: record, machine: nil, machines: [], computers: computers, settings: settings)
            guard case .computer(let id, let workspace) = route else { return XCTFail("\(route)") }
            XCTAssertEqual(id, "pro")
            XCTAssertEqual(workspace, LegacyBrowserWorkspace(sessionID: record.id, path: path))
            let found = try await workspace.find(client)
            XCTAssertEqual(found, expected)
        }
        // Not certain which computer: asked, and the folder still picks the
        // workspace on the one picked.
        let unnamed = session("s-ask", path: "/Users/cprepos/happy")
        var record = unnamed
        record.metadata = .object(["path": .string("/Users/cprepos/happy")])
        guard case .ask(let choices, let workspace) = LegacyBrowserRoute.resolve(session: record, machine: nil, machines: [], computers: computers, settings: settings) else { return XCTFail() }
        XCTAssertEqual(choices, computers)
        let found = try await workspace.find(client)
        XCTAssertEqual(found, "happy")
        guard case .unavailable = LegacyBrowserRoute.resolve(session: record, machine: nil, machines: [], computers: [], settings: settings) else { return XCTFail() }
    }

    // MARK: The chat's live link

    private func text(_ id: String, _ at: Int64, _ body: String, thinking: Bool = false) -> ChatMessage {
        .agentText(AgentTextMessage(id: id, createdAt: at, text: body, isThinking: thinking))
    }

    func testTheChatsNewestLinkIsItsLiveBrowser() {
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32), c = String(repeating: "c", count: 32)
        let messages: [ChatMessage] = [
            text("1", 1, "Watch: http://localhost:6090/live/\(a)"),
            text("2", 5, "Now http://localhost:6090/live/\(b)"),
            text("3", 9, "thinking http://localhost:6090/live/\(c)", thinking: true),
            .userText(UserTextMessage(id: "u", createdAt: 10, text: "http://localhost:6090/live/\(c)")),
            text("4", 11, "no link here"),
        ]
        let facts = ChatSnapshotFacts(LegacyChatSnapshot(sessionId: "s", messages: messages, isLoaded: true))
        XCTAssertEqual(facts.liveBrowser?.id, b)
        XCTAssertNil(ChatSnapshotFacts(LegacyChatSnapshot(sessionId: "s", messages: [text("1", 1, "hi")])).liveBrowser)
    }

    func testABrowserToolsResultIsTheLiveBrowserTooByWhenItCame() {
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        let result: JSONValue = .array([.object(["type": .string("text"), "text": .string("Live view of browser session s1: http://localhost:6090/live/\(b)")])])
        let call = ToolCallMessage(id: "t", createdAt: 6, tool: ToolCall(name: "mcp__happy-browser-bridge__browser_observe", state: .completed, input: .object([:]), createdAt: 6, completedAt: 7, result: result))
        let older = [text("1", 1, "Watch: http://localhost:6090/live/\(a)"), ChatMessage.toolCall(call), text("2", 8, "Looking.")]
        XCTAssertEqual(ChatSnapshotFacts(LegacyChatSnapshot(sessionId: "s", messages: older, isLoaded: true)).liveBrowser?.id, b)
        let newer = [ChatMessage.toolCall(call), text("1", 9, "Watch: http://localhost:6090/live/\(a)")]
        XCTAssertEqual(ChatSnapshotFacts(LegacyChatSnapshot(sessionId: "s", messages: newer, isLoaded: true)).liveBrowser?.id, a)
    }
}
