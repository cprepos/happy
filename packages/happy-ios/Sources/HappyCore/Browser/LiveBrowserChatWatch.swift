import Foundation

/// Asks the bridge which live browser a chat has (`GET /live/chat/<key>`),
/// every `interval` while the chat shows and never otherwise: a chat whose
/// agent never posted its link still gets its red line. The lookup is not
/// viewer activity at the bridge, so it never keeps a browser awake.
@MainActor
public final class LiveBrowserChatWatch {
    public enum Answer: Equatable, Sendable {
        /// Not asked yet, or no answer came.
        case unknown
        /// The chat never had a browser (404 `no_link`).
        case noLink
        case link(LiveBrowserChat)

        public var chat: LiveBrowserChat? { if case .link(let chat) = self { chat } else { nil } }
    }

    public static let interval: Duration = .seconds(4)
    /// While the answer's link has no browser running for it: asked
    /// this seldom, so it still comes back when the agent wakes one.
    public static let idleInterval: Duration = .seconds(30)

    /// The keys the chat may go by, in order (`LiveBrowserChatIdentity.keys`).
    public let keys: [String]
    /// The key asked by now: the first until it answers `no_link`, then
    /// the next, round again; the one that names a link is kept.
    public private(set) var key: String
    public var url: URL { LiveBrowserLink.chatURL(key: key)! }
    private var keyIndex = 0
    private var found = false
    /// The next key is asked at once, not at the next turn.
    private var nextKeyNow = false
    public private(set) var answer: Answer = .unknown {
        didSet { if answer != oldValue { onChange?(answer) } }
    }
    public var onChange: (@MainActor (Answer) -> Void)?
    /// Lookups made (tests).
    public private(set) var polls = 0
    public var isPolling: Bool { polling != nil }
    public private(set) var isVisible = false

    private let interval: Duration
    private let idleInterval: Duration
    private let makeTransport: @MainActor () -> LiveBrowserTransport?
    private var transport: LiveBrowserTransport?
    private var polling: Task<Void, Never>?

    /// Nil for a key that isn't one. `transport` is asked for each time
    /// polling starts; nil (no computer known yet) waits for `reconsider`.
    public convenience init?(key: String, interval: Duration = LiveBrowserChatWatch.interval, idleInterval: Duration = LiveBrowserChatWatch.idleInterval, transport: @escaping @MainActor () -> LiveBrowserTransport?) {
        self.init(keys: [key], interval: interval, idleInterval: idleInterval, transport: transport)
    }

    /// Nil when no key is one.
    public init?(keys: [String], interval: Duration = LiveBrowserChatWatch.interval, idleInterval: Duration = LiveBrowserChatWatch.idleInterval, transport: @escaping @MainActor () -> LiveBrowserTransport?) {
        let keys = keys.filter { LiveBrowserLink.chatURL(key: $0) != nil }
        guard let first = keys.first else { return nil }
        self.keys = keys
        self.key = first
        self.interval = interval
        self.idleInterval = idleInterval
        makeTransport = transport
    }

    /// Something shows the picture (the player): asked every `interval`
    /// even while nothing runs, so a browser the agent wakes shows at once.
    /// Becoming eager, or not, asks now.
    public var eager = false {
        didSet { if eager != oldValue { checkNow() } }
    }

    /// The wait before the next lookup: long while nothing runs, unless
    /// eager.
    public var currentInterval: Duration { eager ? interval : answer.chat.map { $0.running ? interval : idleInterval } ?? interval }

    /// Asks now rather than at the next turn (the feed stopped answering),
    /// if it shows.
    public func checkNow() {
        guard isVisible else { return }
        pause()
        start()
    }

    /// The chat shows, or not.
    public func setVisible(_ visible: Bool) {
        isVisible = visible
        reconsider()
    }

    /// Starts if it should and can: a computer to ask through may have
    /// come since.
    public func reconsider() {
        if isVisible { start() } else { pause() }
    }

    /// Stops for good: the chat let it go.
    public func close() {
        isVisible = false
        onChange = nil
        pause()
    }

    private func start() {
        guard polling == nil else { return }
        guard let transport = transport ?? makeTransport() else { return }
        self.transport = transport
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let keepGoing = await self.poll(transport)
                guard keepGoing, !Task.isCancelled else { break }
                if self.nextKeyNow { self.nextKeyNow = false; continue }
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

    /// One lookup; false when asking again can't help (the workspace can't
    /// reach the bridge, or no computer was decided on).
    private func poll(_ transport: LiveBrowserTransport) async -> Bool {
        polls += 1
        do {
            let data = try await transport.send(method: "GET", url: url, body: nil, accept: "application/json")
            let chat = try JSONDecoder().decode(LiveBrowserChat.self, from: data)
            guard !Task.isCancelled else { return false }
            found = true
            answer = .link(chat)
            return true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return false }
            switch error {
            // The agent may start one later: still asked.
            case BrowserError.upstream(404):
                if !found, keys.count > 1 {
                    keyIndex = (keyIndex + 1) % keys.count
                    key = keys[keyIndex]
                    // Every key asked once with no link: no link.
                    if keyIndex == 0 { answer = .noLink } else { nextKeyNow = true }
                } else {
                    answer = .noLink
                }
                return true
            case BrowserError.upstream(501), BrowserError.unavailable: return false
            // A bridge from before the lookup answers 404 too; anything
            // else keeps the last answer and is asked again.
            default: return true
            }
        }
    }
}
