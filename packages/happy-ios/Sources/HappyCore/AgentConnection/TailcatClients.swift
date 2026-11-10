import Foundation
import HappyWire
import Tailcat

/// What a request to the computer is for. Each category has Tailcat
/// clients of its own (`TailcatClients`) and its own deadline, so a long
/// upload or a broken file client never holds up the event stream or the
/// next call.
public enum RequestCategory: Sendable, CaseIterable {
    /// The event stream: one request that stays open while the computer talks.
    case realtime
    /// Ordinary API calls, small JSON both ways. What a request is unless it says.
    case query
    /// Bytes: pictures and avatars, attachments and messages that carry
    /// images, tool-call media, artifact files; and the in-app browser's
    /// streams, which carry whole pages.
    case file
}

/// File clients one agent connection may have up at once.
let maxFileClients = 8

/// One agent connection's Tailcat clients: one for `.realtime`, one for
/// `.query` and up to `maxFileClients` for `.file`, each made on first
/// use. Every connect is made with a node key of its own, fresh each time:
/// the computer and the DERP relay tell clients apart by node key, and a
/// relay keeps one connection per key, dropping the older of two that
/// share one.
///
/// A file request goes to the file client with the fewest requests in
/// flight; while every one of them is busy, another is made, up to the
/// cap. A failure resets only the client it happened on (`reset(_ lease:)`);
/// the others, the event stream's included, stay.
final class TailcatClients<Client: AnyObject & Sendable>: @unchecked Sendable {
    typealias Connect = @Sendable (RequestCategory, NodePrivateKey) async throws -> Client
    typealias Disconnect = @Sendable (Client) async -> Void

    /// One client's place: connected, reset and connected again on its own.
    final class Slot: @unchecked Sendable {
        let category: RequestCategory
        let index: Int
        // Guarded by the pool's lock.
        fileprivate var client: Client?
        fileprivate var connecting: Task<Client, Error>?
        /// Callers waiting on `connecting`. One leaving early (cancelled,
        /// or past its deadline) cancels the connect only if it was the last.
        fileprivate var waiters = 0
        fileprivate var inFlight = 0
        init(category: RequestCategory, index: Int) { self.category = category; self.index = index }
    }

    /// A request's hold on one client; `release` once its answer or stream is done.
    final class Lease: @unchecked Sendable {
        let slot: Slot
        let client: Client
        private let pool: TailcatClients
        // Guarded by the pool's lock.
        private var released = false

        fileprivate init(slot: Slot, client: Client, pool: TailcatClients) { self.slot = slot; self.client = client; self.pool = pool }

        /// Safe to call more than once, from anywhere.
        func release() {
            pool.locked {
                guard !released else { return }
                released = true
                slot.inFlight -= 1
            }
        }
    }

    private let connect: Connect
    private let disconnect: Disconnect
    private let fileLimit: Int
    private let newKey: @Sendable () throws -> NodePrivateKey
    private let lock = NSLock()
    private var slots: [Slot] = []
    private var closed = false

    init(fileLimit: Int = maxFileClients, newKey: @escaping @Sendable () throws -> NodePrivateKey = { try NodePrivateKey.generate() },
         connect: @escaping Connect, disconnect: @escaping Disconnect) {
        self.fileLimit = fileLimit; self.newKey = newKey; self.connect = connect; self.disconnect = disconnect
    }

    fileprivate func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    /// A client for `category`, connected; waits while its slot connects,
    /// until `deadline` if there is one (then `PairingError.unavailable`).
    /// Throws `CancellationError` once closed.
    func lease(_ category: RequestCategory, until deadline: ContinuousClock.Instant? = nil) async throws -> Lease {
        let slot = try locked {
            guard !closed else { throw CancellationError() }
            let slot = pick(category)
            slot.inFlight += 1
            return slot
        }
        do { return Lease(slot: slot, client: try await client(slot, until: deadline), pool: self) }
        catch {
            locked { slot.inFlight -= 1 }
            throw error
        }
    }

