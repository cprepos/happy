#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// A chat screen that floats a live browser: its transcript's chips find
/// the dock through the responder chain.
@MainActor
protocol LiveBrowserDockHosting: AnyObject {
    var liveBrowserDock: LiveBrowserDock? { get }
}

/// How a chat reaches its live browser: the computer's connection and the
/// workspace whose network holds the bridge.
struct LiveBrowserConnection: Sendable {
    let client: AgentClient
    let workspace: @Sendable () async throws -> String
}

/// One chat's live browser, built once for every kind of chat:
///
/// - the feed (`LiveBrowserFeed`) of the chat's own newest link, and no
///   other chat's;
/// - the red line on the composer's status row (`indicator`), whenever
///   that link hasn't ended;
/// - the floating player over the composer, opened from the line or a
///   chip, or on its own when the agent needs the person;
/// - the full screen, with Take control and Release control;
/// - the voice sheet, taken down to its strip while the player shows.
///
/// A chat screen hands it its link (`update(link:)`), places the line
/// where its layout says (`indicator.place`), tells it where the card and
/// the status line are (`layoutPlayer`), carries `riders` on the keyboard
/// and says when it shows (`setOnScreen`). Nothing else.
@MainActor
final class LiveBrowserDock: NSObject {
    /// Posted (object: the dock) when its link, phase or frame changed.
    static let didChange = Notification.Name("happy.liveBrowserDock.didChange")

    private weak var host: UIViewController?
    /// The chat this dock is for: where the player was left is kept by it.
    let chatKey: String
    private let connect: @MainActor () -> LiveBrowserConnection?
    /// The line came, went or changed its words, or the voice strip moved:
    /// the host lays out again (and measures the composer again).
    var onLayoutChange: (() -> Void)?

    private(set) var feed: LiveBrowserFeed?
    var link: LiveBrowserLink? { feed?.link }
    let indicator = LiveBrowserIndicatorView()
    private(set) var player: LiveBrowserPlayerView?
    private(set) var isOnScreen = false
    private var shownStatus: String?
    private var lastStatus: LiveBrowserState.Status?
    private var corner: LiveBrowserDockLayout.Corner
    private var large: Bool
    private var placed: (card: CGRect, anchor: CGFloat)?
    private weak var fullScreen: UINavigationController?
    private var busy = false

    init(host: UIViewController, chatKey: String, connect: @escaping @MainActor () -> LiveBrowserConnection?) {
        self.host = host
        self.chatKey = chatKey
        self.connect = connect
        let kept = Self.kept(chatKey)
        corner = kept.corner
        large = kept.large
        super.init()
        indicator.isHidden = true
        indicator.addAction(UIAction { [weak self] _ in self?.openPlayer() }, for: .touchUpInside)
        NotificationCenter.default.addObserver(self, selector: #selector(voiceSheetChanged), name: .voiceSheetChanged, object: nil)
    }

    // MARK: The host's part

    /// The chat's newest live link, or nil. A new link replaces the old
    /// one's feed, player and full screen.
    func update(link: LiveBrowserLink?) {
        guard link != self.link else { return }
        feed?.close()
        closePlayer(animated: false)
        fullScreen?.dismiss(animated: false)
        lastStatus = nil
        if let link {
            let feed = LiveBrowserFeed(link: link) { [weak self] in self?.makeTransport() }
            self.feed = feed
            feed.attach(self, visible: isOnScreen) { [weak self] feed in self?.feedChanged(feed) }
        } else {
            feed = nil
        }
        refresh()
    }

    /// The chat shows, or not: nothing is read while it doesn't.
    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
        feed?.set(self, visible: onScreen)
        if let player { feed?.set(player, visible: onScreen) }
    }

    /// What rides the keyboard with the composer: the player, at a bottom
    /// corner.
    var riders: [UIView] {
        guard let player, !corner.isTop else { return [] }
        return [player]
    }

    /// The line's words for the status row, nil while it doesn't show.
    var indicatorText: String? { shownStatus.map(Strings.LiveBrowser.indicator) }

