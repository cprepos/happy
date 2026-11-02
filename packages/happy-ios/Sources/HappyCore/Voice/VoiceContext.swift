import Foundation
import HappyStore
import HappyWire

public struct VoiceContextUpdate: Equatable, Sendable {
    public var context: String
    public var prompts: [String]
    public init(context: String = "", prompts: [String] = []) { self.context = context; self.prompts = prompts }
}

/// Incremental context uses only rendered records. Streaming text is sent
/// when its text changes; tokens do not rebuild history for other sessions.
///
/// A session's recent history goes to the agent once per call, the first time
/// something happens in it (happy-app's injectSessionContext). The first
/// snapshot is only where changes count from: at call start it is history, not
/// news, and sending it would dump every active session on the agent.
public struct VoiceContextReducer: Sendable {
    private var messages: [String: ChatMessage] = [:]
    private var permissions = Set<String>()
    private var loaded = false
    private var shown = false
    public init() {}

    /// Whether the agent already has this session's history.
    var isShown: Bool { shown }

    public mutating func apply(_ snapshot: LegacyChatSnapshot, metadata: JSONValue? = nil) -> VoiceContextUpdate {
        let changed: [ChatMessage] = loaded ? snapshot.messages.suffix(50).filter { messages[$0.id] != $0 } : []
        let lines = changed.compactMap(Self.format)
        var prompts: [String] = []
        for message in snapshot.messages {
            if case .toolCall(let call) = message, let permission = call.tool.permission,
               permission.status == .pending, permissions.insert(permission.id).inserted {
                prompts.append("Coding agent requests permission in session \(snapshot.sessionId): requestId=\(permission.id), tool=\(call.tool.name), input=\(Self.json(call.tool.input)). Ask the user before calling processPermissionRequest.")
            }
            if loaded, messages[message.id] == nil, case .agentEvent(let event) = message, event.event == .ready {
                prompts.append("Coding agent done working in session: \(snapshot.sessionId). Report the preceding summary to the human.")
            }
        }
        remember(snapshot)
        guard !lines.isEmpty || !prompts.isEmpty else { return VoiceContextUpdate() }
        // The history already holds the messages that just changed.
        if !shown {
            shown = true
            return VoiceContextUpdate(context: Self.history(heading: "SESSION", sessionId: snapshot.sessionId, metadata: metadata, messages: snapshot.messages), prompts: prompts)
        }
        return VoiceContextUpdate(context: lines.isEmpty ? "" : "Messages in session \(snapshot.sessionId):\n" + lines.joined(separator: "\n\n"), prompts: prompts)
    }

    /// The session's history if the agent doesn't have it yet, for when
    /// something happens that no snapshot reports. Changes count from here on.
    public mutating func history(_ snapshot: LegacyChatSnapshot, metadata: JSONValue? = nil) -> String? {
        guard !shown else { return nil }
        shown = true
        remember(snapshot)
        return Self.history(heading: "SESSION", sessionId: snapshot.sessionId, metadata: metadata, messages: snapshot.messages)
    }

