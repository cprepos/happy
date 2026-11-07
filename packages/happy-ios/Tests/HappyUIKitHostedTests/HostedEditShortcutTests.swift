#if canImport(UIKit)
import Foundation
import HappyCore
@testable import HappyUI
import UIKit
import XCTest

/// ⌘C, ⌘X, ⌘V and ⌘A are Edit > Copy, Cut, Paste and Select All: the
/// system's menu (the iPad's, and the Mac's menu bar for the iPad app on a
/// Mac) sends `copy:`, `cut:`, `paste:` and `selectAll:` to the first
/// responder that takes them. Here each is sent the same way, with nil as
/// the target, from every chat box and from a lifted message, whose words
/// are drawn rather than a text view's.
@MainActor
final class HostedEditShortcutTests: XCTestCase {
    private var savedPasteboard: [[String: Any]] = []

    override func setUp() {
        super.setUp()
        LegacyFonts.registerBundledFonts()
        savedPasteboard = UIPasteboard.general.items
    }

    override func tearDown() {
        UIPasteboard.general.items = savedPasteboard
        super.tearDown()
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

    /// No key command up the chain claims an Edit shortcut for itself, as
    /// ⌘↩'s send does Return, so the system's Edit menu keeps them.
    private func assertNoEditShortcutTaken(from responder: UIResponder, file: StaticString = #filePath, line: UInt = #line) {
        var next: UIResponder? = responder
        while let current = next {
            for command in current.keyCommands ?? [] where command.modifierFlags.contains(.command) {
                XCTAssertFalse(["c", "x", "v", "a", "z"].contains(command.input?.lowercased() ?? ""),
                               "\(type(of: current)) takes ⌘\(command.input ?? "")", file: file, line: line)
            }
            next = current.next
        }
    }

    /// The Edit menu's action, sent as the menu sends it.
    @discardableResult
    private func edit(_ action: Selector, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let taken = UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil)
        XCTAssertTrue(taken, "nobody took \(action)", file: file, line: line)
        return taken
    }