    /// Where the player goes, in the host view's coordinates: the card's
    /// frame and the highest of the status line's top, the keyboard's.
    /// The voice strip's top is added here.
    func layoutPlayer(card: CGRect, anchor: CGFloat) {
        placed = (card, anchor)
        guard let player, let view = host?.viewIfLoaded, !player.isDragging else { return }
        if player.superview !== view { view.addSubview(player) }
        view.bringSubviewToFront(player)
        let layout = playerLayout(in: view, card: card, anchor: anchor)
        player.apply(layout)
    }

    private func playerLayout(in view: UIView, card: CGRect, anchor: CGFloat) -> LiveBrowserDockLayout {
        let strip = VoiceCoordinator.shared.sheetTop(in: view)
        return LiveBrowserDockLayout(.init(
            size: view.bounds.size, safeArea: LayoutInsets(view.safeAreaInsets), card: card,
            anchor: LiveBrowserDockLayout.anchor(anchor, strip), corner: corner, large: large
        ))
    }

    // MARK: The feed

    private func makeTransport() -> LiveBrowserTransport? {
        guard let connection = connect() else { return RefusedLiveBrowserTransport() }
        return BrowserFetcher(client: connection.client, workspace: connection.workspace)
    }

    private func feedChanged(_ feed: LiveBrowserFeed) {
        guard feed === self.feed else { return }
        let status = feed.phase.state?.status
        // Asked for: the player comes up on its own, once each time.
        if status == .takeover, lastStatus != .takeover, isOnScreen { openPlayer() }
        lastStatus = status
        refresh()
    }

    /// The line's status, nil while it hides: the link ended or expired.
    static func status(_ phase: LiveBrowserFeed.Phase) -> String? {
        switch phase {
        case .connecting, .unreachable: Strings.LiveBrowser.connecting
        case .live(let state): state.ended ? nil : Strings.LiveBrowser.status(state.status)
        case .unavailable: Strings.LiveBrowser.unavailableStatus
        case .ended, .expired: nil
        }
    }

    private func refresh() {
        let status = feed.flatMap { Self.status($0.phase) }
        let changed = status != shownStatus
        shownStatus = status
        indicator.text = indicatorText
        indicator.isHidden = status == nil
        if let feed { player?.show(feed) }
        if status == nil, feed?.phase.isOver == true, player != nil, feed?.phase != .unavailable { closePlayer(animated: true) }
        (fullScreen?.viewControllers.first as? LiveBrowserFullScreenItems)?.update(feed?.phase.state)
        for controller in fullScreen?.viewControllers ?? [] { (controller as? LiveBrowserFullScreenItems)?.update(feed?.phase.state) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        if changed { onLayoutChange?() }
    }

    @objc private func voiceSheetChanged() {
        guard player != nil else { return }
        onLayoutChange?()
    }

    // MARK: The player

    /// From the line, a chip, or the agent asking: the player over the
    /// composer, the voice sheet down to its strip.
    func openPlayer() {
        guard let feed, host?.viewIfLoaded != nil else { return }
        VoiceCoordinator.shared.minimizeSheet()
        if let player {
            player.pulse()
            return
        }
        let player = LiveBrowserPlayerView()
        self.player = player
        player.large = large
        player.onClose = { [weak self] in self?.closePlayer(animated: true) }
        player.onFullScreen = { [weak self] in self?.presentFullScreen(taking: false) }
        player.onResize = { [weak self] in self?.resize() }
        player.onAction = { [weak self] in self?.playerAction() }
        player.onTap = { [weak self] in self?.presentFullScreen(taking: false) }
        player.onDrop = { [weak self] center in self?.drop(at: center) }
        feed.attach(player, visible: isOnScreen, frames: true, fast: large) { [weak player] feed in player?.show(feed) }
        player.show(feed)
        if let view = host?.viewIfLoaded { view.addSubview(player) }
        if let placed { layoutPlayer(card: placed.card, anchor: placed.anchor) }
        player.appear()
        onLayoutChange?()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The player goes; the line stays while the link is live.
    func closePlayer(animated: Bool) {
        guard let player else { return }
        self.player = nil
        feed?.detach(player)
        player.disappear(animated: animated)
        onLayoutChange?()
    }

    /// A chip's tap: its link's player, if it is still the chat's.
    func open(_ link: LiveBrowserLink) {
        guard link == self.link else { return }
        openPlayer()
    }

    private func resize() {
        large.toggle()
        keep()
        player?.large = large
        if let player { feed?.set(player, fast: large) }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            if let placed = self.placed { self.layoutPlayer(card: placed.card, anchor: placed.anchor) }
            self.player?.layoutIfNeeded()
        }
    }

    private func drop(at center: CGPoint) {
        guard let view = host?.viewIfLoaded else { return }
        corner = LiveBrowserDockLayout.corner(nearest: center, in: view.bounds.size)
        keep()
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4) {
            if let placed = self.placed { self.layoutPlayer(card: placed.card, anchor: placed.anchor) }
        }
        onLayoutChange?()
    }

