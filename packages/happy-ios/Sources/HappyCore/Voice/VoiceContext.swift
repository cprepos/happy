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
/// A session's history is not news. Until a session has loaded, its snapshots
/// only set the baseline, so a call never starts with every active session's
/// last fifty messages: that once took the first token past the point the
/// caller hung up. Pending permissions are forwarded regardless.
public struct VoiceContextReducer: Sendable {
    private var messages: [String: ChatMessage] = [:]
    private var window: [ChatMessage] = []
    private var permissions = Set<String>()
    /// A snapshot from before the first pull holds a partial history, and the
    /// pull that follows is still history, not something that just happened.
    public private(set) var loaded = false
    public init() {}

    /// Picks up after what the call's prompt already carries. Its pending
    /// permissions are still to be asked about, on the first `apply`.
    init(prompted snapshot: LegacyChatSnapshot) {
        _ = apply(snapshot)
        permissions.removeAll()
    }

    public mutating func apply(_ snapshot: LegacyChatSnapshot) -> VoiceContextUpdate {
        let recent = snapshot.messages.suffix(50)
        let changed: [ChatMessage] = loaded ? recent.filter { messages[$0.id] != $0 } : []
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
        messages = Dictionary(recent.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        window = Array(recent)
        loaded = loaded || snapshot.isLoaded
        return VoiceContextUpdate(context: Self.context(sessionId: snapshot.sessionId, lines: lines), prompts: prompts)
    }

    /// The baseline as text, for a session the model is told to look at.
    public func history(sessionId: String) -> String {
        Self.context(sessionId: sessionId, lines: window.compactMap(Self.format))
    }

    private static func context(sessionId: String, lines: [String]) -> String {
        lines.isEmpty ? "" : "Messages in session \(sessionId):\n" + lines.joined(separator: "\n\n")
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
    /// Sessions the model has the history of, from the prompt or from a focus.
    private var historySent = Set<String>()
    private var records: [String: SessionRecord] = [:]
    private var focused: String
    private var recentContext = VoiceContextRepeatFilter()
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
        let history = snapshot.messages.suffix(50).compactMap(VoiceContextReducer.format).joined(separator: "\n\n")
        reducers[focused] = VoiceContextReducer(prompted: snapshot)
        if snapshot.isLoaded { historySent.insert(focused) }
        let context = "\(Self.directory(home.sessions))\n\nCURRENT SESSION: \(focused)\nProject: \(metadata?["path"]?.stringValue ?? "")\nSummary: \(metadata?["summary"]?["text"]?.stringValue ?? "")\n\n\(history)"
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
        await sendHistoryOnce(sessionId)
        // A newer focus may have landed during that send; the last one must win.
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
        chatTasks.removeAll(); reducers.removeAll(); historySent.removeAll(); records.removeAll(); sink = nil
    }

    /// The session directory went out in the opening context and isn't re-sent,
    /// as in happy-app: a session's own updates name it when it matters.
    func home(_ snapshot: LegacyHomeSnapshot) async {
        await sendHistoryOnce(focused)
        let oldRecords = records
        records = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, value in value })
        for record in snapshot.sessions where record.active || record.id == focused {
            watch(record.id)
            // ready events may be deliberately hidden by the chat reducer;
            // presence's thinking flip is the same completion signal.
            if oldRecords[record.id]?.thinking == true, !record.thinking, record.active,
               !record.hasPendingPermissionRequests {
                await send(VoiceContextUpdate(prompts: ["Coding agent done working in session: \(record.id). Report its summary to the human."]))
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

    /// Every update but the focus line passes here. The agent acts on each focus
    /// line, and going A, B, A within the window is the user moving, not an echo.
    /// A prompt asks for something new each time, so only context is filtered.
    private func send(_ update: VoiceContextUpdate) async {
        var update = update
        if !update.context.isEmpty, recentContext.isRepeat(update.context) { update.context = "" }
        guard !update.context.isEmpty || !update.prompts.isEmpty else { return }
        await sink?(update)
    }

    func chat(_ snapshot: LegacyChatSnapshot) async {
        var reducer = reducers[snapshot.sessionId] ?? VoiceContextReducer()
        let update = reducer.apply(snapshot)
        reducers[snapshot.sessionId] = reducer
        if snapshot.sessionId == focused { await sendHistoryOnce(snapshot.sessionId) }
        await send(update)
    }

    /// The focused session's history, once per call, as happy-app's
    /// `injectSessionContext` does on focus. A session still loading gets it
    /// from `chat` when it has loaded; only focus sends it, never a background
    /// session's own activity.
    private func sendHistoryOnce(_ sessionId: String) async {
        guard sink != nil, let reducer = reducers[sessionId], reducer.loaded,
              historySent.insert(sessionId).inserted else { return }
        await send(VoiceContextUpdate(context: reducer.history(sessionId: sessionId)))
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
                // Here rather than in a backend: a send counts on either one.
                account.localSettings.voiceMessageCount += 1
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
