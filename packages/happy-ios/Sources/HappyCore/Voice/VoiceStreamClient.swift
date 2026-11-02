import Foundation

/// What the agent is told about a call through `happy.getConfig`, as
/// happy-app's voiceAgentConfig.ts. `voice` and `speed` are sent only when a
/// voice was picked, so the agent otherwise keeps its own defaults.
public struct VoiceAgentConfig: Equatable, Sendable, Encodable {
    public var systemPrompt: String
    public var firstMessage: String
    public var initialContext: String
    public var language: String?
    public var sessionId: String
    public var voice: String?
    public var speed: Double?

    public init(systemPrompt: String = "", firstMessage: String = "", initialContext: String = "", language: String? = nil,
                sessionId: String = "", voice: String? = nil, speed: Double? = nil) {
        self.systemPrompt = systemPrompt
        self.firstMessage = firstMessage
        self.initialContext = initialContext
        self.language = language
        self.sessionId = sessionId
        self.voice = voice
        self.speed = speed
    }

    /// The config for a call, with the prompt and greeting of its voice.
    public init(start: VoiceStart, voiceMessageCount: Int = 0) {
        let persona = start.voicePreset.flatMap { VoicePersona(voice: $0.voice) }
        self.init(
            systemPrompt: VoiceSystemPrompt.build(initialContext: start.context, voiceMessageCount: voiceMessageCount, persona: persona),
            firstMessage: VoiceSystemPrompt.firstMessage(persona: persona),
            initialContext: start.context,
            language: start.language,
            sessionId: start.sessionId,
            voice: start.voicePreset?.voice,
            speed: start.voicePreset?.speed
        )
    }

    private enum CodingKeys: String, CodingKey {
        case systemPrompt, firstMessage, initialContext, language, sessionId, voice, speed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(firstMessage, forKey: .firstMessage)
        try container.encode(initialContext, forKey: .initialContext)
        try container.encode(language, forKey: .language)
        try container.encode(sessionId, forKey: .sessionId)
        if let voice, !voice.isEmpty {
            try container.encode(voice, forKey: .voice)
            try container.encodeIfPresent(speed, forKey: .speed)
        }
    }
}

public enum VoiceStreamEvent: Equatable, Sendable {
    /// Whether the agent is speaking; sent when that changes.
    case agentSpeaking(Bool)
    /// One downlink frame (PCM16, 24 kHz).
    case audio(Data)
    /// The agent was interrupted: drop agent audio not yet played.
    case flush
    /// The call is over and the socket closed. nil is a plain end: the user's,
    /// or the room closing. Always the last event of a call that got ready.
    case ended(VoiceFailure?)
}

/// Why a call never got ready. An `unauthorized` answer is `APIError.unauthorized` instead.
public enum VoiceStreamError: Error, Equatable, Sendable {
    case invalidServerURL
    case alreadyStarted
    case timedOut
    case server(code: String, message: String)
    case closed(WebSocketClosure?)
    /// `end()` was called before the call got ready.
    case ended
}

/// One voice call over the server's voice stream, one socket and no reconnect:
/// JSON control messages as text frames and audio as binary frames (see
/// voiceStream.ts in happy-wire and happy-app's happyVoiceSession.ts). The audio
/// itself belongs to whoever owns the microphone and speaker.
///
/// Usable from any thread. Call `end()` once a started call is over.
public final class VoiceStreamClient: @unchecked Sendable {
    public typealias ToolCall = @Sendable (_ name: String, _ parameters: Data) async -> VoiceToolResult

    private static let path = "/v1/voice/stream"
    private static let maxQueuedMessages = 100
    /// Bytes still unsent beyond which microphone frames are dropped instead of
    /// queued (about a second of audio): after a stall, fresh audio matters
    /// more than complete audio.
    private static let maxPendingBytes = 32000
    /// How long `end()` waits for what's queued before closing regardless.
    private static let drainTimeout = Duration.seconds(1)

    private enum Phase { case idle, starting, ready, ended }

    private enum Outgoing: Sendable {
        case text(String)
        case audio(Data)

        var byteCount: Int {
            switch self {
            case .text(let text): text.utf8.count
            case .audio(let data): data.count
            }
        }
    }

