#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// Which viewer Take control opens: the native one, or noVNC's web page
/// as before, kept as a fallback. This device's choice, off by default.
enum LiveBrowserViewerSetting {
    static let key = "liveBrowserUsesNoVNC"

    static var usesWebViewer: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// The native viewer of a held live browser: its VNC socket, through the
/// workspace proxy, drawn by `LiveBrowserVNCView`, with a bar for the
/// keyboard, paste and copy, the trackpad and the zoom. A dropped
/// connection is tried again while the link is held; after a few tries in
/// a row with nothing it gives up (`onGiveUp`).
@MainActor
final class LiveBrowserVNCController: UIViewController {
    typealias Connect = @Sendable () async throws -> any BrowserStream

    static let attempts = 5

    let target: LiveBrowserVNCTarget
    private let connect: Connect
    /// The connection is gone for good: the dock drops the control page.
    var onGiveUp: (() -> Void)?
    /// The bar's More menu: switch to the web viewer.
    var onUseWebViewer: (() -> Void)?

    let screen = LiveBrowserVNCView()
    private let bar = UIToolbar()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusBox = UIView()
    private let toast = UILabel()
    private var toastClear: Task<Void, Never>?
    private lazy var keyRow = LiveBrowserVNCKeyRow(screen: screen)

    private var client: VNCClient?
    private var session: Task<Void, Never>?
    private(set) var connected = false
    private(set) var stopped = false
    /// What the browser last put on its clipboard; copied to this device's
    /// only when Copy is tapped.
    private(set) var serverClipboard: String?

    private let keyboardItem = UIBarButtonItem()
    private let pasteItem = UIBarButtonItem()
    private let copyItem = UIBarButtonItem()
    private let trackpadItem = UIBarButtonItem()
    private let fitItem = UIBarButtonItem()
    private let moreItem = UIBarButtonItem()

    init(target: LiveBrowserVNCTarget, connect: @escaping Connect) {
        self.target = target
        self.connect = connect
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "live-browser-vnc"
        screen.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        statusBox.translatesAutoresizingMaskIntoConstraints = false
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(screen)
        view.addSubview(bar)
        view.addSubview(statusBox)
        view.addSubview(toast)

        status.textColor = .white
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.numberOfLines = 0
        status.textAlignment = .center
        status.accessibilityIdentifier = "live-browser-vnc-status"
        spinner.color = .white
        spinner.hidesWhenStopped = true
        let statusStack = UIStackView(arrangedSubviews: [spinner, status])
        statusStack.axis = .vertical
        statusStack.spacing = 8
        statusStack.alignment = .center
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusBox.addSubview(statusStack)
        statusBox.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        statusBox.layer.cornerRadius = 12
        statusBox.isUserInteractionEnabled = false

        toast.textColor = .white
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        toast.font = .preferredFont(forTextStyle: .footnote)
        toast.numberOfLines = 0
        toast.textAlignment = .center
        toast.layer.cornerRadius = 8
        toast.layer.masksToBounds = true
        toast.isHidden = true
        toast.accessibilityIdentifier = "live-browser-vnc-toast"

        NSLayoutConstraint.activate([
            screen.topAnchor.constraint(equalTo: view.topAnchor),
            screen.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            screen.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Above the keyboard while it shows, the safe area's bottom else.
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            statusBox.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            statusBox.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
            statusBox.widthAnchor.constraint(lessThanOrEqualTo: screen.widthAnchor, constant: -48),
            statusStack.topAnchor.constraint(equalTo: statusBox.topAnchor, constant: 16),
            statusStack.bottomAnchor.constraint(equalTo: statusBox.bottomAnchor, constant: -16),
            statusStack.leadingAnchor.constraint(equalTo: statusBox.leadingAnchor, constant: 20),
            statusStack.trailingAnchor.constraint(equalTo: statusBox.trailingAnchor, constant: -20),
            toast.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: screen.bottomAnchor, constant: -16),
            toast.widthAnchor.constraint(lessThanOrEqualTo: screen.widthAnchor, constant: -48),
        ])
        view.keyboardLayoutGuide.usesBottomSafeArea = true

