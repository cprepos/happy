import Foundation
import HappyWire

// Our plugins' starting mode for new work, kept out of Conversation.swift
// so upstream merges do not conflict there.
//
// New work's mode is the computer's default it started on, not a pick
// (`followsDefault`, stored in Conversation.swift with our other state):
// the computer's own default, once read, replaces it (one kept offline
// may be out of date), until the person picks one. Its hooks there:
// - `init`'s `startingMode`, the default new work starts on, shown and
//   sent until the computer's own default is read or a pick is made (its
//   last line sets it, and `followsDefault`);
// - `start` reads the live default at once for new work that follows it;
// - `restoreConversation` takes the kept mode through `restoredMode`;
// - `persistConversation` keeps whether the mode was a pick
//   (`KeptConversation.modePicked`: absent in what was kept before it was
//   told apart; first and defaulted, so upstream's initializer call stays
//   as upstream writes it);
// - `setMode` stops following the default;
// - `sendingMode` asks `liveDefault` first while it is followed.
extension Conversation {
    /// New work's default, read from the computer: it replaces the one it
    /// started on, and a pick made meanwhile wins. Unread (the computer out
    /// of reach), the one it started on goes.
    func liveDefault() async throws -> AgentWire.Mode {
        let task = defaultMode ?? readDefaultMode()
        defaultMode = task
        do {
            let live = try await task.value
            guard followsDefault else { return mode ?? live }
            followsDefault = false
            if mode != live {
                mode = live
                snapshot.mode = live
                publish()
            }
            return live
        } catch {
            if defaultMode == task { defaultMode = nil }
            if let mode { return mode }
            throw error
        }
    }

    /// The mode and pick `restoreConversation` leaves, from what was kept:
    /// upstream's (a pick here, else the kept mode) unless it follows the
    /// default. Then an unsent bot or task keeps the person's own pick, and
    /// the default it started on is the computer's, read again.
    func restoredMode(_ kept: AgentWire.Mode?, pickedThen: Bool?, mode: AgentWire.Mode?, picked: AgentWire.Mode?) -> (AgentWire.Mode?, AgentWire.Mode?) {
        guard followsDefault else { return (picked ?? kept, picked) }
        guard pickedThen == true, let pick = kept else { return (mode, picked) }
        followsDefault = false
        return (pick, pick)
    }
}
