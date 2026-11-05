import Foundation
import HappyWire

extension AgentClient {
    /// `machine` names the computer a chat that isn't this connection's
    /// own runs on (a happy-cli session's host): with more than one host
    /// workspace, it picks among them.
    public func browserWorkspace(agentID: String? = nil, artifactID: String? = nil, machine: BrowserMachineHint? = nil) async throws -> String {
        if let artifactID {
            let object = try await artifact(artifactID)
            let source = object["updatedSource"] ?? object["source"]
            if let id = source?["workspaceId"]?.stringValue ?? source?["projectId"]?.stringValue, BrowserPolicy.validID(id) { return id }
            if let id = source?["agentId"]?.stringValue { return try await agent(id).workspaceId }
            for (key, resource, field) in [("botId", "bots", "bot"), ("taskId", "tasks", "task")] {
                if let id = source?[key]?.stringValue, BrowserPolicy.validID(id) {
                    let object = try await decode(JSONValue.self, "GET", "/v0/\(resource)/\(id)")
                    if let workspaceID = object[field]?["workspaceId"]?.stringValue, BrowserPolicy.validID(workspaceID) { return workspaceID }
                    throw BrowserError.unavailable
                }
            }
        }
        if let agentID, !agentID.isEmpty { return try await agent(agentID).workspaceId }
        // The API has no unscoped host CONNECT route. A confirmed local host
        // workspace provides exactly that network context; never pick a runner.
        let listing = try await decode(BrowserHostWorkspaces.self, "GET", "/v0/workspaces")
        guard let id = listing.pick(machine: machine) else { throw BrowserError.unavailable }
        return id
    }

}
/// The computer a chat runs on, as its session names it: what picks among
/// several host workspaces. Names compare without case or a `.local`-style
/// domain.
public struct BrowserMachineHint: Equatable, Sendable {
    public var machineID: String?
    public var hosts: [String]

    public init(machineID: String? = nil, hosts: [String]) {
        self.machineID = machineID
        self.hosts = hosts.filter { !$0.isEmpty }
    }

    static func short(_ name: String) -> String {
        String(name.lowercased().split(separator: ".").first ?? "")
    }

    func matches(_ names: [String]) -> Bool {
        let mine = Set(hosts.map(Self.short)).subtracting([""])
        return names.contains { !$0.isEmpty && ($0 == machineID || mine.contains(Self.short($0))) }
    }
}

/// `GET /v0/workspaces`, as far as picking a host workspace reads it.
public struct BrowserHostWorkspaces: Decodable, Equatable, Sendable {
    public struct Workspace: Decodable, Equatable, Sendable {
        public struct Compute: Decodable, Equatable, Sendable {
            public var type: String
            public var runnerId: String?
            /// What names the computer, where the daemon says.
            public var machineId: String?
            public var hostname: String?
            public var host: String?

            public init(type: String, runnerId: String? = nil, machineId: String? = nil, hostname: String? = nil, host: String? = nil) {
                self.type = type; self.runnerId = runnerId; self.machineId = machineId; self.hostname = hostname; self.host = host
            }
        }
        public var id: String
        public var status: String
        public var compute: Compute
        public var hostname: String?

        public init(id: String, status: String, compute: Compute, hostname: String? = nil) {
            self.id = id; self.status = status; self.compute = compute; self.hostname = hostname
        }

        var names: [String] { [compute.machineId, compute.hostname, compute.host, hostname].compactMap { $0 } }
    }
    public var workspaces: [Workspace]

    public init(workspaces: [Workspace]) { self.workspaces = workspaces }

    /// The one active local host workspace (never a runner's). Of several,
    /// the one on `machine`; nil when none is, or none says: a guess could
    /// reach the wrong computer's browser.
    public func pick(machine: BrowserMachineHint?) -> String? {
        let hosts = workspaces.filter { $0.status == "active" && $0.compute.type == "host" && $0.compute.runnerId == nil }
        if hosts.count <= 1 { return hosts.first?.id }
        guard let machine else { return hosts.first?.id }
        let matching = hosts.filter { machine.matches($0.names) }
        return matching.count == 1 ? matching[0].id : nil
    }
}
