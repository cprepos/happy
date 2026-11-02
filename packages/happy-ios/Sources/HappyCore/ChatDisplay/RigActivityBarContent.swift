import Foundation

/// What RigActivityBar.tsx shows: the metadata's indicators and the running
/// subagents the session's events name. Neither is tied to the other, and the
/// panel isn't tied to Happy Agent: elsewhere there are no indicators, and the
/// bar is the fallback pill alone.
public struct RigActivityBarContent: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var indicator: RigActivityIndicator
        /// "N running": no indicator counts the agents, so the events do.
        public var isFallback: Bool
        /// A tap opens the panel, and a chevron says so.
        public var opensPanel: Bool
    }

    public var items: [Item]
    public var agents: [SubagentInfo]

    public init(indicators: [RigActivityIndicator], running agents: [SubagentInfo]) {
        self.agents = agents
        var items = indicators.map { indicator -> Item in
            guard indicator.kind == .subagents, !agents.isEmpty else {
                return Item(indicator: indicator, isFallback: false, opensPanel: false)
            }
            // The events' count beats the metadata's, which keeps its queue.
            var counted = indicator
            counted.count = agents.count
            return Item(indicator: counted, isFallback: false, opensPanel: true)
        }
        if !agents.isEmpty, !indicators.contains(where: { $0.kind == .subagents }) {
            items.append(Item(indicator: RigActivityIndicator(kind: .subagents, count: agents.count), isFallback: true, opensPanel: true))
        }
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
}

/// RigActivityBar.tsx `AgentRow`'s words for one running agent. RN's literals
/// ("Agent", " tok", "↳ ") aren't in en.ts, so they stay English here.
public struct RigAgentRowContent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var type: String?
    public var elapsed: String
    public var tokens: String?
    public var prompt: String?
    public var summary: String?
    public var lastTool: String?
    /// Spawned by another subagent.
    public var indented: Bool

    public init(_ agent: SubagentInfo, now: Int64) {
        id = agent.id
        title = agent.title ?? agent.type ?? "Agent"
        type = agent.type
        // A clock behind the record's own time reads 0s, not "-3s".
        elapsed = Self.duration(ms: max(0, now &- agent.startedAt))
        tokens = agent.tokens.map { "\(Self.tokens($0)) tok" }
        prompt = agent.prompt
        summary = agent.summary
        lastTool = agent.lastToolName.map { "↳ \($0)" }
        indented = (agent.spawnDepth ?? 1) > 1
    }

    /// `formatDuration`: "42s", "1m 5s", from the rounded seconds.
    public static func duration(ms: Int64) -> String {
        let seconds = ms / 1000 + (ms % 1000 >= 500 ? 1 : 0)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    /// `formatTokens`: "950", "1.2k", "3.4M".
    public static func tokens(_ tokens: Int) -> String {
        if tokens < 1000 { return "\(tokens)" }
        if tokens < 1_000_000 { return String(format: "%.1fk", Double(tokens) / 1000) }
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
}