    /// The footer's button: Release while the person has the browser,
    /// else Take over, which takes it and opens it full screen.
    private func playerAction() {
        if feed?.phase.state?.status == .user { release(minimizing: false) }
        else { presentFullScreen(taking: true) }
    }

    // MARK: Full screen

    /// The live page full screen over everything, the voice sheet
    /// included; `taking`, control taken first and noVNC opened.
    func presentFullScreen(taking: Bool) {
        guard let feed, !busy else { return }
        guard let connection = connect() else { return alert(Strings.LiveBrowser.title, Strings.LiveBrowser.unavailable) }
        busy = true
        player?.isBusy = true
        let link = feed.link
        Task { [weak self] in
            do {
                let workspace = try await connection.workspace()
                let page = try await BrowserPage.workspace(client: connection.client, url: link.url, workspaceID: workspace)
                guard let self else { return }
                self.busy = false
                self.player?.isBusy = false
                guard self.feed === feed else { return }
                let live = LiveBrowserFullScreenItems(dock: self, browser: BrowserViewController(url: link.url, page: page, extraItems: []), noVNC: false)
                self.present(live.browser, items: live)
                if taking { self.take(connection: connection, workspace: workspace) }
            } catch {
                guard let self else { return }
                self.busy = false
                self.player?.isBusy = false
                self.alert(Strings.LiveBrowser.title, Strings.LiveBrowser.unreachable)
            }
        }
    }

    private func present(_ browser: BrowserViewController, items: LiveBrowserFullScreenItems) {
        guard let host, host.viewIfLoaded?.window != nil else { return }
        let navigation = UINavigationController(rootViewController: items)
        HeaderBar.apply(to: navigation.navigationBar)
        navigation.modalPresentationStyle = .fullScreen
        if let player {
            navigation.preferredTransition = .zoom { [weak player] _ in player }
        }
        fullScreen = navigation
        var presenter: UIViewController = host
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        presenter.present(navigation, animated: true)
        items.update(feed?.phase.state)
    }

    /// Take control (`POST /take`), then drive the browser in noVNC, at
    /// the address the bridge answered with.
    func take(connection: LiveBrowserConnection? = nil, workspace: String? = nil) {
        guard let feed, !busy else { return }
        guard let connection = connection ?? connect() else { return alert(Strings.LiveBrowser.takeFailed, Strings.LiveBrowser.unavailable) }
        busy = true
        Task { [weak self] in
            do {
                let take = try await feed.take()
                guard let self else { return }
                defer { self.busy = false }
                guard self.feed === feed else { return }
                if let url = take.novncURL {
                    let id: String
                    if let workspace { id = workspace } else { id = try await connection.workspace() }
                    let page = try await BrowserPage.workspace(client: connection.client, url: url, workspaceID: id)
                    let items = LiveBrowserFullScreenItems(dock: self, browser: BrowserViewController(url: url, page: page, extraItems: []), noVNC: true)
                    self.fullScreen?.pushViewController(items, animated: true)
                    items.update(feed.phase.state)
                }
            } catch {
                guard let self else { return }
                self.busy = false
                self.alert(Strings.LiveBrowser.takeFailed, Strings.LiveBrowser.unreachable)
            }
        }
    }

    /// Release control (`POST /release`): the agent drives again;
    /// `minimizing`, the full screen goes back to the player.
    func release(minimizing: Bool) {
        guard let feed, !busy else { return }
        busy = true
        player?.isBusy = true
        Task { [weak self] in
            do {
                try await feed.release()
                guard let self else { return }
                self.busy = false
                self.player?.isBusy = false
                if minimizing { self.minimize() }
            } catch {
                guard let self else { return }
                self.busy = false
                self.player?.isBusy = false
                self.alert(Strings.LiveBrowser.releaseFailed, Strings.LiveBrowser.unreachable)
            }
        }
    }

