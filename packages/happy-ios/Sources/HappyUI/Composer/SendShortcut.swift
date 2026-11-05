import HappyCore
#if canImport(UIKit)
import UIKit
#endif

/// ⌘↩ sends from a chat box, as its send button does; a plain Return stays
/// a newline. Each box lists `command(action:)` in its `keyCommands`, and
/// when it fires hands `fire` whether its send button could be pressed now
/// and that button's own action, so the shortcut never sends what the
/// button wouldn't (an empty box, a picture still uploading, a send under
/// way, voice instead of send).
public enum SendShortcut {
    /// Return; the command adds ⌘.
    public static let input = "\r"

    /// Runs `send` only when sending is allowed; true when it ran.
    @discardableResult
    public static func fire(allowed: Bool, _ send: () -> Void) -> Bool {
        guard allowed else { return false }
        send()
        return true
    }

    /// The card's round button sends: not Stop, voice, a refused send, an
    /// idle button or one that is busy.
    public static func allows(primary action: AgentInputPrimaryAction, busy: Bool) -> Bool {
        action == .send && !busy
    }

    /// The flat panel's send sends: enabled, and its arrow rather than
    /// voice, the lock or a spinner.
    public static func allows(desktop send: AgentInputDesktopSend) -> Bool {
        send.isEnabled && send.glyph == .arrow
    }
}

#if canImport(UIKit)
extension SendShortcut {
    /// ⌘↩ with priority over the text view, which would otherwise take it
    /// as a newline; "Send" in the ⌘-hold list.
    @MainActor
    public static func command(action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(title: Strings.Composer.send, action: action, input: input, modifierFlags: .command)
        command.discoverabilityTitle = Strings.Composer.send
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
}
#endif
