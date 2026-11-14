import Foundation
import HappyWire
import Tailcat

/// Our plugins' lease deadline for `TailcatClients`, kept out of
/// TailcatClients.swift so upstream merges do not conflict there.
///
/// In TailcatClients.swift, `lease(_:until:)` and `client(_:until:)` carry
/// the deadline: with one, `lease` gives up when it passes, throwing
/// `PairingError.unavailable`. `client` waits on a shared connect through
/// `value(of:until:)`, and its cancel handler is named (`leave`) so that a
/// caller leaving early (`LeftEarly`) lets go the same way a cancelled one
/// does. The connect goes on for whoever still waits.
extension TailcatClients {
    /// How one caller's wait on a shared connect ended.
    enum Waited<T: Sendable>: Sendable {
        /// The connect finished, either way.
        case done(Result<T, Error>)
        /// This caller left first: cancelled, or past its deadline.
        case left(Error)
    }

    /// `task`'s result, or sooner when this caller is cancelled or
    /// `deadline` passes. Never cancels `task`: other callers may be
    /// waiting on it too.
    static func wait<T: Sendable>(for task: Task<T, Error>, until deadline: ContinuousClock.Instant?) async -> Waited<T> {
        let once = Once<Waited<T>>()
        once.watch(Task { once.resume(.done(await task.result)) })
        if let deadline {
            once.watch(Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                if !Task.isCancelled { once.resume(.left(PairingError.unavailable)) }
            })
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { once.set($0) }
        } onCancel: { once.resume(.left(CancellationError())) }
    }

    /// The first of several answers, handed to one continuation whether it
    /// came before or after the continuation did; the tasks racing to give
    /// it are cancelled once it is in.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private var answer: T?
        private var watched: [Task<Void, Never>] = []

        func watch(_ task: Task<Void, Never>) {
            let answered = lock.withLock { () -> Bool in
                if answer == nil { watched.append(task) }
                return answer != nil
            }
            if answered { task.cancel() }
        }

        func set(_ continuation: CheckedContinuation<T, Never>) {
            let answer = lock.withLock { () -> T? in
                if self.answer == nil { self.continuation = continuation }
                return self.answer
            }
            if let answer { continuation.resume(returning: answer) }
        }

        func resume(_ value: T) {
            let (continuation, watched) = lock.withLock { () -> (CheckedContinuation<T, Never>?, [Task<Void, Never>])? in
                guard answer == nil else { return nil }
                answer = value
                defer { self.continuation = nil; self.watched = [] }
                return (self.continuation, self.watched)
            } ?? (nil, [])
            watched.forEach { $0.cancel() }
            continuation?.resume(returning: value)
        }
    }

    /// A caller that stopped waiting on a shared connect before it ended.
    struct LeftEarly: Error { let error: Error }

    /// `task`'s value; with a `deadline`, `LeftEarly` once it passes or
    /// this caller is cancelled first. Without one, waits for the connect
    /// whatever happens to this caller, as the waiter count expects.
    static func value(of task: Task<Client, Error>, until deadline: ContinuousClock.Instant?) async throws -> Client {
        guard let deadline else { return try await task.value }
        switch await wait(for: task, until: deadline) {
        case .done(let result): return try result.get()
        case .left(let error): throw LeftEarly(error: error)
        }
    }
}