    private let serverURL: URL
    private let token: String
    private let config: VoiceAgentConfig
    private let connector: WebSocketConnector
    private let readyTimeout: Duration
    private let tool: ToolCall
    private let outgoing: AsyncStream<Outgoing>
    private let outgoingContinuation: AsyncStream<Outgoing>.Continuation
    private let eventsContinuation: AsyncStream<VoiceStreamEvent>.Continuation

    private let lock = NSLock()
    private var phase = Phase.idle
    private var socket: (any WebSocketConnection)?
    private var starter: CheckedContinuation<String, Error>?
    private var startError: Error?
    private var timeout: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var pendingBytes = 0
    private var queue: [(topic: String, text: String)] = []
    private var agentPresent = false
    private var agentSpeaking = false
    private var failure: VoiceFailure?
    private var voiceMessageCount: Int

    /// Everything the UI reacts to, in order. One consumer.
    public let events: AsyncStream<VoiceStreamEvent>

    /// - Parameters:
    ///   - token: the account's auth token. It travels only in `hello`, never in the URL.
    ///   - config: the reply to `happy.getConfig`.
    ///   - voiceMessageCount: where the runtime counter the agent is told about starts.
    ///   - tool: runs the agent's tool calls.
    public init(serverURL: URL, token: String, config: VoiceAgentConfig, connector: WebSocketConnector,
                readyTimeout: Duration = .seconds(15), voiceMessageCount: Int = 0, tool: @escaping ToolCall) {
        self.serverURL = serverURL
        self.token = token
        self.config = config
        self.connector = connector
        self.readyTimeout = readyTimeout
        self.voiceMessageCount = voiceMessageCount
        self.tool = tool
        (outgoing, outgoingContinuation) = AsyncStream.makeStream(of: Outgoing.self)
        (events, eventsContinuation) = AsyncStream.makeStream(of: VoiceStreamEvent.self)
    }

    /// `https://host/base` is `wss://host/base/v1/voice/stream`.
    public static func url(serverURL: URL) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased() == "http" ? "ws" : "wss"
        var base = components.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        components.percentEncodedPath = base + path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: Lifecycle

