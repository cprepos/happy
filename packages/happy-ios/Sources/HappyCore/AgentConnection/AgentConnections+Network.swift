import Foundation

// Our network and foreground handling for `AgentConnections`, kept out of
// AgentConnections.swift so upstream merges do not conflict there.

/// The phone's way out as last heard (`watchNetwork`).
struct AgentNetworkWatch {
    var watch: NetworkPathWatch?
    var satisfied = true
    var interface: NetworkPathDetails.Interface = .other
}

extension AgentConnections {
    /// Back in the foreground: the network watched again, and what was
    /// learned about proxy tunnels forgotten.
    func networkForegrounded() {
        watchNetwork(); TunnelSupport.shared.forget()
    }

    /// The phone's network came back, or moved between interfaces (Wi-Fi
    /// to cellular, or back): what was learned about proxy tunnels is
    /// forgotten. Tailcat's own path monitor wakes the tunnels.
    func networkMoved() {
        TunnelSupport.shared.forget()
    }

    func watchNetwork() {
        guard network.watch == nil else { return }
        let current = NetworkPath.shared.details
        network.satisfied = current.satisfied
        network.interface = current.interface
        network.watch = NetworkPath.shared.watchDetails { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                let back = path.satisfied && !self.network.satisfied
                // Wi-Fi to cellular (or back) leaves direct paths on the
                // old interface, dead while the phone still has a way out.
                let moved = path.satisfied && self.network.satisfied && path.interface != self.network.interface
                self.network.satisfied = path.satisfied
                self.network.interface = path.interface
                if back || moved { self.networkMoved() }
            }
        }
    }

    /// Pull to refresh: asks `id`'s computer again now, over a new
    /// transport, instead of when the retry backoff says. A revoked
    /// computer is left alone, and so is every computer while the app is
    /// in the background (`.paused`).
    public func restartConnection(_ id: String) async {
        func eligible() -> Bool {
            guard foreground, let account = accounts.first(where: { $0.id == id }) else { return false }
            return !account.revoked && account.status != .revoked && account.status != .paused
        }
        guard eligible() else { return }
        await stop(id)
        // The app may have gone to the background, or the computer been
        // removed or revoked, while the old job wound down.
        guard eligible(), jobs[id] == nil else { return }
        startConnections()
    }
}
