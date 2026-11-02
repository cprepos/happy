import XCTest
import HappyWire
@testable import HappyCore

// Expected values follow happy-app's InlineQuestionForm.tsx,
// AskUserQuestionView.tsx and RequestUserInputView.tsx.

private let input: JSONValue = ["questions": [
    ["question": "Which part?", "header": "Scope", "options": [["label": "List"], ["label": "Composer"]]],
]]
private let words = ToolActionWords(ran: "Ran", edited: "Edited", read: "Read", searched: "Searched", fetched: "Fetched", ranTask: "Ran task")

private func ask(_ state: ToolCall.State, permission: ToolPermission?) -> ToolCall {
    ToolCall(name: "AskUserQuestion", state: state, input: input, createdAt: 0, permission: permission)
}

private func communication(_ status: AgentFormCommunication.Status, allowCustom: Bool? = nil) -> AgentFormCommunication {
    AgentFormCommunication(
        id: "r1", toolUseId: "call-1",
        questions: [AgentQuestion(id: "q1", header: "Scope", question: "Which part?", options: [AgentQuestionOption(label: "List")], allowCustom: allowCustom)],
        status: status, answers: nil
    )
}

private let request = ToolCall(callId: "call-1", name: "request_user_input", state: .running, input: [:], createdAt: 0)

final class InlineQuestionAnsweringTests: XCTestCase {
    // MARK: Dismissing

    func testTheDismissReasonIsHappyAppsWordForWord() {
        // The agent reads this. The CLI's default refusal tells it to stop, so
        // a change here changes what a dismissed question does to the turn.
        XCTAssertEqual(
            InlineQuestionForm.dismissReason,
            "The user dismissed this question without answering it. Do not ask it again as-is: continue with your best judgement, or ask something more specific if you genuinely cannot proceed."
        )
    }

    func testADeniedAskUserQuestionIsDismissedNotAnswered() throws {
        for state in [ToolCall.State.running, .error, .completed] {
            let form = try XCTUnwrap(InlineQuestionForm.askUserQuestion(ask(state, permission: ToolPermission(id: "p", status: .denied))))
            XCTAssertTrue(form.dismissed, "\(state)")
            XCTAssertFalse(form.canInteract, "\(state)")
            XCTAssertNil(form.submitted, "\(state)")
        }
    }

    func testAnApprovedAskUserQuestionIsNotDismissed() throws {
        let form = try XCTUnwrap(InlineQuestionForm.askUserQuestion(ask(.completed, permission: ToolPermission(id: "p", status: .approved))))
        XCTAssertFalse(form.dismissed)
        XCTAssertEqual(form.submitted, [:])
    }

    func testACancelledCommunicationIsDismissed() throws {
        let cancelled = try XCTUnwrap(InlineQuestionForm.requestUserInput(request, communication: communication(.cancelled)))
        XCTAssertTrue(cancelled.dismissed)
        XCTAssertFalse(cancelled.canInteract)
        for status in [AgentFormCommunication.Status.pending, .answered] {
            XCTAssertEqual(InlineQuestionForm.requestUserInput(request, communication: communication(status))?.dismissed, false, "\(status)")
        }
    }

    func testADismissedQuestionStaysOpenUntilTheHeaderFoldsIt() throws {
        let tool = ask(.error, permission: ToolPermission(id: "p", status: .denied))
        func body(expanded: Bool, dismissed: Bool) throws -> ToolPresentation.Body {
            try XCTUnwrap(ChatToolPresentation.present(
                tool, children: [], context: ToolContext(root: "/repo", flavor: nil, compactMode: false),
                state: ToolDisplayState(expanded: expanded, questionDismissed: dismissed), words: words
            )).body
        }
        XCTAssertEqual(try body(expanded: false, dismissed: false), .none)
        XCTAssertNotEqual(try body(expanded: true, dismissed: false), .none)
        XCTAssertNotEqual(try body(expanded: false, dismissed: true), .none)
        XCTAssertEqual(try body(expanded: true, dismissed: true), .none)
    }

    // MARK: Live only once the permission has arrived

    func testAskUserQuestionIsLiveOnlyWithItsPermission() throws {
        let early = try XCTUnwrap(InlineQuestionForm.askUserQuestion(ask(.running, permission: nil)))
        XCTAssertFalse(early.canInteract)
        XCTAssertNil(early.reply)
        XCTAssertFalse(early.dismissed)
        let live = try XCTUnwrap(InlineQuestionForm.askUserQuestion(ask(.running, permission: ToolPermission(id: "p", status: .pending))))
        XCTAssertTrue(live.canInteract)
        XCTAssertEqual(live.reply, .permission(id: "p"))
    }

