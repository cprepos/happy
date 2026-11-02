import HappyWire
import XCTest
@testable import HappyCore

/// OpenCode's questions, in the shape happy-cli's opencodeQuestionBridge
/// writes them to agent state and its event mapper writes the tool call.
final class OpencodeQuestionTests: XCTestCase {
    private let question: JSONValue = [
        "id": "q0", "header": "Database", "question": "Which one?",
        "options": [["label": "Postgres"], ["label": "SQLite", "description": "One file"]],
        "multiSelect": .bool(false), "allowCustom": .bool(true),
    ]

    private func state(_ communication: JSONValue) -> JSONValue {
        ["communications": ["ask-1": communication]]
    }

    private func tool(_ state: ToolCall.State = .running, input: JSONValue = [:]) -> ToolCall {
        ToolCall(callId: "call-1", name: "question", state: state, input: input, createdAt: 0)
    }

    func testAFollowedSessionsQuestionIsAnsweredOnItsCard() throws {
        let agentState = state(["kind": "form", "createdAt": 1, "toolUseId": "call-1", "form": ["questions": [question]]])
        let pending = try XCTUnwrap(AgentCommunications.pending(agentState).first)
        XCTAssertNil(pending.inTranscript)
        XCTAssertTrue(AgentCommunications.canRenderInline(pending))
        XCTAssertFalse(AgentCommunications.usesFallback(pending))

        let communication = AgentCommunications.form(agentState, toolUseId: "call-1")
        let form = try XCTUnwrap(InlineQuestionForm.requestUserInput(tool(), communication: communication))
        XCTAssertTrue(form.canInteract)
        XCTAssertEqual(form.questions.map(\.id), ["q0"])
        XCTAssertEqual(form.reply, .communication(id: "ask-1", kind: "form"))
    }

    /// A sub-agent's question has no card: only the banner can show it.
    func testAQuestionOutOfTheTranscriptGoesToTheBanner() throws {
        let agentState = state(["kind": "form", "createdAt": 1, "inTranscript": .bool(false), "form": ["questions": [question]]])
        let pending = try XCTUnwrap(AgentCommunications.pending(agentState).first)
        XCTAssertEqual(pending.inTranscript, false)
        XCTAssertFalse(AgentCommunications.canRenderInline(pending))
        XCTAssertTrue(AgentCommunications.usesFallback(pending))
    }

    func testOtherFormsStayInline() throws {
        let agentState = state(["kind": "form", "createdAt": 1, "inTranscript": .bool(true), "form": ["questions": [question]]])
        XCTAssertTrue(AgentCommunications.canRenderInline(try XCTUnwrap(AgentCommunications.pending(agentState).first)))
    }

    /// The bridge's answer goes back by its own question ids.
    func testAnAnswerIsSentByQuestionId() throws {
        let agentState = state(["kind": "form", "createdAt": 1, "toolUseId": "call-1", "form": ["questions": [question]]])
        let communication = AgentCommunications.form(agentState, toolUseId: "call-1")
        let form = try XCTUnwrap(InlineQuestionForm.requestUserInput(tool(), communication: communication))
        let answers = InlineQuestionForm.communicationAnswers(form.questions, answers: ["q0": ["SQLite"]])
        XCTAssertEqual(answers, ["q0": AgentQuestionAnswer(options: ["SQLite"]).json])
    }

    func testAnAnsweredOneShowsItsAnswer() throws {
        let agentState: JSONValue = [
            "communications": [:],
            "completedCommunications": ["ask-1": [
                "kind": "form", "toolUseId": "call-1", "status": "answered",
                "form": ["questions": [question]], "answers": ["q0": ["options": ["Postgres"]]],
            ]],
        ]
        let communication = AgentCommunications.form(agentState, toolUseId: "call-1")
        let form = try XCTUnwrap(InlineQuestionForm.requestUserInput(tool(.completed), communication: communication))
        XCTAssertFalse(form.canInteract)
        XCTAssertEqual(form.submitted, ["q0": ["Postgres"]])
    }

    func testTheToolIsAnInteractiveQuestion() {
        XCTAssertTrue(ChatToolDisplay.isInteractiveQuestion("question"))
        XCTAssertEqual(ToolViewKind(toolName: "question"), .requestUserInput)
        XCTAssertFalse(ChatToolDisplay.usesCompactRow(tool(), compactMode: true))
    }

    func testTheCardReadsLikeHappyApps() throws {
        let one: JSONValue = ["questions": [["header": "Database", "question": "Which one?", "options": [], "multiple": .bool(false), "custom": .bool(true)]]]
        XCTAssertEqual(ChatToolPresentation.knownTitle(tool(input: one), root: nil), .literal("Database"))
        XCTAssertEqual(ChatToolPresentation.subtitle(tool(input: one), root: nil), .literal("Which one?"))

        let two: JSONValue = ["questions": [["header": "A", "question": "a?"], ["header": "B", "question": "b?"]]]
        XCTAssertEqual(ChatToolPresentation.subtitle(tool(input: two), root: nil), .multipleQuestions(2))

        XCTAssertEqual(ChatToolPresentation.knownTitle(tool(input: [:]), root: nil), .name(.question))
        XCTAssertNil(ChatToolPresentation.subtitle(tool(input: ["questions": []]), root: nil))
    }

    func testAQuestionsCardHasNoSpinner() throws {
        XCTAssertTrue(ChatToolPresentation.noStatusNames.contains("question"))
    }

    func testItIsAKnownTool() {
        XCTAssertTrue(ChatToolPresentation.knownNames.contains("question"))
    }
}
