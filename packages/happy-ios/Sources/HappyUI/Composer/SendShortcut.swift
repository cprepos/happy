import HappyCore
#if canImport(UIKit)
import UIKit
#endif

/// A hardware keyboard's Return in a chat box. With the account's Enter to
/// send on (`agentInputEnterToSend`, the default), Return sends as the
/// box's send button does, and Shift, ⌘ or Control with Return makes a new
/// line. With it off, Return is a newline as on the on-screen keyboard, ⌘↩
/// sends, and ⌃↩ is a newline too.
///
/// Only a hardware keyboard fires key commands; the on-screen keyboard's
/// Return reaches the text as typed text, so it stays a newline either way.
///
/// Each box lists `commands(send:newline:)` in its `keyCommands`. Its send
/// hands `fire` whether its send button could be pressed now and that
/// button's own action, so the shortcut never sends what the button
/// wouldn't (an empty box, a picture still uploading, a send under way,
/// voice instead of send). A plain Return the box can't send is swallowed,
/// as ⌘↩ is.
///
/// While an input method is composing (Japanese, Chinese: `markedTextRange`)
/// Return confirms the composition. The box's `canPerformAction` then says
/// no to both actions (`takes(in:)`), so no responder takes the command and
/// UIKit hands the key on to the text, where the input method gets it.
public enum SendShortcut {
    /// Return; the commands add their modifiers.
    public static let input = "\r"

    /// The account's Enter to send, as the active account last synced it
    /// (`AppCoordinator` follows it); on until an account says otherwise,
    /// as `AccountSettings.defaults` has it. Read whenever a box builds its
    /// `keyCommands`, so a change applies at once.
    @MainActor public static var enterToSend = true

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
    /// The box's commands, each with priority over the text view, which
    /// would otherwise take the key itself:
    /// - Enter to send on: ↩ sends ("Send" in the ⌘-hold list); ⇧↩, ⌘↩ and
    ///   ⌃↩ make a new line ("New line", listed once for ⇧↩).
    /// - Off: ⌘↩ sends and ⌃↩ makes a new line; ↩ and ⇧↩ aren't listed, so
    ///   the text view types them as it always did.
    @MainActor
    public static func commands(send: Selector, newline: Selector, enterToSend: Bool = SendShortcut.enterToSend) -> [UIKeyCommand] {
        func command(_ flags: UIKeyModifierFlags, _ action: Selector, title: String?) -> UIKeyCommand {
            let command: UIKeyCommand
            if let title {
                command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
                command.discoverabilityTitle = title
            } else {
                // No title keeps it out of the ⌘-hold list; it still fires.
                command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            }
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        if enterToSend {
            return [
                command([], send, title: Strings.Composer.send),
                command(.shift, newline, title: Strings.Composer.newLine),
                command(.command, newline, title: nil),
                command(.control, newline, title: nil),
            ]
        }
        return [
            command(.command, send, title: Strings.Composer.send),
            command(.control, newline, title: nil),
        ]
    }

    /// Whether a box takes one of its ↩ commands now, for its
    /// `canPerformAction`: not without text that has the keyboard, nor
    /// while an input method is composing in it. Saying no leaves the
    /// command without a target, and UIKit then delivers the key to the
    /// text as if no command were listed.
    @MainActor
    public static func takes(in text: UITextInput?) -> Bool {
        guard let text else { return false }
        return text.markedTextRange == nil
    }

    /// The key command was a plain Return, not ⌘↩: a box with suggestions
    /// lets them have it first.
    @MainActor
    public static func isPlainReturn(_ sender: Any?) -> Bool {
        guard let command = sender as? UIKeyCommand else { return false }
        return command.input == input && command.modifierFlags.intersection([.shift, .command, .control, .alternate]).isEmpty
    }

    /// A newline at the selection, typed as the keyboard would type it, so
    /// undo and the text's own change path run; never into a composition.
    @MainActor
    public static func insertNewline(in text: UITextView?) {
        guard let text, text.markedTextRange == nil else { return }
        text.insertText("\n")
    }
}
#endif
