import Foundation
import HappyWire

public enum RealtimeStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error
    /// The server refused this account's credentials several times in a
    /// row. The same token cannot do better, so the socket stops spinning
    /// and tries again only now and then.
    case unauthorized
}

public enum RealtimeEvent: Equatable, Sendable {
    case status(RealtimeStatus)
    /// The namespace handshake completed. Socket.IO connection-state
    /// recovery is off on the server, so every connect is a fresh session
    /// and anything sent while disconnected was missed: run a delta sync.
    case connected
    case event(name: String, payload: JSONValue?)
}

public enum SocketIOError: Error, Equatable, Sendable {
    case notConnected
    case protocolViolation(String)
    case connectRejected(String?)
    case ackTimeout
    case closed
}

/// A minimal Socket.IO client for the default namespace over WebSocket:
/// handshake with an auth payload, heartbeat replies, events in, events and
/// acknowledged calls out, and reconnects with backoff
/// (1 s to 5 s, as happy-app's socket.io-client is configured).
public actor SocketIOClient {
    public nonisolated let events: AsyncStream<RealtimeEvent>
    public private(set) var status: RealtimeStatus = .disconnected

    private let url: URL
    private let connector: WebSocketConnector
    private let auth: @Sendable () async -> JSONValue
    private let backoff: Backoff
    private let sleep: InvalidateSync.Sleep
    private let handshakeTimeout: Duration
    private let continuation: AsyncStream<RealtimeEvent>.Continuation

    /// Connect refusals in a row that make the status `.unauthorized`.
    static let rejectionLimit = 3
    /// The pause between attempts once refused that many times.
    static let rejectedRetry: Duration = .seconds(60)

    private var wantsConnection = false
    /// Bumped by every disconnect. A loop, and the socket it opened, belong
    /// to the generation it started in; once that has passed, whatever it
    /// still says (a status, a socket, an event) is ignored, so overlapping
    /// reconnects cannot write over the newer connection.
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var connection: WebSocketConnection?
    private var lastPacketAt = ContinuousClock.now
    /// Connect refusals since the last good connect.
    private var rejections = 0
    private var nextAckId = 0
    private var pendingAcks: [Int: CheckedContinuation<[JSONValue], Error>] = [:]

    public init(
        url: URL,
        connector: WebSocketConnector = URLSessionWebSocketConnector(),
        backoff: Backoff = Backoff(initial: .seconds(1), maximum: .seconds(5)),
        sleep: @escaping InvalidateSync.Sleep = InvalidateSync.taskSleep,
        handshakeTimeout: Duration = .seconds(20),
        auth: @escaping @Sendable () async -> JSONValue
    ) {
        self.url = url
        self.connector = connector
        self.backoff = backoff
        self.sleep = sleep
        self.handshakeTimeout = handshakeTimeout
        self.auth = auth
        // Unbounded: a burst while the reader is busy (a big catch-up) must
        // not drop an update; a dropped one is a chat that stays stale.
        (events, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        continuation.finish()
    }

    // MARK: Control

    public func connect() {
        wantsConnection = true
        guard loop == nil else { return }
        let generation = self.generation
        loop = Task { await self.runLoop(generation: generation) }
    }

    public func disconnect() async {
        // Everything is let go of before the first await: a connect or
        // reconnect that runs while the old socket is still closing starts
        // a clean loop, and the old loop's late writes are ignored.
        wantsConnection = false
        generation += 1
        loop?.cancel()
        loop = nil
        let old = connection
        connection = nil
        failPendingAcks(SocketIOError.closed)
        setStatus(.disconnected)
        if let old {
            try? await old.send(EngineIOPacket.message(SocketIOPacket.disconnect.text).text)
            await old.close()
        }
    }

    /// How long the current socket has gone without a packet from the
    /// server; nil with no socket. A socket left over from the background
    /// can look connected and be dead.
    public var silence: Duration? {
        connection == nil ? nil : ContinuousClock.now - lastPacketAt
    }

    /// Drops the current socket and connects again, e.g. after a token change.
    public func reconnect() async {
        await disconnect()
        connect()
    }

    // MARK: Sending

    public func emit(_ name: String, _ payload: JSONValue) async throws {
        guard status == .connected, let connection else { throw SocketIOError.notConnected }
        try await connection.send(EngineIOPacket.message(SocketIOPacket.event(name: name, arguments: [payload], ackId: nil).text).text)
    }

    /// Emits and waits for the server's acknowledgement. Fails instead of
    /// waiting forever if the socket drops or the server never answers.
    public func emitWithAck(_ name: String, _ payload: JSONValue, timeout: Duration = .seconds(50)) async throws -> [JSONValue] {
        guard status == .connected, let connection else { throw SocketIOError.notConnected }
        let id = nextAckId
        nextAckId += 1
        let text = EngineIOPacket.message(SocketIOPacket.event(name: name, arguments: [payload], ackId: id).text).text
        let sleep = self.sleep
        return try await withCheckedThrowingContinuation { continuation in
            pendingAcks[id] = continuation
            Task {
                do {
                    try await connection.send(text)
                } catch {
                    self.failAck(id, error)
                }
            }
            Task {
                try? await sleep(timeout)
                self.failAck(id, SocketIOError.ackTimeout)
            }
        }
    }

    // MARK: Connection loop

    /// Whether a loop of `generation` still owns the client.
    private func isCurrent(_ generation: Int) -> Bool {
        wantsConnection && generation == self.generation
    }

    private func runLoop(generation: Int) async {
        var attempt = 0
        while isCurrent(generation) && !Task.isCancelled {
            setStatus(.connecting)
            var failure: Error?
            do {
                try await runConnection(generation: generation) { attempt = 0 }
            } catch {
                failure = error
            }
            // After a disconnect the socket and acks are already let go of,
            // and a reconnect's new loop may hold its own by now.
            guard isCurrent(generation) && !Task.isCancelled else { break }
            connection = nil
            failPendingAcks(SocketIOError.closed)
            if case .connectRejected? = failure as? SocketIOError { rejections += 1 }
            let unauthorized = rejections >= Self.rejectionLimit
            let next: RealtimeStatus = if unauthorized { .unauthorized } else if failure != nil { .error } else { .disconnected }
            setStatus(next)
            attempt += 1
            try? await sleep(unauthorized ? Self.rejectedRetry : backoff.delay(attempt: attempt))
        }
    }

    private func runConnection(generation: Int, onConnected: () -> Void) async throws {
        let connection = try await connector.connect(to: url)
        // A disconnect while this was connecting had no socket to close.
        guard isCurrent(generation) && !Task.isCancelled else {
            await connection.close()
            return
        }
        self.connection = connection
        defer { Task { await connection.close() } }

        // Watched from before the Engine.IO open: a server that accepts the
        // socket and then says nothing, or never answers the namespace
        // CONNECT, gets `handshakeTimeout` and is then dropped, rather than
        // leaving the client "connecting" until the system gives up.
        lastPacketAt = .now
        let deadline = startHandshakeDeadline(generation: generation, connection: connection)
        defer { deadline.cancel() }

        guard case .open(let handshake)? = EngineIOPacket(text: try await connection.receive()) else {
            throw SocketIOError.protocolViolation("expected Engine.IO open")
        }
        guard isCurrent(generation) else { return }
        lastPacketAt = .now
        let watchdog = startWatchdog(handshake: handshake, generation: generation, connection: connection)
        defer { watchdog.cancel() }

        let credentials = await auth()
        guard isCurrent(generation) else { return }
        try await connection.send(EngineIOPacket.message(SocketIOPacket.connect(credentials).text).text)

        while !Task.isCancelled {
            let text = try await connection.receive()
            // A newer connection owns the client: this one says nothing more.
            guard isCurrent(generation) else { return }
            lastPacketAt = .now
            guard let packet = EngineIOPacket(text: text) else { continue }
            switch packet {
            case .ping:
                try await connection.send(EngineIOPacket.pong.text)
            case .close:
                throw SocketIOError.closed
            case .message(let payload):
                guard let message = SocketIOPacket(text: payload) else { continue }
                switch message {
                case .connect:
                    deadline.cancel()
                    rejections = 0
                    setStatus(.connected)
                    onConnected()
                    continuation.yield(.connected)
                case .connectError(let reason):
                    throw SocketIOError.connectRejected(reason?["message"]?.stringValue)
                case .disconnect:
                    throw SocketIOError.closed
                case .event(let name, let arguments, _):
                    continuation.yield(.event(name: name, payload: arguments.first))
                case .ack(let id, let arguments):
                    pendingAcks.removeValue(forKey: id)?.resume(returning: arguments)
                }
            case .open, .pong, .noop:
                break
            }
        }
    }

    /// Closes `connection` unless its namespace CONNECT is acknowledged
    /// within `handshakeTimeout`; cancelled once it is.
    private func startHandshakeDeadline(generation: Int, connection: WebSocketConnection) -> Task<Void, Never> {
        let timeout = handshakeTimeout
        return Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            guard self.isCurrent(generation) else { return }
            await connection.close()
        }
    }

    /// The server pings every `pingInterval`; if nothing arrives for
    /// interval + timeout the link is dead even if TCP has not noticed.
    private func startWatchdog(handshake: EngineIOHandshake, generation: Int, connection: WebSocketConnection) -> Task<Void, Never> {
        let limit = Duration.milliseconds(handshake.pingInterval + handshake.pingTimeout)
        return Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard self.isCurrent(generation) else { return }
                if ContinuousClock.now - self.lastPacketAt > limit {
                    await connection.close()
                    return
                }
            }
        }
    }

    // MARK: Helpers

    private func setStatus(_ newStatus: RealtimeStatus) {
        guard status != newStatus else { return }
        status = newStatus
        continuation.yield(.status(newStatus))
    }

    private func failAck(_ id: Int, _ error: Error) {
        pendingAcks.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failPendingAcks(_ error: Error) {
        let pending = pendingAcks
        pendingAcks = [:]
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }
}
