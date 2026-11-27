#if canImport(UIKit)
import UIKit

/// Waiting for what is shown over a screen to go before pushing onto it.
/// A push made while an alert, a sheet or the home search is still over
/// the stack is dropped by UIKit without a word.
extension UIViewController {
    /// True when nothing is shown over this screen. Otherwise it (a QR
    /// sheet, a scanner, an alert, an open ⋯ menu) is put away, animated,
    /// and `then` runs once it has gone. A menu dismissed without its
    /// animation went on animating after the pairing push had taken its bar
    /// button away, and UIKit stopped the app (SIGTRAP in
    /// `-[_UIContextMenuPresentation dismiss]`, a link arriving while the
    /// install screen's ⋯ was open).
    func clearedOfPresentations(then: @escaping @MainActor () -> Void) -> Bool {
        guard let presented = presentedViewController else { return true }
        if presented.isBeingDismissed {
            if let coordinator = presented.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { _ in then() }
            } else {
                DispatchQueue.main.async { then() }
            }
            return false
        }
        dismiss(animated: true) { then() }
        return false
    }

    /// `then`, now when nothing is shown over this screen, else once all of
    /// it has gone (`clearedOfPresentations`).
    func afterPresentationsClear(_ then: @escaping @MainActor () -> Void) {
        guard clearedOfPresentations(then: { [weak self] in self?.afterPresentationsClear(then) }) else { return }
        then()
    }
}
#endif