    func testWaitingForData() {
        let pending = ToolPermission(id: "p", status: .pending)
        XCTAssertTrue(InlineQuestionForm.isWaitingForData(ask(.running, permission: nil), agentState: nil))
        XCTAssertFalse(InlineQuestionForm.isWaitingForData(ask(.running, permission: pending), agentState: nil))
        XCTAssertFalse(InlineQuestionForm.isWaitingForData(ask(.completed, permission: nil), agentState: nil))
        XCTAssertFalse(InlineQuestionForm.isWaitingForData(ask(.error, permission: nil), agentState: nil))

        let raised: JSONValue = ["communications": ["r1": [
            "kind": "form", "toolUseId": "call-1",
            "form": ["questions": [["id": "q1", "header": "Scope", "question": "Which part?", "options": [["label": "List"]]]]],
        ]]]
        XCTAssertTrue(InlineQuestionForm.isWaitingForData(request, agentState: nil))
        XCTAssertTrue(InlineQuestionForm.isWaitingForData(request, agentState: ["communications": [:]]))
        XCTAssertFalse(InlineQuestionForm.isWaitingForData(request, agentState: raised))
        var finished = request
        finished.state = .completed
        XCTAssertFalse(InlineQuestionForm.isWaitingForData(finished, agentState: nil))

        // A tool that isn't a question never waits on one.
        let bash = ToolCall(callId: "call-1", name: "Bash", state: .running, input: [:], createdAt: 0)
        XCTAssertFalse(InlineQuestionForm.isWaitingForData(bash, agentState: nil))
    }

    // MARK: Written answers

    func testCommunicationQuestionsTakeWrittenAnswersUnlessTheySayNot() {
        XCTAssertEqual(InlineQuestionForm.requestUserInput(request, communication: communication(.pending))?.questions[0].allowCustom, true)
        XCTAssertEqual(InlineQuestionForm.requestUserInput(request, communication: communication(.pending, allowCustom: true))?.questions[0].allowCustom, true)
        XCTAssertEqual(InlineQuestionForm.requestUserInput(request, communication: communication(.pending, allowCustom: false))?.questions[0].allowCustom, false)
    }

    func testAskUserQuestionTakesNoWrittenAnswer() {
        let form = InlineQuestionForm.askUserQuestion(ask(.running, permission: ToolPermission(id: "p", status: .pending)))
        XCTAssertEqual(form?.questions[0].allowCustom, false)
    }

    func testAWrittenAnswerAnswersTheQuestion() {
        let open = InlineQuestion(id: "q", question: "?", header: "", options: [AgentQuestionOption(label: "A")], allowCustom: true)
        let closed = InlineQuestion(id: "q", question: "?", header: "", options: [AgentQuestionOption(label: "A")], allowCustom: false)

        XCTAssertFalse(InlineQuestionSelections().allAnswered([open]))
        XCTAssertFalse(InlineQuestionSelections(custom: ["q": "  \n "]).allAnswered([open]))
        XCTAssertTrue(InlineQuestionSelections(custom: ["q": "mine"]).allAnswered([open]))
        XCTAssertFalse(InlineQuestionSelections(custom: ["q": "mine"]).allAnswered([closed]))
    }

    func testWrittenIsTrimmedAndBlanksAreDropped() {
        let open = InlineQuestion(id: "a", question: "?", header: "", options: [], allowCustom: true)
        let blank = InlineQuestion(id: "b", question: "?", header: "", options: [], allowCustom: true)
        let closed = InlineQuestion(id: "c", question: "?", header: "", options: [], allowCustom: false)
        let selections = InlineQuestionSelections(custom: ["a": "  mine\n", "b": "   ", "c": "not asked for"])
        XCTAssertEqual(selections.written([open, blank, closed]), ["a": "mine"])
    }

    func testTheSummaryShowsLabelsThenTheWrittenAnswer() {
        let question = InlineQuestion(id: "q", question: "?", header: "", options: [AgentQuestionOption(label: "A"), AgentQuestionOption(label: "B")], multiSelect: true, allowCustom: true)
        var selections = InlineQuestionSelections(custom: ["q": "mine"])
        XCTAssertEqual(selections.shown([question]), ["q": ["mine"]])
        selections.toggle(question, option: 1)
        XCTAssertEqual(selections.shown([question]), ["q": ["B", "mine"]])
    }

    func testTheWrittenAnswerGoesInItsOwnField() {
        let single = InlineQuestion(id: "s", question: "?", header: "", options: [], allowCustom: true)
        let many = InlineQuestion(id: "m", question: "?", header: "", options: [], multiSelect: true, allowCustom: true)
        let skipped = InlineQuestion(id: "x", question: "?", header: "", options: [], required: false, allowCustom: true)
        XCTAssertEqual(
            InlineQuestionForm.communicationAnswers(
                [single, many, skipped],
                answers: ["s": ["A", "B"], "m": ["A", "B"]],
                written: ["s": "mine"]
            ),
            ["s": ["options": ["A"], "custom": "mine"], "m": ["options": ["A", "B"]]]
        )
        XCTAssertEqual(
            InlineQuestionForm.communicationAnswers([single], answers: [:], written: ["s": "mine"]),
            ["s": ["options": [], "custom": "mine"]]
        )
    }
}
