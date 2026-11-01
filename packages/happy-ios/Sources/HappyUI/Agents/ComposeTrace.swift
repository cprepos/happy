#if DEBUG && canImport(UIKit)
import UIKit

/// A new-work screen the compose trace can read: Happy Agent's new work
/// (`ChatViewController`) and a legacy account's empty chat
/// (`LegacyChatViewController`), which share `NewWorkPanel`.
@MainActor
protocol ComposeTraced: UIViewController {
    /// "composer", "name" or "none": what has the keyboard.
    var traceResponder: String { get }
    /// The composer, riding the keyboard.
    var traceComposer: UIView? { get }
    /// What new work will be, centred over the composer, while it shows.
    var tracePanel: UIView? { get }
    /// The room the panel is centred in: the bar's foot to the composer's
    /// (or its dock's) top.
    var traceRoom: (top: CGFloat, bottom: CGFloat) { get }
}

/// For tracing a new-work screen (`HAPPY_COMPOSE_TRACE`): every frame
/// while it is up or moving, logged as `COMPOSETRACE` with the screen's
/// and the composer's drawn place (their presentation layers), the
/// keyboard's top as its notifications said, who has the keyboard, the
/// transition and the panel's middle; and, as the value of a 1-point
/// element named "compose-trace", what the UI tests check: the keyboard as
/// the push ended, how many frames of the push and of a swipe back had it,
/// and how far the panel sits from the middle of its room. The keyboard is
/// another process's window: it is up from its will-show notification to
/// its will-hide one.
@MainActor
final class ComposeTrace: NSObject {
    static var isOn: Bool { ProcessInfo.processInfo.environment["HAPPY_COMPOSE_TRACE"] != nil }

    private weak var screen: (any ComposeTraced)?
    private var link: CADisplayLink!
    private let element = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let started = CACurrentMediaTime()
    /// The keyboard's top in the window; nil while it is down.
    private var keyboardTop: CGFloat?
    private var appearKeyboard = "none"
    private var hasAppeared = false
    private var pushFrames = 0
    private var pushKeyboardFrames = 0
    private var swipeFrames = 0
    private var swipeDrops = 0

    init(_ screen: any ComposeTraced) {
        self.screen = screen
        super.init()
        element.isAccessibilityElement = true
        element.accessibilityIdentifier = "compose-trace"
        element.isUserInteractionEnabled = false
        screen.view.addSubview(element)
        link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        event("trace start \(type(of: screen))")
    }

    func stop() { link.invalidate() }

    func event(_ what: String) {
        NSLog("%@", "COMPOSETRACE t=\(String(format: "%.3f", CACurrentMediaTime() - started)) event \(what)")
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = screen?.view.window else { return }
        let local = window.convert(end, from: window.screen.coordinateSpace)
        keyboardTop = local.isEmpty || local.minY >= window.bounds.maxY - 1 ? nil : local.minY
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        event("keyboard top=\(keyboardTop.map { "\(Int($0))" } ?? "down") duration=\(duration)")
    }

    func appeared() {
        guard !hasAppeared else { return }
        hasAppeared = true
        if let keyboardTop { appearKeyboard = "\(Int(keyboardTop))" }
        event("didAppear keyboard=\(appearKeyboard) responder=\(screen?.traceResponder ?? "-")")
        report()
    }

    @objc private func tick() {
        guard let screen, screen.view.window != nil else { return }
        let layer = screen.view.layer.presentation() ?? screen.view.layer
        let x = layer.convert(CGPoint.zero, to: nil).x
        let onScreen = keyboardTop != nil
        let coordinator = screen.transitionCoordinator
        let transition = coordinator.map { $0.isCancelled ? "cancelled" : $0.isInteractive ? "interactive" : "animated" } ?? "-"
        let responder = screen.traceResponder
        if coordinator != nil, !hasAppeared {
            pushFrames += 1
            if onScreen { pushKeyboardFrames += 1 }
        }
        if coordinator?.isInteractive == true, hasAppeared {
            swipeFrames += 1
            if !onScreen || responder == "none" { swipeDrops += 1 }
        }
        // As shown, in the screen: the composer may sit in a dock.
        let composer = screen.traceComposer.map { view in
            let shown = view.layer.presentation() ?? view.layer
            return shown.convert(shown.bounds, to: layer)
        }
        let panel = screen.tracePanel.map { ($0.layer.presentation() ?? $0.layer) }
        func f(_ value: CGFloat?) -> String {
            guard let value, value.isFinite, value < 1e6 else { return "-" }
            return String(format: "%.1f", Double(value))
        }
        NSLog("%@", "COMPOSETRACE t=\(String(format: "%.3f", CACurrentMediaTime() - started)) x=\(f(x)) keyboard=\(f(keyboardTop)) composer=\(f(composer?.minY)) panel=\(f(panel?.frame.midY)) alpha=\(f(panel.map { CGFloat($0.opacity) })) \(responder) \(transition)")
        report()
    }

    func report() {
        guard let screen else { return }
        screen.view.bringSubviewToFront(element)
        let (top, composerTop) = screen.traceRoom
        var offset = "none"
        if let panel = screen.tracePanel, !panel.isHidden, panel.alpha > 0 {
            offset = String(format: "%.2f", panel.frame.midY - (top + composerTop) / 2)
        }
        element.accessibilityValue = "appearKeyboard=\(appearKeyboard) pushFrames=\(pushFrames) pushKeyboardFrames=\(pushKeyboardFrames) swipeFrames=\(swipeFrames) swipeDrops=\(swipeDrops) responder=\(screen.traceResponder) panelOffset=\(offset) barBottom=\(Int(top)) composerTop=\(Int(composerTop))"
    }
}
#endif
