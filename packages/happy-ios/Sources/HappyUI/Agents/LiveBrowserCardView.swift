#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// A browser an agent drives, inline in a conversation
/// (`LiveBrowserLink`): its latest frame and whether it needs the person,
/// read through the chat's workspace every `interval` while the card is on
/// screen, and nothing read while it isn't. A tap opens it full screen.
final class LiveBrowserCardView: UIControl {
    enum Phase: Equatable {
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
    }

    static let interval: Duration = .milliseconds(1500)

    private(set) var link: LiveBrowserLink?
    private(set) var phase: Phase = .connecting { didSet { if phase != oldValue { render() } } }
    private weak var host: PageHosting?
    private var polling: Task<Void, Never>?
    private var fetcher: BrowserFetcher?
    /// Polls made since the card was applied (tests).
    private(set) var polls = 0
    var isPolling: Bool { polling != nil }

    private let frameView = UIImageView()
    private let pill = UIView()
    private let dot = UIView()
    private let pillLabel = UILabel()
    private let titleLabel = UILabel()
    private let addressLabel = UILabel()
    private let messageLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        typealias M = LiveBrowserCardLayout.Metrics
        backgroundColor = UIColor(Palette.cardFill)
        layer.cornerRadius = M.radius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(Palette.divider).cgColor
        clipsToBounds = true
        frameView.contentMode = .scaleAspectFill
        frameView.clipsToBounds = true
        frameView.backgroundColor = UIColor(Palette.surfaceHigh)
        pill.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        pill.layer.cornerRadius = M.pillHeight / 2
        dot.layer.cornerRadius = M.dot / 2
        pillLabel.font = Fonts.ui(.semiBold, size: 12)
        pillLabel.textColor = .white
        titleLabel.font = Fonts.ui(.semiBold, size: 14)
        titleLabel.textColor = UIColor(Palette.cardTitle)
        addressLabel.font = Fonts.ui(.regular, size: 12)
        addressLabel.textColor = UIColor(Palette.cardDetail)
        addressLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.font = Fonts.ui(.medium, size: 14)
        messageLabel.textColor = UIColor(Palette.cardDetail)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        for view in [frameView, messageLabel, pill, titleLabel, addressLabel] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        pill.addSubview(dot)
        pill.addSubview(pillLabel)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "live-browser"
        addAction(UIAction { [weak self] _ in self?.opened() }, for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor(Palette.divider).cgColor
        }
        render()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A row planned again for the same browser keeps its frame and polling.
    func apply(_ link: LiveBrowserLink?) {
        guard link != self.link else { return }
        stop()
        self.link = link
        frameView.image = nil
        polls = 0
        phase = .connecting
        render()
        start()
    }

    override var isHidden: Bool {
        didSet { if isHidden != oldValue { isHidden ? stop() : start() } }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : start()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let message = messageLabel.text.map { _ in Measurable { [messageLabel] in messageLabel.sizeThatFits(CGSize(width: $0, height: .greatestFiniteMagnitude)) } }
        let layout = LiveBrowserCardLayout(size: bounds.size, pillLabel: pillLabel.intrinsicContentSize, message: message)
        frameView.frame = layout.frame
        pill.frame = layout.pill
        dot.frame = layout.dot.offsetBy(dx: -layout.pill.minX, dy: -layout.pill.minY)
        pillLabel.frame = layout.pillLabel.offsetBy(dx: -layout.pill.minX, dy: -layout.pill.minY)
        titleLabel.frame = layout.title
        addressLabel.frame = layout.address
        messageLabel.frame = layout.message
    }

    // MARK: Polling

    private func start() {
        guard polling == nil, let link, window != nil, !isHidden else { return }
        if phase == .ended || phase == .expired || phase == .unavailable { return }
        if case .live(let state) = phase, state.status == .done { return }
        guard let host = host ?? findHost() else { return }
        self.host = host
        let client = host.pageClient
        let agentID = host.pageAgentID
        let fetcher = BrowserFetcher(client: client) { try await client.browserWorkspace(agentID: agentID) }
        self.fetcher = fetcher
        polling = Task { [weak self] in
            while !Task.isCancelled {
                let keepGoing = await self?.poll(link, fetcher) ?? false
                guard keepGoing, !Task.isCancelled else { break }
                try? await Task.sleep(for: Self.interval)
            }
            guard let self, !Task.isCancelled else { return }
            self.polling = nil
            self.release()
        }
    }

