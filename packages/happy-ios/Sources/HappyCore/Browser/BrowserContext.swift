import Foundation
import HappyWire

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
