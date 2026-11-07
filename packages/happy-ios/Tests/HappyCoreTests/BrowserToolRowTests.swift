import XCTest
import HappyWire
@testable import HappyCore

private let words = ToolActionWords(ran: "Ran", edited: "Edited", read: "Read", searched: "Searched", fetched: "Fetched", ranTask: "Ran task")

private func tool(_ name: String, _ input: JSONValue = .object([:]), state: ToolCall.State = .completed) -> ToolCall {
    ToolCall(name: name, state: state, input: input, createdAt: 0, description: nil, result: nil, permission: nil)
}

private func label(_ name: String, _ input: JSONValue = .object([:]), state: ToolCall.State = .completed) -> String {
    ChatToolDisplay.activityLabel(tool(name, input, state: state), words: words)
}

/// The live browser's tools (happy-browser-bridge's `browser_*`), under
/// whichever MCP prefix a harness gives them: a "Browser" row with a short
/// verb, never what was typed.
final class BrowserToolRowTests: XCTestCase {
    func testEveryPrefixIsTheBrowser() {
        for name in ["mcp__happy-browser-bridge__browser_observe", "mcp__browser__browser_observe", "happy-browser-bridge.browser_observe", "browser_observe"] {
            XCTAssertEqual(ChatToolDisplay.browserToolName(name), "browser_observe", name)
            XCTAssertEqual(ChatToolDisplay.displayTitle(tool(name), words: words), "Browser", name)
        }
        for name in ["mcp__linear__create_issue", "browser_", "Bash", "mcp__x__not_browser_observe"] {
            XCTAssertNil(ChatToolDisplay.browserToolName(name), name)
        }
    }

    func testTheRowIsACompactBrowserRow() {
        let presented = ChatToolPresentation.present(
            tool("mcp__happy-browser-bridge__browser_observe"), children: [], context: ToolContext(root: "/repo", flavor: nil, compactMode: false),
            state: ToolDisplayState(expanded: false), words: words
        )
        XCTAssertEqual(presented?.title, .literal("Browser"))
        XCTAssertEqual(presented?.icon, .browser)
        XCTAssertEqual(presented?.form, .compact)
        // Any other MCP tool keeps its own title.
        let other = ChatToolPresentation.present(
            tool("mcp__linear__create_issue"), children: [], context: ToolContext(root: "/repo", flavor: nil, compactMode: false),
            state: ToolDisplayState(expanded: false), words: words
        )
        XCTAssertEqual(other?.title, .literal("MCP: Linear Create Issue"))
        XCTAssertEqual(other?.icon, .mcp)
    }

    func testShortVerbs() {
        let p = "mcp__happy-browser-bridge__"
        XCTAssertEqual(label(p + "browser_create_session", ["start_url": "https://www.example.com/login"]), "Opened example.com")
        XCTAssertEqual(label(p + "browser_create_session"), "Opened the browser")
        XCTAssertEqual(label(p + "browser_execute_action", ["session_id": "s", "action": ["action": "navigate", "url": "https://news.example/a"]]), "Opened news.example")
        XCTAssertEqual(label(p + "browser_execute_action", ["action": ["action": "click", "label": "Sign in"]]), "Clicked Sign in")
        XCTAssertEqual(label(p + "browser_execute_action", ["action": ["action": "type", "label": "Search", "text": "my secret words"]]), "Typed in Search")
        XCTAssertEqual(label(p + "browser_execute_action", ["action": ["action": "type", "text": "my secret words"]]), "Typed")
        XCTAssertEqual(label(p + "browser_execute_action", ["action": ["action": "press", "key": "Enter"]]), "Pressed Enter")
        XCTAssertEqual(label(p + "browser_execute_action", ["action": ["action": "scroll"]]), "Scrolled")
        XCTAssertEqual(label(p + "browser_execute_action", ["action": ["action": "teleport"]]), "Used the page")
        XCTAssertEqual(label(p + "browser_observe"), "Looked at the page")
        XCTAssertEqual(label(p + "browser_screenshot"), "Looked at the page")
        XCTAssertEqual(label(p + "browser_login", ["secret": "github"]), "Signed in")
        XCTAssertEqual(label(p + "browser_fill_secret"), "Signed in")
        XCTAssertEqual(label(p + "browser_wait_for_human", state: .running), "Waiting for you…")
        XCTAssertEqual(label(p + "browser_wait_for_human"), "Waited for you")
        XCTAssertEqual(label(p + "browser_live_link"), "Shared the live view")
        XCTAssertEqual(label(p + "browser_list_secrets"), "Checked saved logins")
        XCTAssertEqual(label(p + "browser_close_session"), "Closed the browser")
        XCTAssertEqual(label(p + "browser_list_downloads"), "List Downloads")
    }

    func testRunningSaysWhatItIsDoing() {
        let p = "mcp__happy-browser-bridge__"
        let navigate: JSONValue = ["action": ["action": "navigate", "url": "https://www.example.com/a"]]
        XCTAssertEqual(label(p + "browser_execute_action", navigate, state: .running), "Opening example.com…")
        XCTAssertEqual(label(p + "browser_execute_action", navigate), "Opened example.com")
        XCTAssertEqual(label(p + "browser_execute_action", navigate, state: .error), "Opened example.com")
        XCTAssertEqual(label(p + "browser_create_session", state: .running), "Opening the browser…")
        XCTAssertEqual(label(p + "browser_create_session"), "Opened the browser")
        XCTAssertEqual(label(p + "browser_create_session", ["start_url": "https://news.example"], state: .running), "Opening news.example…")
        let click: JSONValue = ["action": ["action": "click", "label": "Send"]]
        XCTAssertEqual(label(p + "browser_execute_action", click, state: .running), "Clicking Send…")
        XCTAssertEqual(label(p + "browser_execute_action", click), "Clicked Send")
        XCTAssertEqual(label(p + "browser_execute_action", ["action": ["action": "type", "label": "Search"]], state: .running), "Typing in Search…")
        XCTAssertEqual(label(p + "browser_execute_action", ["action": ["action": "scroll"]], state: .running), "Scrolling…")
        XCTAssertEqual(label(p + "browser_observe", state: .running), "Looking at the page…")
        XCTAssertEqual(label(p + "browser_close_session", state: .running), "Closing the browser…")
        XCTAssertEqual(label(p + "browser_list_downloads", state: .running), "List Downloads")
    }

    func testTypedTextNeverShows() {
        let typed = label("mcp__happy-browser-bridge__browser_execute_action", ["action": ["action": "type", "label": "Password", "text": "hunter2"]])
        XCTAssertFalse(typed.contains("hunter2"))
    }
}
