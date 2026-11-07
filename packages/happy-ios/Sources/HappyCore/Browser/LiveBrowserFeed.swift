import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// What the live browser's feed and lookup say of a request that went
/// nowhere: ids shortened, never a page's contents.
public enum LiveBrowserLog {
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "app.happy", category: "LiveBrowser")
    public static func info(_ message: String) { logger.notice("\(message, privacy: .public)") }
    #else
    public static func info(_ message: String) { print("[LiveBrowser] \(message)") }
    #endif
}

/// How a live browser's feed reaches the bridge: through the chat's
/// workspace (`BrowserFetcher`), or a fake in tests.
public protocol LiveBrowserTransport: Sendable {
    func send(method: String, url: URL, body: Data?, accept: String) async throws -> Data
    /// Lets go of its connections; nothing is sent after.
    func stop() async
}

/// One chat's live browser, read once for everything that shows it: the
/// mini player, the transcript's chip, the indicator over the composer and
/// the full screen's header. Its state every `interval`, and (while
/// something on screen shows the picture) its frame in a loop of its own,
/// one read at a time, `frameGap` apart; only while at least one visible
/// observer is attached; nothing at all once the browser is over.
/// Observers are held weakly, by owner.
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
        /// The bridge says no browser runs for the link now (`/live/chat`
        /// answered not live, asleep or done), with what it last had: it
        /// rests, reading nothing, until `retry()`. The agent's next
        /// browser call brings it back from its saved cookies and page.
        case dormant(LiveBrowserState)
        /// Connecting, with nothing answered (or no picture) for
        /// `stuckLimit`: it stopped asking, until `retry()`.
        case notResponding

        public var state: LiveBrowserState? { if case .live(let state) = self { state } else { nil } }
        /// What the bridge last said of a dormant browser.
        public var dormantState: LiveBrowserState? { if case .dormant(let state) = self { state } else { nil } }
        /// Nothing more will come: the link is gone, or its session closed.
        public var isOver: Bool {
            switch self {
            case .ended, .expired, .unavailable: true
            case .live(let state): state.ended
            case .connecting, .unreachable, .dormant, .notResponding: false
            }
        }
        /// Not read, though not over: `retry()` reads again.
        public var isResting: Bool {
            switch self {
            case .dormant, .notResponding: true
            default: false
            }
        }
        /// The bridge answered, and says a browser runs for it.
        public var isRunning: Bool { state?.runs ?? false }
    }

    /// The state, while nothing shows the picture (the line, a chip).
    public static let interval: Duration = .milliseconds(1500)
    /// The state, while the picture shows, small or large.
    public static let fastInterval: Duration = .milliseconds(1000)
    /// From one frame's answer to the next frame's ask. The bridge takes
    /// most of a second to make a frame (it scrubs each one), so frames
    /// come back to back rather than on a clock.
    public static let frameGap: Duration = .milliseconds(300)
    /// `frameGap`, shorter in tests.
    public var frameGap: Duration = LiveBrowserFeed.frameGap
    /// How long the picture may go without a good frame before the feed
    /// says it is waiting, and the player spins. Until then the last good
    /// frame stays up, with no spinner, through the next frame, a state
    /// read, a page change or a retry at the other origin: the bridge
    /// refreshes often, and a spinner each time is noise. With no frame
    /// yet (the first connect) it is waiting at once.
    public static let staleFrameLimit: Duration = .seconds(4)
    /// `staleFrameLimit`.
    public static let waitingAfter: Duration = staleFrameLimit
    /// `waitingAfter`, shorter in tests.
    public var waitingAfter: Duration = LiveBrowserFeed.waitingAfter
    /// The longest one read of the state or the frame may take. The
    /// workspace tunnel has no deadline of its own: a read that never
    /// answered held the poll forever, and with it the picture, which no
    /// resize or reattach could restart (a poll in flight is never
    /// started again).
    public static let requestTimeout: Duration = .seconds(8)
    /// `requestTimeout`, shorter in tests.
    public var requestTimeout: Duration = LiveBrowserFeed.requestTimeout

    /// The browser, as the feed was made for it: what the chat names, and
    /// what a feed is told apart by.
    public let link: LiveBrowserLink
    /// `link` at the bridge origin that answers from the chat's computer.
    /// It starts as `link`'s own; a read or post there that gets no answer
    /// from the bridge (the tunnel refused, 502, a dropped connection, no
    /// answer in time) moves it to the next of `LiveBrowserLink.origins`,
    /// and the one that answers is kept. A link a chat posted for one
    /// origin still shows from a computer that reaches the bridge at the
    /// other (a Mac chat's `localhost` link, with no tunnel to it).
    public private(set) var activeLink: LiveBrowserLink
    /// Origins moved to (tests).
    public private(set) var originMoves = 0
    public private(set) var phase: Phase = .connecting {
        didSet {
            guard phase != oldValue else { return }
            isWaiting = computeWaiting()
            publish()
        }
    }
    /// The latest frame's bytes (PNG or JPEG; decode by content).
    public private(set) var frame: Data?
    /// Polls of the state made (tests).
    public private(set) var polls = 0
    /// Frame reads asked (tests).
    public private(set) var frameReads = 0
    public var isPolling: Bool { polling != nil }
    /// Reading frames: something shows the picture.
    public var isFraming: Bool { framing != nil }
    /// The picture shows, and the frame it shows is not the latest one:
    /// none has come yet, or the one asked for has gone `waitingAfter`
    /// unanswered (the bridge busy with an action, a slow tunnel). The
    /// player spins over the last frame. Never while asleep, resting or
    /// over: those say so in words.
    public private(set) var isWaiting = false
    /// Polling, yet nothing begun or finished for `stallLimit`: a read
    /// stuck where even `requestTimeout` didn't reach it.
    public var isStalled: Bool {
        guard polling != nil else { return false }
        let now = ContinuousClock.now
        if now - lastActivity > stallLimit { return true }
        return framing != nil && now - lastFrameActivity > requestTimeout + Self.interval + frameGap
    }
    /// Longer than any poll may take: its read, and the wait.
    public var stallLimit: Duration { requestTimeout * 2 + Self.interval }
    /// How long it may connect, or show no picture, with nothing but
    /// failures before it says not responding.
    public static let stuckLimit: Duration = .seconds(20)
    /// `stuckLimit`, shorter in tests.
    public var stuckLimit: Duration = LiveBrowserFeed.stuckLimit
    /// Since when every read failed (or no picture came), if they do.
    private var failingSince: ContinuousClock.Instant?

    private let makeTransport: @MainActor () -> LiveBrowserTransport?
    private var transport: LiveBrowserTransport?
    private var polling: Task<Void, Never>?
    /// The frame loop, while the picture shows.
    private var framing: Task<Void, Never>?
    /// When the frame read now in flight was asked, if one is.
    private var frameAskedAt: ContinuousClock.Instant?
    /// When the last good frame came (or the frame loop began again with
    /// one up); `isWaiting` counts `waitingAfter` from it.
    private var lastFrameAt: ContinuousClock.Instant?
    /// A good frame came under `waitingAfter` ago: the picture is current.
    private var frameIsFresh: Bool {
        guard frame != nil, let at = lastFrameAt else { return false }
        return ContinuousClock.now - at < waitingAfter
    }
    /// Re-reads `isWaiting` when a frame read goes unanswered too long.
    private var waitWatch: Task<Void, Never>?
    /// When the frame loop last began or finished a read.
    private var lastFrameActivity = ContinuousClock.now
    /// The last frame read failed, with no picture yet.
    private var frameFailing = false
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
        activeLink = link
        makeTransport = transport
    }

    // MARK: Observers

    /// `owner` shows the feed: `update` runs on every change while it is
    /// attached. `frames`: it shows the picture (frames then come as fast
    /// as the bridge makes them, and the state at `fastInterval`); `fast`:
    /// it shows the state somewhere it must be quick, with no picture.
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

    /// How often it reads the state now: faster while something shows the
    /// picture, small or large (the small player once read slower, and
    /// only caught up when made large).
    public var currentInterval: Duration { watching.contains(where: { $0.fast || $0.frames }) ? Self.fastInterval : Self.interval }

    /// Polls again from scratch, over a new transport, if the poll is
    /// stalled: the player shown again, or something else asking for it.
    public func kick() {
        guard isStalled else { return }
        pause()
        reconsider()
    }

    /// Something just began showing the picture (the player opened): a
    /// poll that has brought no picture yet starts over now, its failures
    /// forgotten, rather than wait out a read in flight; else as `kick()`.
    public func pollNow() {
        guard polling != nil, frame == nil else { return kick() }
        failingSince = nil
        frameFailing = false
        pause()
        reconsider()
    }

    /// Any change in how many visible observers there are also restarts a
    /// stalled poll; with none, or the browser over, it pauses.
    private func reconsider() {
        let count = watching.count
        defer { visibleCount = count }
        if count == 0 || phase.isOver || phase.isResting { return pause() }
        if count != visibleCount, isStalled { pause() }
        start()
    }

    /// The bridge says no browser runs for the link: it stops reading,
    /// frames and all, and shows `state` (its last page) as asleep.
    public func rest(_ state: LiveBrowserState) {
        guard !phase.isOver else { return }
        failingSince = nil
        frameFailing = false
        phase = .dormant(state)
        pause()
    }

    /// Reads again from scratch after resting (Retry, or the bridge saying
    /// it runs again).
    public func retry() {
        guard phase.isResting else { return }
        failingSince = nil
        frameFailing = false
        phase = .connecting
        pause()
        reconsider()
    }

    /// A read failed (or no picture came): true once that has gone on for
    /// `stuckLimit`, and it is not responding.
    private func failing() -> Bool {
        let now = ContinuousClock.now
        guard let since = failingSince else { failingSince = now; return false }
        guard now - since >= stuckLimit else { return false }
        failingSince = nil
        frameFailing = false
        phase = .notResponding
        return true
    }

    private func publish() {
        for observer in observers.values where observer.owner != nil { observer.update(self) }
    }

    // MARK: Polling

    private func start() {
        startFraming()
        guard polling == nil else { return }
        guard let transport = transport ?? makeTransport() else { return }
        self.transport = transport
        lastActivity = .now
        // Time off screen isn't time failing.
        failingSince = nil
        frameFailing = false
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
            self.stopFraming()
            self.releaseTransport()
        }
        startFraming()
    }

    private func pause() {
        polling?.cancel()
        polling = nil
        stopFraming()
        releaseTransport()
    }

    private func releaseTransport() {
        guard let transport else { return }
        self.transport = nil
        Task { await transport.stop() }
    }

    /// One read of the state; false once there is nothing more to read.
    /// The picture is the frame loop's.
    private func poll(_ transport: LiveBrowserTransport) async -> Bool {
        polls += 1
        do {
            let data = try await readMoving({ $0.stateURL }, accept: "application/json", through: transport)
            let state = try JSONDecoder().decode(LiveBrowserState.self, from: data)
            guard !Task.isCancelled else { return false }
            // Never a picture for `stuckLimit`, though the state answers.
            if wantsFrames, frame == nil, frameFailing, !state.asleep, !state.ended {
                if failing() { return false }
            } else {
                failingSince = nil
            }
            phase = .live(state)
            refreshWaiting()
            return !state.ended
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return false }
            switch error {
            case BrowserError.upstream(404): phase = .ended; return false
            case BrowserError.upstream(410): phase = .expired; return false
            // 501: the workspace's proxy refuses tunnels; `.unavailable`:
            // no workspace for the chat could be decided on.
            case BrowserError.upstream(501), BrowserError.unavailable: phase = .unavailable; return false
            // 503 and the rest: asked again, until it has gone on too long.
            default:
                if failing() { return false }
                // A read missed at both origins while the picture is
                // current: the browser still shows, as it was.
                if phase.state != nil, frameIsFresh { return true }
                phase = .unreachable
                return true
            }
        }
    }

    // MARK: Frames

    /// The frame loop: while the state loop runs and something shows the
    /// picture, one frame read at a time, the next asked `frameGap` after
    /// the last answered, at the same pace small or large. Apart from the
    /// state, so a slow state read never holds the picture back, nor a slow
    /// picture the state.
    private func startFraming() {
        guard polling != nil, wantsFrames, framing == nil, let transport else {
            if !wantsFrames { stopFraming() }
            return
        }
        lastFrameActivity = .now
        // The frame up is the last good one, from now: no spinner over it
        // for `waitingAfter`.
        if frame != nil { lastFrameAt = .now }
        framing = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.readFrame(transport)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: wait)
            }
        }
        refreshWaiting()
    }

    private func stopFraming() {
        framing?.cancel()
        framing = nil
        frameAskedAt = nil
        waitWatch?.cancel()
        waitWatch = nil
        refreshWaiting()
    }

    /// How soon the frame loop looks again for the state's first answer.
    static let stateWait: Duration = .milliseconds(50)

    /// One frame read; answers how long to wait before the next.
    private func readFrame(_ transport: LiveBrowserTransport) async -> Duration {
        lastFrameActivity = .now
        // Not before the bridge has said the browser runs: an asleep one
        // has no frame to give (503), and an over one none at all.
        guard let state = phase.state else { return Self.stateWait }
        if state.asleep || state.ended { return currentInterval }
        frameReads += 1
        let asked = ContinuousClock.now
        frameAskedAt = asked
        watchWaiting(from: frame == nil ? asked : (lastFrameAt ?? asked))
        defer {
            if frameAskedAt == asked { frameAskedAt = nil }
            lastFrameActivity = .now
        }
        do {
            let asked = activeLink
            let frame: Data
            do {
                frame = try await read(asked.frameURL, accept: "image/*,*/*;q=0.8", through: transport)
            } catch {
                // The next frame is asked at the next origin.
                if !Task.isCancelled { missed(asked, error) }
                throw error
            }
            guard !Task.isCancelled else { return .zero }
            frameFailing = false
            frameAskedAt = nil
            lastFrameAt = .now
            let waited = isWaiting
            isWaiting = computeWaiting()
            if frame != self.frame {
                self.frame = frame
                publish()
            } else if waited != isWaiting {
                publish()
            }
            return frameGap
        } catch BrowserError.upstream(503) {
            guard !Task.isCancelled else { return .zero }
            // It fell asleep: the state says so until it wakes.
            if case .live(var state) = phase {
                state.pod = .asleep
                phase = .live(state)
            }
            frameAskedAt = nil
            refreshWaiting()
            return currentInterval
        } catch {
            guard !Task.isCancelled else { return .zero }
            if frame == nil { frameFailing = true }
            frameAskedAt = nil
            refreshWaiting()
            return currentInterval
        }
    }

    /// Re-reads `isWaiting` `waitingAfter` after `asked` (the last good
    /// frame, or with none the read's ask).
    private func watchWaiting(from asked: ContinuousClock.Instant) {
        waitWatch?.cancel()
        let delay = waitingAfter
        waitWatch = Task { [weak self] in
            try? await Task.sleep(until: asked + delay, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.refreshWaiting()
        }
    }

    private func computeWaiting() -> Bool {
        guard framing != nil, wantsFrames, !phase.isOver, !phase.isResting else { return false }
        if let state = phase.state, state.asleep || state.ended { return false }
        if frame == nil { return true }
        // A good frame is up: waiting only once none has come for
        // `waitingAfter`, whatever is read or retried meanwhile.
        return !frameIsFresh
    }

    /// `isWaiting` as it is now, published if it changed.
    private func refreshWaiting() {
        let now = computeWaiting()
        guard now != isWaiting else { return }
        isWaiting = now
        publish()
    }

    // MARK: Origins

    /// Whether `error`, from a request at one origin, says the bridge never
    /// answered there: worth asking at the other. The bridge's own answers
    /// (404 gone, 410 expired, 409, 400, 503 asleep) and what no origin
    /// changes (501 and `unavailable`: the workspace; cancelled) are not.
    nonisolated public static func missesOrigin(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        switch error {
        case BrowserError.upstream(let code): return ![400, 404, 409, 410, 501, 503].contains(code)
        case BrowserError.unavailable, BrowserError.forbidden, BrowserError.tunnelsBlocked, BrowserError.tooLarge: return false
        default: return true
        }
    }

    /// The origin after `link`'s, round again.
    static func nextOrigin(after origin: String) -> String? {
        let origins = LiveBrowserLink.origins
        guard origins.count > 1 else { return nil }
        let index = origins.firstIndex(of: origin) ?? -1
        return origins[(index + 1) % origins.count]
    }

    /// A request at `asked` missed (`missesOrigin`): the next ones go to
    /// the next origin, unless another request already moved it. True when
    /// it moved.
    @discardableResult
    private func missed(_ asked: LiveBrowserLink, _ error: Error) -> Bool {
        guard Self.missesOrigin(error), asked == activeLink,
              let origin = Self.nextOrigin(after: asked.origin), let next = link.at(origin: origin), next != asked else { return false }
        activeLink = next
        originMoves += 1
        LiveBrowserLog.info("live browser \(link.id.prefix(6)): no answer at \(asked.origin) (\(String(describing: error))); trying \(origin)")
        return true
    }

    /// `missed`, or another request moved it since `asked` was sent: either
    /// way, worth asking again at the active origin.
    private func moved(_ asked: LiveBrowserLink, _ error: Error) -> Bool {
        missed(asked, error) || (Self.missesOrigin(error) && asked != activeLink)
    }

    /// A GET of `path` at the active origin; one that misses there is asked
    /// at once at the next (each origin once).
    private func readMoving(_ path: (LiveBrowserLink) -> URL, accept: String, through transport: LiveBrowserTransport) async throws -> Data {
        var tries = 0
        while true {
            let asked = activeLink
            do {
                return try await read(path(asked), accept: accept, through: transport)
            } catch {
                tries += 1
                guard !Task.isCancelled, moved(asked, error), tries < LiveBrowserLink.origins.count else { throw error }
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
    public static func within<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
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
            let data = try await post({ $0.takeURL })
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
        let data = try await post({ $0.endURL })
        if let state = try? JSONDecoder().decode(LiveBrowserState.self, from: data) { phase = .live(state) }
    }

    /// Hands control back (`POST /release`); a bridge from before it
    /// (404) is asked with `/done`.
    public func release() async throws {
        let data: Data
        do {
            data = try await post({ $0.releaseURL })
        } catch BrowserError.upstream(404) {
            data = try await post({ $0.doneURL })
        }
        if let state = try? JSONDecoder().decode(LiveBrowserState.self, from: data) { phase = .live(state) }
    }

    /// Moves the page while in control (`POST /nav`). The bridge answers
    /// 400 for an address it won't open, 409 once control is gone, 503
    /// asleep, 410 closed (`BrowserError.upstream`).
    @discardableResult
    public func navigate(_ action: LiveBrowserNavigation) async throws -> LiveBrowserNavResult {
        let data = try await post({ $0.navURL }, body: action.body)
        return try JSONDecoder().decode(LiveBrowserNavResult.self, from: data)
    }

    /// Approves or denies the action the agent waits on (`POST /approve`
    /// or `/deny`, with the approval's id). The bridge answers 409 when that
    /// approval no longer waits (decided elsewhere, the browser closed):
    /// the card goes away at once, and the next poll brings the state.
    public func decide(_ approval: LiveBrowserState.Approval, approve: Bool) async throws {
        let data: Data
        do {
            data = try await post({ approve ? $0.approveURL : $0.denyURL }, body: approval.decisionBody)
        } catch BrowserError.upstream(409) {
            if case .live(var state) = phase, state.approval?.id == approval.id {
                state.approval = nil
                phase = .live(state)
            }
            throw BrowserError.upstream(409)
        }
        if let state = try? JSONDecoder().decode(LiveBrowserState.self, from: data) { phase = .live(state) }
    }

    /// Over its own transport, which a paused feed may not have, at the
    /// active origin. One the bridge never got (`missesOrigin`, but not a
    /// timeout, which it may have got) is sent again at the next origin.
    private func post(_ path: @escaping (LiveBrowserLink) -> URL, body: Data? = nil) async throws -> Data {
        if let transport { return try await post(path, body: body, through: transport) }
        guard let transport = makeTransport() else { throw BrowserError.unavailable }
        defer { Task { await transport.stop() } }
        return try await post(path, body: body, through: transport)
    }

    private func post(_ path: (LiveBrowserLink) -> URL, body: Data?, through transport: LiveBrowserTransport) async throws -> Data {
        var tries = 0
        while true {
            let asked = activeLink
            do {
                return try await transport.send(method: "POST", url: path(asked), body: body, accept: "application/json")
            } catch {
                tries += 1
                guard moved(asked, error), !(error as? BrowserError == .timeout), tries < LiveBrowserLink.origins.count else { throw error }
            }
        }
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
