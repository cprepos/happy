import Foundation

/// agentInputPrimaryAction.ts: what the composer's one round button does.
/// Send, stop and voice share it.
public enum AgentInputPrimaryAction: String, Equatable, Sendable {
    case send
    case stop
    /// The agent refuses steering while it works; pressing shakes the card.
    case blocked
    /// Starts or reopens the foreground voice conversation.
    case voice
    case idle

    /// `resolveAgentInputPrimaryAction`.
    ///
    /// A blank composer while the agent works is the one case where the
    /// button is Stop; once there is a follow-up, sending wins so the next
    /// message can be queued without aborting the turn. A blocked send never
    /// hides Stop: an agent that refuses steering has no other way to stop.
    public static func resolve(
        hasComposerContent: Bool,
        isSendBlocked: Bool,
        isSendDisabled: Bool,
        showAbortButton: Bool,
        canAbort: Bool,
        canVoice: Bool = false
    ) -> AgentInputPrimaryAction {
        if showAbortButton && canAbort && !hasComposerContent {
            return .stop
        }
        if isSendBlocked && hasComposerContent {
            return .blocked
        }
        if !isSendDisabled && hasComposerContent {
            return .send
        }
        if !isSendDisabled && canVoice {
            return .voice
        }
        return .idle
    }
}

/// AgentInput.tsx's wide composer (`desktopActionControls`, a window wider
/// than 700 points): its send button sends, and with nothing to send it is
/// the voice button (`handleSendPress` calls `onMicPress`). Stop has its own
/// button beside the gear. While a call runs SessionView passes no
/// `onMicPress`, so the button is a plain send again and the shared status
/// row reopens the call.
public struct AgentInputDesktopSend: Equatable, Sendable {
    public enum Fill: Equatable, Sendable {
        /// `sendButtonLocked`: surfaceHigh in a 1pt divider ring.
        case locked
        /// `sendButtonActive`: button.primary.background.
        case active
        /// `sendButtonInactive`: button.primary.disabled.
        case inactive
    }

    public enum Glyph: Equatable, Sendable {
        case spinner
        /// Ionicons `lock-closed` 15, textSecondary.
        case lock
        /// Octicons `arrow-up` 16, button.primary.tint.
        case arrow
        /// `icon-voice-white.png` 24, button.primary.tint.
        case voice
    }

    public var fill: Fill
    public var glyph: Glyph
    /// `desktopCanPressSendButton`.
    public var isEnabled: Bool

    /// A press starts voice instead of sending.
    public var startsVoice: Bool {
        glyph == .voice && isEnabled
    }

    /// `hasText` is the text alone (it colours the button); content counts
    /// picked images too (it enables it). `canVoice` is `onMicPress &&
    /// !isMicActive`: voice can start here and no call is running.
    ///
    /// happy-app draws the voice glyph whenever there is no text, so
    /// pictures alone show it although a press sends them. Here the glyph
    /// is voice only when a press starts voice: with pictures it is the
    /// arrow, on the same filled button.
    public init(
        hasText: Bool,
        hasComposerContent: Bool,
        isSendBlocked: Bool,
        isSending: Bool = false,
        isSendDisabled: Bool = false,
        canVoice: Bool = false
    ) {
        fill = isSendBlocked ? .locked : hasText || isSending || canVoice ? .active : .inactive
        glyph = isSending ? .spinner
            : isSendBlocked ? .lock
            : !hasComposerContent && canVoice ? .voice
            : .arrow
        isEnabled = !isSending && !isSendDisabled
            && (isSendBlocked ? hasComposerContent : hasComposerContent || canVoice)
    }
}
