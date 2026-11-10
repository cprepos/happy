#if canImport(UIKit)
import HappyCore
import HappyLayout
import HappyStore
import ImageIO
import UIKit
import WebKit

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
/// A Happy CLI chat also asks the bridge for its link by the session
/// (`lookUp(key:)`, `LiveBrowserChatWatch`) while it shows: what that
/// answers wins over the transcript's link, and its `live` decides the
/// red line. A browser asleep shows no line, and nothing reads its state
/// until something opens it.
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
    /// The chat's computer, read each time it is needed; a test hands in
    /// one of its own.
    var connect: @MainActor () -> LiveBrowserConnection?
    /// The chat's computer and workspace as `route` decided them.
    var routedConnection: LiveBrowserConnection?
    /// The keys `route` asks the bridge by, in order (tests, and the log).
    var routedKeys: [String] = []
    /// What `route` was last asked for, and its work while it decides.
    var routedFor: String?
    var routing: Task<Void, Never>?
    /// Made to decide its own computer (`route(_:through:)`): no link is
    /// shown before it has.
    private(set) var routesItself = false
    /// The machine's computer isn't certain: the host asks the person, as
    /// a link does (`LegacyLinkOpening`), and answers with the computer
    /// picked, or nil. Unset, such a chat says unavailable.
    var askComputer: ((_ choices: [LegacyLinkComputer], _ record: SessionRecord, _ picked: @escaping @MainActor (String?) -> Void) -> Void)?
    /// The line came, went or changed its words, or the voice strip moved:
    /// the host lays out again (and measures the composer again).
    var onLayoutChange: (() -> Void)?

    private(set) var feed: LiveBrowserFeed?
    var link: LiveBrowserLink? { feed?.link }
    /// The newest link the chat's transcript holds.
    private var transcriptLink: LiveBrowserLink?
    /// The bridge's answer for this chat, asked while it shows.
    private(set) var chatWatch: LiveBrowserChatWatch?
    let indicator = LiveBrowserIndicatorView()
    private(set) var player: LiveBrowserPlayerView?
    private(set) var isOnScreen = false
    private var shownStatus: String?
    private var lastStatus: LiveBrowserState.Status?
    /// The approval the alert last came up for, so each comes up on its own once.
    private var askedApproval: String?
    /// The approval alert while it shows: it goes once the approval does.
    private weak var approvalAlert: UIAlertController?
    private var approvalShown: String?
    private var corner: LiveBrowserDockLayout.Corner
    private var large: Bool
    private var placed: (card: CGRect, anchor: CGFloat)?
    private weak var fullScreen: UINavigationController?
    private var busy = false
    /// This app took control (`POST /take`) and hasn't handed it back:
    /// Release stays offered while the bridge says user or takeover.
    private(set) var controlTaken = false
    private var takenAt: ContinuousClock.Instant?
    /// Release control is on its way (the button): leaving noVNC then
    /// sends no second one.
    private var releasing = false
    /// Control was handed back as noVNC went, once for each take.
    private var releasedOnLeave = false
    /// In the background a few seconds, noVNC goes and control with it.
    private var backgroundRelease: Task<Void, Never>?
    static let backgroundGrace: Duration = .seconds(5)

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
        NotificationCenter.default.addObserver(self, selector: #selector(appBackgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appForegrounded), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    /// A dock whose computer is what `route(_:through:)` decides.
    convenience init(host: UIViewController, chatKey: String) {
        self.init(host: host, chatKey: chatKey) { nil }
        connect = { [weak self] in self?.routedConnection }
        routesItself = true
    }

    // MARK: The host's part

    /// The chat's newest live link in its transcript, or nil. The bridge's
    /// answer by chat, when there is one, goes first.
    func update(link: LiveBrowserLink?) {
        transcriptLink = link
        // Its computer not yet decided: shown once it is, so the feed never
        // reads through another, or reads through none and stays unavailable.
        guard routing == nil, !(routesItself && routedFor == nil) else { return }
        follow()
    }

    /// Asks the bridge for the chat's link by `key` (`LiveBrowserLink.chatKey`)
    /// while the chat shows; nil stops asking. Called again once a computer
    /// to ask through is known.
    func lookUp(key: String?) {
        lookUp(keys: key.map { [$0] } ?? [])
    }

    /// `lookUp(key:)` by the first of `keys` that names a link, in order;
    /// none stops asking.
    func lookUp(keys: [String]) {
        if let watch = chatWatch, watch.keys == keys {
            watch.reconsider()
            return
        }
        chatWatch?.close()
        chatWatch = keys.isEmpty ? nil : LiveBrowserChatWatch(keys: keys) { [weak self] in self?.lookupTransport() }
        chatWatch?.onChange = { [weak self] _ in self?.lookupChanged() }
        chatWatch?.eager = player != nil
        chatWatch?.setVisible(isOnScreen)
        lookupChanged()
    }

    private func lookupChanged() {
        follow()
        reconsiderFeed()
        refresh()
    }

    /// The bridge's word on the feed's link wins over what the feed read:
    /// not running, it rests as asleep with its last page; running again,
    /// a resting feed reads again.
    private func settleFeed() {
        guard let feed, let chat = chatWatch?.answer.chat, chat.link == feed.link else { return }
        if !chat.running {
            var state = chat.state
            // Done or dead at the bridge is asleep here: the agent's next
            // browser call resumes it from the saved cookies and page.
            if state.ended { state.status = .watching }
            state.live = false
            if !holdsControl { feed.rest(state) }
        } else if feed.phase.isResting {
            feed.retry()
        }
    }

    /// Retry or Check again, from the player: reads again, and asks the
    /// bridge for the chat now.
    func retryBrowser() {
        // Asleep at the bridge: only the bridge can say otherwise.
        if !lookupSaysIdle { feed?.retry() }
        chatWatch?.checkNow()
        refresh()
    }

    /// The link to show: the bridge's for this chat, else the transcript's.
    private func follow() {
        show(link: chatWatch?.answer.chat?.link ?? transcriptLink)
        settleFeed()
    }

    /// The bridge says no browser runs for this link now (`live` false):
    /// no line, and the dock reads nothing, so the browser can sleep.
    private var lookupSaysIdle: Bool {
        guard let chat = chatWatch?.answer.chat, chat.link == feed?.link else { return false }
        return !chat.running
    }

    private func reconsiderFeed() {
        feed?.set(self, visible: isOnScreen && !lookupSaysIdle)
    }

    /// A new link replaces the old one's feed, player and full screen.
    private func show(link: LiveBrowserLink?) {
        guard link != self.link else { return }
        if let feed { releaseHeld(feed) }
        feed?.close()
        closePlayer(animated: false)
        dismissFullScreen(animated: false)
        lastStatus = nil
        askedApproval = nil
        dismissApproval()
        controlTaken = false
        if let link {
            let feed = LiveBrowserFeed(link: link) { [weak self] in self?.makeTransport() }
            self.feed = feed
            feed.attach(self, visible: isOnScreen && !lookupSaysIdle) { [weak self] feed in self?.feedChanged(feed) }
        } else {
            feed = nil
        }
        refresh()
    }

    /// The chat shows, or not: nothing is read while it doesn't.
    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
        chatWatch?.setVisible(onScreen)
        reconsiderFeed()
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
            anchor: LiveBrowserDockLayout.anchor(anchor, strip), corner: corner, large: large, phone: isPhone
        ))
    }

    /// An iPhone, not an iPad and not the app on a Mac: one player size
    /// (the large one), and full screen is the bigger view.
    static func isPhone(_ traits: UITraitCollection) -> Bool {
        traits.userInterfaceIdiom == .phone && !ProcessInfo.processInfo.isiOSAppOnMac
    }

    var isPhone: Bool { Self.isPhone(host?.traitCollection ?? UITraitCollection.current) }

    /// The player's size: a phone's is always large, whatever was kept.
    private var showsLarge: Bool { isPhone || large }

    /// The live picture's width over its height, read from the newest
    /// frame's header; nil before the first.
    var frameAspect: CGFloat? {
        guard let bytes = feed?.frame else { return nil }
        if let aspectOf, aspectOf.count == bytes.count, aspectOf.prefix == bytes.prefix(64) { return aspectOf.aspect }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let aspect = CGFloat(width / height)
        aspectOf = (bytes.count, bytes.prefix(64), aspect)
        return aspect
    }
    private var aspectOf: (count: Int, prefix: Data, aspect: CGFloat)?

    // MARK: The feed

    private func makeTransport() -> LiveBrowserTransport? {
        guard let connection = connect() else { return RefusedLiveBrowserTransport() }
        return BrowserFetcher(client: connection.client, workspace: connection.workspace)
    }

    /// The lookup waits for a computer rather than be refused.
    private func lookupTransport() -> LiveBrowserTransport? {
        guard let connection = connect() else { return nil }
        return BrowserFetcher(client: connection.client, workspace: connection.workspace)
    }

    private func feedChanged(_ feed: LiveBrowserFeed) {
        guard feed === self.feed else { return }
        let status = feed.phase.state?.status
        // Asked for: the player comes up on its own, once each time.
        if status == .takeover, lastStatus != .takeover, isOnScreen { openPlayer() }
        lastStatus = status
        // An action waits on the person's yes: the player, and the question, once each.
        let approval = feed.phase.state?.pendingApproval
        if approval?.id != approvalShown { dismissApproval() }
        if let approval, approval.id != askedApproval, isOnScreen {
            askedApproval = approval.id
            openPlayer()
            // The full screen is the live page, which asks for itself.
            if fullScreen == nil { askApproval(approval) }
        }
        // The bridge let the person go (the agent took it back, or the link
        // ended): a noVNC page still up is driving nothing.
        // A read sent before `/take` can still answer watching: not for a
        // moment after it.
        let settled = takenAt.map { ContinuousClock.now - $0 > .seconds(2) } ?? true
        if (status == .watching && settled) || feed.phase.isOver {
            controlTaken = false
            dropNoVNC()
        }
        // Connecting too long: the bridge is asked whether it sleeps.
        if feed.phase == .notResponding { chatWatch?.checkNow() }
        refresh()
    }

    /// The line's status, nil while it hides: the link ended or expired.
    static func status(_ phase: LiveBrowserFeed.Phase) -> String? {
        switch phase {
        case .connecting, .unreachable: Strings.LiveBrowser.connecting
        case .dormant: Strings.LiveBrowser.asleepStatus
        case .notResponding: Strings.LiveBrowser.notRespondingStatus
        case .live(let state):
            if state.ended { nil }
            else if state.pendingApproval != nil { Strings.LiveBrowser.needsApproval }
            else if state.asleep { Strings.LiveBrowser.asleepStatus }
            else if state.starting, state.status == .watching { Strings.LiveBrowser.starting }
            else { Strings.LiveBrowser.status(state.status) }
        case .unavailable: Strings.LiveBrowser.unavailableStatus
        case .ended, .expired: nil
        }
    }

    /// Whether the red line may show: only once the bridge answered that a
    /// browser runs for the link (its state, and its lookup when asked),
    /// never while connecting, asleep, dead, done or not responding.
    private var lineShows: Bool { browserRuns }

    /// The bridge says a browser runs for the chat's link: the red line,
    /// and the chip's red dot.
    var browserRuns: Bool {
        !lookupSaysIdle && feed?.phase.isRunning == true
    }

    private func refresh() {
        let status = lineShows ? feed.flatMap { Self.status($0.phase) } : nil
        let changed = status != shownStatus
        shownStatus = status
        indicator.text = indicatorText
        indicator.isHidden = status == nil
        if let feed { player?.show(feed) }
        if status == nil, feed?.phase.isOver == true, player != nil, feed?.phase != .unavailable { closePlayer(animated: true) }
        for controller in fullScreen?.viewControllers ?? [] { (controller as? LiveBrowserFullScreenItems)?.update(feed?.phase.state, held: holdsControl) }
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
        chatWatch?.eager = true
        if let player {
            player.pulse()
            freshen(feed)
            return
        }
        let player = LiveBrowserPlayerView()
        self.player = player
        player.large = showsLarge
        player.onClose = { [weak self] in self?.closePlayer(animated: true) }
        player.onFullScreen = { [weak self] in self?.presentFullScreen(taking: false) }
        player.onResize = { [weak self] in self?.resize() }
        player.onAction = { [weak self] in self?.playerAction() }
        player.holdsControl = { [weak self] in self?.holdsControl ?? false }
        player.onEnd = { [weak self, weak player] in self?.confirmEnd(from: player?.menuButton) }
        player.onSleep = { [weak self] in self?.sleep() }
        player.onTap = { [weak self] in self?.presentFullScreen(taking: false) }
        player.onDrop = { [weak self] center in self?.drop(at: center) }
        feed.attach(player, visible: isOnScreen, frames: true, fast: showsLarge) { [weak player] feed in player?.show(feed) }
        // Shown again after X: a poll that stalled starts over.
        freshen(feed)
        player.show(feed)
        if let view = host?.viewIfLoaded { view.addSubview(player) }
        if let placed { layoutPlayer(card: placed.card, anchor: placed.anchor) }
        player.appear()
        onLayoutChange?()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The player opened, or was asked for again: the bridge is asked for
    /// the chat now, rather than its last answer (asleep, maybe 30 s old)
    /// kept; a feed that stopped responding reads again; and a poll with
    /// no picture yet starts over.
    private func freshen(_ feed: LiveBrowserFeed) {
        chatWatch?.checkNow()
        if feed.phase == .notResponding, !lookupSaysIdle { feed.retry() } else { feed.pollNow() }
    }

    /// The player goes; the line stays while the link is live.
    func closePlayer(animated: Bool) {
        guard let player else { return }
        self.player = nil
        chatWatch?.eager = false
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
        // A phone's player has one size: full screen is the bigger one.
        guard !isPhone else { return }
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
        if let approval = feed?.phase.state?.pendingApproval { askApproval(approval) }
        else if feed?.phase.isResting == true { retryBrowser() }
        else if holdsControl { release() }
        else { presentFullScreen(taking: true) }
    }

    /// The noVNC page's bar: moves the page (`POST /nav`).
    func navigate(_ action: LiveBrowserNavigation) async -> Result<LiveBrowserNavResult, LiveBrowserNavFailure> {
        guard let feed else { return .failure(LiveBrowserNavFailure(BrowserError.unavailable)) }
        do {
            return .success(try await feed.navigate(action))
        } catch {
            return .failure(LiveBrowserNavFailure(error))
        }
    }

    /// Whether Release is what's offered: the person has the browser, or
    /// the agent asks for them while this app still holds it.
    var holdsControl: Bool {
        switch feed?.phase.state?.status {
        case .user: true
        case .takeover: controlTaken
        default: false
        }
    }

    // MARK: Full screen

    /// The live page full screen over everything, the voice sheet
    /// included; `taking`, control taken first and noVNC opened.
    func presentFullScreen(taking: Bool) {
        guard let feed, !busy else { return }
        guard let connection = connect() else { return alert(Strings.LiveBrowser.title, Strings.LiveBrowser.unavailable) }
        busy = true
        player?.isBusy = true
        // At the origin the feed reads it from: the one the chat's computer reaches.
        let link = feed.activeLink
        Task { [weak self] in
            do {
                let workspace = try await connection.workspace()
                let page = try await BrowserPage.workspace(client: connection.client, url: link.url, workspaceID: workspace)
                guard let self else { return }
                self.busy = false
                self.player?.isBusy = false
                guard self.feed === feed else { return }
                let browser = BrowserViewController(url: link.url, page: page, extraItems: [])
                // A phone: the page's own footer (Take control, Release,
                // Sleep) and header go, the header and the strip have
                // them, and the picture has the page.
                if self.isPhone { browser.configure = { Self.pictureOnly(in: $0) } }
                let live = LiveBrowserFullScreenItems(dock: self, browser: browser, noVNC: false)
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
            // Never pulled down or pinched closed while noVNC has the
            // touches: a two-finger drag there is the page's.
            let options = UIViewController.Transition.ZoomOptions()
            options.interactiveDismissShouldBegin = { [weak self] _ in self?.allowsInteractiveDismiss ?? true }
            navigation.preferredTransition = .zoom(options: options) { [weak player] _ in player }
        }
        fullScreen = navigation
        // The chat under it disappears, and with it the dock's reading: the
        // full screen reads the state itself, so a change under noVNC shows.
        feed?.attach(navigation, visible: true) { _ in }
        var presenter: UIViewController = host
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        presenter.present(navigation, animated: true)
        items.update(feed?.phase.state, held: holdsControl)
    }

    private func dismissFullScreen(animated: Bool) {
        guard let fullScreen else { return }
        // Minimize, End, the chat closing: noVNC goes with the full
        // screen, and control with it, said here rather than left to the
        // page's disappearing.
        if noVNCPage != nil { releaseHeld() }
        self.fullScreen = nil
        feed?.detach(fullScreen)
        // The chat shows again: said here too, not only by its
        // appearance, which a zoom back to the player can leave unsaid,
        // and the player's reading with it.
        fullScreen.dismiss(animated: animated) { [weak self] in self?.hostShows() }
    }

    /// The chat is on screen when its view is in a window again.
    private func hostShows() {
        guard let view = host?.viewIfLoaded, view.window != nil else { return }
        setOnScreen(true)
        feed?.kick()
    }

    /// The full screen may be pulled down or pinched closed: not while
    /// noVNC is on it.
    var allowsInteractiveDismiss: Bool { noVNCPage == nil }

    /// The noVNC page on top of the full screen, while there is one.
    var noVNCPage: LiveBrowserFullScreenItems? {
        (fullScreen?.viewControllers.last as? LiveBrowserFullScreenItems).flatMap { $0.isNoVNC ? $0 : nil }
    }

    /// noVNC went away (released, disconnected, failed, or the bridge
    /// moved on): its page and tunnel go, and the live frame view shows
    /// again with the controls for the state now.
    func dropNoVNC() {
        guard let fullScreen, let noVNC = noVNCPage else { return }
        noVNC.browser?.close()
        noVNC.viewer?.stop()
        guard let frame = fullScreen.viewControllers.first(where: { ($0 as? LiveBrowserFullScreenItems)?.isNoVNC == false }) else {
            return minimize()
        }
        fullScreen.popToViewController(frame, animated: true)
        (frame as? LiveBrowserFullScreenItems)?.update(feed?.phase.state, held: holdsControl)
    }

    // MARK: Control only while noVNC shows

    /// The noVNC screen went, whatever took it (Minimize, the full screen
    /// dismissed, popped, dropped): control works only there, so it is
    /// handed back.
    func noVNCLeft() {
        releaseHeld()
    }

    /// The chat closed: control held through it goes back, and its full
    /// screen with it.
    func hostClosed() {
        releaseHeld()
        dismissFullScreen(animated: false)
    }

    /// `POST /release` for `feed`'s link, through its own transport, once
    /// for each take, and not while Release control is already on its way.
    private func releaseHeld(_ feed: LiveBrowserFeed? = nil) {
        guard let feed = feed ?? self.feed, feed === self.feed, !releasedOnLeave, !releasing,
              controlTaken || feed.phase.state?.status == .user else { return }
        releasedOnLeave = true
        controlTaken = false
        Task { [weak self] in
            try? await feed.release()
            guard let self, self.feed === feed else { return }
            self.refresh()
        }
        refresh()
    }

    @objc private func appBackgrounded() {
        backgroundRelease?.cancel()
        guard noVNCPage != nil, holdsControl else { return }
        backgroundRelease = Task { [weak self] in
            try? await Task.sleep(for: Self.backgroundGrace)
            guard !Task.isCancelled, let self, UIApplication.shared.applicationState == .background else { return }
            self.releaseHeld()
            self.dropNoVNC()
        }
    }

    @objc private func appForegrounded() {
        backgroundRelease?.cancel()
        backgroundRelease = nil
    }

    /// Take control (`POST /take`), then drive the browser in noVNC, at
    /// the address the bridge answered with.
    func take(connection: LiveBrowserConnection? = nil, workspace: String? = nil) {
        guard let feed, !busy else { return }
        guard let connection = connection ?? connect() else { return alert(Strings.LiveBrowser.takeFailed, Strings.LiveBrowser.unavailable) }
        busy = true
        // An asleep browser takes a few seconds to wake (`/take` 202): the
        // feed says starting meanwhile.
        player?.isBusy = true
        Task { [weak self] in
            do {
                let take = try await feed.take()
                guard let self else { return }
                self.player?.isBusy = false
                defer { self.busy = false }
                guard self.feed === feed else { return }
                self.controlTaken = true
                self.takenAt = .now
                self.releasedOnLeave = false
                // Left before `/take` answered: control is no good without
                // noVNC, so it goes straight back.
                guard self.fullScreen != nil else { self.releaseHeld(feed); return self.refresh() }
                if let url = take.novncURL, self.fullScreen != nil, self.noVNCPage == nil {
                    let id: String
                    if let workspace { id = workspace } else { id = try await connection.workspace() }
                    let place = ControlPlace(url: url, client: connection.client, workspaceID: id)
                    self.controlPlace = place
                    let items = try await self.controlPage(place, native: !LiveBrowserViewerSetting.usesWebViewer)
                    if self.fullScreen != nil, self.noVNCPage == nil {
                        self.fullScreen?.pushViewController(items, animated: true)
                        items.update(feed.phase.state, held: self.holdsControl)
                    }
                }
                self.refresh()
            } catch {
                guard let self else { return }
                self.busy = false
                self.player?.isBusy = false
                self.alert(Strings.LiveBrowser.takeFailed, Strings.LiveBrowser.unreachable)
            }
        }
    }

    /// Where control's page connects: the address `/take` answered, and
    /// the computer and workspace it goes through.
    struct ControlPlace {
        let url: URL
        let client: AgentClient
        let workspaceID: String
    }
    /// The last take's, for switching viewers while it is held.
    private var controlPlace: ControlPlace?

    /// Control's page: the native viewer when asked for and the address
    /// is one it can reach, noVNC's web page else.
    private func controlPage(_ place: ControlPlace, native: Bool) async throws -> LiveBrowserFullScreenItems {
        if native, let target = LiveBrowserVNCTarget(novncURL: place.url) {
            let client = place.client, workspaceID = place.workspaceID
            let viewer = LiveBrowserVNCController(target: target) {
                try await client.liveBrowserVNC(target, workspaceID: workspaceID)
            }
            viewer.onGiveUp = { [weak self] in self?.dropNoVNC() }
            viewer.onUseWebViewer = { [weak self] in self?.switchViewer(native: false) }
            // Just after a tap: did the click put the page's focus in a field?
            viewer.readFocus = { [weak self] in
                guard let feed = self?.feed, let state = try? await feed.readState() else { return nil }
                return state.editableFocused
            }
            return LiveBrowserFullScreenItems(dock: self, viewer: viewer)
        }
        let url = isPhone ? Self.scaledNoVNC(place.url) : place.url
        let page = try await BrowserPage.workspace(client: place.client, url: url, workspaceID: place.workspaceID)
        let browser = BrowserViewController(url: url, page: page, extraItems: [])
        browser.isRemoteScreen = true
        let watch = LiveBrowserNoVNCWatch()
        watch.disconnected = { [weak self] in self?.dropNoVNC() }
        browser.configure = { watch.install(in: $0) }
        browser.onFailure = { [weak self] _ in self?.dropNoVNC() }
        return LiveBrowserFullScreenItems(dock: self, browser: browser, noVNC: true)
    }

    /// The live page as its picture alone, edge to edge: no header, no
    /// footer, no margins. Set through the CSS object model, which the
    /// page's nonce-only `style-src` leaves alone (a `<style>` added here
    /// would be refused). Approvals and the page's notes still show.
    nonisolated static let pictureOnlySource = """
    (function () {
      var set = function (selector, styles) {
        var element = document.querySelector(selector);
        if (!element) { return; }
        for (var name in styles) { element.style.setProperty(name, styles[name], 'important'); }
      };
      set('header', { display: 'none' });
      set('footer', { display: 'none' });
      set('main', { padding: '0' });
      set('#box', { border: '0', 'border-radius': '0', 'max-width': 'none', 'min-height': '0',
                    'max-height': '100dvh' });
    })();
    """

    static func pictureOnly(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(source: pictureOnlySource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    /// noVNC's page scaling the remote screen to fit, never asking it to
    /// take the phone's size: `resize=remote` becomes `resize=scale`. The
    /// bridge already sends `scale`; an older pod's `remote` would leave
    /// x11vnc's fixed 1920x1200 unscaled and cut off.
    static func scaledNoVNC(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems, items.contains(where: { $0.name == "resize" && $0.value == "remote" }) else { return url }
        parts.queryItems = items.map { $0.name == "resize" ? URLQueryItem(name: "resize", value: "scale") : $0 }
        return parts.url ?? url
    }

    /// The other viewer in place of the one showing, control kept: the
    /// choice is remembered on this device.
    func switchViewer(native: Bool) {
        guard let place = controlPlace, let old = noVNCPage, holdsControl else { return }
        LiveBrowserViewerSetting.usesWebViewer = !native
        Task { [weak self] in
            guard let self, let items = try? await self.controlPage(place, native: native),
                  let fullScreen = self.fullScreen, self.noVNCPage === old else { return }
            old.swappedOut = true
            old.browser?.close()
            old.viewer?.stop()
            var stack = fullScreen.viewControllers
            stack.removeLast()
            stack.append(items)
            fullScreen.setViewControllers(stack, animated: false)
            items.update(self.feed?.phase.state, held: self.holdsControl)
        }
    }

    /// Release control (`POST /release`): the agent drives again, and a
    /// noVNC page goes, back to the live frame view.
    func release() {
        guard let feed, !busy else { return }
        busy = true
        releasing = true
        player?.isBusy = true
        Task { [weak self] in
            do {
                try await feed.release()
                guard let self else { return }
                self.busy = false
                self.releasing = false
                self.player?.isBusy = false
                guard self.feed === feed else { return }
                self.controlTaken = false
                self.dropNoVNC()
                self.refresh()
            } catch {
                guard let self else { return }
                self.busy = false
                self.releasing = false
                self.player?.isBusy = false
                self.alert(Strings.LiveBrowser.releaseFailed, Strings.LiveBrowser.unreachable)
            }
        }
    }

    /// End browser, asked about first: an action sheet from `source` (a
    /// bar button item or a view).
    func confirmEnd(from source: AnyObject?) {
        guard let host, feed?.phase.isOver == false else { return }
        var presenter: UIViewController = host
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let sheet = UIAlertController(title: Strings.LiveBrowser.endConfirm, message: Strings.LiveBrowser.endConfirmDetail, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: Strings.LiveBrowser.endBrowser, style: .destructive) { [weak self] _ in self?.end() })
        sheet.addAction(UIAlertAction(title: Strings.LiveBrowser.cancel, style: .cancel))
        if let popover = sheet.popoverPresentationController {
            if let item = source as? UIBarButtonItem {
                popover.sourceItem = item
            } else if let view = source as? UIView, view.window != nil {
                popover.sourceView = view
                popover.sourceRect = view.bounds
            } else {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
        }
        presenter.present(sheet, animated: true)
    }

    /// Ends the browser (`POST /end`): its session closes and the agent is
    /// told the person ended it. The full screen goes; the line and the
    /// player fade as they do for any ended browser.
    func end() {
        guard let feed, !busy else { return }
        busy = true
        player?.isBusy = true
        Task { [weak self] in
            do {
                try await feed.end()
                guard let self else { return }
                self.busy = false
                self.player?.isBusy = false
                guard self.feed === feed else { return }
                self.controlTaken = false
                self.dismissFullScreen(animated: true)
                self.refresh()
            } catch {
                guard let self else { return }
                self.busy = false
                self.player?.isBusy = false
                self.alert(Strings.LiveBrowser.endFailed, Strings.LiveBrowser.unreachable)
            }
        }
    }

    /// Puts the browser to sleep (`POST /sleep`), with no question: the
    /// logins and the page are kept, and the agent's next call or Take
    /// control wakes it where it was. Control goes back to the agent; the
    /// full screen goes, and the player shows it asleep.
    func sleep() {
        guard let feed, !busy, !feed.phase.isOver else { return }
        busy = true
        player?.isBusy = true
        Task { [weak self] in
            do {
                try await feed.sleep()
                guard let self else { return }
                self.busy = false
                self.player?.isBusy = false
                guard self.feed === feed else { return }
                self.controlTaken = false
                self.dismissFullScreen(animated: true)
                self.refresh()
            } catch {
                guard let self else { return }
                self.busy = false
                self.player?.isBusy = false
                let refused = error as? BrowserError == .upstream(404) || error as? BrowserError == .upstream(409)
                self.alert(Strings.LiveBrowser.sleepFailed, refused ? Strings.LiveBrowser.sleepRefused : Strings.LiveBrowser.unreachable)
            }
        }
    }

    /// Back to the player.
    func minimize() {
        if player == nil { openPlayer() }
        dismissFullScreen(animated: true)
    }

    // MARK: Approvals

    /// Approve, Deny, or Not now for the action the agent waits on. The
    /// words are the bridge's scrubbed summary: never what was typed.
    private func askApproval(_ approval: LiveBrowserState.Approval) {
        guard let host, approvalAlert == nil else { return }
        var presenter: UIViewController = host
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let alert = UIAlertController(title: Strings.LiveBrowser.approvalTitle, message: approval.text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Strings.LiveBrowser.deny, style: .destructive) { [weak self] _ in self?.decide(approval, approve: false) })
        let approve = UIAlertAction(title: Strings.LiveBrowser.approve, style: .default) { [weak self] _ in self?.decide(approval, approve: true) }
        alert.addAction(approve)
        alert.addAction(UIAlertAction(title: Strings.LiveBrowser.notNow, style: .cancel))
        alert.preferredAction = approve
        alert.view.accessibilityIdentifier = "live-browser-approval"
        approvalAlert = alert
        approvalShown = approval.id
        presenter.present(alert, animated: true)
    }

    /// The approval went (decided, elsewhere or here; the browser closed).
    private func dismissApproval() {
        approvalShown = nil
        guard let alert = approvalAlert else { return }
        approvalAlert = nil
        if alert.presentingViewController != nil, !alert.isBeingDismissed { alert.dismiss(animated: true) }
    }

    private func decide(_ approval: LiveBrowserState.Approval, approve: Bool) {
        approvalAlert = nil
        approvalShown = nil
        guard let feed else { return }
        Task { [weak self] in
            do {
                try await feed.decide(approval, approve: approve)
            } catch BrowserError.upstream(409) {
                self?.alert(Strings.LiveBrowser.approvalFailed, Strings.LiveBrowser.approvalGone)
            } catch {
                self?.alert(Strings.LiveBrowser.approvalFailed, Strings.LiveBrowser.unreachable)
            }
        }
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

/// The full screen's page: the browser, with Minimize and End browser at
/// the left and Take control or Release control at the right.
@MainActor
final class LiveBrowserFullScreenItems: UIViewController {
    /// The web page shown: the live frame view, or noVNC's page.
    let browser: BrowserViewController!
    /// The native viewer of a held browser, in noVNC's place.
    let viewer: LiveBrowserVNCController?
    private weak var dock: LiveBrowserDock?
    /// Control's page (noVNC or the native viewer), not the frame view.
    let isNoVNC: Bool
    /// Replaced by the other viewer: leaving hands nothing back.
    var swappedOut = false
    let control = UIBarButtonItem()
    /// End browser: at the left by Minimize, far from Release control.
    let endItem = UIBarButtonItem()
    /// Sleep browser: beside End, not destructive.
    let sleepItem = UIBarButtonItem()
    private var state: LiveBrowserState?
    private var held = false

    init(dock: LiveBrowserDock, browser: BrowserViewController, noVNC: Bool) {
        self.dock = dock
        self.browser = browser
        self.viewer = nil
        self.isNoVNC = noVNC
        super.init(nibName: nil, bundle: nil)
    }

    /// Control's page with the native viewer.
    init(dock: LiveBrowserDock, viewer: LiveBrowserVNCController) {
        self.dock = dock
        self.browser = nil
        self.viewer = viewer
        self.isNoVNC = true
        super.init(nibName: nil, bundle: nil)
    }

    /// What fills the page under the header.
    private var content: UIViewController { viewer ?? browser }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = isNoVNC ? "live-browser-novnc" : "live-browser-full-screen"
        let content = self.content
        addChild(content)
        view.addSubview(content.view)
        var placed: [NSLayoutConstraint] = []
        if viewer != nil {
            // The native viewer: no bar of ours under the header. The
            // picture is Chrome's window, address bar and all, so it
            // has the whole page below the header.
            content.view.translatesAutoresizingMaskIntoConstraints = false
            view.backgroundColor = .systemBackground
            placed = [
                content.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
        } else if isNoVNC {
            // The bar under the header, clear of the keyboard pill at the
            // bottom and of Minimize: noVNC below it.
            let bar = navBar
            bar.translatesAutoresizingMaskIntoConstraints = false
            content.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            view.backgroundColor = .systemBackground
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            ])
            placed = [
                content.view.topAnchor.constraint(equalTo: bar.bottomAnchor),
                content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
        } else {
            // The live frame view: placed by `LiveBrowserFullScreenLayout`
            // (the whole screen, or a phone's picture edge to edge).
            content.view.frame = view.bounds
            if isPhone { view.backgroundColor = UIColor(Palette.surface) }
        }
        if placesByLayout {
            // noVNC's page on a phone: placed by the layout, as the frame view.
            content.view.translatesAutoresizingMaskIntoConstraints = true
        } else {
            NSLayoutConstraint.activate(placed)
            constrained = placed
        }
        content.didMove(toParent: self)
        let minimize = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), primaryAction: UIAction { [weak self] _ in self?.dock?.minimize() })
        minimize.accessibilityLabel = Strings.LiveBrowser.minimize
        minimize.accessibilityIdentifier = "live-browser-minimize"
        // Minimize is the way back: noVNC's page has no back to go to,
        // and a back button there would leave control held.
        navigationItem.hidesBackButton = true
        endItem.image = UIImage(systemName: "xmark.octagon")
        endItem.tintColor = .systemRed
        endItem.accessibilityLabel = Strings.LiveBrowser.endBrowser
        endItem.accessibilityIdentifier = "live-browser-end"
        endItem.primaryAction = UIAction(title: Strings.LiveBrowser.endBrowser, image: UIImage(systemName: "xmark.octagon")) { [weak self] _ in
            guard let self else { return }
            self.dock?.confirmEnd(from: self.endItem)
        }
        sleepItem.image = UIImage(systemName: "moon.zzz")
        sleepItem.accessibilityLabel = Strings.LiveBrowser.sleepBrowser
        sleepItem.accessibilityIdentifier = "live-browser-sleep"
        sleepItem.primaryAction = UIAction(title: Strings.LiveBrowser.sleepBrowser, image: UIImage(systemName: "moon.zzz")) { [weak self] _ in
            self?.dock?.sleep()
        }
        navigationItem.leftBarButtonItems = [minimize, endItem, sleepItem]
        control.style = .prominent
        control.accessibilityIdentifier = "live-browser-control"
        // Control alone at the right, or with reload on the frame view: the
        // browser's back, forward and share pushed it into the header's
        // overflow menu on a phone, out of sight under noVNC. So did the
        // viewer switch beside it, with Minimize, End and Sleep at the
        // left: on noVNC's page it is in the More menu of the bar under
        // the header, as Use the web viewer is in the native viewer's.
        if viewer != nil || isNoVNC {
            navigationItem.rightBarButtonItems = [control]
        } else {
            navigationItem.rightBarButtonItems = [control, browser.reloadItem]
        }
        if isPhone { buildStrip() }
        update(state, held: held)
    }

    // MARK: A phone turned sideways

    /// An iPhone (not an iPad, not the app on a Mac).
    private var isPhone: Bool { LiveBrowserDock.isPhone(traitCollection) }
    /// The content's constraints where it has them, off while the strip shows.
    private var constrained: [NSLayoutConstraint] = []
    /// The header's controls in a column at the trailing edge, on a phone
    /// turned sideways; the header and noVNC's address row hide meanwhile.
    let strip = UIView()
    private(set) var stripShown = false
    private let stripControl = UIButton(configuration: .prominentGlass())
    private let stripEnd = LiveBrowserFullScreenItems.stripButton("xmark.octagon", Strings.LiveBrowser.endBrowser, "live-browser-end")
    private let stripSleep = LiveBrowserFullScreenItems.stripButton("moon.zzz", Strings.LiveBrowser.sleepBrowser, "live-browser-sleep")

    /// The web pages (the frame view, and noVNC's on a phone) are placed
    /// by `LiveBrowserFullScreenLayout` always; the native viewer, which
    /// fits the picture itself over its own bar and the keyboard, only
    /// while the strip shows.
    private var placesByLayout: Bool { viewer == nil && (!isNoVNC || isPhone) }

    private func fullScreenLayout() -> LiveBrowserFullScreenLayout {
        // Under the header, and under noVNC's address row while it shows.
        let top = isNoVNC && viewer == nil && !navBar.isHidden ? navBar.frame.maxY : view.safeAreaInsets.top
        return LiveBrowserFullScreenLayout(size: view.bounds.size, safeArea: LayoutInsets(view.safeAreaInsets),
                                           top: top, phone: isPhone, aspect: dock?.frameAspect)
    }

    /// A button in the column: the glyph alone on a 44-point target, in
    /// the header's tint.
    private static func stripButton(_ symbol: String, _ label: String, _ id: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        configuration.baseForegroundColor = UIColor(Palette.headerTint)
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        typealias M = LiveBrowserFullScreenLayout.Metrics
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: M.button),
            button.heightAnchor.constraint(equalToConstant: M.button),
        ])
        return button
    }

    /// Minimize, End and Sleep at the top; the page's own (back, forward,
    /// reload, More) in the middle; Take or Release control at the bottom.
    private func buildStrip() {
        typealias M = LiveBrowserFullScreenLayout.Metrics
        let minimize = Self.stripButton("chevron.down", Strings.LiveBrowser.minimize, "live-browser-minimize")
        minimize.addAction(UIAction { [weak self] _ in self?.dock?.minimize() }, for: .touchUpInside)
        stripEnd.configuration?.baseForegroundColor = .systemRed
        stripEnd.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.dock?.confirmEnd(from: self.stripEnd)
        }, for: .touchUpInside)
        stripSleep.addAction(UIAction { [weak self] _ in self?.dock?.sleep() }, for: .touchUpInside)
        var page: [UIView] = []
        if viewer == nil, isNoVNC {
            func nav(_ symbol: String, _ label: String, _ id: String, _ action: LiveBrowserNavigation) -> UIButton {
                let button = Self.stripButton(symbol, label, id)
                button.addAction(UIAction { [weak self] _ in self?.navigate(action) }, for: .touchUpInside)
                return button
            }
            let more = Self.stripButton("ellipsis.circle", Strings.LiveBrowser.Viewer.more, "live-browser-viewer-menu")
            more.showsMenuAsPrimaryAction = true
            more.menu = viewerMenu.menu
            page = [
                nav("chevron.backward", Strings.LiveBrowser.back, "live-browser-back", .back),
                nav("chevron.forward", Strings.LiveBrowser.forward, "live-browser-forward", .forward),
                nav("arrow.clockwise", Strings.LiveBrowser.reload, "live-browser-reload", .reload),
                more,
            ]
        } else if viewer == nil, let browser {
            let reload = Self.stripButton("arrow.clockwise", Strings.Browser.reload, "browser-reload")
            reload.addAction(UIAction { [weak browser] _ in browser?.reloadOrStop() }, for: .touchUpInside)
            page = [reload]
        }
        stripControl.accessibilityIdentifier = "live-browser-control"
        stripControl.addAction(UIAction { [weak self] _ in
            guard let self, let dock = self.dock else { return }
            if self.held { dock.release() } else { dock.take() }
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            stripControl.widthAnchor.constraint(equalToConstant: M.button),
            stripControl.heightAnchor.constraint(equalToConstant: M.button),
        ])
        func group(_ views: [UIView]) -> UIStackView {
            let stack = UIStackView(arrangedSubviews: views)
            stack.axis = .vertical
            stack.alignment = .center
            return stack
        }
        let column = UIStackView(arrangedSubviews: [group([minimize, stripEnd, stripSleep]), group(page), group([stripControl])])
        column.axis = .vertical
        column.alignment = .center
        column.distribution = .equalSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: strip.topAnchor),
            column.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            column.centerXAnchor.constraint(equalTo: strip.centerXAnchor),
        ])
        strip.backgroundColor = UIColor(Palette.surface)
        strip.accessibilityIdentifier = "live-browser-strip"
        strip.isHidden = true
        view.addSubview(strip)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        applyMode()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let layout = fullScreenLayout()
        if let frame = layout.strip { strip.frame = frame }
        if stripShown || placesByLayout { content.view.frame = layout.content }
    }

    /// Sideways on a phone, the strip; upright, the header. Follows the
    /// device's own turn: nothing here asks for an orientation.
    private func applyMode() {
        let wants = LiveBrowserFullScreenLayout.usesStrip(phone: isPhone, size: view.bounds.size)
        if wants != stripShown {
            stripShown = wants
            strip.isHidden = !wants
            if wants {
                NSLayoutConstraint.deactivate(constrained)
                content.view.translatesAutoresizingMaskIntoConstraints = true
            } else if !constrained.isEmpty {
                content.view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate(constrained)
            }
            showNavRow()
            view.bringSubviewToFront(strip)
        }
        if let navigation = navigationController, navigation.topViewController === self, navigation.isNavigationBarHidden != wants {
            navigation.setNavigationBarHidden(wants, animated: false)
        }
    }

    /// noVNC's address row hides with the header; a failure's words
    /// still show.
    private func showNavRow() {
        guard isNoVNC, viewer == nil else { return }
        navRow?.isHidden = stripShown
        navBar.isHidden = stripShown && navMessage.isHidden
    }

    /// The gestures around noVNC that would take its touches, off while
    /// it shows and back as they were when it goes.
    private var heldGestures: [(UIGestureRecognizer, Bool)] = []
    private var heldSplit: (UISplitViewController, Bool)?
    private var heldModal: Bool?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isNoVNC { holdGestures() }
        applyMode()
    }

    /// Going for good (popped, or its full screen dismissed), not covered
    /// for a moment or laid out again: control goes back. Asked before it
    /// goes, while the dismissal still says so.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isNoVNC else { return }
        restoreGestures()
        let navigation = navigationController
        guard !swappedOut else { return }
        if isMovingFromParent || isBeingDismissed || navigation?.isBeingDismissed == true { dock?.noVNCLeft() }
    }

    /// Whatever the will-disappear missed: gone from its full screen.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isNoVNC else { return }
        let gone = parent == nil || navigationController?.presentingViewController == nil
        // The native viewer's socket goes with its page, however it went.
        if gone { viewer?.stop() }
        guard !swappedOut else { return }
        if gone { dock?.noVNCLeft() }
    }

    /// noVNC has every touch: no swipe back, no pull to dismiss, no split
    /// view's sidebar swipe under it.
    func holdGestures() {
        guard heldGestures.isEmpty, heldSplit == nil, heldModal == nil, let navigation = navigationController else { return }
        var gestures = [navigation.interactivePopGestureRecognizer].compactMap { $0 }
        if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer { gestures.append(content) }
        heldGestures = gestures.map { ($0, $0.isEnabled) }
        for gesture in gestures { gesture.isEnabled = false }
        heldModal = navigation.isModalInPresentation
        navigation.isModalInPresentation = true
        if let split = navigation.presentingViewController.flatMap(Self.split) {
            heldSplit = (split, split.presentsWithGesture)
            split.presentsWithGesture = false
        }
    }

    func restoreGestures() {
        for (gesture, enabled) in heldGestures { gesture.isEnabled = enabled }
        heldGestures = []
        if let heldModal { navigationController?.isModalInPresentation = heldModal }
        heldModal = nil
        if let (split, gestured) = heldSplit { split.presentsWithGesture = gestured }
        heldSplit = nil
    }

    /// The split view the full screen was presented over, if any.
    private static func split(_ controller: UIViewController) -> UISplitViewController? {
        if let split = controller as? UISplitViewController { return split }
        if let split = controller.splitViewController { return split }
        for child in controller.children { if let split = split(child) { return split } }
        return nil
    }

    /// The gestures noVNC holds off now (tests).
    var holdsGestures: Bool { !heldGestures.isEmpty || heldModal != nil }

    // MARK: The noVNC page's bar

    /// Back, Forward, Reload and the address, over noVNC's web page
    /// (`POST /nav`); not over the native viewer, whose picture shows
    /// Chrome's own.
    /// The bridge knows no history, so Back and Forward are always on.
    let address = UITextField()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let navMessage = UILabel()
    /// More, at the end of the bar: Use the native viewer, a tap away
    /// from the fallback page, kept off the header where it crowded
    /// Release control into the overflow menu.
    let viewerMenu = UIButton(type: .system)
    /// Calls in flight.
    private(set) var navigating = 0
    private var messageClear: Task<Void, Never>?
    /// Back, Forward, Reload, the address and More: hidden while the strip has them.
    private var navRow: UIView?

    private lazy var navBar: UIView = {
        func button(_ symbol: String, _ label: String, _ id: String, _ action: LiveBrowserNavigation) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.accessibilityLabel = label
            button.accessibilityIdentifier = id
            button.addAction(UIAction { [weak self] _ in self?.navigate(action) }, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            return button
        }
        address.borderStyle = .roundedRect
        address.font = .preferredFont(forTextStyle: .subheadline)
        address.placeholder = Strings.LiveBrowser.address
        address.accessibilityLabel = Strings.LiveBrowser.address
        address.accessibilityIdentifier = "live-browser-address"
        address.keyboardType = .URL
        address.autocorrectionType = .no
        address.autocapitalizationType = .none
        address.spellCheckingType = .no
        address.smartDashesType = .no
        address.smartQuotesType = .no
        address.returnKeyType = .go
        address.clearButtonMode = .whileEditing
        address.textContentType = .URL
        address.delegate = self
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spinner.hidesWhenStopped = true
        spinner.accessibilityIdentifier = "live-browser-nav-spinner"
        viewerMenu.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        viewerMenu.accessibilityLabel = Strings.LiveBrowser.Viewer.more
        viewerMenu.accessibilityIdentifier = "live-browser-viewer-menu"
        viewerMenu.showsMenuAsPrimaryAction = true
        viewerMenu.menu = UIMenu(children: [
            UIAction(title: Strings.LiveBrowser.Viewer.nativeViewer, image: UIImage(systemName: "rectangle.on.rectangle"),
                     identifier: UIAction.Identifier("live-browser-native-viewer")) { [weak self] _ in
                self?.dock?.switchViewer(native: true)
            },
        ])
        viewerMenu.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let row = UIStackView(arrangedSubviews: [
            button("chevron.backward", Strings.LiveBrowser.back, "live-browser-back", .back),
            button("chevron.forward", Strings.LiveBrowser.forward, "live-browser-forward", .forward),
            button("arrow.clockwise", Strings.LiveBrowser.reload, "live-browser-reload", .reload),
            address,
            spinner,
            viewerMenu,
        ])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        navRow = row
        navMessage.font = .preferredFont(forTextStyle: .footnote)
        navMessage.textColor = .systemRed
        navMessage.numberOfLines = 2
        navMessage.isHidden = true
        navMessage.accessibilityIdentifier = "live-browser-nav-message"
        let stack = UIStackView(arrangedSubviews: [row, navMessage])
        stack.axis = .vertical
        stack.spacing = 4
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        stack.backgroundColor = .secondarySystemBackground
        stack.accessibilityIdentifier = "live-browser-nav-bar"
        return stack
    }()

    func navigate(_ action: LiveBrowserNavigation) {
        guard let dock else { return }
        navigating += 1
        spinner.startAnimating()
        show(navMessage: nil)
        Task { [weak self] in
            let result = await dock.navigate(action)
            guard let self else { return }
            self.navigating -= 1
            if self.navigating == 0 { self.spinner.stopAnimating() }
            switch result {
            case .success(let reply):
                if let url = reply.url, !url.isEmpty, !self.address.isEditing { self.address.text = url }
            case .failure(let failure):
                self.show(navMessage: failure.message)
            }
        }
    }

    private func show(navMessage text: String?) {
        messageClear?.cancel()
        navMessage.text = text
        navMessage.isHidden = text == nil
        showNavRow()
        guard text != nil else { return }
        messageClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.show(navMessage: nil)
        }
    }

    /// Before it loads too: it shows the state once it does. `held`,
    /// Release control; else Take control.
    func update(_ state: LiveBrowserState?, held: Bool) {
        self.state = state
        self.held = held
        guard isViewLoaded else { return }
        control.primaryAction = UIAction(title: held ? Strings.LiveBrowser.releaseControl : Strings.LiveBrowser.takeControl) { [weak self] _ in
            guard let dock = self?.dock else { return }
            if held { dock.release() } else { dock.take() }
        }
        control.isEnabled = state.map { !$0.ended } ?? false
        endItem.isEnabled = state.map { !$0.ended } ?? false
        sleepItem.isEnabled = state.map { !$0.ended && !$0.asleep } ?? false
        let controlTitle = held ? Strings.LiveBrowser.releaseControl : Strings.LiveBrowser.takeControl
        stripControl.configuration?.image = UIImage(systemName: held ? "hand.raised.slash" : "hand.tap")
        stripControl.accessibilityLabel = controlTitle
        stripControl.isEnabled = control.isEnabled
        stripEnd.isEnabled = endItem.isEnabled
        stripSleep.isEnabled = sleepItem.isEnabled
        // The picture's height follows the frame's aspect once one came.
        if isPhone, viewer == nil { view.setNeedsLayout() }
        viewer?.pageFocusChanged(held ? state?.editableFocused : nil)
        if isNoVNC, viewer == nil, !address.isEditing, navigating == 0, let url = state?.url, !url.isEmpty { address.text = url }
        navigationItem.subtitle = state.flatMap { $0.asleep ? Strings.LiveBrowser.asleep : $0.starting ? Strings.LiveBrowser.startingBrowser : nil }
            ?? state?.lastAction.map(Strings.LiveBrowser.lastAction)
            ?? state.map { Strings.LiveBrowser.status($0.status) }
    }
}

