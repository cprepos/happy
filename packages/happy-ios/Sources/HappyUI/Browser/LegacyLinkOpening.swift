#if canImport(UIKit)
import HappyCore
import UIKit

extension UIViewController {
    /// A link from a Happy CLI chat, opened through the paired computer
    /// `LegacyLinkRoute` picks for the chat's machine: the one whose Happy
    /// Agent the machine names, else the one kept for it, else the only one
    /// named like it, else the one the person picks now
    /// (kept for the machine's later links). Without a paired computer the
    /// browser shows its unavailable state; nothing opens on the phone's
    /// own network.
    func openLegacyLink(_ url: URL, machineId: String?, machineName: String?, agentNodeName: String?, settings: LocalSettings, context: AppContext) {
        guard BrowserPolicy.route(url) != .system else { UIApplication.shared.open(url); return }
        let computers = Self.legacyLinkComputers(context.account)
        switch LegacyLinkRoute.resolve(machineId: machineId, machineName: machineName, agentNodeName: agentNodeName, computers: computers, settings: settings) {
        case .computer(let id):
            presentBrowser(BrowserViewController(url: url, session: Session.session(for: id, context: context)))
        case .unavailable:
            presentBrowser(BrowserViewController(url: url, session: nil))
        case .ask(let choices):
            let alert = UIAlertController(title: Strings.Browser.relayPickerTitle(machineName), message: machineId == nil ? nil : Strings.Browser.relayPickerMessage, preferredStyle: .alert)
            for computer in choices {
                alert.addAction(UIAlertAction(title: computer.name, style: .default) { [weak self] _ in
                    if let machineId { LegacyLinkRoute.remember(computer.id, for: machineId, settings: settings) }
                    self?.presentBrowser(BrowserViewController(url: url, session: Session.session(for: computer.id, context: context)))
                })
            }
            alert.addAction(UIAlertAction(title: Strings.Common.cancel, style: .cancel))
            alert.view.accessibilityIdentifier = "relay-link-picker"
            present(alert, animated: true)
        }
    }

    /// The paired computers a Happy CLI chat's links can go through: every
    /// agent connection still paired and shown.
    static func legacyLinkComputers(_ account: AccountController) -> [LegacyLinkComputer] {
        guard account.showsAgentConnections else { return [] }
        return account.agentConnections.accounts.filter { !$0.revoked }.map { LegacyLinkComputer(id: $0.id, name: $0.name) }
    }
}
#endif