    /// Opens the socket, says hello and returns the conversation id on `ready`.
    /// Throws `APIError.unauthorized` when the server refuses the token,
    /// `CancellationError` when the task is cancelled, else `VoiceStreamError`
    /// or the connector's error. A client starts once.
    public func start() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                lock.lock()
                guard phase == .idle else {
                    let error = startError ?? VoiceStreamError.alreadyStarted
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                phase = .starting
                starter = continuation
                let readyTimeout = readyTimeout
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: readyTimeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(startError: VoiceStreamError.timedOut)
                }
                lock.unlock()
                Task { await self.run() }
            }
        } onCancel: {
            finish(startError: CancellationError())
        }
    }

    /// Ends the call: tells the server, lets what's queued go, closes with
    /// 1000 `end`. Safe at any time and more than once.
    public func end() async {
        let (socket, sender): ((any WebSocketConnection)?, Task<Void, Never>?) = lock.withLock {
            guard phase != .ended else { return (nil, nil) }
            if self.socket != nil { enqueue(Self.encoded(EndMessage())) }
            return (self.socket, self.sender)
        }
        finish(startError: VoiceStreamError.ended, closing: false)
        guard let socket else { return }
        let deadline = Task {
            try? await Task.sleep(for: Self.drainTimeout)
            guard !Task.isCancelled else { return }
            await socket.close(code: 1000, reason: "end")
        }
        await sender?.value
        deadline.cancel()
        await socket.close(code: 1000, reason: "end")
    }

    private func run() async {
        guard let url = Self.url(serverURL: serverURL) else {
            finish(startError: VoiceStreamError.invalidServerURL)
            return
        }
        let socket: any WebSocketConnection
        do {
            socket = try await connector.connect(to: url)
        } catch {
            finish(startError: error)
            return
        }
        guard attach(socket) else {
            await socket.close(code: 1000, reason: "end")
            return
        }
        await read(socket)
    }

    /// Keeps a just-opened socket unless the call already ended, and says hello.
    private func attach(_ socket: any WebSocketConnection) -> Bool {
        lock.withLock {
            guard phase != .ended else { return false }
            self.socket = socket
            sender = Task { [outgoing] in
                for await message in outgoing {
                    do {
                        switch message {
                        case .text(let text): try await socket.send(text)
                        case .audio(let data): try await socket.send(binary: data)
                        }
                    } catch {
                        // The reader sees the socket go and ends the call.
                        await socket.close(code: 1000, reason: "end")
                        return
                    }
                    self.sent(message.byteCount)
                }
            }
            enqueue(Self.encoded(HelloMessage(
                token: token,
                sessionId: config.sessionId.isEmpty ? nil : config.sessionId,
                language: config.language?.isEmpty == false ? config.language : nil
            )))
            return true
        }
    }

    private func sent(_ bytes: Int) {
        lock.withLock { pendingBytes -= bytes }
    }

    private func read(_ socket: any WebSocketConnection) async {
        do {
            while true {
                switch try await socket.receiveFrame() {
                case .text(let text): receive(text)
                case .binary(let data): receive(audio: data)
                }
            }
        } catch {
            finish(startError: VoiceStreamError.closed(socket.closure))
        }
    }

    /// The one way a call ends. Before ready it fails `start()`; after, it
    /// reports `.ended` with whatever the server said went wrong.
    private func finish(startError: Error, closing: Bool = true) {
        let (ended, starter, socket, timeout, failure): (Bool, CheckedContinuation<String, Error>?, (any WebSocketConnection)?, Task<Void, Never>?, VoiceFailure?) = lock.withLock {
            guard phase != .ended else { return (false, nil, nil, nil, nil) }
            let wasReady = phase == .ready
            phase = .ended
            self.startError = startError
            queue = []
            let starter = self.starter
            self.starter = nil
            return (wasReady, starter, self.socket, self.timeout, self.failure)
        }
        timeout?.cancel()
        outgoingContinuation.finish()
        starter?.resume(throwing: startError)
        if ended { eventsContinuation.yield(.ended(failure)) }
        eventsContinuation.finish()
        if closing, let socket {
            Task { await socket.close(code: 1000, reason: "end") }
        }
    }

    // MARK: Sending

    /// Sends one uplink frame of exactly `VoiceStreamAudio.uplinkFrameBytes`,
    /// the only size the server takes. Returns whether it was accepted: frames
    /// are dropped until the call is ready and while the socket is stalled.
    @discardableResult
    public func sendAudio(_ frame: Data) -> Bool {
        guard frame.count == VoiceStreamAudio.uplinkFrameBytes else { return false }
        return lock.withLock {
            guard phase == .ready, pendingBytes <= Self.maxPendingBytes else { return false }
            enqueue(.audio(frame))
            return true
        }
    }

    /// Something for the agent to respond to.
    public func sendText(_ text: String) {
        publish(topic: "happy.text", text: text)
    }

    /// Something the agent should know, without responding.
    public func sendContext(_ text: String) {
        publish(topic: "happy.context", text: text)
    }

    /// Holds messages until the call is ready and the agent is in the room,
    /// keeping the newest.
    private func publish(topic: String, text: String) {
        lock.withLock {
            guard phase != .ended else { return }
            guard phase == .ready, agentPresent else {
                queue.append((topic, text))
                if queue.count > Self.maxQueuedMessages { queue.removeFirst() }
                return
            }
            enqueue(Self.encoded(TextMessage(topic: topic, text: text)))
        }
    }

    /// Caller holds the lock, which also keeps the wire in call order.
    private func enqueue(_ message: Outgoing) {
        pendingBytes += message.byteCount
        outgoingContinuation.yield(message)
    }

    /// Caller holds the lock.
    private func flushQueueIfOpen() {
        guard phase == .ready, agentPresent else { return }
        let pending = queue
        queue = []
        for (topic, text) in pending {
            enqueue(Self.encoded(TextMessage(topic: topic, text: text)))
        }
    }

    // MARK: Receiving

    private func receive(audio frame: Data) {
        let ready = lock.withLock { phase == .ready }
        if ready { eventsContinuation.yield(.audio(frame)) }
    }

    private func receive(_ text: String) {
        // Anything unknown or malformed is ignored: a newer server may say more.
        guard let message = try? JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8)) else { return }
        switch message.type {
        case "ready":
            guard let conversationId = message.conversationId else { return }
            ready(conversationId)
        case "agent":
            guard let present = message.present else { return }
            if let state = message.state, !ServerMessage.agentStates.contains(state) { return }
            agent(present: present, speaking: present && message.state == "speaking")
        case "rpc":
            guard let id = message.id, let method = message.method, let payload = message.payload else { return }
            Task { await self.answer(id: id, method: method, payload: payload) }
        case "flush":
            eventsContinuation.yield(.flush)
        case "error":
            guard let code = message.code, ServerMessage.errorCodes.contains(code), let description = message.message else { return }
            serverError(code: code, message: description)
        default:
            return
        }
    }

    private func ready(_ conversationId: String) {
        let (starter, timeout): (CheckedContinuation<String, Error>?, Task<Void, Never>?) = lock.withLock {
            guard phase == .starting else { return (nil, nil) }
            phase = .ready
            let starter = self.starter
            self.starter = nil
            flushQueueIfOpen()
            return (starter, self.timeout)
        }
        timeout?.cancel()
        starter?.resume(returning: conversationId)
    }

    private func agent(present: Bool, speaking: Bool) {
        let changed: Bool = lock.withLock {
            let joined = present && !agentPresent
            agentPresent = present
            if joined { flushQueueIfOpen() }
            guard speaking != agentSpeaking else { return false }
            agentSpeaking = speaking
            return true
        }
        if changed { eventsContinuation.yield(.agentSpeaking(speaking)) }
    }

    /// Before ready this fails the start now. After, the call ends when the
    /// server closes the socket, which it does right after an error.
    private func serverError(code: String, message: String) {
        let starting: Bool = lock.withLock {
            guard phase == .ready else { return true }
            failure = code == "unauthorized" ? .authentication : .connection
            return false
        }
        guard starting else { return }
        finish(startError: code == "unauthorized" ? APIError.unauthorized : VoiceStreamError.server(code: code, message: message))
    }

    // MARK: The agent's calls

    private enum Reply {
        case result(String)
        case error(String)
    }

    private func answer(id: String, method: String, payload: String) async {
        let reply = await call(method: method, payload: payload)
        let message: RPCResultMessage
        switch reply {
        case .result(let text): message = RPCResultMessage(id: id, result: text, error: nil)
        case .error(let text): message = RPCResultMessage(id: id, result: nil, error: text)
        }
        lock.withLock {
            guard phase != .ended else { return }
            enqueue(Self.encoded(message))
        }
    }

    private func call(method: String, payload: String) async -> Reply {
        switch method {
        case "happy.getConfig":
            return .result(Self.json(config))
        case "sendMessageToSession", "processPermissionRequest":
            let parameters = Data((payload.isEmpty ? "{}" : payload).utf8)
            guard (try? JSONSerialization.jsonObject(with: parameters, options: .fragmentsAllowed)) != nil else {
                return .error("payload is not valid JSON")
            }
            let result = await tool(method, parameters)
            if method == "sendMessageToSession", !result.isError { messageSent() }
            return .result(result.text)
        default:
            return .error("unknown method \(method)")
        }
    }

    private func messageSent() {
        let count: Int = lock.withLock {
            voiceMessageCount += 1
            return voiceMessageCount
        }
        sendContext("# Runtime counters updated\n- voice_message_count: \(count)")
    }

    // MARK: Wire

    private struct HelloMessage: Encodable {
        var type = "hello"
        let token: String
        let sessionId: String?
        let language: String?
    }

    private struct TextMessage: Encodable {
        var type = "text"
        let topic: String
        let text: String
    }

    private struct RPCResultMessage: Encodable {
        var type = "rpcResult"
        let id: String
        let result: String?
        let error: String?
    }

    private struct EndMessage: Encodable {
        var type = "end"
    }

    private struct ServerMessage: Decodable {
        static let agentStates: Set<String> = ["initializing", "idle", "listening", "thinking", "speaking"]
        static let errorCodes: Set<String> = ["unauthorized", "bad_request", "unavailable", "internal"]

        let type: String
        let conversationId: String?
        let present: Bool?
        let state: String?
        let id: String?
        let method: String?
        let payload: String?
        let code: String?
        let message: String?
    }

    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Plain strings and numbers always encode.
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func encoded(_ value: some Encodable) -> Outgoing {
        .text(json(value))
    }
}

extension VoiceStreamClient {
    /// A call for this account, its tools running through `context`.
    public convenience init(account: AccountSession, context: VoiceContext, start: VoiceStart) {
        let count = account.localSettings.voiceMessageCount
        self.init(serverURL: account.serverURL, token: account.credentials.token,
                  config: VoiceAgentConfig(start: start, voiceMessageCount: count),
                  connector: account.voiceConnector, voiceMessageCount: count) { name, parameters in
            await context.tool(name: name, parameters: parameters)
        }
    }
}