extension LiveBrowserFullScreenItems: UITextFieldDelegate {
    /// Return goes to the address typed.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let typed = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return false }
        textField.resignFirstResponder()
        navigate(.goto(typed))
        return true
    }
}

/// Why `/nav` failed, in the words the bar shows.
struct LiveBrowserNavFailure: Error, Equatable {
    let message: String

    init(_ error: Error) {
        message = switch error {
        case BrowserError.upstream(400): Strings.LiveBrowser.notAWebAddress
        case BrowserError.upstream(409): Strings.LiveBrowser.notInControl
        case BrowserError.upstream(503): Strings.LiveBrowser.navAsleep
        case BrowserError.upstream(404), BrowserError.upstream(410): Strings.LiveBrowser.navGone
        default: Strings.LiveBrowser.navFailed
        }
    }
}

/// Watches a noVNC page for its connection ending: the RFB socket
/// closing, or the page leaving its connected state (noVNC's
/// `noVNC_connected` class on the document).
@MainActor
final class LiveBrowserNoVNCWatch: NSObject {
    static let name = "liveBrowserNoVNC"
    static let source = """
    (function () {
      var post = function (s) { try { window.webkit.messageHandlers.liveBrowserNoVNC.postMessage(s); } catch (e) {} };
      var Socket = window.WebSocket;
      if (Socket) {
        var Watched = function (url, protocols) {
          var socket = protocols === undefined ? new Socket(url) : new Socket(url, protocols);
          socket.addEventListener('open', function () { post('connected'); });
          socket.addEventListener('close', function () { post('disconnected'); });
          return socket;
        };
        Watched.prototype = Socket.prototype;
        ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) { Watched[k] = Socket[k]; });
        window.WebSocket = Watched;
      }
      var connected = false;
      var check = function () {
        var c = document.documentElement.classList;
        if (c.contains('noVNC_connected')) { connected = true; }
        else if (connected && !c.contains('noVNC_connecting')) { connected = false; post('disconnected'); }
      };
      new MutationObserver(check).observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
    })();
    """