    /// Back to the player.
    func minimize() {
        if player == nil { openPlayer() }
        fullScreen?.dismiss(animated: true)
    }

    private func alert(_ title: String, _ message: String) {
        guard let host else { return }
        var presenter: UIViewController = host
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Strings.Common.ok, style: .default))
        presenter.present(alert, animated: true)
    }

    // MARK: Where it was left

    private static func key(_ chat: String) -> String { "liveBrowserDock.\(chat)" }

    static func kept(_ chat: String) -> (corner: LiveBrowserDockLayout.Corner, large: Bool) {
        let parts = (UserDefaults.standard.string(forKey: key(chat)) ?? "").split(separator: "|")
        let corner = parts.first.flatMap { LiveBrowserDockLayout.Corner(rawValue: String($0)) } ?? .bottomRight
        return (corner, parts.count > 1 && parts[1] == "large")
    }

    private func keep() {
        UserDefaults.standard.set("\(corner.rawValue)|\(large ? "large" : "small")", forKey: Self.key(chatKey))
    }
}

/// The full screen's page: the browser, with Minimize at the left and
/// Take control or Release control at the right.
@MainActor
final class LiveBrowserFullScreenItems: UIViewController {
    let browser: BrowserViewController
    private weak var dock: LiveBrowserDock?
    private let noVNC: Bool
    private let control = UIBarButtonItem()

    init(dock: LiveBrowserDock, browser: BrowserViewController, noVNC: Bool) {
        self.dock = dock
        self.browser = browser
        self.noVNC = noVNC
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = noVNC ? "live-browser-novnc" : "live-browser-full-screen"
        addChild(browser)
        view.addSubview(browser.view)
        browser.view.frame = view.bounds
        browser.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        browser.didMove(toParent: self)
        let minimize = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), primaryAction: UIAction { [weak self] _ in self?.dock?.minimize() })
        minimize.accessibilityLabel = Strings.LiveBrowser.minimize
        minimize.accessibilityIdentifier = "live-browser-minimize"
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItem = minimize
        control.style = .prominent
        control.accessibilityIdentifier = "live-browser-control"
        // The browser's own buttons sit at the right; control goes first.
        var items = navigationItem.rightBarButtonItems ?? []
        items.insert(control, at: 0)
        navigationItem.rightBarButtonItems = items
    }

    func update(_ state: LiveBrowserState?) {
        guard isViewLoaded else { return }
        let held = state?.status == .user
        control.primaryAction = UIAction(title: held ? Strings.LiveBrowser.releaseControl : Strings.LiveBrowser.takeControl) { [weak self] _ in
            guard let dock = self?.dock else { return }
            if held { dock.release(minimizing: true) } else { dock.take() }
        }
        control.isEnabled = state.map { !$0.ended } ?? false
        navigationItem.subtitle = state?.lastAction.map(Strings.LiveBrowser.lastAction)
            ?? state.map { Strings.LiveBrowser.status($0.status) }
    }
}

// MARK: The red line

/// "Live browser · Watching ●": the composer status row's right, its dot at
/// the card's edge, in the row's font. A tap opens the player.
final class LiveBrowserIndicatorView: UIControl {
    private let dot = StatusDotView()
    private let label = UILabel()
    /// The status row's style, as the host scales it.
    var style: TextStyle = TextStyles.composerStatus { didSet { render() } }
    var text: String? { didSet { if text != oldValue { render() } } }
    private var row: AgentInputLayout.StatusRow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.backgroundColor = UIColor(Palette.statusError)
        dot.isUserInteractionEnabled = false
        label.isUserInteractionEnabled = false
        addSubview(label)
        addSubview(dot)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "live-browser-indicator"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func render() {
        let color = UIColor(Palette.statusError)
        label.attributedText = text.map { style.attributedString($0, color: color, lineBreakMode: .byTruncatingTail) }
        accessibilityLabel = text
        dot.isPulsing = text != nil
        setNeedsLayout()
    }

    /// The text's size, measured; nil while hidden.
    var textSize: CGSize? {
        guard !isHidden, text != nil else { return nil }
        return label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    }

