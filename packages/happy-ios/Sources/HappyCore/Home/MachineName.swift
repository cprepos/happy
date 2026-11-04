import Foundation
import HappyStore
import HappyWire

/// What a relay machine is called wherever the app names it: the name the
/// person gave it in the app (`displayName`, which nothing else ever
/// overrides), then the Happy Agent sharing its computer (`happyAgent.nodeName`,
/// which happy-cli's daemon publishes from that agent's `config.node.name`),
/// then its host. Empty strings fall through. Older daemons publish no
/// `happyAgent`.
public enum MachineName {
    public static func named(_ metadata: JSONValue?) -> String? {
        nonEmpty(metadata?["displayName"]?.stringValue) ?? unnamed(metadata)
    }

    /// The name without the person's own: the agent's node, then the host.
    public static func unnamed(_ metadata: JSONValue?) -> String? {
        agentNodeName(metadata) ?? nonEmpty(metadata?["host"]?.stringValue)
    }

    /// `happyAgent.nodeName`, trimmed; nil when absent or blank.
    public static func agentNodeName(_ metadata: JSONValue?) -> String? {
        nonEmpty(metadata?["happyAgent"]?["nodeName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `machine`'s name among the account's `machines`. A Happy Agent's own
    /// relay machine names no node; it publishes its host with a suffix
    /// ("Mac — Happy Agent"). When the happy-cli machine on the same host
    /// names the node, that node replaces the host at the front of the
    /// name, so the agent's section reads "prep-pro — Happy Agent". A name
    /// that doesn't start with the host is the person's, and stays.
    public static func named(_ machine: MachineRecord?, among machines: [MachineRecord]) -> String? {
        let metadata = machine?.metadata
        guard agentNodeName(metadata) == nil,
              let host = nonEmpty(metadata?["host"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)),
              let node = agentNodeName(machine, among: machines)
        else { return named(metadata) }
        guard let display = nonEmpty(metadata?["displayName"]?.stringValue) else { return node }
        return display.hasPrefix(host) ? node + display.dropFirst(host.count) : display
    }

    /// The Happy Agent node for `machine`: its own, else the one node named
    /// by the other machines on its host (the happy-cli machine beside a
    /// Happy Agent's own relay machine). Several nodes on one host name none.
    public static func agentNodeName(_ machine: MachineRecord?, among machines: [MachineRecord]) -> String? {
        if let own = agentNodeName(machine?.metadata) { return own }
        guard let machine, let host = hostKey(machine) else { return nil }
        let siblings = machines.filter { $0.id != machine.id && hostKey($0) == host }.compactMap { agentNodeName($0.metadata) }
        guard Set(siblings.map { $0.lowercased() }).count == 1 else { return nil }
        return siblings.first
    }

    /// A machine's host as the same-computer lookup compares it.
    private static func hostKey(_ machine: MachineRecord) -> String? {
        nonEmpty(machine.metadata?["host"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value?.isEmpty == false ? value : nil
    }
}
