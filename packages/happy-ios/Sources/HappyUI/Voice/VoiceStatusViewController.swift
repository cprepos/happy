#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// Standard measured rows keep the call controls scrollable at every text
/// size and in landscape. Dismissing the sheet leaves the call running;
/// the composer's microphone opens these controls again.
@MainActor
final class VoiceStatusViewController: UIViewController, UISheetPresentationControllerDelegate {
    /// The strip detent: the bar, which says the call's status and holds
    /// the mute button.
    static let stripHeight: CGFloat = 120

    private let coordinator: VoiceCoordinator
    private let list = GroupedListView()
    private let mute = UIBarButtonItem()
    init(coordinator: VoiceCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        followsTextSize()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() { view = list }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = Strings.Voice.title
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: Strings.Voice.done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        mute.primaryAction = UIAction { [weak self] _ in self?.coordinator.toggleMute() }
        mute.accessibilityIdentifier = "voice-strip-mute"
        // A tap on the strip opens the sheet to half height; elsewhere it
        // changes nothing.
        let tap = UITapGestureRecognizer(target: self, action: #selector(stripTapped))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        update(coordinator.state)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let bar = navigationController?.navigationBar, bar.gestureRecognizers?.contains(where: { $0.name == "voice-strip" }) != true {
            let tap = UITapGestureRecognizer(target: self, action: #selector(stripTapped))
            tap.name = "voice-strip"
            tap.cancelsTouchesInView = false
            bar.addGestureRecognizer(tap)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.post(name: .voiceSheetChanged, object: coordinator)
    }

    var isStrip: Bool { navigationController?.sheetPresentationController?.selectedDetentIdentifier == .voiceStrip }

    @objc private func stripTapped() {
        guard isStrip else { return }
        coordinator.expandSheet()
    }

    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheet: UISheetPresentationController) {
        NotificationCenter.default.post(name: .voiceSheetChanged, object: coordinator)
    }

    /// Only a call through ElevenLabs shares context with it.
    static func footer(for backend: VoiceBackend?) -> String? {
        backend == .elevenlabs ? Strings.Voice.callFooter : nil
    }

    func update(_ state: VoiceState) {
        guard isViewLoaded else { return }
        let title: String
        var rows: [ItemRowView] = []
        switch state {
        case .idle: title = Strings.Voice.ended
        case .connecting: title = Strings.Voice.connecting
        case .active(let activity, let muted):
            let activityTitle = switch activity {
            case .listening: Strings.Voice.listening
            case .userSpeaking: Strings.Voice.userSpeaking
            case .agentSpeaking: Strings.Voice.agentSpeaking
            }
            title = muted ? Strings.Voice.muted : activityTitle
            rows.append(ItemRowView(title: muted ? Strings.Voice.unmute : Strings.Voice.mute,
                                    icon: ItemIcon(.ionicons(muted ? "mic-outline" : "mic"), tint: Palette.iconBlue)) { [weak self] in
                self?.coordinator.toggleMute()
            })
        case .denied(let denial):
            title = switch denial.reason {
            case .subscriptionRequired: Strings.Voice.subscriptionRequired
            case .hardLimitReached: Strings.Voice.hardLimit
            case .conversationLimitReached: Strings.Voice.conversationLimit
            }
            if denial.reason == .subscriptionRequired {
                rows.append(ItemRowView(title: Strings.Voice.upgrade, icon: ItemIcon(.ionicons("heart-outline"), tint: Palette.iconRed)) { [weak self] in
                    self?.navigationController?.pushViewController(SupportUsViewController(), animated: true)
                })
            }
        case .failed(let failure):
            title = failure == .microphonePermission ? Strings.Voice.permissionDenied : failure == .authentication ? Strings.Voice.authentication : Strings.Voice.unavailable
            if failure == .microphonePermission {
                rows.append(ItemRowView(title: Strings.Voice.openSettings, icon: ItemIcon(.ionicons("settings-outline"), tint: Palette.iconBlue)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                })
            }
        }
        // The strip shows the bar alone: the status under the title, and
        // the mute button while the call is live.
        navigationItem.subtitle = title
        if case .active(_, let muted) = state {
            mute.image = UIImage(systemName: muted ? "mic.slash.fill" : "mic.fill")
            mute.accessibilityLabel = muted ? Strings.Voice.unmute : Strings.Voice.mute
            navigationItem.leftBarButtonItem = mute
        } else {
            navigationItem.leftBarButtonItem = nil
        }
        let status = ItemRowView(title: title, icon: ItemIcon(.ionicons("mic-outline"), tint: Palette.iconBlue))
        status.showsChevron = false
        status.isLoading = state == .connecting
        switch state {
        case .connecting, .active:
            rows.append(ItemRowView(title: Strings.Voice.stop, icon: ItemIcon(.octicons("stop"), tint: Palette.iconRed), isDestructive: true) { [weak self] in
                self?.coordinator.stop()
            })
        default: break
        }
        list.sections = [ItemGroupView(footer: Self.footer(for: coordinator.activeBackend), rows: [status] + rows)]
        // Error explanations must remain readable at accessibility sizes.
        // Groups finish configuring dividers before these measured limits.
        for row in [status] + rows { row.titleLabel.numberOfLines = 0 }
        list.setNeedsLayout()
    }
}
#endif