    /// At `row` (in the superview's coordinates); nil hides it.
    func place(_ row: AgentInputLayout.StatusRow?) {
        self.row = row
        guard let row else { return }
        setLayoutFrame(row.frame)
        label.frame = row.text.offsetBy(dx: -row.frame.minX, dy: -row.frame.minY)
        dot.frame = row.dot.offsetBy(dx: -row.frame.minX, dy: -row.frame.minY)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The row is 20 tall: a finger gets 12 more above and below.
        bounds.insetBy(dx: -8, dy: -12).contains(point)
    }
}

// MARK: The player

/// The floating picture: ✕, full screen and bigger or smaller over it, the
/// status and Take over or Release under it. Dragged, it lands in the
/// nearest corner.
final class LiveBrowserPlayerView: UIView {
    var onClose: (() -> Void)?
    var onFullScreen: (() -> Void)?
    var onResize: (() -> Void)?
    var onAction: (() -> Void)?
    var onTap: (() -> Void)?
    var onDrop: ((CGPoint) -> Void)?
    var large = false { didSet { resize.setImage(UIImage(systemName: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"), for: .normal); resize.accessibilityLabel = large ? Strings.LiveBrowser.smaller : Strings.LiveBrowser.bigger } }
    var isBusy = false { didSet { spinner.isHidden = !isBusy; isBusy ? spinner.startAnimating() : spinner.stopAnimating() } }
    private(set) var isDragging = false

    private let picture = UIImageView()
    private let message = UILabel()
    private let close = LiveBrowserPlayerView.overlayButton("xmark")
    private let full = LiveBrowserPlayerView.overlayButton("arrow.up.left.and.arrow.down.right.rectangle")
    private let resize = LiveBrowserPlayerView.overlayButton("arrow.up.left.and.arrow.down.right")
    private let footer = UIView()
    private let pillDot = UIView()
    private let pill = UILabel()
    private let action = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var layout: LiveBrowserDockLayout?
    private var frameBytes: Data?
    private var dragStart = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        typealias M = LiveBrowserDockLayout.Metrics
        accessibilityIdentifier = "live-browser-player"
        backgroundColor = UIColor(Palette.cardFill)
        layer.cornerRadius = M.radius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(Palette.divider).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.backgroundColor = UIColor(Palette.surfaceHigh)
        picture.isUserInteractionEnabled = true
        picture.accessibilityIdentifier = "live-browser-picture"
        picture.layer.cornerRadius = M.radius
        picture.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        message.font = Fonts.ui(.medium, size: 11)
        message.textColor = UIColor(Palette.cardDetail)
        message.textAlignment = .center
        message.numberOfLines = 3
        pillDot.layer.cornerRadius = 3
        pill.font = Fonts.ui(.semiBold, size: 11)
        pill.textColor = UIColor(Palette.cardTitle)
        action.titleLabel?.font = Fonts.ui(.semiBold, size: 12)
        action.accessibilityIdentifier = "live-browser-player-action"
        action.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)
        close.accessibilityLabel = Strings.LiveBrowser.close
        close.accessibilityIdentifier = "live-browser-player-close"
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        full.accessibilityLabel = Strings.LiveBrowser.fullScreen
        full.accessibilityIdentifier = "live-browser-player-full-screen"
        full.addAction(UIAction { [weak self] _ in self?.onFullScreen?() }, for: .touchUpInside)
        resize.accessibilityIdentifier = "live-browser-player-resize"
        resize.addAction(UIAction { [weak self] _ in self?.onResize?() }, for: .touchUpInside)
        spinner.color = .white
        spinner.isHidden = true
        for view in [picture, message, footer, close, full, resize, spinner] as [UIView] { addSubview(view) }
        for view in [pillDot, pill, action] as [UIView] { footer.addSubview(view) }
        picture.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        large = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor(Palette.divider).cgColor
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func overlayButton(_ symbol: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        configuration.baseForegroundColor = .white
        configuration.background.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        configuration.background.cornerRadius = LiveBrowserDockLayout.Metrics.button / 2
        configuration.contentInsets = .zero
        return UIButton(configuration: configuration)
    }

    func apply(_ layout: LiveBrowserDockLayout) {
        self.layout = layout
        bounds = CGRect(origin: .zero, size: layout.frame.size)
        center = CGPoint(x: layout.frame.midX, y: layout.frame.midY)
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout else { return }
        typealias M = LiveBrowserDockLayout.Metrics
        picture.frame = layout.picture
        message.frame = layout.picture.insetBy(dx: 8, dy: 8)
        close.frame = layout.close
        full.frame = layout.fullScreen
        resize.frame = layout.resize
        spinner.center = CGPoint(x: layout.picture.midX, y: layout.picture.midY)
        footer.frame = layout.footer
        let pad = M.footerPadding
        let height = layout.footer.height
        let actionWidth = min(layout.footer.width - 2 * pad, action.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: height)).width + 8)
        pill.isHidden = !layout.showsPill
        pillDot.isHidden = !layout.showsPill
        if layout.showsPill {
            action.frame = CGRect(x: layout.footer.width - pad - actionWidth, y: 0, width: actionWidth, height: height)
            pillDot.frame = CGRect(x: pad + 2, y: (height - 6) / 2, width: 6, height: 6)
            pill.frame = CGRect(x: pillDot.frame.maxX + 6, y: 0, width: max(0, action.frame.minX - pillDot.frame.maxX - 12), height: height)
        } else {
            action.frame = CGRect(x: pad, y: 0, width: layout.footer.width - 2 * pad, height: height)
        }
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: M.radius).cgPath
    }

