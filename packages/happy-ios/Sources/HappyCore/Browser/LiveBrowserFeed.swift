import Foundation

/// How a live browser's feed reaches the bridge: through the chat's
/// workspace (`BrowserFetcher`), or a fake in tests.
public protocol LiveBrowserTransport: Sendable {
    func send(method: String, url: URL, body: Data?, accept: String) async throws -> Data
    /// Lets go of its connections; nothing is sent after.
    func stop() async
}

/// One chat's live browser, read once for everything that shows it: the
/// mini player, the transcript's chip, the indicator over the composer and
/// the full screen's header. Its state, then (while something on screen
/// shows the picture) its frame, every `interval`, and only while at least
/// one visible observer is attached; nothing at all once the browser is
/// over. Observers are held weakly, by owner.
@MainActor
public final class LiveBrowserFeed {
    public enum Phase: Equatable, Sendable {
        case connecting
        case live(LiveBrowserState)
        /// The bridge doesn't know the link (404).
        case ended
        /// The link expired (410).
        case expired
        /// The workspace's proxy refuses tunnels (501): it runs in a
        /// container, and the browser on the host.
        case unavailable
        /// Anything else; tried again on the next poll.
        case unreachable

        public var state: LiveBrowserState? { if case .live(let state) = self { state } else { nil } }
        /// Nothing more will come: the link is gone, or its session closed.
        public var isOver: Bool {
            switch self {
            case .ended, .expired, .unavailable: true
            case .live(let state): state.ended
            case .connecting, .unreachable: false
            }
        }
    }

    /// Over the chat, small.
    public static let interval: Duration = .milliseconds(1500)
    /// Large or full screen.
    public static let fastInterval: Duration = .milliseconds(1000)
    /// The longest one read of the state or the frame may take. The
    /// workspace tunnel has no deadline of its own: a read that never
    /// answered held the poll forever, and with it the picture, which no
    /// resize or reattach could restart (a poll in flight is never
    /// started again).
    public static let requestTimeout: Duration = .seconds(8)
    /// `requestTimeout`, shorter in tests.
    public var requestTimeout: Duration = LiveBrowserFeed.requestTimeout

    public let link: LiveBrowserLink
    public private(set) var phase: Phase = .connecting { didSet { if phase != oldValue { publish() } } }
    /// The latest frame's bytes (PNG or JPEG; decode by content).
    public private(set) var frame: Data?
    /// Polls made (tests).
    public private(set) var polls = 0
    public var isPolling: Bool { polling != nil }
    /// Polling, yet nothing begun or finished for `stallLimit`: a read
    /// stuck where even `requestTimeout` didn't reach it.
    public var isStalled: Bool { polling != nil && ContinuousClock.now - lastActivity > stallLimit }
    /// Longer than any poll may take: both its reads, and the wait.
    public var stallLimit: Duration { requestTimeout * 2 + Self.interval }

    private let makeTransport: @MainActor () -> LiveBrowserTransport?
    private var transport: LiveBrowserTransport?
    private var polling: Task<Void, Never>?
    private var observers: [ObjectIdentifier: Observer] = [:]
    /// When the poll last began, finished or woke.
    private var lastActivity = ContinuousClock.now
    /// Visible observers when last reconsidered.
    private var visibleCount = 0

    private struct Observer {
        weak var owner: AnyObject?
        var visible: Bool
        var frames: Bool
        var fast: Bool
        var update: @MainActor (LiveBrowserFeed) -> Void
    }

    /// `transport` is made when polling starts and stopped when it pauses;
    /// nil (no computer to reach it through) leaves the feed connecting.
    public init(link: LiveBrowserLink, transport: @escaping @MainActor () -> LiveBrowserTransport?) {
        self.link = link
        makeTransport = transport
    }

    // MARK: Observers

    /// `owner` shows the feed: `update` runs on every change while it is
    /// attached. `frames`: it shows the picture; `fast`: it shows it large.
    public func attach(_ owner: AnyObject, visible: Bool = true, frames: Bool = false, fast: Bool = false, update: @escaping @MainActor (LiveBrowserFeed) -> Void) {
        observers[ObjectIdentifier(owner)] = Observer(owner: owner, visible: visible, frames: frames, fast: fast, update: update)
        reconsider()
    }

