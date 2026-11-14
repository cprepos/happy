import Foundation

// Our plugins' subagent payloads for `SessionEvent`'s `stop` and `agents`
// cases, kept out of SessionProtocol.swift so upstream merges do not
// conflict there. The cases and their coding stay in that file.

/// How a subagent ended (`stop`'s `status`).
public enum SessionSubagentStatus: String, Codable, Hashable, Sendable {
    case completed
    case failed
    case stopped
}

/// One entry of the `agents` event.
public struct SessionAgentEntry: Codable, Hashable, Sendable {
    public var id: String
    public var type: String?
    public var description: String?
    public var parentId: String?

    public init(id: String, type: String? = nil, description: String? = nil, parentId: String? = nil) {
        self.id = id
        self.type = type
        self.description = description
        self.parentId = parentId
    }
}
