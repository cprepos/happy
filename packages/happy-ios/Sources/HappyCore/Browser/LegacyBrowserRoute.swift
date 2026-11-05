import Foundation
import HappyStore

/// Where a Happy CLI chat's browser goes: its links, its live view and
/// Take control, all one way. The paired computer is `LegacyLinkRoute`'s
/// pick for the session's machine; on that computer, the host workspace is
/// the one the folder the chat runs in is in (`BrowserHostWorkspaces.pick(path:)`).
public enum LegacyBrowserRoute: Sendable {
    /// Through this agent connection, in the workspace `workspace` finds.
    case computer(String, workspace: LegacyBrowserWorkspace)
    /// Ask which of these computers; the answer is kept for the machine
    /// (`LegacyLinkRoute.remember`), and `workspace` then finds the
    /// workspace on the one picked.
    case ask([LegacyLinkComputer], workspace: LegacyBrowserWorkspace)
    /// No paired computer: the browser's unavailable state.
    case unavailable

    /// The route for `session` on `machine` (nil when the store has none),
    /// `machines` being every machine the store has, among `computers`.
    /// A session not yet read names no machine or folder: the person is
    /// asked, and the first host workspace is used.
    public static func resolve(session: SessionRecord?, machine: MachineRecord?, machines: [MachineRecord], computers: [LegacyLinkComputer], settings: LocalSettings) -> LegacyBrowserRoute {
        let workspace = session.map(LegacyBrowserWorkspace.init(session:)) ?? LegacyBrowserWorkspace(sessionID: "", path: nil)
        switch LegacyLinkRoute.resolve(
            machineId: session.flatMap(machineId), machineName: session.flatMap { LegacyLinkRoute.machineName(session: $0, machine: machine) },
            agentNodeName: LegacyLinkRoute.agentNodeName(machine, among: machines), computers: computers, settings: settings
        ) {
        case .computer(let id): return .computer(id, workspace: workspace)
        case .ask(let choices): return .ask(choices, workspace: workspace)
        case .unavailable: return .unavailable
        }
    }

    /// The machine the session says it runs on.
    public static func machineId(_ session: SessionRecord) -> String? {
        session.metadata?["machineId"]?.stringValue
    }
}

/// Finds a Happy CLI session's host workspace on a paired computer, by the
/// folder the session runs in (`metadata.path`).
public struct LegacyBrowserWorkspace: Equatable, Sendable {
    public let sessionID: String
    public let path: String?

    public init(sessionID: String, path: String?) {
        self.sessionID = sessionID; self.path = path
    }

    public init(session: SessionRecord) {
        self.init(sessionID: session.id, path: session.metadata?["path"]?.stringValue)
    }

    /// The workspace on `client`'s computer.
    public func find(_ client: AgentClient) async throws -> String {
        try await client.browserWorkspace(path: path, sessionID: sessionID)
    }
}