    /// Under the lock.
    private func pick(_ category: RequestCategory) -> Slot {
        let own = slots.filter { $0.category == category }
        let limit = category == .file ? fileLimit : 1
        if let idlest = own.min(by: { $0.inFlight < $1.inFlight }), idlest.inFlight == 0 || own.count >= limit { return idlest }
        let slot = Slot(category: category, index: own.count)
        slots.append(slot)
        return slot
    }

    private func client(_ slot: Slot, until deadline: ContinuousClock.Instant?) async throws -> Client {
        while true {
            let (ready, task) = try locked { () throws -> (Client?, Task<Client, Error>?) in
                guard !closed else { throw CancellationError() }
                if let client = slot.client { return (client, nil) }
                if let connecting = slot.connecting {
                    slot.waiters += 1
                    return (nil, connecting)
                }
                let connect = connect, newKey = newKey, category = slot.category
                let task = Task { try await connect(category, try newKey()) }
                slot.connecting = task
                slot.waiters = 1
                return (nil, task)
            }
            if let ready { return ready }
            guard let task else { throw CancellationError() }
            let made: Client
            switch await Self.wait(for: task, until: deadline) {
            case .left(let error):
                // Gone early: the connect goes on for whoever still waits.
                let last = locked { () -> Bool in
                    guard slot.connecting == task else { return false }
                    slot.waiters -= 1
                    guard slot.waiters <= 0 else { return false }
                    slot.connecting = nil
                    slot.waiters = 0
                    return true
                }
                if last {
                    task.cancel()
                    // One that connects anyway has nobody to hold it.
                    let disconnect = disconnect
                    Task { if let made = try? await task.value { await disconnect(made) } }
                }
                throw error
            case .done(.failure(let error)):
                locked { if slot.connecting == task { slot.connecting = nil; slot.waiters = 0 } }
                throw error
            case .done(.success(let client)):
                made = client
            }
            // The first caller back keeps it; callers that waited on the same connect see it up once.
            let (kept, owner, isClosed) = locked { () -> (Bool, Bool, Bool) in
                let owner = slot.connecting == task
                if owner { slot.connecting = nil; slot.waiters = 0; if !closed { slot.client = made } }
                return (!closed && slot.client === made, owner, closed)
            }
            if kept { return made }
            // Closed while it connected: nobody will close it later.
            if owner { await disconnect(made) }
            if isClosed { throw CancellationError() }
            // Reset while it connected: connect again.
        }
    }

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

    /// Lets go of `lease`'s client after a failure on it, if its slot still
    /// holds it; the next request there connects again.
    func reset(_ lease: Lease) async {
        let old = locked { () -> Client? in
            guard lease.slot.client === lease.client else { return nil }
            lease.slot.client = nil
            return lease.client
        }
        if let old { await disconnect(old) }
    }

    /// Lets go of every client of `category`; the other categories' stay.
    func reset(_ category: RequestCategory) async {
        let old = locked { () -> [Client] in
            slots.filter { $0.category == category }.compactMap { slot in
                defer { slot.client = nil }
                return slot.client
            }
        }
        for client in old { await disconnect(client) }
    }

    /// Closes every client; nothing connects again.
    func close() async {
        let old = locked { () -> [Client] in
            closed = true
            return slots.compactMap { slot in
                // A connect that finishes anyway is closed by the caller that waited on it.
                slot.connecting?.cancel()
                defer { slot.client = nil }
                return slot.client
            }
        }
        for client in old { await disconnect(client) }
    }

    /// Every connected client, busy or not; none is let go.
    func connected() -> [Client] { locked { slots.compactMap(\.client) } }

    /// How many places `category` has, connected or not.
    func count(_ category: RequestCategory) -> Int { locked { slots.filter { $0.category == category }.count } }
}