        screen.send = { [weak self] events in self?.client?.pointer(events) }
        screen.sendKey = { [weak self] keysym, modifiers in self?.client?.tap(keysym, modifiers: modifiers) }
        screen.sendText = { [weak self] text in self?.client?.type(text) }
        screen.onPaste = { [weak self] in self?.paste() }
        screen.onArmedChange = { [weak self] in self?.keyRow.update() }

        configureBar()
        show(status: Strings.LiveBrowser.Viewer.connecting, busy: true)
        start()
    }

    // MARK: The bar

    private func configureBar() {
        typealias S = Strings.LiveBrowser.Viewer
        keyboardItem.image = UIImage(systemName: "keyboard")
        keyboardItem.accessibilityLabel = S.keyboard
        keyboardItem.accessibilityIdentifier = "live-browser-vnc-keyboard"
        keyboardItem.primaryAction = UIAction(title: S.keyboard, image: UIImage(systemName: "keyboard")) { [weak self] _ in self?.toggleKeyboard() }

        pasteItem.image = UIImage(systemName: "doc.on.clipboard")
        pasteItem.accessibilityLabel = S.paste
        pasteItem.accessibilityIdentifier = "live-browser-vnc-paste"
        pasteItem.menu = UIMenu(children: [
            UIAction(title: S.paste, subtitle: S.pasteDetail, image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste() },
            UIAction(title: S.typeClipboard, subtitle: S.typeClipboardDetail, image: UIImage(systemName: "keyboard.badge.ellipsis")) { [weak self] _ in self?.typeClipboard() },
        ])
        pasteItem.primaryAction = nil

        copyItem.image = UIImage(systemName: "doc.on.doc")
        copyItem.accessibilityLabel = S.copy
        copyItem.accessibilityIdentifier = "live-browser-vnc-copy"
        copyItem.primaryAction = UIAction(title: S.copy, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy() }
        copyItem.isEnabled = false

        trackpadItem.image = UIImage(systemName: "rectangle.and.hand.point.up.left")
        trackpadItem.accessibilityLabel = S.trackpad
        trackpadItem.accessibilityIdentifier = "live-browser-vnc-trackpad"
        trackpadItem.primaryAction = UIAction(title: S.trackpad, image: UIImage(systemName: "rectangle.and.hand.point.up.left")) { [weak self] _ in
            self?.toggleTrackpad()
        }

        fitItem.image = UIImage(systemName: "arrow.down.right.and.arrow.up.left")
        fitItem.accessibilityLabel = S.fit
        fitItem.accessibilityIdentifier = "live-browser-vnc-fit"
        fitItem.primaryAction = UIAction(title: S.fit, image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")) { [weak self] _ in
            self?.screen.fit()
        }

        moreItem.image = UIImage(systemName: "ellipsis")
        moreItem.accessibilityLabel = S.more
        moreItem.accessibilityIdentifier = "live-browser-vnc-more"
        moreItem.menu = UIMenu(children: [
            UIAction(title: S.rightClick, image: UIImage(systemName: "cursorarrow.click.2")) { [weak self] _ in
                guard let self else { return }
                var pointer = self.screen.pointer
                self.client?.pointer(pointer.click(.right))
            },
            UIAction(title: S.webViewer, image: UIImage(systemName: "globe")) { [weak self] _ in self?.onUseWebViewer?() },
        ])

        let space = { UIBarButtonItem(systemItem: .flexibleSpace) }
        bar.items = [keyboardItem, space(), pasteItem, space(), copyItem, space(), trackpadItem, space(), fitItem, space(), moreItem]
        bar.accessibilityIdentifier = "live-browser-vnc-bar"
    }

