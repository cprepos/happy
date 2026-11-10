#if canImport(UIKit)
import HappyCore
import UIKit

// Our additions to `ChatViewController`, kept out of the upstream file so
// merging upstream doesn't conflict there; the upstream file only calls in.

extension ChatViewController {
    // MARK: Command-Return from the full-screen draft

    /// Command-Return in the full-screen editor sends as the card's round
    /// button would once the draft is back in the card.
    func wireSendShortcut(_ editor: ComposerEditorViewController) {
        editor.canSend = { [weak self] text in
            guard let self else { return false }
            return SendShortcut.allows(primary: self.primaryAction(text: text), busy: self.card.configuration.isPrimaryBusy)
        }
        editor.onSend = { [weak self] in self?.card.sendShortcut(nil) }
    }

    /// The card's round button for this text with the pictures picked now:
    /// what `updatePrimary` sets for the card's own text. The full-screen
    /// draft isn't in the card until the editor closes, so the card's
    /// current `primaryAction` can be behind it.
    func primaryAction(text: String) -> AgentInputPrimaryAction {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pictures.images.isEmpty
        return AgentInputPrimaryAction.resolve(
            hasComposerContent: hasContent, isSendBlocked: false, isSendDisabled: false, showAbortButton: chat.working, canAbort: true,
            canRecord: !previewing
        )
    }
}
#endif