    /// The page as a remote screen: it never zooms or scrolls itself
    /// (a fixed viewport, `touch-action: none`), so every touch, two
    /// fingers too, goes to noVNC's own gesture handling; and its canvas
    /// has the focus from the start and again once connected, so the first
    /// drag needs no tap first.
    static let touch = """
    (function () {
      var head = document.head || document.documentElement;
      var meta = document.querySelector('meta[name=viewport]');
      if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; head.appendChild(meta); }
      meta.content = 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no';
      var style = document.createElement('style');
      style.textContent = 'html, body, canvas, #noVNC_container { touch-action: none !important; overscroll-behavior: none !important; -webkit-user-select: none; }';
      head.appendChild(style);
      var focus = function () {
        var canvas = document.querySelector('#noVNC_container canvas') || document.querySelector('canvas');
        if (!canvas) { return false; }
        if (!canvas.hasAttribute('tabindex')) { canvas.setAttribute('tabindex', '-1'); }
        try { canvas.focus({ preventScroll: true }); } catch (e) { canvas.focus(); }
        return document.activeElement === canvas;
      };
      window.liveBrowserFocusCanvas = focus;
      focus();
      new MutationObserver(function () {
        if (document.documentElement.classList.contains('noVNC_connected')) { focus(); }
      }).observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
      // noVNC adds its canvas once it connects; until then, look again
      // a few times.
      var tries = 0;
      var look = setInterval(function () { if (focus() || ++tries > 40) { clearInterval(look); } }, 250);
    })();
    """