    private func stop() {
        polling?.cancel()
        polling = nil
        release()
    }

    private func release() {
        guard let fetcher else { return }
        self.fetcher = nil
        Task { await fetcher.stop() }
    }

    /// One read of the state and frame; false once there's nothing more to read.
    private func poll(_ link: LiveBrowserLink, _ fetcher: BrowserFetcher) async -> Bool {
        polls += 1
        do {
            let data = try await fetcher.send(method: "GET", url: link.stateURL, accept: "application/json")
            let state = try JSONDecoder().decode(LiveBrowserState.self, from: data)
            if let frame = try? await fetcher.data(link.frameURL), let image = UIImage(data: frame) {
                guard !Task.isCancelled, self.link == link else { return false }
                frameView.image = image
            }
            guard !Task.isCancelled, self.link == link else { return false }
            phase = .live(state)
            return state.status != .done
        } catch {
            guard !Task.isCancelled, self.link == link, !(error is CancellationError) else { return false }
            switch error {
            case BrowserError.upstream(404): phase = .ended; return false
            case BrowserError.upstream(410): phase = .expired; return false
            case BrowserError.upstream(501): phase = .unavailable; return false
            default: phase = .unreachable; return true
            }
        }
    }

    // MARK: Showing

    private func render() {
        let state: LiveBrowserState? = if case .live(let state) = phase { state } else { nil }
        let label: String
        let color: ColorToken
        switch phase {
        case .connecting: label = Strings.LiveBrowser.connecting; color = Palette.textSecondary
        case .live(let state):
            label = Strings.LiveBrowser.status(state.status)
            color = switch state.status {
            case .watching: Palette.success
            case .takeover: Palette.warningText
            case .done: Palette.textSecondary
            }
        case .ended, .expired: label = Strings.LiveBrowser.done; color = Palette.textSecondary
        case .unavailable, .unreachable: label = Strings.LiveBrowser.title; color = Palette.statusError
        }
        pillLabel.text = label
        dot.backgroundColor = UIColor(color)
        let message: String? = switch phase {
        case .ended: Strings.LiveBrowser.ended
        case .expired: Strings.LiveBrowser.expired
        case .unavailable: Strings.LiveBrowser.unavailable
        case .unreachable: frameView.image == nil ? Strings.LiveBrowser.unreachable : nil
        default: nil
        }
        messageLabel.text = message
        messageLabel.isHidden = message == nil
        frameView.alpha = message == nil ? 1 : 0.25
        let title = state?.title.flatMap { $0.isEmpty ? nil : $0 } ?? Strings.LiveBrowser.title
        titleLabel.text = title
        // While the agent waits on the person, the strip says why.
        let reason = state?.status == .takeover ? state?.reason.flatMap { $0.isEmpty ? nil : $0 } : nil
        addressLabel.text = reason ?? state?.url.flatMap { $0.isEmpty ? nil : $0 } ?? link?.url.absoluteString
        addressLabel.textColor = UIColor(reason == nil ? Palette.cardDetail : Palette.warningText)
        addressLabel.lineBreakMode = reason == nil ? .byTruncatingMiddle : .byTruncatingTail
        accessibilityLabel = [title, label, reason, message].compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = switch phase {
        case .connecting: "connecting"
        case .live(let state): state.status.rawValue
        case .ended: "ended"
        case .expired: "expired"
        case .unavailable: "unavailable"
        case .unreachable: "unreachable"
        }
        setNeedsLayout()
    }

    private func opened() {
        guard let link, let host = host ?? findHost() else { return }
        let status: LiveBrowserState.Status? = if case .live(let state) = phase { state.status } else { nil }
        host.page(openLive: link, status: status)
    }

    private func findHost() -> PageHosting? {
        var responder: UIResponder? = self
        while let current = responder {
            if let host = current as? PageHosting { return host }
            responder = current.next
        }
        return nil
    }
}
#endif
