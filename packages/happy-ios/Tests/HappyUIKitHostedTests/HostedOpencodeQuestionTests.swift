#if canImport(UIKit)
import HappyCore
import HappyWire
@testable import HappyUI
import XCTest

/// OpenCode's `question` tool reaches the answer form the chat already has.
final class HostedOpencodeQuestionTests: XCTestCase {
    private let agentState: JSONValue = .object([
        "communications": .object(["ask-1": .object([
            "kind": .string("form"), "createdAt": .number(1), "toolUseId": .string("call-1"),
            "form": .object(["questions": .array([.object([
                "id": .string("q0"), "header": .string("Database"), "question": .string("Which one?"),
                "options": .array([.object(["label": .string("Postgres")]), .object(["label": .string("SQLite")])]),
                "multiSelect": .bool(false), "allowCustom": .bool(true),
            ])])]),
        ])]),
    ])

    func testTheQuestionToolRoutesToItsCommunicationsForm() throws {
        let tool = ToolCall(callId: "call-1", name: "question", state: .running, input: .object([:]), createdAt: 0)
        let form = try XCTUnwrap(ChatRows.questionForm(tool, agentState: agentState))
        XCTAssertEqual(form.questions.map(\.question), ["Which one?"])
        XCTAssertEqual(form.reply, .communication(id: "ask-1", kind: "form"))
        XCTAssertTrue(form.canInteract)
    }

    func testACardWithoutItsCommunicationHasNoForm() {
        let tool = ToolCall(callId: "other", name: "question", state: .running, input: .object([:]), createdAt: 0)
        XCTAssertNil(ChatRows.questionForm(tool, agentState: agentState))
    }
}
#endif