    var disconnected: (() -> Void)?

    func install(in configuration: WKWebViewConfiguration) {
        let content = configuration.userContentController
        content.removeScriptMessageHandler(forName: Self.name)
        content.add(Relay(self), name: Self.name)
        content.addUserScript(WKUserScript(source: Self.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.touch, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    func received(_ body: Any) {
        if body as? String == "disconnected" { disconnected?() }
    }

    /// The content controller keeps its handler: this keeps the watch
    /// weakly.
    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var watch: LiveBrowserNoVNCWatch?
        init(_ watch: LiveBrowserNoVNCWatch) { self.watch = watch }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { watch?.received(message.body) }
        }
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
    /// The menu's End browser.
    var onEnd: (() -> Void)?
    /// The menu's Sleep browser.
    var onSleep: (() -> Void)?
    var onTap: (() -> Void)?
    var onDrop: ((CGPoint) -> Void)?
    /// Whether Release is what's offered: the dock's word, which knows
    /// this app took control under the agent's asking (`takeover`).
    var holdsControl: (() -> Bool)?
    var large = false { didSet { resize.setImage(UIImage(systemName: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"), for: .normal); resize.accessibilityLabel = large ? Strings.LiveBrowser.smaller : Strings.LiveBrowser.bigger } }
    /// Taking or giving back control, ending: the spinner shows.
    var isBusy = false { didSet { updateSpinner() } }
    /// The feed waits for a frame (none yet, or the bridge slow to make
    /// the next): the spinner shows over the last one, small or large.
    private(set) var isWaiting = false { didSet { if isWaiting != oldValue { updateSpinner() } } }
    /// The spinner is showing (tests).
    var isSpinning: Bool { !spinner.isHidden }
    private(set) var isDragging = false

    private let bar = UIView()
    private let picture = UIImageView()
    private let message = UILabel()
    private let close = LiveBrowserPlayerView.overlayButton("xmark")
    private let full = LiveBrowserPlayerView.overlayButton("arrow.up.left.and.arrow.down.right.rectangle")
    private let resize = LiveBrowserPlayerView.overlayButton("arrow.up.left.and.arrow.down.right")
    /// End browser, away from Take over and Release: behind a menu, and
    /// asked about again before anything ends.
    let menuButton = LiveBrowserPlayerView.overlayButton("ellipsis")
    private let footer = UIView()
    private let pillDot = UIView()
    private let pill = UILabel()
    private let action = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var layout: LiveBrowserDockLayout?
    /// The browser ended: nothing left to end.
    private var isOver = false
    private var frameBytes: Data?
    /// The picture shown now (tests).
    var shownImage: UIImage? { picture.image }
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
        // The bar takes the top corners: the picture is square under it.
        bar.layer.cornerRadius = M.radius
        bar.layer.cornerCurve = .continuous
        bar.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        bar.backgroundColor = UIColor(Palette.cardFill)
        bar.accessibilityIdentifier = "live-browser-player-bar"
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
        menuButton.accessibilityLabel = Strings.LiveBrowser.more
        menuButton.accessibilityIdentifier = "live-browser-player-menu"
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIAction(title: Strings.LiveBrowser.sleepBrowser, image: UIImage(systemName: "moon.zzz")) { [weak self] _ in self?.onSleep?() },
            UIAction(title: Strings.LiveBrowser.endBrowser, image: UIImage(systemName: "xmark.octagon"), attributes: .destructive) { [weak self] _ in self?.onEnd?() },
        ])
        spinner.color = .white
        spinner.isHidden = true
        spinner.hidesWhenStopped = false
        // A dark disc: white alone is lost on a light page.
        spinner.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        spinner.bounds = CGRect(x: 0, y: 0, width: 36, height: 36)
        spinner.layer.cornerRadius = 18
        spinner.accessibilityIdentifier = "live-browser-player-spinner"
        for view in [bar, picture, message, footer, close, full, resize, menuButton, spinner] as [UIView] { addSubview(view) }
        for view in [pillDot, pill, action] as [UIView] { footer.addSubview(view) }
        picture.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        large = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor(Palette.divider).cgColor
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A button on the bar over the picture: the glyph alone, in the
    /// card's colours, on a 44-point target.
    private static func overlayButton(_ symbol: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        configuration.baseForegroundColor = UIColor(Palette.cardTitle)
        configuration.contentInsets = .zero
        return UIButton(configuration: configuration)
    }

    /// Whether the menu (End browser) is on the bar: not on a narrow
    /// player, where full screen has it.
    var showsMenu: Bool { !menuButton.isHidden }

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
        bar.frame = layout.bar
        picture.frame = layout.picture
        message.frame = layout.picture.insetBy(dx: 8, dy: 8)
        close.frame = layout.close
        full.frame = layout.fullScreen ?? .zero
        full.isHidden = layout.fullScreen == nil
        resize.frame = layout.resize ?? .zero
        resize.isHidden = layout.resize == nil
        menuButton.frame = layout.menu ?? .zero
        menuButton.isHidden = layout.menu == nil || isOver
        // Over the picture's middle; above the words when there are some.
        spinner.center = CGPoint(x: layout.picture.midX, y: layout.picture.midY - (message.isHidden ? 0 : 34))
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
        case .live(let state) where state.asleep: Strings.LiveBrowser.asleep
        case .live(let state) where state.starting: Strings.LiveBrowser.startingBrowser
        case .dormant(let state): Strings.LiveBrowser.dormant(state.title ?? state.url)
        case .notResponding: Strings.LiveBrowser.notResponding
        default: nil
        }
        message.text = text
        message.isHidden = text == nil
        picture.alpha = text == nil ? 1 : 0.25
        isWaiting = feed.isWaiting
        let status = LiveBrowserDock.status(feed.phase) ?? Strings.LiveBrowser.endedStatus
        pill.text = status
        pillDot.backgroundColor = UIColor(state?.asleep == true || state == nil ? Palette.textSecondary : LiveBrowserPlayerView.color(state?.status))
        let held = holdsControl?() ?? (state?.status == .user)
        let title = switch feed.phase {
        case .dormant: Strings.LiveBrowser.checkAgain
        case .notResponding: Strings.LiveBrowser.retry
        default: state?.pendingApproval != nil ? Strings.LiveBrowser.review : held ? Strings.LiveBrowser.release : Strings.LiveBrowser.takeOver
        }
        action.setTitle(title, for: .normal)
        action.isEnabled = !feed.phase.isOver
        isOver = feed.phase.isOver
        menuButton.isHidden = layout?.menu == nil || isOver
        accessibilityLabel = [Strings.LiveBrowser.title, status].joined(separator: ", ")
        accessibilityValue = state?.status.rawValue ?? "\(feed.phase)"
        setNeedsLayout()
    }

    private func updateSpinner() {
        let spins = isBusy || isWaiting
        guard spins == spinner.isHidden else { return }
        spinner.isHidden = !spins
        if spins { spinner.startAnimating() } else { spinner.stopAnimating() }
        if spins { bringSubviewToFront(spinner) }
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
    nonisolated static let height: CGFloat = 44
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
        // The same browser at another origin is the same browser.
        return current.id != link.id
    }

    private func render() {
        let status: String
        let color: ColorToken
        if isReplaced {
            status = Strings.LiveBrowser.replaced
            color = Palette.textSecondary
        } else if let feed = dock?.feed, feed.link.id == link?.id {
            status = LiveBrowserDock.status(feed.phase) ?? Strings.LiveBrowser.endedStatus
            // Red only while the bridge says it runs.
            color = dock?.browserRuns == true ? Palette.statusError : Palette.textSecondary
        } else {
            // A link in the text says nothing of whether it runs.
            status = Strings.LiveBrowser.open
            color = Palette.textSecondary
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
