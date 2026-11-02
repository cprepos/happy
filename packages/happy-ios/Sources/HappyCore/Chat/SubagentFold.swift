import Foundation
import HappyWire

/// storageTypes.ts `SubagentInfo`: what the session knows of one subagent.
public struct SubagentInfo: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case running, completed, failed, stopped
    }

    public var id: String
    public var title: String?
    public var type: String?
    public var model: String?
    public var status: Status
    public var prompt: String?
    public var summary: String?
    public var tokens: Int?
    public var toolUses: Int?
    public var durationMs: Double?
    /// Epoch milliseconds of its `start` record.
    public var startedAt: Int64
    public var spawnDepth: Int?
    public var parentId: String?
    public var lastToolName: String?

    public init(
        id: String, title: String? = nil, type: String? = nil, model: String? = nil, status: Status = .running,
        prompt: String? = nil, summary: String? = nil, tokens: Int? = nil, toolUses: Int? = nil, durationMs: Double? = nil,
        startedAt: Int64, spawnDepth: Int? = nil, parentId: String? = nil, lastToolName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.model = model
        self.status = status
        self.prompt = prompt
        self.summary = summary
        self.tokens = tokens
        self.toolUses = toolUses
        self.durationMs = durationMs
        self.startedAt = startedAt
        self.spawnDepth = spawnDepth
        self.parentId = parentId
        self.lastToolName = lastToolName
    }

    /// RigActivityBar's `agentList`: running only, newest first. A finished
    /// one stays in the session and leaves the panel.
    public static func running(_ agents: [String: SubagentInfo]) -> [SubagentInfo] {
        agents.values.filter { $0.status == .running }.sorted {
            $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id < $1.id
        }
    }
}

/// storage.ts `applyMessages`' subagent fold, keyed by the envelope's
/// `subagent`. An empty string counts as absent, as its truthiness checks do.
///
/// Unlike storage.ts, it goes by the records' own time rather than by arrival.
/// Here records come out of order (a socket record before a lower sequence, a
/// page of older history after the newest), and an older `start` landing after
/// a `stop` would otherwise leave a finished agent running for good. An older
/// record's fields only fill gaps left by newer ones. Equal times go by arrival.
struct SubagentFold: Equatable, Sendable {
    private struct Clock: Equatable, Sendable {
        /// The newest `start`, once one is in.
        var start: Int64?
        /// The record that set the status, a `start` or a `stop`.
        var status: Int64 = .min
        /// The newest record of any kind.
        var fields: Int64 = .min
    }

    private(set) var agents: [String: SubagentInfo] = [:]
    private var clocks: [String: Clock] = [:]

    mutating func apply(_ event: SessionEvent, id: String, at time: Int64) {
        var agent = agents[id] ?? SubagentInfo(id: id, startedAt: time)
        var clock = clocks[id] ?? Clock()
        let newest = time >= clock.fields

        func set<Value>(_ path: WritableKeyPath<SubagentInfo, Value?>, _ value: Value?) {
            guard let value, newest || agent[keyPath: path] == nil else { return }
            agent[keyPath: path] = value
        }
        func set(_ path: WritableKeyPath<SubagentInfo, String?>, text value: String?) {
            set(path, value?.isEmpty == true ? nil : value)
        }

        switch event {
        case .start(let title, let subagentType, let model, let prompt, let spawnDepth, let parentTaskId):
            if time >= clock.start ?? .min {
                agent.startedAt = time
                clock.start = time
            }
            if time >= clock.status {
                agent.status = .running
                clock.status = time
            }
            set(\.title, text: title)
            set(\.type, text: subagentType)
            set(\.model, text: model)
            set(\.prompt, text: prompt)
            set(\.spawnDepth, spawnDepth)
            set(\.parentId, text: parentTaskId)
        case .stop(let status, let summary, let tokens, let toolUses, let durationMs):
            if time >= clock.status {
                agent.status = status.flatMap { SubagentInfo.Status(rawValue: $0.rawValue) } ?? .completed
                clock.status = time
            }
            set(\.summary, text: summary)
            set(\.tokens, tokens)
            set(\.toolUses, toolUses)
            set(\.durationMs, durationMs)
        case .progress(let tokens, let toolUses, let durationMs, let lastToolName, let summary):
            set(\.tokens, tokens)
            set(\.toolUses, toolUses)
            set(\.durationMs, durationMs)
            set(\.lastToolName, text: lastToolName)
            set(\.summary, text: summary)
        default:
            return
        }
        // Until its `start` is in, the earliest record stands in for it.
        if clock.start == nil { agent.startedAt = min(agent.startedAt, time) }
        clock.fields = max(clock.fields, time)
        agents[id] = agent
        clocks[id] = clock
    }
}
