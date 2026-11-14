import Foundation
import HappyWire

/// Our plugins' additions to the composer's agent defaults: a session's
/// flavor, where an unknown one reads no one's catalogs, kept out of
/// ModelModeOptions.swift so upstream merges do not conflict there.
extension AgentDefaults.Agent {
    /// A session's flavor, when this app has catalogs for it: no flavor is
    /// Claude, and `rig` keeps the Claude catalogs it always read. A flavor
    /// this app doesn't know is nobody's, so Claude's lists and saved
    /// defaults stay off it.
    init?(sessionFlavor flavor: String?) {
        switch flavor {
        case nil, "", "rig": self = .claude
        case let flavor?:
            guard let agent = Self(rawValue: flavor) else { return nil }
            self = agent
        }
    }
}

extension AgentDefaults {
    /// `resolve` for a session's flavor. A flavor this app doesn't know
    /// reads no one's overrides and asks for nothing of its own.
    static func resolve(_ overrides: [String: JSONValue], sessionFlavor flavor: String?, cliVersion: String?) -> Config {
        guard let agent = Agent(sessionFlavor: flavor) else { return unknownFlavorDefaults }
        return resolve(overrides, agent, cliVersion: cliVersion)
    }

    static let unknownFlavorDefaults = Config(permissionMode: "default", modelMode: "default", effortLevel: nil)
}
