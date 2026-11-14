import Foundation
#if canImport(OSLog)
import OSLog
#endif

// Our plugins' retry, refresh and cancelled-read handling for `Conversation`, kept
// out of Conversation.swift so upstream merges do not conflict there.
extension Conversation {
    // Stored in Conversation.swift, beside `reading` (an extension cannot
    // store): `readingId`, which `reload` `reading` is (`beginReading`);
    // `starting`, `start` is past its guard and not yet following, so a
    // second call or a retry waits for it rather than starting again;
    // `followed`, `follow` has asked for history, so a retry reads again
    // from there; `stopped`, `stop` was called; `claimOverride`, stands in
    // for the checkpoint claim, for a test.

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
        deliverWaiting()
        while let current = reading {
            await current.value
            if reading == current { break }
        }
    }

    /// Whether a start or a read is underway, for a test.
    var loadInFlight: Bool { starting || reading != nil }

    /// Makes the checkpoint claim `claim`, for a test.
    func overrideClaim(_ claim: @escaping @Sendable (String) async throws -> Void) { claimOverride = claim }

    /// The checkpoint claim for `key` a test made (`overrideClaim`), or nil
    /// for the real one: `checkpointClaim`'s one call, before it makes its
    /// own.
    func overriddenClaim(_ key: String) -> Task<Void, Error>? {
        guard let claimOverride else { return nil }
        return Task { try await claimOverride(key) }
    }

    /// `start`'s first line: past it, `start` is underway (`starting`,
    /// which `start` lets go of as it returns), so a second call or a retry
    /// waits for it rather than starting again. False, with nothing
    /// changed, while one is underway or once stopped. `start`'s own guard
    /// follows; its claim failing leaves it not following, so `retryLoad`
    /// starts it again, and a `stop` meanwhile ends it (`if stopped`).
    func beginStart() -> Bool {
        guard !starting, !stopped else { return false }
        starting = true
        return true
    }

    /// `reload`'s read begins: a new `readingId` (stored in
    /// Conversation.swift, beside `reading`), which the read hands to
    /// `endReading` as it ends.
    func beginReading() -> UUID {
        let id = UUID()
        readingId = id
        return id
    }

    /// `reload`'s read `id` ended: `reading` is let go of only when it is
    /// still that read's, so one that ends after a newer began leaves the
    /// newer's in place.
    func endReading(_ id: UUID) {
        if readingId == id { reading = nil }
    }

    /// A read cancelled underneath it, not by it (a connect another caller
    /// gave up on): `reload` asks again without saying it failed, as for a
    /// network change (its one call, beside upstream's `carrierResets`
    /// check). The caller checks that the cancellation is not the read's own.
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