    /// On screen or not; anything else stays as attached.
    public func set(_ owner: AnyObject, visible: Bool? = nil, frames: Bool? = nil, fast: Bool? = nil) {
        guard var observer = observers[ObjectIdentifier(owner)] else { return }
        if let visible { observer.visible = visible }
        if let frames { observer.frames = frames }
        if let fast { observer.fast = fast }
        observers[ObjectIdentifier(owner)] = observer
        reconsider()
    }

    public func detach(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
        reconsider()
    }

    /// Stops for good: the chat let the feed go.
    public func close() {
        observers.removeAll()
        reconsider()
    }

    private var watching: [Observer] {
        observers = observers.filter { $0.value.owner != nil }
        return observers.values.filter(\.visible)
    }

    private var wantsFrames: Bool { watching.contains(where: \.frames) }

    /// How often it reads now: faster while something shows it large.
    public var currentInterval: Duration { watching.contains(where: \.fast) ? Self.fastInterval : Self.interval }

    /// Polls again from scratch, over a new transport, if the poll is
    /// stalled: the player shown again, or something else asking for it.
    public func kick() {
        guard isStalled else { return }
        pause()
        reconsider()
    }

    /// Any change in how many visible observers there are also restarts a
    /// stalled poll; with none, or the browser over, it pauses.
    private func reconsider() {
        let count = watching.count
        defer { visibleCount = count }
        if count == 0 || phase.isOver { return pause() }
        if count != visibleCount, isStalled { pause() }
        start()
    }

    private func publish() {
        for observer in observers.values where observer.owner != nil { observer.update(self) }
    }

    // MARK: Polling

