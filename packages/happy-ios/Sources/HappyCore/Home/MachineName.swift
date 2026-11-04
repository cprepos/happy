import Foundation
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

    private static func nonEmpty(_ value: String?) -> String? {
        value?.isEmpty == false ? value : nil
    }
}
