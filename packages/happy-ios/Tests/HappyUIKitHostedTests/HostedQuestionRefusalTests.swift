#if canImport(UIKit)
import Foundation
import HappyCore
import HappyStore
import HappyWire
@testable import HappyUI
import UIKit
import XCTest

private struct RefusalOffline: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
}

private struct RefusalNoSocket: WebSocketConnector {
    func connect(to url: URL) async throws -> WebSocketConnection { throw URLError(.notConnectedToInternet) }
}

/// An answer that didn't land says so, on the answer sheet and on the form in
/// the transcript, and leaves the form to answer again.
@MainActor
final class HostedQuestionRefusalTests: XCTestCase {
    private let reason = "This question is no longer waiting for an answer"

    private let agentState: JSONValue = .object([
        "communications": .object(["ask-1": .object([
            "kind": .string("form"), "createdAt": .number(1), "toolUseId": .string("call-1"),
            "form": .object(["questions": .array([.object([
                "id": .string("q0"), "header": .string("Database"), "question": .string("Which one?"),
                "options": .array([.object(["label": .string("Postgres")]), .object(["label": .string("SQLite")])]),
                "multiSelect": .bool(false), "allowCustom": .bool(false),
            ])])]),
        ])]),
    ])

    override func setUp() {
        super.setUp()
        LegacyFonts.registerBundledFonts()
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func control(_ view: UIView, sending action: String, target: UIViewController) throws -> UIControl {
        try XCTUnwrap(descendants(view).compactMap { $0 as? UIControl }.first {
            $0.actions(forTarget: target, forControlEvent: .touchUpInside)?.contains(action) == true
        }, action)
    }

    /// The sheet's real controls, with a submit that throws what
    /// `SessionActions` throws.
    private func sheet(submit: @escaping (JSONValue) async throws -> Void) async throws -> (UIWindow, AgentQuestionSheetController) {
        let pending = try XCTUnwrap(AgentCommunications.pending(agentState).first)
        let sheet = AgentQuestionSheetController(pending: pending, submit: submit, cancel: {})
        let scene = try await hostedActiveScene()
        let window = hostedKeyWindow(in: scene, root: sheet)
        window.layoutIfNeeded()
        try control(sheet.view, sending: "optionTapped:", target: sheet).sendActions(for: .touchUpInside)
        try control(sheet.view, sending: "submitTapped", target: sheet).sendActions(for: .touchUpInside)
        return (window, sheet)
    }

    func testTheSheetShowsTheAgentsWordsAndStaysOpen() async throws {
        let refusal = SessionActionError.failed(reason)
        let (window, sheet) = try await sheet { _ in throw refusal }
        defer { window.isHidden = true }
        try await until { sheet.errorText != nil }
        XCTAssertEqual(sheet.errorText, reason)
        XCTAssertNil(sheet.presentingViewController)
        XCTAssertTrue(try control(sheet.view, sending: "submitTapped", target: sheet).isEnabled, "it can be sent again")
    }

    func testTheSheetFallsBackWhenThereAreNoWords() async throws {
        let (window, sheet) = try await sheet { _ in throw SessionActionError.noAnswer }
        defer { window.isHidden = true }
        try await until { sheet.errorText != nil }
        XCTAssertEqual(sheet.errorText, Strings.AgentQuestion.submitFailed)
    }

    func testReasons() {
        XCTAssertEqual(QuestionAnswerFailure.reason(SessionActionError.failed(" Gone ")), "Gone")
        XCTAssertNil(QuestionAnswerFailure.reason(SessionActionError.failed("  ")))
        XCTAssertNil(QuestionAnswerFailure.reason(SessionActionError.notDecryptable))
        XCTAssertNil(QuestionAnswerFailure.reason(CancellationError()))
    }

    /// The real chat with a question in its transcript. This offline account
    /// can't seal the reply, so the answer fails as a refused one does in the
    /// chat: an alert, and the form back.
    func testTheTranscriptsFormSaysSoAndComesBack() async throws {
        let controller = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil,
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: RefusalOffline(), connector: RefusalNoSocket()
        )
        try await controller.signIn(Credentials(token: "t", secret: Data(repeating: 11, count: 32)))
        let account = try XCTUnwrap(controller.session)
        let store = account.store
        let state = agentState
        try await Task.detached { [store] in
            try SeededAccount.seed(store)
            guard var row = try store.sessions().first else { return }
            row.id = "asking"
            row.seq = 1
            row.agentState = state
            var fields = row.metadata?.objectValue ?? [:]
            fields["flavor"] = .string("opencode")
            row.metadata = .object(fields)
            try store.upsertSessions([row])
            let at = SeededAccount.base + 1000
            try store.applyMessagePage(sessionId: "asking", messages: [MessageRecord(
                id: "asking-m1", sessionId: "asking", seq: 1, localId: nil, createdAt: at, updatedAt: at, contentCipher: "harness",
                content: .object([
                    "role": .string("session"),
                    "content": .object([
                        "id": .string("asking-e1"), "time": .number(Double(at)), "role": .string("agent"), "turn": .string("asking-turn"),
                        "ev": .object([
                            "t": .string("tool-call-start"), "call": .string("call-1"), "name": .string("question"),
                            "title": .string("Question"), "description": .string("Which one?"), "args": .object([:]),
                        ]),
                    ]),
                ])
            )], syncedThrough: 1)
        }.value
        let context = AppContext(account: controller, variant: .production, version: "test")
        let chat = LegacyChatViewController(context: context, session: account, sessionId: "asking")
        let navigation = UINavigationController(rootViewController: chat)
        let scene = try await hostedActiveScene()
        let window = hostedKeyWindow(in: scene, root: navigation)
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        try await until { chat.contentInstalled && !chat.questionForms.isEmpty }
        let toolId = try XCTUnwrap(chat.questionForms.keys.first)
        let questionId = try XCTUnwrap(chat.questionForms[toolId]?.form.questions.first?.id)
        let list = try XCTUnwrap(descendants(chat.view).compactMap { $0 as? ChatListView }.first)
        list.ultra.onAction?(.questionOption(toolId: toolId, questionId: questionId, option: 0))
        list.ultra.onAction?(.questionSubmit(toolId: toolId))
        try await until { navigation.presentedViewController is UIAlertController }
        let alert = try XCTUnwrap(navigation.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, Strings.AgentQuestion.submitFailed)
        let draft = try XCTUnwrap(chat.questionDrafts[toolId])
        XCTAssertNil(draft.sent, "the form comes back to answer again")
        XCTAssertFalse(draft.submitting)
        XCTAssertTrue(draft.canInteract)
    }
}
#endif