    private func start() {
        guard polling == nil else { return }
        guard let transport = transport ?? makeTransport() else { return }
        self.transport = transport
        lastActivity = .now
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.lastActivity = .now
                let keepGoing = await self.poll(transport)
                guard !Task.isCancelled else { return }
                self.lastActivity = .now
                guard keepGoing else { break }
                try? await Task.sleep(for: self.currentInterval)
            }
            guard let self, !Task.isCancelled else { return }
            self.polling = nil
            self.releaseTransport()
        }
    }

    private func pause() {
        polling?.cancel()
        polling = nil
        releaseTransport()
    }

    private func releaseTransport() {
        guard let transport else { return }
        self.transport = nil
        Task { await transport.stop() }
    }

    /// One read of the state and, if shown, the frame; false once there is
    /// nothing more to read.
    private func poll(_ transport: LiveBrowserTransport) async -> Bool {
        polls += 1
        do {
            let data = try await read(link.stateURL, accept: "application/json", through: transport)
            var state = try JSONDecoder().decode(LiveBrowserState.self, from: data)
            guard !Task.isCancelled else { return false }
            // An asleep browser has no frame to give (503); none is asked for.
            if wantsFrames, !state.ended, !state.asleep {
                do {
                    let frame = try await read(link.frameURL, accept: "image/*,*/*;q=0.8", through: transport)
                    guard !Task.isCancelled else { return false }
                    if frame != self.frame {
                        self.frame = frame
                        if phase == .live(state) { publish() }
                    }
                } catch BrowserError.upstream(503) {
                    // It fell asleep between the two reads.
                    state.pod = .asleep
                } catch {}
                guard !Task.isCancelled else { return false }
            }
            phase = .live(state)
            return !state.ended
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return false }
            switch error {
            case BrowserError.upstream(404): phase = .ended; return false
            case BrowserError.upstream(410): phase = .expired; return false
            // 501: the workspace's proxy refuses tunnels; `.unavailable`:
            // no workspace for the chat could be decided on.
            case BrowserError.upstream(501), BrowserError.unavailable: phase = .unavailable; return false
            default: phase = .unreachable; return true
            }
        }
    }

    /// One GET, given up on (`BrowserError.timeout`) after
    /// `requestTimeout` whether or not the transport lets go of it.
    private func read(_ url: URL, accept: String, through transport: LiveBrowserTransport) async throws -> Data {
        try await Self.within(requestTimeout) {
            try await transport.send(method: "GET", url: url, body: nil, accept: accept)
        }
    }

    /// `operation`'s answer, or `BrowserError.timeout` after `limit`, or
    /// `CancellationError` once the caller is cancelled: the first of the
    /// three. The operation is cancelled when it loses, but it isn't waited
    /// for, so one that ignores cancellation can't hold the caller.
    static func within<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = Once<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.begin(continuation)
                let work = Task {
                    do { once.finish(.success(try await operation())) } catch { once.finish(.failure(error)) }
                }
                once.onLose { work.cancel() }
                Task {
                    try? await Task.sleep(for: limit)
                    once.finish(.failure(BrowserError.timeout))
                }
            }
        } onCancel: {
            once.finish(.failure(CancellationError()))
        }
    }

    /// The continuation `within` resumes once, whichever finishes first.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var early: Result<T, Error>?
        private var done = false
        private var lose: (() -> Void)?

        func begin(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let early { lock.unlock(); continuation.resume(with: early); return }
            self.continuation = continuation
            lock.unlock()
        }

        func onLose(_ action: @escaping () -> Void) {
            lock.lock()
            if done { lock.unlock(); action(); return }
            lose = action
            lock.unlock()
        }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let continuation = continuation
            self.continuation = nil
            if continuation == nil { early = result }
            let lose = lose
            self.lose = nil
            lock.unlock()
            continuation?.resume(with: result)
            lose?()
        }
    }

    // MARK: Control

    /// How long Take control waits for an asleep browser to wake.
    public static let wakeTimeout: Duration = .seconds(20)
    /// The first wait before asking again; it grows to `wakeRetryMax`.
    public static let wakeRetry: Duration = .milliseconds(500)
    public static let wakeRetryMax: Duration = .seconds(1)

    /// Takes control (`POST /take`): the agent's actions are refused until
    /// `release()`. Answers the noVNC page to drive it with. An asleep
    /// browser is woken: the bridge answers 202 (`waking`), the phase says
    /// starting, and it is asked again until it runs, for up to `timeout`
    /// (then `BrowserError.timeout`).
    @discardableResult
    public func take(timeout: Duration = LiveBrowserFeed.wakeTimeout, retry: Duration = LiveBrowserFeed.wakeRetry) async throws -> LiveBrowserTake {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var wait = retry
        while true {
            let data = try await post(link.takeURL)
            let take = try JSONDecoder().decode(LiveBrowserTake.self, from: data)
            phase = .live(take.state)
            guard take.waking else { return take }
            guard clock.now + wait <= deadline else { throw BrowserError.timeout }
            try await Task.sleep(for: wait)
            wait = min(wait * 2, max(retry, Self.wakeRetryMax))
        }
    }

    /// Ends the browser (`POST /end`): its session closes and the agent
    /// loses the page. The feed is then over (`done`, `user_ended`).
    public func end() async throws {
        let data = try await post(link.endURL)
        if let state = try? JSONDecoder().decode(LiveBrowserState.self, from: data) { phase = .live(state) }
    }

    /// Hands control back (`POST /release`); a bridge from before it
    /// (404) is asked with `/done`.
    public func release() async throws {
        let data: Data
        do {
            data = try await post(link.releaseURL)
        } catch BrowserError.upstream(404) {
            data = try await post(link.doneURL)
        }
        if let state = try? JSONDecoder().decode(LiveBrowserState.self, from: data) { phase = .live(state) }
    }

    /// Over its own transport, which a paused feed may not have.
    private func post(_ url: URL) async throws -> Data {
        if let transport { return try await transport.send(method: "POST", url: url, body: nil, accept: "application/json") }
        guard let transport = makeTransport() else { throw BrowserError.unavailable }
        defer { Task { await transport.stop() } }
        return try await transport.send(method: "POST", url: url, body: nil, accept: "application/json")
    }
}

/// For a chat with no computer to reach its browser through: every
/// request is refused, and the feed says unavailable.
public struct RefusedLiveBrowserTransport: LiveBrowserTransport {
    public init() {}
    public func send(method: String, url: URL, body: Data?, accept: String) async throws -> Data { throw BrowserError.unavailable }
    public func stop() async {}
}

#if canImport(Network)
extension BrowserFetcher: LiveBrowserTransport {}
#endif
