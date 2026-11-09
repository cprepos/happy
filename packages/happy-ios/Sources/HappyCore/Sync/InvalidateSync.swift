import Foundation

/// Exponential backoff, capped.
public struct Backoff: Sendable {
    public var initial: Duration
    public var maximum: Duration

    public init(initial: Duration, maximum: Duration) {
        self.initial = initial
        self.maximum = maximum
    }

    public static let standard = Backoff(initial: .seconds(1), maximum: .seconds(30))

    /// Delay before retry number `attempt` (1-based).
    public func delay(attempt: Int) -> Duration {
        var delay = initial
        for _ in 1..<max(1, attempt) {
            delay = delay * 2
            if delay >= maximum { return maximum }
        }
        return min(delay, maximum)
    }
}

/// Runs an operation whenever it is invalidated, coalescing invalidations
/// that arrive while it is running into a single follow-up run, and
/// retrying failures with backoff. The Swift counterpart of happy-app's
/// InvalidateSync: every sync job (sessions, machines, one session's
/// messages, the outbox) is one of these.
public actor InvalidateSync {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// `Task.sleep`, the default `Sleep`. Default arguments name this rather
    /// than spelling the closure out: a public default argument is compiled
    /// again into every module that leaves it out, and with Swift 6.3.3 such
    /// an async closure came out with a 144-byte async context here and a
    /// 128-byte one in the calling module. The linker kept one module's
    /// function and the other's size, the callee wrote past its context,
    /// and the task allocator aborted ("freed pointer was not the last
    /// allocation"). A stored closure is compiled once, in this module.
    public static let taskSleep: Sleep = { try await Task.sleep(for: $0) }

    /// A run that took longer than its `timeout`; it was cancelled and is
    /// retried with backoff like any other failure.
    public struct TimedOut: Error, Equatable {}

    private let operation: @Sendable () async throws -> Void
    private let backoff: Backoff
    private let sleep: Sleep
    private let timeout: Duration?
    private var task: Task<Void, Never>?
    /// Bumped by `restart`: a drain of an older generation was cancelled and
    /// leaves the task, the waiters and the dirty flag to the newer one.
    private var generation = 0
    private var dirty = false
    private var stopped = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// `timeout` bounds each run (nil: none): a request that hangs without
    /// failing would otherwise hold the job, and every invalidation queued
    /// behind it, until the system gives up. It is measured on the real
    /// clock, not `sleep`, which only paces retries.
    public init(
        backoff: Backoff = .standard,
        sleep: @escaping Sleep = InvalidateSync.taskSleep,
        timeout: Duration? = nil,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        self.backoff = backoff
        self.sleep = sleep
        self.timeout = timeout
        self.operation = operation
    }

    public var isRunning: Bool { task != nil }

    public func invalidate() {
        guard !stopped else { return }
        dirty = true
        if task == nil {
            let generation = self.generation
            task = Task { await self.drain(generation) }
        }
    }

    /// Runs now: a run in flight, or a backoff pause before a retry, is
    /// cancelled, and a fresh run starts once the cancelled one has ended
    /// (runs never overlap). For a person asking for fresh data, who should
    /// not wait out a backoff or a request that has stalled.
    public func restart() {
        guard !stopped else { return }
        dirty = true
        let previous = task
        previous?.cancel()
        generation += 1
        let generation = self.generation
        task = Task {
            await previous?.value
            await self.drain(generation)
        }
    }

    /// `restart`, then returns once a run has succeeded (or the sync was
    /// stopped).
    public func restartAndAwait() async {
        guard !Task.isCancelled else { return }
        restart()
        await awaitRun()
    }

    /// Invalidates and returns once a run that started after this call has
    /// succeeded (or the sync was stopped).
    public func invalidateAndAwait() async {
        guard !Task.isCancelled else { return }
        invalidate()
        await awaitRun()
    }

    private func awaitRun() async {
        guard task != nil else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Returns once nothing is left to run, without asking for another run:
    /// at once when idle, else when the run in flight (and its retries)
    /// has succeeded or the sync was stopped.
    public func settled() async {
        guard task != nil, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Cancels the run in flight and returns once it has ended, so nothing it
    /// fetched is merged afterwards: a switch or sign-out may close or erase
    /// the store next. Requests honour cancellation; a store write already
    /// under way finishes first.
    public func stop() async {
        stopped = true
        let running = task
        running?.cancel()
        resumeWaiters()
        await running?.value
        task = nil
    }

    private func drain(_ generation: Int) async {
        var attempt = 0
        while dirty && !stopped && generation == self.generation && !Task.isCancelled {
            dirty = false
            do {
                try await runOnce()
                attempt = 0
            } catch {
                if stopped || Task.isCancelled { break }
                dirty = true
                attempt += 1
                try? await sleep(backoff.delay(attempt: attempt))
            }
        }
        // A restart superseded this drain: the newer one owns what is left.
        guard generation == self.generation else { return }
        task = nil
        resumeWaiters()
    }

    /// One run of the operation, cancelled and failed with `TimedOut` past
    /// `timeout`. A run that ignores cancellation is still waited for, so
    /// runs never overlap.
    private func runOnce() async throws {
        guard let timeout else { return try await operation() }
        let operation = self.operation
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func resumeWaiters() {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
