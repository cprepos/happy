import Foundation
import HappyStore
import HappyWire

/// Our plugins' additions to `AccountSession`, kept out of
/// AccountSession.swift so merges from upstream do not conflict there.
extension AccountSession {
    /// Away this long, and coming back to the foreground starts over: iOS
    /// may have frozen the socket while the app was suspended and dropped
    /// the updates sent meanwhile.
    static let staleAfter: Duration = .seconds(20)

    /// A socket silent this long is taken for dead. The server pings every
    /// 15 s (happy-server `socketConfig.ts` `pingInterval`), so a healthy
    /// socket is never quiet for two of them plus a margin.
    static let silentAfter: Duration = .seconds(40)

    static func isStale(away: Duration?, silence: Duration?) -> Bool {
        (away ?? .zero) > staleAfter || (silence ?? .zero) > silentAfter
    }

    /// A new socket (whose catch-up pulls what changed), every list pulled
    /// now rather than after it connects, and the chat on screen too.
    func resyncAfterForeground() async {
        await realtime.reconnect()
        await sync.syncAll()
        if let open = resync.openSession {
            await sync.invalidate(.messages(sessionId: open))
        }
    }

    /// The chat on screen, pulled again on a return to the foreground.
    public func chatAppeared(_ sessionId: String) {
        resync.setOpenSession(sessionId)
    }

    /// That chat left the screen (another may have appeared first).
    public func chatDisappeared(_ sessionId: String) {
        resync.clearOpenSession(sessionId)
    }

    /// Brings `scope` up to date because the person asked: the socket is
    /// replaced even when it says connected (it may be dead), and the
    /// scope's pulls start now, skipping any backoff, then are waited for
    /// up to `timeout`. Past it the pulls go on; the answer is `.timedOut`.
    /// Calls for a scope already refreshing share that refresh.
    @discardableResult
    public func refresh(scope: RefreshScope, timeout: Duration = .seconds(15)) async -> RefreshOutcome {
        guard !resync.isStopped else { return .offline }
        let realtime = self.realtime
        let sync = self.sync
        let task = resync.refresh(scope) {
            await Self.performRefresh(scope: scope, timeout: timeout, realtime: realtime, sync: sync,
                                      online: NetworkPath.shared.isSatisfied)
        }
        return await task.value
    }

    static func performRefresh(scope: RefreshScope, timeout: Duration, realtime: SocketIOClient,
                               sync: LegacySyncEngine, online: Bool) async -> RefreshOutcome {
        guard online else { return .offline }
        await realtime.reconnect()
        let jobs: [LegacySyncEngine.Job] = switch scope {
        case .home: [.sessions, .pendingMessages]
        case .chat(let id): [.messages(sessionId: id)]
        case .machines: [.machines]
        }
        // Not a child of this call: a refresh that times out, or whose
        // caller goes away, leaves the pulls running.
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                for job in jobs { group.addTask { await sync.restartAndAwait(job) } }
            }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<RefreshOutcome, Never>) in
            let answer = FirstAnswer(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                answer.resume(.timedOut)
            }
            Task {
                await work.value
                answer.resume(.refreshed)
                timer.cancel()
            }
        }
    }

    /// `sendAppState`'s hook, after the engine hears it: back after a long
    /// while (or with the socket silent too long), the socket is replaced
    /// and everything is pulled again; going away starts the clock.
    func foregroundChanged(active: Bool) async {
        if active {
            let away = resync.foregrounded()
            let silence = await realtime.silence
            if !resync.isStopped, Self.isStale(away: away, silence: silence) { await resyncAfterForeground() }
        } else {
            resync.backgrounded()
        }
    }

    /// An update this build cannot read still says something changed: the
    /// change is pulled instead of dropped, so the chat or list it touched
    /// does not stay stale until the next reconnect. Only the type is
    /// logged, never the payload.
    static func undecodable(update payload: JSONValue, sync: LegacySyncEngine) async {
        let body = payload["body"]
        let type = body?["t"]?.stringValue ?? "?"
        SyncLog.error("update of type \(type) did not decode; pulling instead")
        if type == "new-message", let sessionId = body?["sid"]?.stringValue {
            await sync.invalidate(.messages(sessionId: sessionId))
        } else {
            await sync.syncAll()
        }
    }

    /// Presence this build cannot read: what it would have changed is in
    /// the session or machine records, pulled again.
    static func undecodable(ephemeral payload: JSONValue, sync: LegacySyncEngine) async {
        let type = payload["type"]?.stringValue ?? "?"
        SyncLog.error("ephemeral of type \(type) did not decode; pulling instead")
        switch type {
        case "activity": await sync.invalidate(.sessions)
        case "machine-activity", "machine-status": await sync.invalidate(.machines)
        default: await sync.syncAll()
        }
    }
}

/// `AccountSession`'s foreground and refresh bookkeeping, behind a lock.
final class ResyncState: @unchecked Sendable {
    private let lock = NSLock()
    private var backgroundedAt: ContinuousClock.Instant?
    private var open: String?
    private var refreshes: [RefreshScope: (id: UUID, task: Task<RefreshOutcome, Never>)] = [:]
    /// Tests: added to the clock, standing in for time away.
    private var skew: Duration = .zero
    private var stopped = false

    var isStopped: Bool { lock.withLock { stopped } }

    func stop() {
        lock.withLock { stopped = true }
    }

    /// Read with the lock held.
    private var now: ContinuousClock.Instant { ContinuousClock.now + skew }

    func backgrounded() {
        lock.withLock { backgroundedAt = now }
    }

    /// How long the app was in the background; nil if it was not.
    func foregrounded() -> Duration? {
        lock.withLock {
            defer { backgroundedAt = nil }
            return backgroundedAt.map { now - $0 }
        }
    }

    var openSession: String? { lock.withLock { open } }

    func setOpenSession(_ id: String) {
        lock.withLock { open = id }
    }

    func clearOpenSession(_ id: String) {
        lock.withLock { if open == id { open = nil } }
    }

    func advanceClock(by duration: Duration) {
        lock.withLock { skew += duration }
    }

    /// The refresh of `scope` running, or a new one running `work`.
    func refresh(_ scope: RefreshScope, _ work: @escaping @Sendable () async -> RefreshOutcome) -> Task<RefreshOutcome, Never> {
        lock.withLock {
            if let running = refreshes[scope] { return running.task }
            let id = UUID()
            let task = Task {
                let outcome = await work()
                self.finished(scope, id)
                return outcome
            }
            refreshes[scope] = (id, task)
            return task
        }
    }

    private func finished(_ scope: RefreshScope, _ id: UUID) {
        lock.withLock { if refreshes[scope]?.id == id { refreshes[scope] = nil } }
    }
}

/// Resumes a continuation with the first answer given, ignoring the rest.
final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let pending: CheckedContinuation<Value, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
