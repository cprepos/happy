import Foundation

/// This fork's additions to `SyncEngine`, kept out of SyncEngine.swift so
/// merges from upstream do not conflict there.
extension SyncEngine {
    /// How long the run's setup, and taking in one hello, may take before
    /// the try counts as failed: a step stuck on a dead connection or a
    /// slow disk shows as an error instead of "connecting…" for good.
    static let setupDeadline: Duration = .seconds(30)
    static let helloDeadline: Duration = .seconds(30)

    /// Waits for `work` up to `limit`, throwing what it throws. Past the
    /// limit `work` is cancelled and this throws `BrowserError.timeout`;
    /// a cancelled waiter cancels `work` and throws `CancellationError`.
    static func wait(for work: Task<Void, Error>, upTo limit: Duration) async throws {
        try await LiveBrowserFeed.within(limit) {
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        }
    }

    /// Pull to refresh: drop the realtime and query clients (never the file
    /// client, so a download in flight goes on), start the run again even
    /// when it is live, read home whole once rather than resuming the
    /// stream, and wait until it is live and caught up. False when that
    /// takes longer than `timeout`, or the engine is paused or stopped.
    public func resync(timeout: Duration) async -> Bool {
        guard !stopped, !held else { return false }
        await client.transport.reset(.realtime)
        await client.transport.reset(.query)
        guard !stopped, !held else { return false }
        snapshot.error = nil
        await pause()
        // Not resuming: the next stream opens after a full read. Cleared
        // once the old run has ended, so it cannot set it again.
        verifiedDaemon = nil
        start()
        let updates = snapshots()
        do {
            return try await LiveBrowserFeed.within(timeout) {
                for await snapshot in updates where snapshot.live && !snapshot.syncing { return true }
                return false
            }
        } catch {
            return false
        }
    }
}
