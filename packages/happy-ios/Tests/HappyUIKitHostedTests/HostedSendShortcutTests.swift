#if canImport(UIKit)
import Foundation
import HappyCore
@testable import HappyUI
import UIKit
import XCTest

/// ⌘↩ sends from every chat box, and only when its send would; a plain
/// Return is still a newline. The command is the one the box lists from
/// the text's place in the responder chain, sent the way a hardware
/// keyboard's press is: to the first responder that takes its action.
@MainActor
final class HostedSendShortcutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LegacyFonts.registerBundledFonts()
    }

    private final class Recorder: AgentInputCardDelegate {
        var primary = 0
        var send = 0
        func agentInputCardDidPressPrimary(_ card: AgentInputCardView) { primary += 1 }
        func agentInputCardDidPressSend(_ card: AgentInputCardView) { send += 1 }
    }

    /// What the sheet submitted, from whatever thread its submit runs on.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [JSONValue] = []
        func add(_ value: JSONValue) { lock.withLock { values.append(value) } }
        var count: Int { lock.withLock { values.count } }
    }

    private func window(_ root: UIViewController = UIViewController()) async throws -> UIWindow {
        let scene = try await hostedActiveScene()
        let previous = scene.keyWindow
        let window = hostedKeyWindow(in: scene, root: root)
        window.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            window.endEditing(true)
            window.isHidden = true
            previous?.makeKey()
        }
        return window
    }

    /// The ⌘↩ the first responder's chain lists, checked for what makes it
    /// beat the text view's own Return.
    private func command(from responder: UIResponder, file: StaticString = #filePath, line: UInt = #line) throws -> UIKeyCommand {
        var next: UIResponder? = responder
        while let current = next {
            if let found = current.keyCommands?.first(where: { $0.input == "\r" && $0.modifierFlags == .command }) {
                XCTAssertTrue(found.wantsPriorityOverSystemBehavior, "over the text view's newline", file: file, line: line)
                XCTAssertEqual(found.discoverabilityTitle, "Send", file: file, line: line)
                return found
            }
            next = current.next
        }
        return try XCTUnwrap(nil as UIKeyCommand?, "no ⌘↩ in the chain", file: file, line: line)
    }

    /// Presses ⌘↩ with `text` focused.
    private func commandReturn(in text: UIResponder, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(text.isFirstResponder, "the box has the keyboard", file: file, line: line)
        let command = try command(from: text, file: file, line: line)
        let action = try XCTUnwrap(command.action, file: file, line: line)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: nil, from: command, for: nil), "someone took it", file: file, line: line)
    }

    private func card(_ configuration: AgentInputCardConfiguration, in window: UIWindow) -> (AgentInputCardView, Recorder) {
        let recorder = Recorder()
        let card = AgentInputCardView(configuration: configuration)
        card.delegate = recorder
        let root = window.rootViewController!.view!
        root.addSubview(card)
        let width = root.bounds.width - 16
        card.frame = CGRect(x: 8, y: 200, width: width, height: card.height(fitting: width))
        card.layoutIfNeeded()
        return (card, recorder)
    }

    func testTheCardsRoundButtonSends() async throws {
        let window = try await window()
        let (card, recorder) = card(AgentInputCardConfiguration(placeholder: "Message"), in: window)
        XCTAssertTrue(card.textView.becomeFirstResponder())

        // Empty: the button is idle, and ⌘↩ does nothing.
        try commandReturn(in: card.textView)
        XCTAssertEqual(recorder.primary, 0)

        card.text = "Run the tests"
        card.configuration.primaryAction = .send
        try commandReturn(in: card.textView)
        XCTAssertEqual(recorder.primary, 1, "⌘↩ is the round button")

        card.configuration.isPrimaryBusy = true
        try commandReturn(in: card.textView)
        XCTAssertEqual(recorder.primary, 1, "not while a send is under way")
        card.configuration.isPrimaryBusy = false

        for action: AgentInputPrimaryAction in [.stop, .blocked, .voice] {
            card.configuration.primaryAction = action
            try commandReturn(in: card.textView)
            XCTAssertEqual(recorder.primary, 1, "not as \(action)")
        }

        card.configuration.primaryAction = .send
        card.textView.insertText("\n")
        XCTAssertEqual(card.text, "Run the tests\n", "Return is a newline")
        XCTAssertEqual(recorder.primary, 1)
    }

    func testTheFlatPanelSends() async throws {
        let window = try await window()
        let empty = AgentInputDesktopSend(hasText: false, hasComposerContent: false, isSendBlocked: false)
        let (card, recorder) = card(AgentInputCardConfiguration(placeholder: "Message", desktop: AgentInputDesktopConfiguration(send: empty)), in: window)
        XCTAssertTrue(card.textView.becomeFirstResponder())

        try commandReturn(in: card.textView)
        XCTAssertEqual(recorder.send, 0, "empty")

        card.text = "Run the tests"
        card.configuration.desktop?.send = AgentInputDesktopSend(hasText: true, hasComposerContent: true, isSendBlocked: false, isSending: true)
        try commandReturn(in: card.textView)
        XCTAssertEqual(recorder.send, 0, "a send under way")

        card.configuration.desktop?.send = AgentInputDesktopSend(hasText: true, hasComposerContent: true, isSendBlocked: false)
        try commandReturn(in: card.textView)
        XCTAssertEqual(recorder.send, 1, "⌘↩ is the panel's send")
        XCTAssertEqual(recorder.primary, 0)

        card.textView.insertText("\n")
        XCTAssertEqual(card.text, "Run the tests\n", "Return is a newline")
        XCTAssertEqual(recorder.send, 1)
    }

    func testTheFullScreenEditorSends() async throws {
        let editor = ComposerEditorViewController(text: "", selection: NSRange(location: 0, length: 0), keyboardTop: nil)
        var sent = 0
        editor.canSend = { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        editor.onSend = { sent += 1 }
        _ = try await window(editor)
        XCTAssertTrue(editor.textView.becomeFirstResponder())

        try commandReturn(in: editor.textView)
        XCTAssertEqual(sent, 0, "empty")

        editor.textView.insertText("Run the tests")
        editor.textView.insertText("\n")
        XCTAssertEqual(editor.textView.text, "Run the tests\n", "Return is a newline")
        XCTAssertEqual(sent, 0)

        try commandReturn(in: editor.textView)
        XCTAssertEqual(sent, 1, "⌘↩ sends the chat's text")
    }

    func testTheNewSessionPromptSends() async throws {
        let window = try await window()
        let composer = NewSessionComposerView(frame: .zero)
        var sent = 0
        composer.sendButton.addAction(UIAction { _ in sent += 1 }, for: .touchUpInside)
        let root = window.rootViewController!.view!
        root.addSubview(composer)
        composer.frame = CGRect(x: 8, y: 200, width: root.bounds.width - 16, height: 160)
        composer.layoutIfNeeded()
        XCTAssertTrue(composer.textView.becomeFirstResponder())

        composer.sendButton.canSend = false
        try commandReturn(in: composer.textView)
        XCTAssertEqual(sent, 0, "send can't be pressed")

        composer.textView.insertText("Fix the build")
        composer.sendButton.canSend = true
        composer.sendButton.isBusy = true
        try commandReturn(in: composer.textView)
        XCTAssertEqual(sent, 0, "a session is starting")

        composer.sendButton.isBusy = false
        composer.textView.insertText("\n")
        XCTAssertEqual(composer.textView.text, "Fix the build\n", "Return is a newline")
        XCTAssertEqual(sent, 0)

        try commandReturn(in: composer.textView)
        XCTAssertEqual(sent, 1, "⌘↩ is send's press")
    }

    func testTheAttachCaptionSends() async throws {
        let window = try await window()
        let panel = AttachMenuPanel(frame: .zero)
        var sent = 0
        panel.onSend = { sent += 1 }
        let root = window.rootViewController!.view!
        root.addSubview(panel)
        panel.frame = CGRect(x: 8, y: 200, width: root.bounds.width - 16, height: 200)
        panel.setPicking(true, animated: false)
        panel.layoutIfNeeded()
        XCTAssertTrue(panel.field.becomeFirstResponder())

        panel.field.insertText("Before and after")
        panel.field.insertText("\n")
        XCTAssertEqual(panel.field.text, "Before and after\n", "Return is a newline")
        XCTAssertEqual(sent, 0)

        try commandReturn(in: panel.field)
        XCTAssertEqual(sent, 1, "⌘↩ sends the picked pictures")
    }

    func testTheQuestionSheetSubmits() async throws {
        let agentState: JSONValue = .object([
            "communications": .object(["ask-1": .object([
                "kind": .string("form"), "createdAt": .number(1), "toolUseId": .string("call-1"),
                "form": .object(["questions": .array([.object([
                    "id": .string("q0"), "header": .string("Database"), "question": .string("Which one?"),
                    "options": .array([.object(["label": .string("Postgres")])]),
                    "multiSelect": .bool(false), "allowCustom": .bool(true),
                ])])]),
            ])]),
        ])
        let pending = try XCTUnwrap(AgentCommunications.pending(agentState).first)
        let answers = Answers()
        let sheet = AgentQuestionSheetController(pending: pending, submit: { answers.add($0) }, cancel: {})
        _ = try await window(sheet)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let input = try XCTUnwrap(descendants(sheet.view).compactMap { $0 as? UITextView }.first { $0.isEditable }, "the written answer")
        XCTAssertTrue(input.becomeFirstResponder())

        try commandReturn(in: input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(answers.count, 0, "nothing answered yet")

        input.insertText("MySQL")
        input.insertText("\n")
        XCTAssertEqual(input.text, "MySQL\n", "Return is a newline")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(answers.count, 0)

        try commandReturn(in: input)
        let deadline = ContinuousClock.now + .seconds(5)
        while answers.count == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(answers.count, 1, "⌘↩ is Submit Answer")
    }

    func testTheInlineQuestionFieldSubmits() async throws {
        let window = try await window()
        let field = ChatQuestionFieldView()
        let root = window.rootViewController!.view!
        root.addSubview(field)
        field.frame = CGRect(x: 8, y: 200, width: root.bounds.width - 16, height: 80)
        XCTAssertTrue(field.becomeFirstResponder())

        XCTAssertNil(field.keyCommands?.first { $0.input == "\r" }, "no ⌘↩ without a form to submit")

        var submitted = 0
        field.onSubmit = { submitted += 1 }
        field.insertText("MySQL")
        field.insertText("\n")
        XCTAssertEqual(field.text, "MySQL\n", "Return is a newline")
        XCTAssertEqual(submitted, 0)

        try commandReturn(in: field)
        XCTAssertEqual(submitted, 1, "⌘↩ is the form's Submit Answer")
    }
}
#endif
