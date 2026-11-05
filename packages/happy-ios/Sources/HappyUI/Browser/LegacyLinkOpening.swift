#if canImport(UIKit)
import HappyCore
import HappyStore
import UIKit

extension UIViewController {
    /// A link from a Happy CLI chat, opened through the paired computer
    /// and host workspace `LegacyBrowserRoute` picks for the session, as
    /// its live view is: the computer whose Happy Agent the machine names,
    /// else the one kept for it, else the only one named like it, else the
    /// one the person picks now (kept for the machine's later links); on
    /// it, the workspace the session's folder is in. Without a paired
    /// computer the browser shows its unavailable state; nothing opens on
    /// the phone's own network.
    func openLegacyLink(_ url: URL, session record: SessionRecord?, machine: MachineRecord?, machines: [MachineRecord], settings: LocalSettings, context: AppContext) {
        guard BrowserPolicy.route(url) != .system else { UIApplication.shared.open(url); return }
        let computers = Self.legacyLinkComputers(context.account)
        func browser(_ id: String, _ workspace: LegacyBrowserWorkspace) -> BrowserViewController {
            let session = Session.session(for: id, context: context)
            let client = session?.client
            return BrowserViewController(url: url, session: session, workspace: client.map { client in { try await workspace.find(client) } })
        }
        switch LegacyBrowserRoute.resolve(session: record, machine: machine, machines: machines, computers: computers, settings: settings) {
        case .computer(let id, let workspace):
            presentBrowser(browser(id, workspace))
        case .unavailable:
            presentBrowser(BrowserViewController(url: url, session: nil))
        case .ask(let choices, let workspace):
            let machineId = record.flatMap(LegacyBrowserRoute.machineId)
            let machineName = record.flatMap { LegacyLinkRoute.machineName(session: $0, machine: machine) }
            let alert = UIAlertController(title: Strings.Browser.relayPickerTitle(machineName), message: machineId == nil ? nil : Strings.Browser.relayPickerMessage, preferredStyle: .alert)
            for computer in choices {
                alert.addAction(UIAlertAction(title: computer.name, style: .default) { [weak self] _ in
                    if let machineId { LegacyLinkRoute.remember(computer.id, for: machineId, settings: settings) }
                    self?.presentBrowser(browser(computer.id, workspace))
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