    /// Select All, Copy, Cut and Paste round trip in a focused text view.
    private func assertEditing(_ text: UITextView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text.isFirstResponder, "the box has the keyboard", file: file, line: line)
        assertNoEditShortcutTaken(from: text, file: file, line: line)
        text.insertText("Run the tests")
        let selectAll = #selector(UIResponderStandardEditActions.selectAll(_:))
        let copy = #selector(UIResponderStandardEditActions.copy(_:))
        let cut = #selector(UIResponderStandardEditActions.cut(_:))
        let paste = #selector(UIResponderStandardEditActions.paste(_:))
        XCTAssertTrue(text.canPerformAction(selectAll, withSender: nil), file: file, line: line)
        edit(selectAll, file: file, line: line)
        XCTAssertEqual(text.selectedRange, NSRange(location: 0, length: 13), "⌘A selects it all", file: file, line: line)
        UIPasteboard.general.string = ""
        edit(copy, file: file, line: line)
        XCTAssertEqual(UIPasteboard.general.string, "Run the tests", "⌘C copies", file: file, line: line)
        edit(cut, file: file, line: line)
        XCTAssertEqual(text.text, "", "⌘X cuts", file: file, line: line)
        UIPasteboard.general.string = "Fix the build"
        XCTAssertTrue(text.canPerformAction(paste, withSender: nil), file: file, line: line)
        edit(paste, file: file, line: line)
        XCTAssertEqual(text.text, "Fix the build", "⌘V pastes", file: file, line: line)
    }

    func testTheCardEdits() async throws {
        let window = try await window()
        let card = AgentInputCardView(configuration: AgentInputCardConfiguration(placeholder: "Message"))
        let root = window.rootViewController!.view!
        root.addSubview(card)
        let width = root.bounds.width - 16
        card.frame = CGRect(x: 8, y: 200, width: width, height: card.height(fitting: width))
        card.layoutIfNeeded()
        XCTAssertTrue(card.textView.becomeFirstResponder())
        assertEditing(card.textView)
    }

    func testTheCardPastesTextWithAPictureHandlerSet() async throws {
        let window = try await window()
        let card = AgentInputCardView(configuration: AgentInputCardConfiguration(placeholder: "Message"))
        var attached = 0
        card.textView.onPasteAttachment = { attached += 1 }
        let root = window.rootViewController!.view!
        root.addSubview(card)
        let width = root.bounds.width - 16
        card.frame = CGRect(x: 8, y: 200, width: width, height: card.height(fitting: width))
        card.layoutIfNeeded()
        XCTAssertTrue(card.textView.becomeFirstResponder())
        assertEditing(card.textView)
        XCTAssertEqual(attached, 0, "copied text pastes as text")
    }

    func testTheFullScreenEditorEdits() async throws {
        let editor = ComposerEditorViewController(text: "", selection: NSRange(location: 0, length: 0), keyboardTop: nil)
        editor.canSend = { _ in true }
        editor.onSend = {}
        _ = try await window(editor)
        XCTAssertTrue(editor.textView.becomeFirstResponder())
        assertEditing(editor.textView)
    }

    func testTheNewSessionPromptEdits() async throws {
        let window = try await window()
        let composer = NewSessionComposerView(frame: .zero)
        let root = window.rootViewController!.view!
        root.addSubview(composer)
        composer.frame = CGRect(x: 8, y: 200, width: root.bounds.width - 16, height: 160)
        composer.layoutIfNeeded()
        XCTAssertTrue(composer.textView.becomeFirstResponder())
        assertEditing(composer.textView)
    }

    func testTheAttachCaptionEdits() async throws {
        let window = try await window()
        let panel = AttachMenuPanel(frame: .zero)
        let root = window.rootViewController!.view!
        root.addSubview(panel)
        panel.frame = CGRect(x: 8, y: 200, width: root.bounds.width - 16, height: 200)
        panel.setPicking(true, animated: false)
        panel.layoutIfNeeded()
        XCTAssertTrue(panel.field.becomeFirstResponder())
        assertEditing(panel.field)
    }

    func testTheInlineQuestionFieldEdits() async throws {
        let window = try await window()
        let field = ChatQuestionFieldView()
        field.onSubmit = {}
        let root = window.rootViewController!.view!
        root.addSubview(field)
        field.frame = CGRect(x: 8, y: 200, width: root.bounds.width - 16, height: 80)
        XCTAssertTrue(field.becomeFirstResponder())
        assertEditing(field)
    }

    // MARK: A lifted message

    private func lift(_ words: String, in window: UIWindow) throws -> MessageLiftOverlay {
        let style = ChatRowStyle(render: .isolated())
        let plan = ChatRowRenderer.plan(
            ChatRowInput(item: .message(.agentText(AgentTextMessage(id: "a1", createdAt: 0, text: words))), style: style),
            width: window.bounds.width
        )
        let selection = try XCTUnwrap(plan.selection)
        let canvas = ChatPlanView()
        canvas.frame = CGRect(origin: CGPoint(x: 0, y: 120), size: plan.size)
        canvas.apply(plan)
        window.rootViewController!.view.addSubview(canvas)
        let source = MessageLiftSource(
            plan: plan, selection: selection, canvas: { [weak canvas] in canvas }, setLifted: { _ in },
            host: window.rootViewController
        )
        let overlay = try XCTUnwrap(MessageLiftOverlay.present(source, in: window))
        addTeardownBlock { @MainActor in overlay.dismiss(animated: false) }
        return overlay
    }

    func testALiftedMessageCopiesWhatIsSelected() async throws {
        let window = try await window()
        let overlay = try lift("The quick brown fox jumps over the lazy dog.", in: window)
        XCTAssertTrue(overlay.isFirstResponder, "the lifted message takes the Edit menu")
        assertNoEditShortcutTaken(from: overlay)
        let copy = #selector(UIResponderStandardEditActions.copy(_:))
        XCTAssertTrue(overlay.canPerformAction(copy, withSender: nil))
        XCTAssertFalse(overlay.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil), "nothing to paste into")

        let brown = (overlay.selection.run.pieces.map(\.text).joined() as NSString).range(of: "brown")
        XCTAssertNotEqual(brown.location, NSNotFound)
        overlay.selection.setSelection(brown.location..<(brown.location + brown.length), animateIn: false)
        UIPasteboard.general.string = ""
        edit(copy)
        XCTAssertEqual(UIPasteboard.general.string, "brown", "⌘C copies the selected words")
    }

    func testALiftedMessageCopiesAllOfItWithNothingSelected() async throws {
        let window = try await window()
        let words = "The quick brown fox jumps over the lazy dog."
        let overlay = try lift(words, in: window)
        UIPasteboard.general.string = ""
        edit(#selector(UIResponderStandardEditActions.copy(_:)))
        XCTAssertEqual(UIPasteboard.general.string, words, "⌘C copies the message, as the menu's Copy")
    }

    func testALiftedMessageSelectsAll() async throws {
        let window = try await window()
        let words = "The quick brown fox jumps over the lazy dog."
        let overlay = try lift(words, in: window)
        edit(#selector(UIResponderStandardEditActions.selectAll(_:)))
        XCTAssertEqual(overlay.selection.selected, 0..<overlay.selection.run.length, "⌘A selects all of the words")
        UIPasteboard.general.string = ""
        edit(#selector(UIResponderStandardEditActions.copy(_:)))
        XCTAssertEqual(UIPasteboard.general.string, words)
    }
}
#endif
