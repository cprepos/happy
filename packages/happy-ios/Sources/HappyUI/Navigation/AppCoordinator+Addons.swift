#if canImport(UIKit)
import Foundation
import HappyCore

/// Our plugins' additions to `AppCoordinator`: the chat boxes' Enter to
/// send, kept out of AppCoordinator.swift so upstream merges do not
/// conflict there.
extension AppCoordinator {
    /// The chat boxes' Return follows the shown account's Enter to send on
    /// this device (`LocalSettings.enterToSend`), as it is set; on while
    /// none is shown. The account's synced `agentInputEnterToSend` plays no
    /// part, so the web's setting doesn't change it.
    func followEnterToSend(_ session: AccountSession?) {
        if let enterToSendObservation {
            NotificationCenter.default.removeObserver(enterToSendObservation)
        }
        enterToSendObservation = nil
        guard let settings = session?.localSettings else {
            SendShortcut.enterToSend = true
            return
        }
        SendShortcut.enterToSend = settings.enterToSend
        enterToSendObservation = NotificationCenter.default.addObserver(
            forName: LocalSettings.enterToSendDidChange, object: settings, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SendShortcut.enterToSend = settings.enterToSend }
        }
    }
}
#endif
