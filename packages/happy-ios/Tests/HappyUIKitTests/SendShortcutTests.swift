import HappyCore
@testable import HappyUI
import XCTest

/// ⌘↩ fires a box's send only when its send button would send. Runs on
/// Linux too: the rule is plain Swift, apart from the key command.
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
}
