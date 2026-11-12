import HappyCore
@testable import HappyUI
import HappyWire
import XCTest
#if canImport(UIKit)
import UIKit
#endif

/// A hardware keyboard's Return fires a box's send only when its send button
/// would send; which keys send and which make a line follow Enter to send.
/// Runs on Linux too: the rule is plain Swift, apart from the key commands.
final class SendShortcutTests: XCTestCase {
    func testFiresOnlyWhenAllowed() {
        var sent = 0
        XCTAssertFalse(SendShortcut.fire(allowed: false) { sent += 1 })
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(SendShortcut.fire(allowed: true) { sent += 1 })
        XCTAssertEqual(sent, 1)
    }

    func testTheRoundButtonSendsOnlyWhenItShowsSend() {
        XCTAssertTrue(SendShortcut.allows(primary: .send, busy: false))
        // A send under way, or the home dock starting a session.
        XCTAssertFalse(SendShortcut.allows(primary: .send, busy: true))
        for action: AgentInputPrimaryAction in [.idle, .stop, .blocked, .voice] {
            XCTAssertFalse(SendShortcut.allows(primary: action, busy: false), "\(action)")
        }
    }

    func testTheRoundButtonFollowsTheComposer() {
        func allows(content: Bool, working: Bool = false, blocked: Bool = false, voice: Bool = false) -> Bool {
            SendShortcut.allows(primary: .resolve(
                hasComposerContent: content, isSendBlocked: blocked, isSendDisabled: false,
                showAbortButton: working, canAbort: true, canVoice: voice
            ), busy: false)
        }
        XCTAssertFalse(allows(content: false), "an empty box")
        XCTAssertFalse(allows(content: false, working: true), "an empty box is Stop")
        XCTAssertFalse(allows(content: false, voice: true), "an empty box is voice")
        XCTAssertFalse(allows(content: true, blocked: true), "the agent refuses steering")
        XCTAssertTrue(allows(content: true))
        XCTAssertTrue(allows(content: true, working: true), "a follow-up queues")
    }

    func testTheFlatPanelSendsOnlyWithItsArrow() {
        XCTAssertTrue(SendShortcut.allows(desktop: AgentInputDesktopSend(hasText: true, hasComposerContent: true, isSendBlocked: false)))
        XCTAssertTrue(SendShortcut.allows(desktop: AgentInputDesktopSend(hasText: false, hasComposerContent: true, isSendBlocked: false)), "pictures alone")
        XCTAssertFalse(SendShortcut.allows(desktop: AgentInputDesktopSend(hasText: false, hasComposerContent: false, isSendBlocked: false)), "empty")
        XCTAssertFalse(SendShortcut.allows(desktop: AgentInputDesktopSend(hasText: false, hasComposerContent: false, isSendBlocked: false, canVoice: true)), "voice")
        XCTAssertFalse(SendShortcut.allows(desktop: AgentInputDesktopSend(hasText: true, hasComposerContent: true, isSendBlocked: false, isSending: true)), "sending")
        XCTAssertFalse(SendShortcut.allows(desktop: AgentInputDesktopSend(hasText: true, hasComposerContent: true, isSendBlocked: false, isSendDisabled: true)), "disabled")
        XCTAssertFalse(SendShortcut.allows(desktop: AgentInputDesktopSend(hasText: true, hasComposerContent: true, isSendBlocked: true)), "refused")
    }

    func testTheCommandIsReturn() {
        XCTAssertEqual(SendShortcut.input, "\r")
    }

    @MainActor
    func testEnterToSendIsOnUntilAnAccountSaysOtherwise() {
        XCTAssertTrue(AccountSettings().enterToSend, "happy-app's default")
        XCTAssertFalse(AccountSettings(["agentInputEnterToSend": .bool(false)]).enterToSend)
    }

    #if canImport(UIKit)
    /// What a box's actions are named.
    private final class Actions: NSObject {
        @objc func sendShortcut(_ sender: Any?) {}
        @objc func newlineShortcut(_ sender: Any?) {}
    }
    private static let send = #selector(Actions.sendShortcut(_:))
    private static let newline = #selector(Actions.newlineShortcut(_:))

    /// Each command as (modifiers, action, title in the ⌘-hold list).
    @MainActor
    private func listed(enterToSend: Bool) -> [(UIKeyModifierFlags, Selector?, String?)] {
        let commands = SendShortcut.commands(send: Self.send, newline: Self.newline, enterToSend: enterToSend)
        for command in commands {
            XCTAssertEqual(command.input, "\r")
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior, "over the text view's own Return")
        }
        return commands.map { ($0.modifierFlags, $0.action, $0.discoverabilityTitle) }
    }

    /// On: ↩ sends; ⇧↩, ⌘↩ and ⌃↩ are new lines, listed once as ⇧↩.
    @MainActor
    func testWithEnterToSendReturnSendsAndTheModifiedReturnsMakeLines() {
        let commands = listed(enterToSend: true)
        XCTAssertEqual(commands.map(\.0), [[], .shift, .command, .control])
        XCTAssertEqual(commands.map(\.1), [Self.send, Self.newline, Self.newline, Self.newline], "⌘↩ no longer sends")
        XCTAssertEqual(commands.map(\.2), ["Send", "New line", nil, nil])
    }

    /// Off: ↩ and ⇧↩ stay the text view's; ⌘↩ sends, ⌃↩ is a new line.
    @MainActor
    func testWithoutEnterToSendCommandReturnSends() {
        let commands = listed(enterToSend: false)
        XCTAssertEqual(commands.map(\.0), [.command, .control])
        XCTAssertEqual(commands.map(\.1), [Self.send, Self.newline])
        XCTAssertEqual(commands.map(\.2), ["Send", nil])
    }

    /// The commands follow the account's setting when not told otherwise.
    @MainActor
    func testTheCommandsFollowTheSetting() {
        let saved = SendShortcut.enterToSend
        defer { SendShortcut.enterToSend = saved }
        SendShortcut.enterToSend = false
        XCTAssertNil(SendShortcut.commands(send: Self.send, newline: Self.newline).first { $0.modifierFlags.isEmpty })
        SendShortcut.enterToSend = true
        XCTAssertNotNil(SendShortcut.commands(send: Self.send, newline: Self.newline).first { $0.modifierFlags.isEmpty })
    }

    @MainActor
    func testOnlyAPlainReturnIsPlain() {
        let commands = SendShortcut.commands(send: Self.send, newline: Self.newline, enterToSend: true)
        XCTAssertEqual(commands.map { SendShortcut.isPlainReturn($0) }, [true, false, false, false])
        XCTAssertFalse(SendShortcut.isPlainReturn(nil))
    }

    /// A new line goes in at the cursor; with no text, nothing takes the
    /// keys. Composition is HostedSendShortcutTests', in a window.
    @MainActor
    func testANewLineGoesInAtTheCursor() {
        let text = UITextView()
        XCTAssertTrue(SendShortcut.takes(in: text))
        text.text = "ab"
        text.selectedRange = NSRange(location: 1, length: 0)
        SendShortcut.insertNewline(in: text)
        XCTAssertEqual(text.text, "a\nb")
        XCTAssertFalse(SendShortcut.takes(in: nil as UITextView?), "no text with the keyboard")
    }
    #endif
}
