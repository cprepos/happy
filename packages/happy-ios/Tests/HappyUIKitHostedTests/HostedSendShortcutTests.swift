#if canImport(UIKit)
import Foundation
import HappyCore
import HappyWire
@testable import HappyUI
import UIKit
import XCTest

/// A hardware keyboard's Return in every chat box. With Enter to send on
/// (the default), ↩ sends, only when the box's send would, and ⇧↩, ⌘↩ and
/// ⌃↩ make a new line at the cursor; with it off, ↩ isn't a command (the
/// text view types it), ⌘↩ sends and ⌃↩ is a new line. While an input
/// method is composing, no box takes any of them, so the key goes on to the
/// text. A command is the one the box lists from the text's place in the
/// responder chain, sent the way a hardware keyboard's press is: to the
/// first responder that takes its action.
@MainActor
final class HostedSendShortcutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LegacyFonts.registerBundledFonts()
        let saved = SendShortcut.enterToSend
        SendShortcut.enterToSend = true
        addTeardownBlock { @MainActor in SendShortcut.enterToSend = saved }
    }

    private final class Recorder: AgentInputCardDelegate {
        var primary = 0
        var send = 0
        /// An open suggestion list: Return picks.
        var picks = false
        var picked = 0
        func agentInputCardDidPressPrimary(_ card: AgentInputCardView) { primary += 1 }
        func agentInputCardDidPressSend(_ card: AgentInputCardView) { send += 1 }
        func agentInputCardShouldInsertNewline(_ card: AgentInputCardView) -> Bool {
            guard picks else { return true }
            picked += 1
            return false
        }
    }

    /// What the sheet submitted, from whatever thread its submit runs on.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [JSONValue] = []
        func add(_ value: JSONValue) { lock.withLock { values.append(value) } }
        var count: Int { lock.withLock { values.count } }
    }

    /// A box with the keyboard: its text, and how many times it has sent.
    private struct Box {
        let text: UITextView
        let sent: () -> Int
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

    /// The ↩ with `flags` the first responder's chain lists, if any.
    private func find(_ flags: UIKeyModifierFlags, from responder: UIResponder) -> UIKeyCommand? {
        var next: UIResponder? = responder
        while let current = next {
            if let found = current.keyCommands?.first(where: { $0.input == "\r" && $0.modifierFlags == flags }) { return found }
            next = current.next
        }
        return nil
    }

    /// The ↩ with `flags`, checked for what makes it beat the text view's
    /// own Return.
    private func command(_ flags: UIKeyModifierFlags, from responder: UIResponder, file: StaticString = #filePath, line: UInt = #line) throws -> UIKeyCommand {
        let found = try XCTUnwrap(find(flags, from: responder), "no ↩ \(flags.rawValue) in the chain", file: file, line: line)
        XCTAssertTrue(found.wantsPriorityOverSystemBehavior, "over the text view's newline", file: file, line: line)
        return found
    }

    /// Presses ↩ with `flags` and `text` focused.
    private func press(_ flags: UIKeyModifierFlags, in text: UIResponder, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(text.isFirstResponder, "the box has the keyboard", file: file, line: line)
        let command = try command(flags, from: text, file: file, line: line)
        let action = try XCTUnwrap(command.action, file: file, line: line)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: nil, from: command, for: nil), "someone took it", file: file, line: line)
    }

    /// ↩ alone.
    private func returnKey(in text: UIResponder, file: StaticString = #filePath, line: UInt = #line) throws {
        try press([], in: text, file: file, line: line)
    }

    /// What every box does with the keys short of sending, which each box's
    /// own test covers: the list's names, a new line at the cursor from
    /// each newline key, nothing taken while an input method composes, and
    /// the keys with Enter to send off. `text` holds something sendable.
    private func checkKeys(_ box: Box, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = box.text
        let sent = box.sent()
        SendShortcut.enterToSend = true
        XCTAssertEqual(try command([], from: text, file: file, line: line).discoverabilityTitle, "Send", file: file, line: line)
        XCTAssertEqual(try command(.shift, from: text, file: file, line: line).discoverabilityTitle, "New line", file: file, line: line)
        XCTAssertNil(try command(.command, from: text, file: file, line: line).discoverabilityTitle, "listed once, as ⇧↩", file: file, line: line)
        XCTAssertNil(try command(.control, from: text, file: file, line: line).discoverabilityTitle, file: file, line: line)

        for flags: UIKeyModifierFlags in [.shift, .command, .control] {
            text.text = "ab"
            text.selectedRange = NSRange(location: 1, length: 0)
            try press(flags, in: text, file: file, line: line)
            XCTAssertEqual(text.text, "a\nb", "↩ \(flags.rawValue) is a new line at the cursor", file: file, line: line)
            XCTAssertEqual(text.selectedRange, NSRange(location: 2, length: 0), file: file, line: line)
        }
        XCTAssertEqual(box.sent(), sent, "no newline key sends", file: file, line: line)

        // Mid-composition the box takes none of them: the key goes on to the
        // text, whose input method confirms with it.
        text.selectedRange = NSRange(location: (text.text as NSString).length, length: 0)
        text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(text.markedTextRange, file: file, line: line)
        for flags: UIKeyModifierFlags in [[], .shift, .command, .control] {
            let command = try command(flags, from: text, file: file, line: line)
            let action = try XCTUnwrap(command.action, file: file, line: line)
            XCTAssertNil(text.target(forAction: action, withSender: command), "↩ \(flags.rawValue) passes on to the input method", file: file, line: line)
            XCTAssertFalse(UIApplication.shared.sendAction(action, to: nil, from: command, for: nil), file: file, line: line)
        }
        text.unmarkText()
        XCTAssertNil(text.markedTextRange, file: file, line: line)
        XCTAssertEqual(box.sent(), sent, "nothing sent mid-composition", file: file, line: line)

        // Off: ↩ and ⇧↩ are the text view's again, ⌘↩ is Send and ⌃↩ a line.
        SendShortcut.enterToSend = false
        XCTAssertNil(find([], from: text), "↩ is typed", file: file, line: line)
        XCTAssertNil(find(.shift, from: text), file: file, line: line)
        XCTAssertEqual(try command(.command, from: text, file: file, line: line).discoverabilityTitle, "Send", file: file, line: line)
        text.text = "ab"
        text.selectedRange = NSRange(location: 1, length: 0)
        try press(.control, in: text, file: file, line: line)
        XCTAssertEqual(text.text, "a\nb", "⌃↩ is a new line", file: file, line: line)
        XCTAssertEqual(box.sent(), sent, file: file, line: line)
        SendShortcut.enterToSend = true
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

        // Empty: the button is idle, and ↩ does nothing, not even a line.
        try returnKey(in: card.textView)
        XCTAssertEqual(recorder.primary, 0)
        XCTAssertEqual(card.text, "")

        card.text = "Run the tests"
        card.configuration.primaryAction = .send
        try checkKeys(Box(text: card.textView, sent: { recorder.primary }))

        card.text = "Run the tests"
        card.configuration.isPrimaryBusy = true
        try returnKey(in: card.textView)
        XCTAssertEqual(recorder.primary, 0, "not while a send is under way")
        card.configuration.isPrimaryBusy = false

        for action: AgentInputPrimaryAction in [.stop, .blocked, .voice] {
            card.configuration.primaryAction = action
            try returnKey(in: card.textView)
            XCTAssertEqual(recorder.primary, 0, "not as \(action)")
        }

        card.configuration.primaryAction = .send
        try returnKey(in: card.textView)
        XCTAssertEqual(recorder.primary, 1, "↩ is the round button")
        XCTAssertEqual(card.text, "Run the tests", "and types nothing")

        SendShortcut.enterToSend = false
        try press(.command, in: card.textView)
        XCTAssertEqual(recorder.primary, 2, "with Enter to send off, ⌘↩ is")

        // The on-screen keyboard's Return arrives as text: a newline.
        card.textView.insertText("\n")
        XCTAssertEqual(card.text, "Run the tests\n", "a typed Return is a newline")
        XCTAssertEqual(recorder.primary, 2)
    }

    func testAnOpenSuggestionListTakesReturnFirst() async throws {
        let window = try await window()
        let (card, recorder) = card(AgentInputCardConfiguration(placeholder: "Message"), in: window)
        XCTAssertTrue(card.textView.becomeFirstResponder())
        card.text = "/com"
        card.configuration.primaryAction = .send

        recorder.picks = true
        try returnKey(in: card.textView)
        XCTAssertEqual(recorder.picked, 1, "↩ picks the suggestion")
        XCTAssertEqual(recorder.primary, 0, "and doesn't send")
        XCTAssertEqual(card.text, "/com")

        // ⇧↩ is a new line whatever the list: it never asks.
        card.textView.selectedRange = NSRange(location: 4, length: 0)
        try press(.shift, in: card.textView)
        XCTAssertEqual(card.text, "/com\n")
        XCTAssertEqual(recorder.picked, 1)

        recorder.picks = false
        try returnKey(in: card.textView)
        XCTAssertEqual(recorder.primary, 1, "with the list closed, ↩ sends")
    }

    func testTheFlatPanelSends() async throws {
        let window = try await window()
        let empty = AgentInputDesktopSend(hasText: false, hasComposerContent: false, isSendBlocked: false)
        let (card, recorder) = card(AgentInputCardConfiguration(placeholder: "Message", desktop: AgentInputDesktopConfiguration(send: empty)), in: window)
        XCTAssertTrue(card.textView.becomeFirstResponder())

        try returnKey(in: card.textView)
        XCTAssertEqual(recorder.send, 0, "empty")

        card.text = "Run the tests"
        card.configuration.desktop?.send = AgentInputDesktopSend(hasText: true, hasComposerContent: true, isSendBlocked: false, isSending: true)
        try returnKey(in: card.textView)
        XCTAssertEqual(recorder.send, 0, "a send under way")

        card.configuration.desktop?.send = AgentInputDesktopSend(hasText: true, hasComposerContent: true, isSendBlocked: false)
        try checkKeys(Box(text: card.textView, sent: { recorder.send }))
        try returnKey(in: card.textView)
        XCTAssertEqual(recorder.send, 1, "↩ is the panel's send")
        XCTAssertEqual(recorder.primary, 0)

        SendShortcut.enterToSend = false
        try press(.command, in: card.textView)
        XCTAssertEqual(recorder.send, 2, "with Enter to send off, ⌘↩ is")
    }

    private func editor() async throws -> (ComposerEditorViewController, () -> Int) {
        let editor = ComposerEditorViewController(text: "", selection: NSRange(location: 0, length: 0), keyboardTop: nil)
        var sent = 0
        editor.canSend = { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        editor.onSend = { sent += 1 }
        _ = try await window(editor)
        XCTAssertTrue(editor.textView.becomeFirstResponder())
        return (editor, { sent })
    }

    func testTheFullScreenEditorSends() async throws {
        let (editor, sent) = try await editor()
        try returnKey(in: editor.textView)
        XCTAssertEqual(sent(), 0, "empty")
        XCTAssertEqual(editor.textView.text, "")

        editor.textView.insertText("Run the tests")
        try checkKeys(Box(text: editor.textView, sent: sent))
        try returnKey(in: editor.textView)
        XCTAssertEqual(sent(), 1, "↩ sends the chat's text")

        // It closes as it sends: a fresh one for ⌘↩.
        SendShortcut.enterToSend = false
        let (again, sentAgain) = try await self.editor()
        again.textView.insertText("Run the tests")
        try press(.command, in: again.textView)
        XCTAssertEqual(sentAgain(), 1, "with Enter to send off, ⌘↩ sends")
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
        try returnKey(in: composer.textView)
        XCTAssertEqual(sent, 0, "send can't be pressed")

        composer.textView.insertText("Fix the build")
        composer.sendButton.canSend = true
        composer.sendButton.isBusy = true
        try returnKey(in: composer.textView)
        XCTAssertEqual(sent, 0, "a session is starting")

        composer.sendButton.isBusy = false
        try checkKeys(Box(text: composer.textView, sent: { sent }))
        try returnKey(in: composer.textView)
        XCTAssertEqual(sent, 1, "↩ is send's press")

        SendShortcut.enterToSend = false
        try press(.command, in: composer.textView)
        XCTAssertEqual(sent, 2, "with Enter to send off, ⌘↩ is")
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
        try checkKeys(Box(text: panel.field, sent: { sent }))
        try returnKey(in: panel.field)
        XCTAssertEqual(sent, 1, "↩ sends the picked pictures")

        SendShortcut.enterToSend = false
        try press(.command, in: panel.field)
        XCTAssertEqual(sent, 2, "with Enter to send off, ⌘↩ does")
    }

    private func sheet() async throws -> (UITextView, Answers) {
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
        return (input, answers)
    }

    private func waitForAnswer(_ answers: Answers) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while answers.count == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testTheQuestionSheetSubmits() async throws {
        let (input, answers) = try await sheet()
        try returnKey(in: input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(answers.count, 0, "nothing answered yet")

        input.insertText("MySQL")
        try checkKeys(Box(text: input, sent: { answers.count }))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(answers.count, 0)

        try returnKey(in: input)
        try await waitForAnswer(answers)
        XCTAssertEqual(answers.count, 1, "↩ is Submit Answer")

        // It submits once: a fresh sheet for ⌘↩.
        SendShortcut.enterToSend = false
        let (again, answersAgain) = try await sheet()
        again.insertText("MySQL")
        try press(.command, in: again)
        try await waitForAnswer(answersAgain)
        XCTAssertEqual(answersAgain.count, 1, "with Enter to send off, ⌘↩ is")
    }

    func testTheInlineQuestionFieldSubmits() async throws {
        let window = try await window()
        let field = ChatQuestionFieldView()
        let root = window.rootViewController!.view!
        root.addSubview(field)
        field.frame = CGRect(x: 8, y: 200, width: root.bounds.width - 16, height: 80)
        XCTAssertTrue(field.becomeFirstResponder())

        XCTAssertNil(field.keyCommands?.first { $0.input == "\r" }, "no ↩ without a form to submit")

        var submitted = 0
        field.onSubmit = { submitted += 1 }
        field.insertText("MySQL")
        try checkKeys(Box(text: field, sent: { submitted }))
        try returnKey(in: field)
        XCTAssertEqual(submitted, 1, "↩ is the form's Submit Answer")

        SendShortcut.enterToSend = false
        try press(.command, in: field)
        XCTAssertEqual(submitted, 2, "with Enter to send off, ⌘↩ is")
    }
}
#endif