    private mutating func remember(_ snapshot: LegacyChatSnapshot) {
        messages = Dictionary(snapshot.messages.suffix(50).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        loaded = true
    }

    /// The same words the call's opening context uses for its session.
    static func history(heading: String, sessionId: String, metadata: JSONValue?, messages: [ChatMessage]) -> String {
        let lines = messages.suffix(50).compactMap(format).joined(separator: "\n\n")
        return "\(heading): \(sessionId)\nProject: \(metadata?["path"]?.stringValue ?? "")\nSummary: \(metadata?["summary"]?["text"]?.stringValue ?? "")\n\n\(lines)"
    }

    public static func format(_ message: ChatMessage) -> String? {
        switch message {
        case .userText(let text): "User: \(text.text.prefix(8000))"
        case .agentText(let text): text.isThinking ? nil : "Coding agent: \(text.text.prefix(8000))"
        case .toolCall(let call): call.tool.description.map { "Coding agent uses \(call.tool.name): \($0.prefix(2000))" }
        default: nil
        }
    }

    private static func json(_ value: JSONValue) -> String {
        (try? String(decoding: value.encoded(), as: UTF8.self)) ?? "{}"
    }
}

/// Lives only during a voice call. Disk reads, context derivation and tool
/// execution stay on this actor, never on UIKit's queue.
public actor VoiceContext {
    private let account: AccountSession
    private let sending: any ChatSending
    private let actions: SessionActions
    private var homeTask: Task<Void, Never>?
    private var chatTasks: [String: Task<Void, Never>] = [:]
    private var reducers: [String: VoiceContextReducer] = [:]
    private var records: [String: SessionRecord] = [:]
    private var focused: String
    private var closed = false
    private var sink: (@Sendable (VoiceContextUpdate) async -> Void)?

    public init(account: AccountSession, sessionId: String) {
        self.account = account; focused = sessionId
        sending = account.sender; actions = account.actions
    }

    init(account: AccountSession, sessionId: String, sending: any ChatSending, actions: SessionActions) {
        self.account = account; focused = sessionId
        self.sending = sending; self.actions = actions
    }

    /// What a call starts with, on the backend `config` and the saved setting
    /// pick. Throws `VoiceBackendUnavailable` when nothing can carry a call.
    public func initial(config: VoiceConfig = .elevenLabsOnly) async throws -> VoiceStart {
        let home = try account.store.homeSnapshot()
        let settings = AccountSettings(home.settings)
        records = Dictionary(home.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, value in value })
        var iterator = account.chatFeed.snapshots(sessionId: focused).makeAsyncIterator()
        let snapshot = await iterator.next() ?? LegacyChatSnapshot(sessionId: focused)
        let metadata = records[focused]?.metadata
        // The prompt carries this session's history, so it never goes again, and
        // what lands between this read and the call's first update still counts.
        var reducer = VoiceContextReducer()
        _ = reducer.history(snapshot, metadata: metadata)
        reducers[focused] = reducer
        let context = "\(Self.directory(home.sessions))\n\n" + VoiceContextReducer.history(heading: "CURRENT SESSION", sessionId: focused, metadata: metadata, messages: snapshot.messages)
        let bypassed = settings.bool("voiceBypassToken") ? settings.string("voiceCustomAgentId") : nil
        let custom = bypassed.flatMap { $0.isEmpty ? nil : $0 }
        let selection = config.selection(saved: settings.voiceBackend, customAgentId: custom)
        guard let backend = selection.backend else { throw VoiceBackendUnavailable() }
        let language = settings.string("voiceAssistantLanguage")
        return VoiceStart(sessionId: focused, context: context,
                          language: backend == .stream ? VoiceLanguage.streamCode(language) : VoiceLanguage.selection(language).providerCode,
                          customAgentId: custom,
                          backend: backend,
                          voicePreset: VoicePreset.resolve(sessionId: focused, bySession: settings.voiceBySession, defaultId: settings.voiceAssistantVoice),
                          savedBackendUnavailable: selection.savedUnavailable)
    }

    public func start(sink: @escaping @Sendable (VoiceContextUpdate) async -> Void) {
        guard !closed, homeTask == nil else { return }
        attach(sink: sink)
        homeTask = Task { [weak self, account] in
            for await snapshot in account.homeFeed.snapshots() {
                guard !Task.isCancelled else { break }
                await self?.home(snapshot)
            }
        }
    }

    func attach(sink: @escaping @Sendable (VoiceContextUpdate) async -> Void) {
        self.sink = sink
    }

    public func focus(_ sessionId: String) async {
        guard sessionId != focused else { return }
        focused = sessionId
        watch(sessionId)
        await showHistory(of: sessionId)
        // A newer focus may have landed during that read; the last one must win.
        guard focused == sessionId else { return }
        await sink?(VoiceContextUpdate(context: Self.focusLine(sessionId)))
    }

    /// Bare, as happy-app's formatSessionFocus: the agent takes everything after
    /// the colon up to the next whitespace as the session id, so anything
    /// touching the id becomes part of it and the agent's sends get refused.
    static func focusLine(_ sessionId: String) -> String {
        "Session became focused: \(sessionId)"
    }

    public func stop() {
        closed = true
        homeTask?.cancel(); homeTask = nil
        for task in chatTasks.values { task.cancel() }
        chatTasks.removeAll(); reducers.removeAll(); records.removeAll(); sink = nil
    }

