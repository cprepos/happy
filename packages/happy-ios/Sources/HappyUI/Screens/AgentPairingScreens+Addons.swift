#if canImport(UIKit)
import UIKit

/// Our additions to `PairingFlow`: the pairing screen's push, kept out of
/// AgentPairingScreens.swift so upstream merges do not conflict there.
extension PairingFlow {
    /// `pairing` pushed onto `controller`'s stack, or else the window's
    /// topmost one, once nothing is shown over it (`afterPresentationsClear`).
    /// A pasted link's prompt is still going away, and home's search may be
    /// up, when this runs; a push then was dropped without a word. False,
    /// logged and said, when there is no stack to push onto.
    static func push(_ pairing: AgentPairingViewController, from controller: UIViewController) -> Bool {
        let window = controller.viewIfLoaded?.window
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let top = window.flatMap(HappyScan.topmost(in:))
        guard let navigation = stack(of: controller) ?? top.flatMap(stack(of:)) else {
            HappyScan.log.error("no navigation stack for the pairing screen")
            Alerts.show("Could not pair", "The pairing screen could not be opened. Try the link again.", on: top ?? controller)
            return false
        }
        navigation.afterPresentationsClear { [weak navigation] in
            navigation?.pushViewController(pairing, animated: true)
        }
        return true
    }

    private static func stack(of controller: UIViewController) -> UINavigationController? {
        controller.navigationController ?? (controller as? UINavigationController)
    }
}
#endif
