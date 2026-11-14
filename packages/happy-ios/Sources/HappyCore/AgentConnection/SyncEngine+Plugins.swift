import Foundation

/// Our plugins' additions to `SyncEngine`, kept out of SyncEngine.swift so
/// merges from upstream do not conflict there.
extension SyncEngine {
    /// How long the run's setup, and taking in one hello, may take before
    /// the try counts as failed: a step stuck on a dead connection or a
    /// slow disk shows as an error instead of "connecting…" for good.
    ///
    /// In `run`, upstream's setup body and its hello body each sit inside
    /// `try await Self.wait(for: Task { … }, upTo: …)`; the bodies keep
    /// upstream's indentation so the wrap is two lines at each site. Past
    /// `setupDeadline` the run ends with "Could not open this connection";
    /// past `helloDeadline` the try counts as a dropped stream and comes
    /// back round. The hello's `attempt = 0` moved out of the body, which
    /// cannot change the run's local.
    static let setupDeadline: Duration = .seconds(30)
    static let helloDeadline: Duration = .seconds(30)

    // `held` (stored in SyncEngine.swift, beside `stopped`): paused on
    // purpose, or not started yet. `start()` clears it and `pause()` sets
    // it, each as its first line; while running it is always false, since
    // `pause()` lets go of `runner` before its first await.

    /// `reconnect`'s first line: a run that ended on its own (its setup
    /// failed or timed out) starts again, when nothing paused or stopped
    /// the engine. True when it did, and `reconnect` has nothing more to do.
    func restartEndedRun() -> Bool {
        guard !stopped, !held, !running else { return false }
        snapshot.error = nil
        start()
        return true
    }

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