    private func toggleKeyboard() {
        if screen.isFirstResponder {
            screen.showsKeyboard = false
        } else {
            screen.showsKeyboard = true
            screen.keyRow = keyRow
            screen.becomeFirstResponder()
        }
    }

    private func toggleTrackpad() {
        screen.setTrackpad(!screen.trackpad)
        trackpadItem.isSelected = screen.trackpad
        say(screen.trackpad ? Strings.LiveBrowser.Viewer.trackpadOn : Strings.LiveBrowser.Viewer.touchOn)
    }

    /// This device's clipboard as the browser's, then Ctrl+V: a paste. Text
    /// the protocol can't carry (beyond Latin-1) is typed instead.
    func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return say(Strings.LiveBrowser.Viewer.clipboardEmpty) }
        guard let client else { return }
        guard RFBMessage.latin1(text) != nil else { return client.type(text) }
        client.clipboard(text)
        // The server sets its selection as the cut text arrives; the paste
        // follows a moment later so it pastes what was just sent.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.client?.tap(VNCKeys.keysym(for: "v"), modifiers: [VNCKeys.control])
        }
    }

    /// This device's clipboard typed key by key.
    func typeClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return say(Strings.LiveBrowser.Viewer.clipboardEmpty) }
        client?.type(text)
    }

    /// The browser's clipboard to this device's, only when asked.
    func copy() {
        guard let serverClipboard else { return }
        UIPasteboard.general.string = serverClipboard
        say(Strings.LiveBrowser.Viewer.copied)
    }

    private func say(_ text: String) {
        toastClear?.cancel()
        toast.text = "  \(text)  "
        toast.isHidden = false
        toastClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast.isHidden = true
        }
    }

    private func show(status text: String?, busy: Bool) {
        status.text = text
        statusBox.isHidden = text == nil
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    // MARK: The connection

    func start() {
        guard session == nil, !stopped else { return }
        session = Task { [weak self] in await self?.runConnection() }
    }

    /// The connection goes, for good: released, or the page left.
    func stop() {
        stopped = true
        screen.stopGlide()
        session?.cancel()
        session = nil
        if let client {
            self.client = nil
            Task { await client.close() }
        }
    }

    private func runConnection() async {
        var failures = 0
        while !Task.isCancelled, !stopped {
            var reached = false
            do {
                let stream = try await connect()
                guard !Task.isCancelled, !stopped else { await stream.close(); return }
                let client = VNCClient(stream: stream)
                self.client = client
                try await withTaskCancellationHandler {
                    try await client.run(password: target.password) { [weak self] event in
                        if case .frame(let frame) = event {
                            // Made here, off the main thread; drawn there.
                            guard let image = VNCImage.make(frame) else { return }
                            await self?.screen.show(image)
                            return
                        }
                        await self?.handle(event)
                    }
                } onCancel: {
                    Task { await client.close() }
                }
            } catch {
                if Task.isCancelled || stopped { return }
                reached = connected
                connected = false
                client = nil
                if case RFBError.authenticationFailed = error { return giveUp(Strings.LiveBrowser.Viewer.wrongPassword) }
                // The bridge won't have it: not held, gone, expired.
                if let refusal = error as? TunnelRefusal, [401, 403, 404, 410].contains(refusal.status) { return giveUp(Strings.LiveBrowser.Viewer.failed) }
                // The workspace's proxy refuses tunnels at all.
                if case BrowserError.tunnelsBlocked = error { return giveUp(Strings.LiveBrowser.Viewer.failed) }
            }
            failures = reached ? 1 : failures + 1
            if failures >= Self.attempts { return giveUp(Strings.LiveBrowser.Viewer.failed) }
            show(status: Strings.LiveBrowser.Viewer.reconnecting, busy: true)
            // 0.5, 1, 2, 4 seconds: inside the bridge's grace for a held
            // link whose socket closed.
            try? await Task.sleep(for: .milliseconds(500 << max(0, failures - 1)))
        }
    }

    private func handle(_ event: VNCEvent) {
        switch event {
        case .connected(let width, let height, _):
            connected = true
            show(status: nil, busy: false)
            screen.desktop(width: width, height: height)
        case .clipboard(let text):
            serverClipboard = text.isEmpty ? nil : text
            copyItem.isEnabled = serverClipboard != nil
        case .bell:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .frame:
            break
        }
    }

    private func giveUp(_ message: String) {
        session = nil
        show(status: message, busy: false)
        onGiveUp?()
    }
}

