import Foundation
import HappyWire

/// sync/opencodeModes.ts: OpenCode's mode picker, an agent (build, plan, ...)
/// plus a permission policy.
///
/// Each agent is offered as `<Agent>-auto` and `<Agent>-ask`, keyed
/// `<agent>:auto` and `<agent>:ask`. What a session reports depends on the
/// CLI running it: the ACP runner lists the explicit keys, the TUI mirror
/// lists the plain id for its launch policy and `<agent>:<other policy>` for
/// the other, and older CLIs list plain ids only. The picker always shows the
/// explicit keys, built from whichever of these the session has.
public enum OpencodeModes {
    public enum Policy: String, CaseIterable, Sendable {
        case auto, ask

        /// `agentInput.permissionMode.opencodeAuto` and `opencodeAsk`.
        var description: String {
            switch self {
            case .auto: "approves tool permissions automatically"
            case .ask: "asks before tools that need permission"
            }
        }
    }

    public static let defaultPermissionMode = "build:auto"
    public static let defaultAgents = ["build", "plan"]

    /// Keys other harnesses use. They are not OpenCode agents, so they never
    /// become `<key>:<policy>`.
    static let genericPermissionKeys: Set<String> = [
        "default", "auto", "yolo", "bypassPermissions", "acceptEdits", "safe-yolo", "read-only",
    ]

    /// `splitOpencodeModeKey`: `build:ask` is build and ask; `plan` and
    /// `ns:agent` are agents with no policy.
    public static func split(_ key: String) -> (agent: String, policy: Policy?) {
        guard let separator = key.lastIndex(of: ":"), separator > key.startIndex,
              let policy = Policy(rawValue: String(key[key.index(after: separator)...])) else {
            return (key, nil)
        }
        return (String(key[..<separator]), policy)
    }

    /// `opencodeLaunchPolicy`: the policy a plain agent id stands for in this
    /// mode list. The TUI mirror lists the plain id next to the other
    /// policy's key; anything else is auto, the default.
    public static func launchPolicy(_ modes: [ModeOption], agent: String) -> Policy {
        let codes = Set(modes.map(\.key))
        return codes.contains(agent) && codes.contains("\(agent):auto") && !codes.contains("\(agent):ask") ? .ask : .auto
    }

    /// `normalizeOpencodePermissionModeKey`: a saved or reported key as an
    /// explicit `<agent>:<policy>`. Generic keys and nil come back unchanged.
    public static func normalize(_ key: String?, modes: [ModeOption] = []) -> String? {
        guard let key, !key.isEmpty, !genericPermissionKeys.contains(key) else { return key }
        let (agent, policy) = split(key)
        return policy == nil ? "\(agent):\(launchPolicy(modes, agent: agent).rawValue)" : key
    }

    /// `opencodeAgentsFromModes`: the agents of a reported list, in order,
    /// with their own row when they have a plain one.
    static func agents(in modes: [ModeOption]) -> [(agent: String, option: ModeOption?)] {
        var agents: [(agent: String, option: ModeOption?)] = []
        for mode in modes {
            let agent = split(mode.key).agent
            if genericPermissionKeys.contains(agent) { continue }
            if let index = agents.firstIndex(where: { $0.agent == agent }) {
                if agents[index].option == nil, mode.key == agent { agents[index].option = mode }
            } else {
                agents.append((agent, mode.key == agent ? mode : nil))
            }
        }
        return agents
    }

    /// `opencodeAgentDisplayName`: "Build" for build. OpenCode sometimes
    /// reports "build, build" or "plan/plan", and the TUI mirror names its
    /// plain rows "Build-auto".
    public static func displayName(agent: String, option: ModeOption?) -> String {
        let raw = option?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = (raw.isEmpty ? agent : raw)
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "/" }).first.map(String.init) ?? ""
        var trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if let suffix = policySuffix(of: trimmed) { trimmed.removeLast(suffix.count) }
        let name = trimmed.isEmpty ? agent : trimmed
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// `getOpencodePermissionModes`: what Settings and the new-session screen
    /// show before a session exists.
    static func hardcodedOptions() -> [AgentDefaults.Option] {
        let descriptions = ["build": "opencode build agent", "plan": "plan first"]
        return defaultAgents.flatMap { agent in
            Policy.allCases.map { policy in
                AgentDefaults.Option(
                    "\(agent):\(policy.rawValue)",
                    "\(displayName(agent: agent, option: nil))-\(policy.rawValue)",
                    "\(descriptions[agent] ?? agent) · \(policy.description)"
                )
            }
        }
    }

    /// `getOpencodeSessionPermissionModes`: a running session's list, as
    /// explicit keys whatever shape its CLI reported. A session that has
    /// reported nothing yet gets the default agents.
    static func sessionPermissionModes(metadata: JSONValue?) -> [ModeOption] {
        let reported = ModelModeOptions.mapMetadataOptions(metadata?["operatingModes"])
        let agents = agents(in: reported)
        if agents.isEmpty { return ModelModeOptions.hardcodedPermissionModes(flavor: OpencodeHarness.key) }
        return agents.flatMap { agent, option in
            let name = displayName(agent: agent, option: option)
            let launch = launchPolicy(reported, agent: agent)
            return Policy.allCases.map { policy in
                let explicit = reported.first { $0.key == "\(agent):\(policy.rawValue)" }
                let plain = option != nil && launch == policy ? option : nil
                let plainDescription = plain.flatMap { policySuffix(of: $0.name) == nil ? nil : $0.description }
                return ModeOption(
                    key: "\(agent):\(policy.rawValue)",
                    name: "\(name)-\(policy.rawValue)",
                    description: explicit?.description ?? plainDescription ?? policy.description
                )
            }
        }
    }

    /// useComposerModes.ts: the keys a session's permission chip is read
    /// from. Without a pick or a saved default it shows what the running CLI
    /// reports, which is what it does when a message carries no mode.
    static func preferredPermissionKeys(pick: String?, overrides: [String: JSONValue], metadata: JSONValue?) -> [String?] {
        let reported = ModelModeOptions.mapMetadataOptions(metadata?["operatingModes"])
        return [
            pick,
            AgentDefaults.override(overrides, .opencode, .permissionMode),
            metadata?["currentOperatingModeCode"]?.stringValue,
            defaultPermissionMode,
        ].map { normalize($0, modes: reported) }
    }

    /// `-auto` or `-ask` at the end of a name, in any case.
    private static func policySuffix(of name: String) -> String? {
        let lowered = name.lowercased()
        return Policy.allCases.map { "-\($0.rawValue)" }.first { lowered.hasSuffix($0) }
    }
}
