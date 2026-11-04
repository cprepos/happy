import Foundation
import HappyStore

/// A paired computer a Happy CLI chat's links can open through: an agent
/// connection's id and the name it is shown under (`config.node.name`).
public struct LegacyLinkComputer: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id; self.name = name
    }
}

/// Which paired computer a Happy CLI chat's links open through
/// (docs/browser-proxy.md, Routing). A relay session has no workspace on
/// any agent connection, so its pages go through a computer's host
/// workspace: the one whose node the machine says shares it (the Happy
/// Agent on the same computer), else the one the person picked for the
/// machine before, else the only one named like the machine, else the
/// person is asked.
/// Without a paired computer nothing opens; there is no default one.
public enum LegacyLinkRoute: Equatable, Sendable {
    /// Through this agent connection's host workspace.
    case computer(String)
    /// Ask which of these; the answer is kept for the machine.
    case ask([LegacyLinkComputer])
    /// No paired computer: the browser's unavailable state.
    case unavailable

    /// The machine's name as home lists it (`SessionList.hostName`): its
    /// own name, then its host, then the host the session recorded.
    public static func machineName(session: SessionRecord, machine: MachineRecord?) -> String? {
        SessionList.hostName(session, machines: machine.map { [$0.id: $0] } ?? [:])
    }

    /// The node name of the Happy Agent on the machine's computer, which
    /// happy-cli's daemon publishes in the machine's metadata
    /// (`happyAgent.nodeName`, the agent's `config.node.name`). Older daemons
    /// publish none.
    public static func agentNodeName(_ machine: MachineRecord?) -> String? {
        machine?.metadata?["happyAgent"]?["nodeName"]?.stringValue
    }

    /// The route for a link from a session on `machineId`, called
    /// `machineName`, whose computer's Happy Agent is `agentNodeName`. That
    /// node, when it is exactly one of `computers`, decides first: it is
    /// the same computer, whatever the machine is called. A kept choice
    /// whose computer is no longer among `computers` is dropped from
    /// `settings`, and the rest decides again.
    public static func resolve(machineId: String?, machineName: String?, agentNodeName: String? = nil, computers: [LegacyLinkComputer], settings: LocalSettings) -> LegacyLinkRoute {
        if let node = agentNodeName.flatMap(matchKey) {
            let same = computers.filter { matchKey($0.name) == node }
            if same.count == 1 { return .computer(same[0].id) }
        }
        if let machineId, let kept = settings.legacyLinkComputers[machineId] {
            if computers.contains(where: { $0.id == kept }) { return .computer(kept) }
            settings.legacyLinkComputers[machineId] = nil
        }
        guard !computers.isEmpty else { return .unavailable }
        if let name = machineName.flatMap(matchKey) {
            let named = computers.filter { matchKey($0.name) == name }
            if named.count == 1 { return .computer(named[0].id) }
        }
        return .ask(computers)
    }

    /// The person's pick for `machineId`, used by its later links.
    public static func remember(_ computerID: String, for machineId: String, settings: LocalSettings) {
        settings.legacyLinkComputers[machineId] = computerID
    }

    /// The computer `machineId`'s links go through, while it is still one of
    /// `computers`; nil when nothing was picked or it has gone.
    public static func remembered(for machineId: String, computers: [LegacyLinkComputer], settings: LocalSettings) -> LegacyLinkComputer? {
        guard let kept = settings.legacyLinkComputers[machineId] else { return nil }
        return computers.first { $0.id == kept }
    }

    /// A name as the comparison reads it, trimmed and in any case. An agent
    /// connection is shown under `AgentName.friendly` ("prep-pro" becomes
    /// "Prep Pro"), so the machine's name is read the same way first: a
    /// relay machine called "prep-pro", "Prep Pro" or "prep-pro.local"
    /// matches the computer whose node is "prep-pro".
    static func matchKey(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AgentName.friendly(trimmed).lowercased()
    }
}
