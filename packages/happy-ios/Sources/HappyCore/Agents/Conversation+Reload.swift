import Foundation
#if canImport(OSLog)
import OSLog
#endif

// Our retry, refresh and cancelled-read handling for `Conversation`, kept
// out of Conversation.swift so upstream merges do not conflict there.
extension Conversation {
    /// Reads again a conversation whose read failed, or that never
    /// finished reading with nothing reading it now: a screen opening it,
    /// or the phone coming back to it. A start that failed is started
    /// again. Does nothing while a start or a read is underway, once read
    /// without an error, for new work, or after `stop`; so it may be
    /// called as often as it likes.
    public func retryLoad() async {
        guard !stopped, !starting, creation == nil else { return }
        if following == nil {
            Self.note("retrying start for \(agentId)")
            if snapshot.error != nil { snapshot.error = nil; publish() }
            await start()
            return
        }
        guard followed, reading == nil, snapshot.error != nil || !snapshot.loaded else { return }
        Self.note("retrying read for \(agentId)")
        snapshot.error = nil
        // Nothing to show meanwhile: back to reading, not an empty conversation.
        if transcript.runs.isEmpty, transcript.pending.isEmpty { snapshot.loaded = false }
        publish()
        reload()
    }

    /// Pull to refresh: the conversation read whole again now, whether or
    /// not the last read failed, and unsent messages offered again, as
    /// after the stream's resync. One whose start failed is started again.
    /// Returns once that read has ended (a read retried after a cancel
    /// underneath it included). Nothing for new work, or after `stop`.
    public func refresh() async {
        guard !stopped, !starting, creation == nil else { return }
        guard following != nil else {
            if snapshot.error != nil { snapshot.error = nil; publish() }
            await start()
            return
        }
        // Still restoring what was kept: its first read is on its way.
        guard followed else { return }
        if snapshot.error != nil { snapshot.error = nil; publish() }
        reload()
        for send in outgoing where !send.accepted && send.failure == nil { deliver(send.id) }
        while let current = reading {
            await current.value
            if reading == current { break }
        }
    }

    /// Whether a start or a read is underway, for a test.
    var loadInFlight: Bool { starting || reading != nil }

    /// Makes the checkpoint claim `claim`, for a test.
    func overrideClaim(_ claim: @escaping @Sendable (String) async throws -> Void) { claimOverride = claim }

    /// A failed read cancelled underneath it, not by it (a connect another
    /// caller gave up on): no answer, so no failure to keep. Read again
    /// shortly; past that, left unread for a reopen or the phone's return to
    /// read again. False for any other failure, which the caller keeps.
    func readAgainIfCancelledUnderneath(_ error: Error, agentId: String, attempt: Int) async -> Bool {
        if Self.cancelledUnderneath(error) {
            guard attempt < Self.transientRetries else {
                Self.note("read of \(agentId) cancelled underneath \(attempt + 1) times; left unread")
                return true
            }
            Self.note("read of \(agentId) cancelled underneath; reading again")
            try? await Task.sleep(for: Self.transientBackoff(attempt))
            if Task.isCancelled { return true }
            reload(attempt: attempt + 1)
            return true
        }
        Self.note("read of \(agentId) failed")
        return false
    }

    /// Reads again after a read cancelled underneath it, before leaving it unread.
    static let transientRetries = 3
    static func transientBackoff(_ attempt: Int) -> Duration { .milliseconds(250 << min(attempt, 4)) }

    /// A cancellation that is not the read's own: the caller checks that.
    static func cancelledUnderneath(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "app.happy", category: "Conversation")
    #endif
    static func note(_ message: String) {
        #if canImport(OSLog)
        logger.notice("\(message, privacy: .public)")
        #endif
    }
}
