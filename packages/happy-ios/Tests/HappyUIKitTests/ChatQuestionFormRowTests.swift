#if canImport(UIKit)
@testable import HappyCore
import HappyLayout
@testable import HappyUI
import HappyWire
import UIKit
import XCTest

/// What an inline question form draws in its row: the X, the field for a
/// written answer, "Dismissed", and the loader before its data arrives.
@MainActor
final class ChatQuestionFormRowTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        LegacyFonts.registerBundledFonts()
    }

    private let questions: JSONValue = .object(["questions": .array([.object([
        "question": .string("Which build?"), "header": .string("Build"),
        "options": .array([.object(["label": .string("Debug")]), .object(["label": .string("Release")])]),
    ])])])

    private func ask(permission: ToolPermission?, state: ToolCall.State = .running) -> ToolCall {
        ToolCall(name: "AskUserQuestion", state: state, input: questions, createdAt: 0, permission: permission)
    }

    private var request: ToolCall {
        ToolCall(callId: "call-1", name: "request_user_input", state: .running, input: .object([:]), createdAt: 0)
    }

    private func plan(_ call: ToolCall, _ change: (inout ChatRowInput) -> Void = { _ in }) -> ChatRowPlan {
        var input = ChatRowInput(item: .message(.toolCall(ToolCallMessage(id: "t", createdAt: 0, tool: call))), style: ChatRowStyle(render: .isolated()))
        change(&input)
        return ChatRowRenderer.plan(input, width: 393)
    }

    private func strings(_ plan: ChatRowPlan) -> [String] {
        plan.items.compactMap { item in
            if case .text(let layout, _) = item { return layout.string.string }
            return nil
        }
    }

    private func dismisses(_ plan: ChatRowPlan) -> Bool {
        plan.hits.contains { hit in
            if case .questionDismiss(toolId: "t") = hit.action { return true }
            return false
        }
    }

    private func fields(_ plan: ChatRowPlan) -> [ChatQuestionField] {
        plan.items.compactMap { item in
            if case .embed(.questionField(let field), _) = item { return field }
            return nil
        }
    }

    private func communicationForm(status: AgentFormCommunication.Status = .pending, allowCustom: Bool? = nil) -> InlineQuestionForm? {
        InlineQuestionForm.requestUserInput(request, communication: AgentFormCommunication(
            id: "r1", toolUseId: "call-1",
            questions: [AgentQuestion(id: "q1", header: "Build", question: "Which build?", options: [AgentQuestionOption(label: "Debug")], allowCustom: allowCustom)],
            status: status, answers: nil
        ))
    }

    func testALiveFormHasItsX() {
        let call = ask(permission: ToolPermission(id: "p", status: .pending))
        let live = plan(call) { $0.question = InlineQuestionForm.askUserQuestion(call).map { ChatQuestionState(form: $0) } }
        XCTAssertTrue(dismisses(live))
        // The X's hit comes first: its slop may reach over the form.
        if case .questionDismiss = live.hits.first?.action {} else { XCTFail("\(String(describing: live.hits.first?.action))") }
    }

    func testAFormWithoutItsPermissionOffersNothing() {
        let call = ask(permission: nil)
        let early = plan(call) { $0.question = InlineQuestionForm.askUserQuestion(call).map { ChatQuestionState(form: $0) } }
        XCTAssertFalse(dismisses(early))
        XCTAssertFalse(strings(early).contains(ChatWords.english.submitAnswer))
        XCTAssertTrue(strings(early).contains("Which build?"))
    }

    func testASubmittingFormsXTakesNoTap() {
        let call = ask(permission: ToolPermission(id: "p", status: .pending))
        let busy = plan(call) { input in
            var state = InlineQuestionForm.askUserQuestion(call).map { ChatQuestionState(form: $0) }
            state?.submitting = true
            input.question = state
        }
        XCTAssertFalse(dismisses(busy))
    }

    func testADeniedQuestionSaysDismissedAndNothingElse() {
        let call = ask(permission: ToolPermission(id: "p", status: .denied), state: .error)
        let dismissed = plan(call) { $0.question = InlineQuestionForm.askUserQuestion(call).map { ChatQuestionState(form: $0) } }
        XCTAssertTrue(strings(dismissed).contains(ChatWords.english.questionDismissed))
        // The card's header keeps the question as its subtitle, as ToolView
        // does (knownTools' `extractSubtitle`); the card under it drops it
        // and its options.
        XCTAssertEqual(strings(dismissed).filter { $0 == "Which build?" }.count, 1)
        XCTAssertFalse(strings(dismissed).contains("Debug"))
        XCTAssertFalse(strings(dismissed).contains("Release"))
        XCTAssertFalse(strings(dismissed).contains(ChatWords.english.submitAnswer))
        XCTAssertFalse(strings(dismissed).contains("—"))
        XCTAssertFalse(dismisses(dismissed))
    }

    func testDismissedFromHereSaysSoBeforeTheAgentDoes() {
        let call = ask(permission: ToolPermission(id: "p", status: .pending))
        let dismissed = plan(call) { input in
            var state = InlineQuestionForm.askUserQuestion(call).map { ChatQuestionState(form: $0) }
            state?.dismissedHere = true
            input.question = state
        }
        XCTAssertTrue(strings(dismissed).contains(ChatWords.english.questionDismissed))
    }

    func testAQuestionThatTakesWritingHasItsField() {
        let call = request
        let form = communicationForm()
        let open = plan(call) { $0.question = form.map { ChatQuestionState(form: $0) } }
        XCTAssertEqual(fields(open).map(\.questionId), ["q1"])
        XCTAssertEqual(fields(open).first?.placeholder, ChatWords.english.ownAnswerPlaceholder)

        let closed = communicationForm(allowCustom: false)
        XCTAssertEqual(fields(plan(call) { $0.question = closed.map { ChatQuestionState(form: $0) } }), [])

        let asked = ask(permission: ToolPermission(id: "p", status: .pending))
        XCTAssertEqual(fields(plan(asked) { $0.question = InlineQuestionForm.askUserQuestion(asked).map { ChatQuestionState(form: $0) } }), [])
    }

    func testTheRowGrowsWithWhatIsWritten() throws {
        let call = request
        let form = try XCTUnwrap(communicationForm())
        let short = plan(call) { $0.question = ChatQuestionState(form: form) }
        let tall = plan(call) { input in
            var state = ChatQuestionState(form: form)
            state.selections.custom["q1"] = "one\ntwo\nthree\nfour\n"
            input.question = state
        }
        XCTAssertGreaterThan(tall.size.height, short.size.height)
        XCTAssertEqual(fields(tall).first?.text, "one\ntwo\nthree\nfour\n")
    }

    func testTheLoaderSaysSoWhileTheFormIsOnItsWay() {
        let waiting = plan(request) { $0.questionLoading = true }
        XCTAssertTrue(strings(waiting).contains(ChatWords.english.loadingQuestion))
        XCTAssertTrue(waiting.items.contains { if case .spinner = $0 { return true } else { return false } })
    }
}
#endif