/// The keys a phone's keyboard lacks, over it: Esc, Tab, the modifiers
/// (held for the next key), the arrows and the page keys.
@MainActor
final class LiveBrowserVNCKeyRow: UIInputView {
    private weak var screen: LiveBrowserVNCView?
    private var modifierButtons: [(UIButton, UInt32)] = []

    init(screen: LiveBrowserVNCView) {
        self.screen = screen
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        accessibilityIdentifier = "live-browser-vnc-keys"
        typealias S = Strings.LiveBrowser.Viewer
        let keys: [UIButton] = [
            key(S.escape, label: S.escape, VNCKeys.escape),
            key(S.tab, label: S.tab, VNCKeys.tab),
            modifier(S.control, label: S.control, VNCKeys.control),
            modifier(S.alt, label: S.alt, VNCKeys.alt),
            // ⌘ is Ctrl: the remote browser runs on Linux.
            modifier(S.command, label: S.command, VNCKeys.control),
            key(symbol: "arrow.left", label: S.left, VNCKeys.left),
            key(symbol: "arrow.up", label: S.up, VNCKeys.up),
            key(symbol: "arrow.down", label: S.down, VNCKeys.down),
            key(symbol: "arrow.right", label: S.right, VNCKeys.right),
            key(S.home, label: S.home, VNCKeys.home),
            key(S.end, label: S.end, VNCKeys.end),
            key(S.pageUp, label: S.pageUp, VNCKeys.pageUp),
            key(S.pageDown, label: S.pageDown, VNCKeys.pageDown),
            key(S.delete, label: S.delete, VNCKeys.delete),
        ]
        let row = UIStackView(arrangedSubviews: keys)
        row.axis = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        let hide = UIButton(type: .system)
        hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hide.accessibilityLabel = S.hideKeyboard
        hide.accessibilityIdentifier = "live-browser-vnc-hide-keyboard"
        hide.translatesAutoresizingMaskIntoConstraints = false
        hide.addAction(UIAction { [weak self] _ in self?.screen?.showsKeyboard = false }, for: .touchUpInside)
        addSubview(scroll)
        addSubview(hide)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -6),
            hide.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            hide.widthAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func makeButton(title: String?, symbol: String?, label: String) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        return button
    }

    private func key(_ title: String? = nil, symbol: String? = nil, label: String, _ keysym: UInt32) -> UIButton {
        let made = makeButton(title: title, symbol: symbol, label: label)
        made.addAction(UIAction { [weak self] _ in self?.screen?.press(keysym) }, for: .touchUpInside)
        return made
    }

    private func modifier(_ title: String, label: String, _ keysym: UInt32) -> UIButton {
        let made = makeButton(title: title, symbol: nil, label: label)
        made.changesSelectionAsPrimaryAction = false
        made.addAction(UIAction { [weak self] _ in self?.screen?.arm(keysym) }, for: .touchUpInside)
        modifierButtons.append((made, keysym))
        return made
    }

    /// The modifiers armed show selected (⌘ and Ctrl together: they're one).
    func update() {
        let armed = screen?.armed ?? []
        for (button, keysym) in modifierButtons {
            var configuration = button.configuration ?? .gray()
            let on = armed.contains(keysym)
            configuration.baseBackgroundColor = on ? .tintColor : nil
            configuration.baseForegroundColor = on ? .white : nil
            button.configuration = configuration
        }
    }
}
#endif
