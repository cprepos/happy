import XCTest
@testable import HappyCore
import HappyWire

/// The chat's newest navigate (`LiveBrowserNavigate`): a navigate or a new
/// session whose result carries the live link, in a Happy CLI chat and an
/// agent-connection chat. Other actions, and results with no link, don't count.
final class LiveBrowserNavigateTests: XCTestCase {
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)
    private let bridge = "mcp__happy-browser-bridge__"

    private func result(_ id: String?) -> JSONValue {
        let text = id.map { "Live view of browser session s1: http://localhost:6090/live/\($0)" } ?? "Clicked."
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private func action(_ name: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["session_id": .string("s1"), "action": .object(["action": .string(name)].merging(extra) { $1 })])
    }

    private func call(_ id: String, _ at: Int64, _ name: String, _ input: JSONValue, link: String?) -> ChatMessage {
        .toolCall(ToolCallMessage(id: "m-\(id)", createdAt: at, tool: ToolCall(callId: id, name: name, state: .completed, input: input, createdAt: at, completedAt: at + 1, result: result(link))))
    }

    func testWhatCountsAsANavigate() {
        XCTAssertTrue(LiveBrowserNavigate.isNavigate(tool: bridge + "browser_execute_action", input: action("navigate", ["url": .string("https://example.com")])))
        XCTAssertTrue(LiveBrowserNavigate.isNavigate(tool: "happy-browser-bridge.browser_execute_action", input: action("navigate")))
        XCTAssertTrue(LiveBrowserNavigate.isNavigate(tool: "browser_execute_action", input: .object(["action": .string("navigate")])), "flat")
        XCTAssertTrue(LiveBrowserNavigate.isNavigate(tool: bridge + "browser_execute_action", input: .string(#"{"action":{"action":"navigate"}}"#)), "as JSON text")
        XCTAssertTrue(LiveBrowserNavigate.isNavigate(tool: bridge + "browser_create_session", input: .object([:])))
        for other in ["click", "type", "scroll", "go_back", "reload"] {
            XCTAssertFalse(LiveBrowserNavigate.isNavigate(tool: bridge + "browser_execute_action", input: action(other)), other)
        }
        XCTAssertFalse(LiveBrowserNavigate.isNavigate(tool: bridge + "browser_observe", input: .object([:])))
        XCTAssertFalse(LiveBrowserNavigate.isNavigate(tool: bridge + "browser_live_link", input: .object([:])))
        XCTAssertFalse(LiveBrowserNavigate.isNavigate(tool: "Bash", input: .object(["action": .string("navigate")])))
        XCTAssertFalse(LiveBrowserNavigate.isNavigate(tool: bridge + "browser_execute_action", input: nil))
        XCTAssertNil(LiveBrowserNavigate(id: "n", tool: bridge + "browser_execute_action", input: action("navigate"), result: result(nil)), "no link in its result")
        XCTAssertNil(LiveBrowserNavigate(id: "", tool: bridge + "browser_execute_action", input: action("navigate"), result: result(a)), "no id")
    }

    func testAHappyChatsNewestNavigate() {
        let messages: [ChatMessage] = [
            call("n1", 1, bridge + "browser_create_session", .object([:]), link: a),
            call("n2", 5, bridge + "browser_execute_action", action("navigate"), link: b),
            call("c1", 9, bridge + "browser_execute_action", action("click"), link: b),
            call("o1", 10, bridge + "browser_observe", .object(["session_id": .string("s1")]), link: b),
            call("n3", 11, bridge + "browser_execute_action", action("navigate"), link: nil),
        ]
        let facts = ChatSnapshotFacts(LegacyChatSnapshot(sessionId: "s", messages: messages, isLoaded: true))
        XCTAssertEqual(facts.liveNavigate?.id, "n2")
        XCTAssertEqual(facts.liveNavigate?.link.id, b)

        let none = ChatSnapshotFacts(LegacyChatSnapshot(sessionId: "s", messages: [call("c1", 1, bridge + "browser_execute_action", action("type"), link: a)], isLoaded: true))
        XCTAssertNil(none.liveNavigate)
        XCTAssertEqual(none.liveBrowser?.id, a, "its link still names the chat's browser")
    }

    func testAnAgentChatsNewestNavigate() {
        func tool(_ id: String, _ name: String, _ arguments: JSONValue, link: String?) -> ChatItem {
            ChatItem(id: "item-\(id)", role: .tool(ChatItem.Tool(name: name, status: "completed", callId: id, arguments: arguments, result: result(link))), pieces: [], delivery: .sent, turn: "r1")
        }
        var snapshot = ChatSnapshot()
        snapshot.items = [
            ChatItem(id: "u", role: .user, pieces: [.text("open example.com")], delivery: .sent),
            tool("n1", bridge + "browser_execute_action", action("navigate"), link: a),
            tool("n2", bridge + "browser_create_session", .object([:]), link: b),
            tool("c1", bridge + "browser_execute_action", action("click"), link: b),
            tool("n3", bridge + "browser_execute_action", action("navigate"), link: nil),
        ]
        XCTAssertEqual(snapshot.latestLiveNavigate, LiveBrowserNavigate(id: "n2", link: LiveBrowserLink(id: b)!))

        // A call with no id of its own goes by its item's.
        snapshot.items.append(tool("", bridge + "browser_execute_action", action("navigate"), link: a))
        XCTAssertEqual(snapshot.latestLiveNavigate?.id, "item-")

        snapshot.items = [tool("c1", bridge + "browser_execute_action", action("scroll"), link: a)]
        XCTAssertNil(snapshot.latestLiveNavigate)
    }
}