    /// The feed as it is now: the latest picture, the status, the button.
    func show(_ feed: LiveBrowserFeed) {
        if feed.frame != frameBytes {
            frameBytes = feed.frame
            picture.image = feed.frame.flatMap(UIImage.init(data:))
        }
        let state = feed.phase.state
        let text: String? = switch feed.phase {
        case .unavailable: Strings.LiveBrowser.unavailable
        case .ended: Strings.LiveBrowser.ended
        case .expired: Strings.LiveBrowser.expired
        case .unreachable where picture.image == nil: Strings.LiveBrowser.unreachable
        default: nil
        }
        message.text = text
        message.isHidden = text == nil
        picture.alpha = text == nil ? 1 : 0.25
        let status = LiveBrowserDock.status(feed.phase) ?? Strings.LiveBrowser.endedStatus
        pill.text = status
        pillDot.backgroundColor = UIColor(LiveBrowserPlayerView.color(state?.status))
        let held = state?.status == .user
        action.setTitle(held ? Strings.LiveBrowser.release : Strings.LiveBrowser.takeOver, for: .normal)
        action.isEnabled = !feed.phase.isOver
        accessibilityLabel = [Strings.LiveBrowser.title, status].joined(separator: ", ")
        accessibilityValue = state?.status.rawValue ?? "\(feed.phase)"
        setNeedsLayout()
    }

    static func color(_ status: LiveBrowserState.Status?) -> ColorToken {
        switch status {
        case .watching?: Palette.success
        case .takeover?: Palette.warningText
        case .user?: Palette.iconBlue
        case .done?, nil: Palette.textSecondary
        }
    }

    func appear() {
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func disappear(animated: Bool) {
        guard animated, window != nil else { return removeFromSuperview() }
        UIView.animate(withDuration: 0.2, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        }, completion: { _ in self.removeFromSuperview() })
    }

    /// Asked for again while it shows.
    func pulse() {
        UIView.animate(withDuration: 0.12, animations: { self.transform = CGAffineTransform(scaleX: 1.06, y: 1.06) }) { _ in
            UIView.animate(withDuration: 0.2) { self.transform = .identity }
        }
    }

    @objc private func tapped() { onTap?() }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let superview else { return }
        switch pan.state {
        case .began:
            isDragging = true
            dragStart = center
        case .changed:
            let moved = pan.translation(in: superview)
            center = CGPoint(x: dragStart.x + moved.x, y: dragStart.y + moved.y)
        case .ended, .cancelled, .failed:
            isDragging = false
            let velocity = pan.velocity(in: superview)
            // A flick carries it a little further than the finger let go.
            let landing = CGPoint(x: center.x + velocity.x * 0.15, y: center.y + velocity.y * 0.15)
            onDrop?(landing)
        default: break
        }
    }
}

// MARK: The transcript's chip

