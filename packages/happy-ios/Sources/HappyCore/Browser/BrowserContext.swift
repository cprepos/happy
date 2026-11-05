import Foundation
import HappyWire
#if canImport(OSLog)
import OSLog
#endif

extension AgentClient {
    /// `path` is the folder a chat that isn't this connection's own runs in
    /// (a happy-cli session's `metadata.path`): with more than one host
    /// workspace, it picks the one that folder is in
    /// (`BrowserHostWorkspaces.pick(path:)`). `sessionID` only names the
    /// chat in the log when no workspace holds the folder.
    public func browserWorkspace(agentID: String? = nil, artifactID: String? = nil, path: String? = nil, sessionID: String? = nil) async throws -> String {
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
        let choice = try listing.choose(path: path)
        if !choice.matched {
            BrowserHostWorkspaces.log("no host workspace holds session \(sessionID ?? "-")'s folder …/\(BrowserHostWorkspaces.lastPart(path)); using \(choice.id)")
        }
        return choice.id
    }
}

/// `GET /v0/workspaces`, as far as picking a host workspace reads it.
public struct BrowserHostWorkspaces: Decodable, Equatable, Sendable {
    public struct Workspace: Decodable, Equatable, Sendable {
        public struct Compute: Decodable, Equatable, Sendable {
            public var type: String
            public var runnerId: String?
            /// The folder a host workspace is, on its computer.
            public var path: String?

            public init(type: String, runnerId: String? = nil, path: String? = nil) {
                self.type = type; self.runnerId = runnerId; self.path = path
            }
        }
        public var id: String
        public var status: String
        public var orderKey: String?
        public var compute: Compute

        public init(id: String, status: String, orderKey: String? = nil, compute: Compute) {
            self.id = id; self.status = status; self.orderKey = orderKey; self.compute = compute
        }
    }
    public var workspaces: [Workspace]

    public init(workspaces: [Workspace]) { self.workspaces = workspaces }

    /// The host workspace a chat in `path` reaches its computer's browser
    /// through. Only an active local host workspace (never a runner's or a
    /// container's) with a folder is a candidate. The one whose folder is
    /// `path` wins; else the one with the longest folder `path` is inside,
    /// on whole folder names, without case or a trailing `/`
    /// (`/a/happy2` is not inside `/a/happy`); else the first by `orderKey`
    /// then id. No candidate is `BrowserError.unavailable`.
    public func pick(path: String?) throws -> String { try choose(path: path).id }

    /// `pick(path:)`, and whether a folder matched rather than the first
    /// being taken.
    func choose(path: String?) throws -> (id: String, matched: Bool) {
        let candidates = workspaces
            .filter { $0.status == "active" && $0.compute.type == "host" && $0.compute.runnerId == nil }
            .compactMap { workspace in Self.components(workspace.compute.path).map { (workspace, $0) } }
            .sorted { ($0.0.orderKey ?? "", $0.0.id) < ($1.0.orderKey ?? "", $1.0.id) }
        guard let first = candidates.first else { throw BrowserError.unavailable }
        guard let session = Self.components(path) else { return (first.0.id, false) }
        if let exact = candidates.first(where: { $0.1 == session }) { return (exact.0.id, true) }
        let parents = candidates.filter { $0.1.count < session.count && Array(session.prefix($0.1.count)) == $0.1 }
        // `max` keeps the first of equals, which is the first in order.
        if let longest = parents.max(by: { $0.1.count < $1.1.count }) { return (longest.0.id, true) }
        return (first.0.id, false)
    }

    /// A folder as compared: its names, lowercased, without empty parts,
    /// `.` or what a `..` undoes. Nil for no folder; `/` is no names.
    static func components(_ path: String?) -> [String]? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part.lowercased())
            }
        }
        return parts
    }

    /// The folder's own name, as the log names it: not the whole path.
    static func lastPart(_ path: String?) -> String {
        path?.split(separator: "/").last.map(String.init) ?? "-"
    }

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "app.happy", category: "BrowserWorkspace")
    static func log(_ message: String) { logger.notice("\(message, privacy: .public)") }
    #else
    static func log(_ message: String) { print("[BrowserWorkspace] \(message)") }
    #endif
}