    /// The session directory went out in the opening context and isn't re-sent,
    /// as in happy-app: a session's own updates name it when it matters.
    func home(_ snapshot: LegacyHomeSnapshot) async {
        let oldRecords = records
        records = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, value in value })
        for record in snapshot.sessions where record.active || record.id == focused {
            watch(record.id)
            // ready events may be deliberately hidden by the chat reducer;
            // presence's thinking flip is the same completion signal.
            if oldRecords[record.id]?.thinking == true, !record.thinking, record.active,
               !record.hasPendingPermissionRequests {
                await showHistory(of: record.id)
                await sink?(VoiceContextUpdate(prompts: ["Coding agent done working in session: \(record.id). Report its summary to the human."]))
            }
        }
        let remaining = Set(snapshot.sessions.filter { $0.active || $0.id == focused }.map(\.id))
        for id in Array(chatTasks.keys) where !remaining.contains(id) { chatTasks.removeValue(forKey: id)?.cancel() }
    }

    private func watch(_ sessionId: String) {
        guard chatTasks[sessionId] == nil else { return }
        chatTasks[sessionId] = Task { [weak self, account] in
            for await snapshot in account.chatFeed.snapshots(sessionId: sessionId) {
                guard !Task.isCancelled else { break }
                await self?.chat(snapshot)
            }
        }
    }

    /// Reads the session rather than waiting for its watch: the agent is about
    /// to be asked about it. Not before the call can hear, or the history is lost.
    private func showHistory(of sessionId: String) async {
        guard sink != nil, reducers[sessionId]?.isShown != true else { return }
        var iterator = account.chatFeed.snapshots(sessionId: sessionId).makeAsyncIterator()
        guard let snapshot = await iterator.next(), !closed else { return }
        var reducer = reducers[sessionId] ?? VoiceContextReducer()
        let history = reducer.history(snapshot, metadata: records[sessionId]?.metadata)
        reducers[sessionId] = reducer
        if let history { await sink?(VoiceContextUpdate(context: history)) }
    }

    func chat(_ snapshot: LegacyChatSnapshot) async {
        var reducer = reducers[snapshot.sessionId] ?? VoiceContextReducer()
        let update = reducer.apply(snapshot, metadata: records[snapshot.sessionId]?.metadata)
        reducers[snapshot.sessionId] = reducer
        if !update.context.isEmpty || !update.prompts.isEmpty { await sink?(update) }
    }

    private static func directory(_ records: [SessionRecord]) -> String {
        "Available sessions:\n" + records.filter(\.active).sorted { $0.id < $1.id }.map {
            "- \($0.id): \($0.metadata?["summary"]?["text"]?.stringValue ?? "No summary")"
        }.joined(separator: "\n")
    }
}

public struct VoiceToolResult: Sendable, Equatable {
    public let text: String
    public let isError: Bool
    public init(_ text: String, isError: Bool = false) { self.text = text; self.isError = isError }
}

extension VoiceContext {
    /// Parameters are decoded at the boundary and permissions are looked up
    /// again immediately before execution, so stale requests cannot be approved.
    /// The text is what the agent hears back, on either backend: these are the
    /// strings of happy-app's realtimeClientTools.ts.
    public func tool(name: String, parameters: Data) async -> VoiceToolResult {
        do {
            try Task.checkCancellation()
            guard !closed else { return VoiceToolResult("error (voice session ended)", isError: true) }
            switch name {
            case "sendMessageToSession":
                struct Parameters: Decodable { let sessionId: String; let message: String }
                guard let value = try? JSONDecoder().decode(Parameters.self, from: parameters),
                      !value.sessionId.isEmpty, !value.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return VoiceToolResult("error (invalid parameters)", isError: true)
                }
                // The model can invent a session id; refuse it instead of reporting success.
                guard try account.store.session(id: value.sessionId) != nil else {
                    return VoiceToolResult("error (unknown session id; use a sessionId from the session list in your context)", isError: true)
                }
                do { _ = try await sending.send(OutgoingMessage(text: value.message, source: .voice), sessionId: value.sessionId) }
                catch { return VoiceToolResult("error (the message could not be sent to the session)", isError: true) }
                return VoiceToolResult("sent [DO NOT say anything else, simply say 'sent']")
            case "processPermissionRequest":
                struct Parameters: Decodable {
                    enum Decision: String, Decodable { case allow, deny }
                    let requestId: String; let decision: Decision
                }
                guard let value = try? JSONDecoder().decode(Parameters.self, from: parameters), !value.requestId.isEmpty else {
                    return VoiceToolResult("error (invalid parameters)", isError: true)
                }
                let matching = try account.store.sessions().filter { $0.agentState?["requests"]?[value.requestId]?.objectValue != nil }
                guard matching.count == 1, let session = matching.first else {
                    return VoiceToolResult("error (permission request not found)", isError: true)
                }
                do {
                    if value.decision == .allow { try await actions.allow(sessionId: session.id, permissionId: value.requestId) }
                    else { try await actions.deny(sessionId: session.id, permissionId: value.requestId) }
                } catch {
                    return VoiceToolResult("error (failed to \(value.decision.rawValue) permission)", isError: true)
                }
                return VoiceToolResult("done [DO NOT say anything else, simply say 'done']")
            default: return VoiceToolResult("error (unknown client tool)", isError: true)
            }
        } catch { return VoiceToolResult("error (client tool failed)", isError: true) }
    }
}
