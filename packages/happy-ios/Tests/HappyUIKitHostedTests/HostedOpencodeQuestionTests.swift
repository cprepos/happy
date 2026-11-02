#if canImport(UIKit)
import HappyCore
import HappyWire
@testable import HappyUI
import XCTest

/// OpenCode's `question` tool reaches the answer form the chat already has.
final class HostedOpencodeQuestionTests: XCTestCase {
    private let agentState: JSONValue = [
        "communications": ["ask-1": [
            "kind": "form", "createdAt": 1, "toolUseId": "call-1",
            "form": ["questions": [[
                "id": "q0", "header": "Database", "question": "Which one?",
                "options": [["label": "Postgres"], ["label": "SQLite"]],
                "multiSelect": .bool(false), "allowCustom": .bool(true),
            ]]],
        ]],
    ]

    func testTheQuestionToolRoutesToItsCommunicationsForm() throws {
        let tool = ToolCall(callId: "call-1", name: "question", state: .running, input: [:], createdAt: 0)
        let form = try XCTUnwrap(ChatRows.questionForm(tool, agentState: agentState))
        XCTAssertEqual(form.questions.map(\.question), ["Which one?"])
        XCTAssertEqual(form.reply, .communication(id: "ask-1", kind: "form"))
        XCTAssertTrue(form.canInteract)
    }

    func testACardWithoutItsCommunicationHasNoForm() {
        let tool = ToolCall(callId: "other", name: "question", state: .running, input: [:], createdAt: 0)
        XCTAssertNil(ChatRows.questionForm(tool, agentState: agentState))
    }
}
#endif
