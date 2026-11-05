#if canImport(UIKit)
import AVFAudio
import HappyCore
import UIKit

extension Notification.Name {
    static let voiceStateChanged = Notification.Name("happy.voiceStateChanged")
    /// The voice sheet came, went or changed its height: what floats over
    /// a chat (the live browser) keeps above its strip.
    static let voiceSheetChanged = Notification.Name("happy.voiceSheetChanged")
}

extension UISheetPresentationController.Detent.Identifier {
    /// The voice sheet's least height: its bar, with the call's status and
    /// the mute button, over the chat, which stays usable under it.
    static let voiceStrip = Self("happy.voiceStrip")
}

/// Lazily creates everything on the microphone press. Navigation focus and
/// account callbacks do no disk work or SDK initialization.
@MainActor
public final class VoiceCoordinator: NSObject {
    public static let shared = VoiceCoordinator()
    private var account: AccountSession?
    private var session: VoiceSession?
    private var context: VoiceContext?
    private var preparation: Task<Void, Never>?
    private var generation = 0
    private let lifetime = VoiceConnectionLifetime()
    private weak var screen: VoiceStatusViewController?
    public private(set) var state: VoiceState = .idle
    /// Who carries the current call; nil until it is known and once it is over.
    public private(set) var activeBackend: VoiceBackend?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    public func start(account: AccountSession, sessionId: String, presenting: UIViewController) {
        // Off (`LegacyVoice`): said so, before any microphone, grant, context or provider.
        guard LegacyVoice.isEnabled else { return Alerts.show(Strings.Voice.legacyOff, on: presenting) }
        if self.account === account, isRunning {
            focus(account: account, sessionId: sessionId)
            show(from: presenting)
            return
        }
        stop()
        self.account = account
        let current = generation
        let context = VoiceContext(account: account, sessionId: sessionId)
        self.context = context
        setState(.connecting)
        show(from: presenting)
        preparation = Task { [weak self] in
            do {
                let api = account.api
                let request = try await context.initial(config: api.voiceConfig())
                guard let self, !Task.isCancelled, current == generation else { return }
                self.activeBackend = request.backend
                self.screen?.update(self.state)
                let voice = VoiceSession(permission: {
                    await AVAudioApplication.requestRecordPermission()
                }, credentials: {
                    try await api.voiceCredentials()
                }, lifetime: lifetime, connect: { grant, request, activity, disconnected in
                    switch request.backend {
                    case .stream:
                        return try await StreamVoiceConnection.connect(account: account, request: request, context: context,
                                                                       activity: activity, disconnected: disconnected)
                    case .elevenlabs:
                        return try await ElevenLabsVoiceConnection.connect(grant: grant, request: request, context: context,
                                                                           activity: activity, disconnected: disconnected)
                    }
                })
                self.session = voice
                voice.onState = { [weak self, weak voice] state in
                    guard let self, self.session === voice else { return }
                    self.setState(state)
                    switch state {
                    case .active:
                        Task {
                            await context.start { [weak self, weak voice] update in
                                guard let voice, await self?.isCurrent(voice) == true else { return }
                                await voice.context(update.context, prompts: update.prompts)
                            }
                        }
                    case .idle, .failed, .denied:
                        Task { await context.stop() }
                    case .connecting: break
                    }
                }
                voice.start(request)
            } catch {
                guard let self, current == generation, !Task.isCancelled else { return }
                self.setState(.failed(error as? APIError == .unauthorized ? .authentication : .unavailable))
                await context.stop()
            }
        }
    }

    private func isCurrent(_ voice: VoiceSession) -> Bool { session === voice }

    private var isRunning: Bool {
        switch state { case .connecting, .active: true; default: false }
    }

    func state(for account: AccountSession) -> VoiceState { self.account === account ? state : .idle }

    public func focus(account: AccountSession, sessionId: String) {
        guard self.account === account, let context else { return }
        Task { await context.focus(sessionId) }
    }

    public func accountDidChange(to account: AccountSession?) {
        guard self.account != nil, self.account !== account else { return }
        stop()
        screen?.dismiss(animated: false)
    }

    public func stop() {
        generation += 1
        preparation?.cancel(); preparation = nil
        session?.stop(); session = nil
        let context = self.context
        self.context = nil
        account = nil
        Task { await context?.stop() }
        setState(.idle)
    }

    func toggleMute() { Task { await session?.toggleMute() } }

    private func show(from presenting: UIViewController) {
        if let screen, screen.presentingViewController != nil { return }
        let screen = VoiceStatusViewController(coordinator: self)
        self.screen = screen
        presenting.present(Self.sheet(screen), animated: true) {
            NotificationCenter.default.post(name: .voiceSheetChanged, object: self)
        }
    }

    /// The sheet's stack: the strip, half and full height, the chat under
    /// the strip left undimmed and live.
    static func sheet(_ screen: VoiceStatusViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: screen)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.custom(identifier: .voiceStrip) { _ in VoiceStatusViewController.stripHeight }, .medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
            sheet.largestUndimmedDetentIdentifier = .voiceStrip
            sheet.prefersGrabberVisible = true
            sheet.delegate = screen
        }
        return navigation
    }

    private var sheet: UISheetPresentationController? {
        guard let navigation = screen?.navigationController, navigation.presentingViewController != nil else { return nil }
        return navigation.sheetPresentationController
    }

    /// Down to the strip, if the sheet is up: the live browser opened.
    func minimizeSheet() {
        guard let sheet, sheet.selectedDetentIdentifier != .voiceStrip else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = .voiceStrip }
        NotificationCenter.default.post(name: .voiceSheetChanged, object: self)
    }

    /// Up to half height from the strip.
    func expandSheet() {
        guard let sheet, sheet.selectedDetentIdentifier == .voiceStrip else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = .medium }
        NotificationCenter.default.post(name: .voiceSheetChanged, object: self)
    }

    /// The sheet's top in `view`, while it is up; nil while it isn't.
    func sheetTop(in view: UIView) -> CGFloat? {
        guard let sheet, let presented = sheet.presentedView, presented.window != nil, view.window != nil else { return nil }
        let height: CGFloat? = switch sheet.selectedDetentIdentifier {
        case .voiceStrip?: VoiceStatusViewController.stripHeight
        default: nil
        }
        // The strip's height is known before its animation lands; a taller
        // detent is read from where the sheet is.
        if let height, let window = view.window {
            let top = window.bounds.maxY - window.safeAreaInsets.bottom - height
            return view.convert(CGPoint(x: 0, y: top), from: window).y
        }
        return presented.convert(presented.bounds, to: view).minY
    }

    private func setState(_ state: VoiceState) {
        guard state != self.state else { return }
        self.state = state
        if state == .idle { activeBackend = nil }
        screen?.update(state)
        NotificationCenter.default.post(name: .voiceStateChanged, object: self)
    }

    /// Locking the phone backgrounds the app. A call that is connecting or
    /// live keeps going (the app has the `audio` background mode); anything
    /// else has nothing to keep. Real interruptions (a phone call, Siri) and
    /// a lost audio route still end the call below.
    @objc private func backgrounded() {
        guard !isRunning else { return }
        stop()
    }
    @objc private func audioReset() { stop() }
    @objc private func interrupted(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              type == AVAudioSession.InterruptionType.began.rawValue else { return }
        stop()
    }
    @objc private func routeChanged(_ notification: Notification) {
        guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        stop()
    }
}
#endif