/// A live link in the transcript: a 44-point chip that opens the chat's
/// player, or says a newer browser replaced it.
final class LiveBrowserChipView: UIControl {
    static let height: CGFloat = 44
    static let maxWidth: CGFloat = 320

    private(set) var link: LiveBrowserLink?
    private weak var dock: LiveBrowserDock?
    private let box = UIView()
    private let dot = UIView()
    private let title = UILabel()
    private let detail = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "pip.enter"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        box.backgroundColor = UIColor(Palette.cardFill)
        box.layer.cornerRadius = 12
        box.layer.cornerCurve = .continuous
        box.layer.borderWidth = 1
        box.layer.borderColor = UIColor(Palette.divider).cgColor
        box.isUserInteractionEnabled = false
        dot.layer.cornerRadius = 4
        title.font = Fonts.ui(.semiBold, size: 14)
        title.textColor = UIColor(Palette.cardTitle)
        title.text = Strings.LiveBrowser.indicator
        detail.font = Fonts.ui(.regular, size: 13)
        detail.textColor = UIColor(Palette.cardDetail)
        detail.lineBreakMode = .byTruncatingTail
        chevron.tintColor = UIColor(Palette.textSecondary)
        chevron.contentMode = .scaleAspectFit
        addSubview(box)
        for view in [dot, title, detail, chevron] as [UIView] { view.isUserInteractionEnabled = false; box.addSubview(view) }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "live-browser-chip"
        addAction(UIAction { [weak self] _ in self?.tapped() }, for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.box.layer.borderColor = UIColor(Palette.divider).cgColor
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ link: LiveBrowserLink?) {
        guard link != self.link else { return }
        self.link = link
        render()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let dock = window == nil ? nil : findDock()
        guard dock !== self.dock else { return render() }
        if let old = self.dock { NotificationCenter.default.removeObserver(self, name: LiveBrowserDock.didChange, object: old) }
        self.dock = dock
        if let dock { NotificationCenter.default.addObserver(self, selector: #selector(dockChanged), name: LiveBrowserDock.didChange, object: dock) }
        render()
    }

    @objc private func dockChanged() { render() }

    /// Its link isn't the chat's newest any more.
    var isReplaced: Bool {
        guard let link, let current = dock?.link else { return false }
        return current != link
    }

    private func render() {
        let status: String
        let color: ColorToken
        if isReplaced {
            status = Strings.LiveBrowser.replaced
            color = Palette.textSecondary
        } else if let feed = dock?.feed, feed.link == link {
            status = LiveBrowserDock.status(feed.phase) ?? Strings.LiveBrowser.endedStatus
            color = LiveBrowserDock.status(feed.phase) == nil ? Palette.textSecondary : Palette.statusError
        } else {
            status = Strings.LiveBrowser.open
            color = Palette.statusError
        }
        detail.text = status
        dot.backgroundColor = UIColor(color)
        alpha = isReplaced ? 0.6 : 1
        accessibilityLabel = "\(Strings.LiveBrowser.indicator), \(status)"
        accessibilityValue = isReplaced ? "replaced" : status
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width, Self.maxWidth)
        box.frame = CGRect(x: 0, y: 0, width: width, height: min(bounds.height, Self.height))
        let h = box.bounds.height
        dot.frame = CGRect(x: 12, y: (h - 8) / 2, width: 8, height: 8)
        chevron.frame = CGRect(x: width - 12 - 18, y: (h - 18) / 2, width: 18, height: 18)
        let titleWidth = min(title.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: h)).width, chevron.frame.minX - dot.frame.maxX - 16)
        title.frame = CGRect(x: dot.frame.maxX + 8, y: 0, width: max(0, titleWidth), height: h)
        detail.frame = CGRect(x: title.frame.maxX + 6, y: 0, width: max(0, chevron.frame.minX - 8 - title.frame.maxX - 6), height: h)
    }

    private func tapped() {
        guard let link, let dock = dock ?? findDock() else { return }
        dock.open(link)
    }

    private func findDock() -> LiveBrowserDock? {
        var responder: UIResponder? = self
        while let current = responder {
            if let host = current as? LiveBrowserDockHosting { return host.liveBrowserDock }
            responder = current.next
        }
        return nil
    }
}
#endif
