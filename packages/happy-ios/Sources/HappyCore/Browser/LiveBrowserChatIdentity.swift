import Foundation
import HappyStore
import HappyWire

/// Which chat a live browser belongs to, as every chat screen names it.
/// Everything the dock asks the bridge for is derived from this one chat,
/// and never from another's.
public enum LiveBrowserChatIdentity: Equatable, Sendable {
    /// A Happy CLI session: its machine's paired computer, in the host
    /// workspace its folder is in (`LegacyBrowserRoute`).
    case cliSession(SessionRecord)
    /// A Happy Agent conversation, on the computer whose screen it is, in
    /// the agent's own workspace. `happySession` is the Happy session the
    /// agent is mirrored to, when known.
    case agent(id: String, happySession: String?)
    /// A bot's mirrored Happy session (`metadata.bot`), from the Sessions
    /// list: its machine's paired computer, in the bot's workspace.
    case botSession(SessionRecord)

    /// The identity of a Happy session's chat: a bot's mirror, or a CLI
    /// session.
    public static func session(_ record: SessionRecord) -> LiveBrowserChatIdentity {
        record.isBot ? .botSession(record) : .cliSession(record)
    }

    /// The chat's session record, when it is a Happy session's: its machine
    /// decides the computer.
    public var record: SessionRecord? {
        switch self {
        case .cliSession(let record), .botSession(let record): record
        case .agent: nil
        }
    }

    /// The bot a bot session is, by `metadata.bot`.
    public var botID: String? {
        guard case .botSession(let record) = self,
              let id = record.metadata?["bot"]?["id"]?.stringValue, BrowserPolicy.validID(id) else { return nil }
        return id
    }

    /// The keys to ask the bridge by, in order. A Happy session's key goes
    /// first (the bridge files an agent with a Happy session under it), then
    /// the agent's own (`agent`, once known for a bot session).
    public func keys(agent agentID: String? = nil) -> [String] {
        var keys: [String] = []
        switch self {
        case .cliSession(let record):
            keys.append(LiveBrowserLink.chatKey(happySession: record.id))
        case .botSession(let record):
            keys.append(LiveBrowserLink.chatKey(happySession: record.id))
            if let agentID, !agentID.isEmpty { keys.append(LiveBrowserLink.chatKey(agent: agentID)) }
        case .agent(let id, let happySession):
            if let happySession, !happySession.isEmpty { keys.append(LiveBrowserLink.chatKey(happySession: happySession)) }
            keys.append(LiveBrowserLink.chatKey(agent: id))
        }
        return keys
    }

    /// Where on its computer the chat's browser is reached: a bot's, its
    /// agent's workspace (prep-ml's bridge, through the agent's computer).
    public var workspace: LiveBrowserChatWorkspace {
        switch self {
        case .cliSession(let record): .folder(LegacyBrowserWorkspace(session: record))
        case .botSession(let record):
            .bot(id: botID ?? "", workspaceID: record.metadata?["bot"]?["workspaceId"]?.stringValue)
        case .agent(let id, _): .agent(id)
        }
    }
}

/// The workspace on a computer whose network holds the chat's bridge.
public enum LiveBrowserChatWorkspace: Equatable, Sendable {
    /// The host workspace a CLI session's folder is in.
    case folder(LegacyBrowserWorkspace)
    /// The agent's own workspace.
    case agent(String)
    /// A bot's workspace: the one its metadata names, else the bot's as
    /// the computer has it.
    case bot(id: String, workspaceID: String?)

    public func find(_ client: AgentClient) async throws -> String {
        switch self {
        case .folder(let workspace): return try await workspace.find(client)
        case .agent(let id): return try await client.browserWorkspace(agentID: id)
        case .bot(let id, let workspaceID):
            // The bot's agent's own workspace, as an agent chat's; else the
            // one the bot names.
            let bot = BrowserPolicy.validID(id) ? try? await client.liveBrowserBot(id) : nil
            if let agent = bot?.agentID { return try await client.browserWorkspace(agentID: agent) }
            if let workspaceID, BrowserPolicy.validID(workspaceID) { return workspaceID }
            guard let found = bot?.workspaceID else { throw BrowserError.unavailable }
            return found
        }
    }
}

extension AgentClient {
    /// A bot as the computer has it (`GET /v0/bots/<id>`): its workspace and
    /// the agent its conversation is.
    public func liveBrowserBot(_ id: String) async throws -> (workspaceID: String?, agentID: String?) {
        guard BrowserPolicy.validID(id) else { throw BrowserError.unavailable }
        let object = try await decode(JSONValue.self, "GET", "/v0/bots/\(id)")
        let bot = object["bot"] ?? object
        let workspace = bot["workspaceId"]?.stringValue.flatMap { BrowserPolicy.validID($0) ? $0 : nil }
        let agent = bot["agent"]?["id"]?.stringValue.flatMap { BrowserPolicy.validID($0) ? $0 : nil }
        return (workspace, agent)
    }

    /// The bot whose conversation is `agentID`, among the computer's bots.
    public func liveBrowserBotID(agent agentID: String) async throws -> String? {
        for bot in try await bots() where bot["agent"]?["id"]?.stringValue == agentID {
            if let id = bot["id"]?.stringValue, BrowserPolicy.validID(id) { return id }
        }
        return nil
    }
}

/// The Happy session a bot's conversation is mirrored to: the one whose
/// `metadata.bot.id` is the bot, exactly; nil when none or more than one is.
public enum LiveBrowserMirror {
    public static func happySession(bot botID: String, among sessions: [SessionRecord]) -> String? {
        let matches = sessions.filter { $0.metadata?["bot"]?["id"]?.stringValue == botID }
        return matches.count == 1 ? matches[0].id : nil
    }
}
