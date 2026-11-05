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

    public let link: LiveBrowserLink
    public private(set) var phase: Phase = .connecting { didSet { if phase != oldValue { publish() } } }
    /// The latest frame's bytes (PNG or JPEG; decode by content).
    public private(set) var frame: Data?
    /// Polls made (tests).
    public private(set) var polls = 0
    public var isPolling: Bool { polling != nil }

    private let makeTransport: @MainActor () -> LiveBrowserTransport?
    private var transport: LiveBrowserTransport?
    private var polling: Task<Void, Never>?
    private var observers: [ObjectIdentifier: Observer] = [:]

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

    private func reconsider() {
        if watching.isEmpty || phase.isOver { pause() } else { start() }
    }

    private func publish() {
        for observer in observers.values where observer.owner != nil { observer.update(self) }
    }

    // MARK: Polling

    private func start() {
        guard polling == nil else { return }
        guard let transport = transport ?? makeTransport() else { return }
        self.transport = transport
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let keepGoing = await self.poll(transport)
                guard keepGoing, !Task.isCancelled else { break }
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
            let data = try await transport.send(method: "GET", url: link.stateURL, body: nil, accept: "application/json")
            let state = try JSONDecoder().decode(LiveBrowserState.self, from: data)
            guard !Task.isCancelled else { return false }
            if wantsFrames, !state.ended, let frame = try? await transport.send(method: "GET", url: link.frameURL, body: nil, accept: "image/*,*/*;q=0.8") {
                guard !Task.isCancelled else { return false }
                if frame != self.frame {
                    self.frame = frame
                    if phase == .live(state) { publish() }
                }
            }
            phase = .live(state)
            return !state.ended
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return false }
            switch error {
            case BrowserError.upstream(404): phase = .ended; return false
            case BrowserError.upstream(410): phase = .expired; return false
            case BrowserError.upstream(501): phase = .unavailable; return false
            default: phase = .unreachable; return true
            }
        }
    }

    // MARK: Control

    /// Takes control (`POST /take`): the agent's actions are refused until
    /// `release()`. Answers the noVNC page to drive it with.
    @discardableResult
    public func take() async throws -> LiveBrowserTake {
        let data = try await post(link.takeURL)
        let take = try JSONDecoder().decode(LiveBrowserTake.self, from: data)
        phase = .live(take.state)
        return take
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

#if canImport(Network)
extension BrowserFetcher: LiveBrowserTransport {}
#endif
