import Foundation
import HappyWire

/// How an HTTPS server's proxy tunnels open (edge SSO contract §4), learned
/// per origin so a blocked server isn't tried again and again:
///
/// - `webSocket` when health reports `capabilities.webSocketTunnels`;
/// - otherwise CONNECT, until something in front of the daemon definitively
///   refuses it (an answer below 500 that isn't Happy's JSON), which makes
///   it `blocked`: previews say so instead of retrying.
///
/// A timeout, a dropped connection or a 5xx never blocks: those are the
/// network or the server having a bad moment, not the edge's policy. A
/// block lasts `blockedFor`, and `forget()` (foreground, network change,
/// refresh) clears everything learned.
public final class TunnelSupport: @unchecked Sendable {
    enum Mode: Equatable, Sendable { case webSocket, connect, blocked }

    public static let shared = TunnelSupport()
    /// How long a definitive refusal keeps an origin blocked.
    static let blockedFor: TimeInterval = 60

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var modes: [String: Mode] = [:]
    private var blockedAt: [String: Date] = [:]

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func mode(_ origin: String) -> Mode? {
        lock.withLock {
            expireLocked(origin)
            return modes[origin]
        }
    }

    func set(_ mode: Mode, for origin: String) {
        lock.withLock {
            expireLocked(origin)
            // Blocked stays blocked until its time runs out or `forget()`.
            guard modes[origin] != .blocked else { return }
            modes[origin] = mode
            if mode == .blocked { blockedAt[origin] = now() }
        }
    }

    /// Clears every origin's mode, so the next tunnel learns afresh.
    public func forget() {
        lock.withLock {
            modes.removeAll()
            blockedAt.removeAll()
        }
    }

    /// Whether a refusal that is neither sign-in nor the daemon's own error
    /// is the edge's settled answer: it said something, below 500.
    static func isDefinitive(status: Int) -> Bool { (200..<500).contains(status) }

    /// Called with `lock` held.
    private func expireLocked(_ origin: String) {
        guard modes[origin] == .blocked, let since = blockedAt[origin],
              now().timeIntervalSince(since) >= Self.blockedFor else { return }
        modes[origin] = nil
        blockedAt[origin] = nil
    }
}

extension AgentHTTPTransport {
    /// Over Tailcat the tunnel is CONNECT to the daemon itself. Over HTTPS
    /// it goes through whatever fronts the daemon, so it is the WebSocket
    /// twin when the daemon has one.
    public func proxyTunnel(_ path: String, credential: String) async throws -> any BrowserStream {
        guard let publicUrl else { return try await connectTunnel(path, credential: credential) }
        let origin = try AgentOrigin(publicUrl).value
        let support = TunnelSupport.shared
        var mode = support.mode(origin)
        if mode == nil {
            mode = try await webSocketTunnels(credential: credential) ? .webSocket : .connect
            support.set(mode!, for: origin)
            mode = support.mode(origin)
        }
        switch mode {
        case .blocked: throw BrowserError.tunnelsBlocked
        case .webSocket: return try await webSocketTunnel(path, credential: credential, origin: origin)
        default: return try await publicConnectTunnel(path, credential: credential, origin: origin)
        }
    }

    /// `capabilities.webSocketTunnels` from health.
    private func webSocketTunnels(credential: String) async throws -> Bool {
        let response = try await request(method: "GET", path: "/v0/health", credential: credential, body: nil, headers: [:], category: .query)
        if SignInRequired.check(response) {
            throw TunnelRefusal(status: response.status, contentType: response.headers["content-type"], body: response.body)
        }
        guard response.status == 200 else { throw BrowserError.unavailable }
        struct Health: Decodable { struct Capabilities: Decodable { let webSocketTunnels: Bool? }; let capabilities: Capabilities? }
        return (try? JSONDecoder().decode(Health.self, from: response.body))?.capabilities?.webSocketTunnels == true
    }

    private func webSocketTunnel(_ path: String, credential: String, origin: String) async throws -> any BrowserStream {
        let stream = try await browserConnection()
        do {
            return try await WebSocketTunnel.open(stream, path: path + "/websocket", credential: credential)
        } catch let refusal as TunnelRefusal {
            throw Self.classify(refusal, origin: origin)
        } catch {
            await stream.close()
            throw error
        }
    }

    /// CONNECT through the server's edge, telling its refusal apart from
    /// the daemon's.
    private func publicConnectTunnel(_ path: String, credential: String, origin: String) async throws -> any BrowserStream {
        let stream = try await browserConnection()
        do {
            try await stream.write(Data("CONNECT \(path) HTTP/1.1\r\nHost: \(stream.authority)\r\nAuthorization: Bearer \(credential)\r\n\r\n".utf8))
            let head: BrowserHTTPHead, rest: Data
            do { (head, rest) = try await BrowserRelay.head(stream) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Dropped or timed out without an answer. That may be the
                // edge, but it may as well be the network: never a block.
                throw BrowserError.unavailable
            }
            let status = Int(head.line.split(separator: " ").dropFirst().first ?? "") ?? 0
            guard status == 200, rest.isEmpty else {
                var body = rest
                if let length = head.value("content-length").flatMap(Int.init), length <= 65536 {
                    while body.count < length, let bytes = try? await stream.read(maximumBytes: 65536), !bytes.isEmpty { body.append(bytes) }
                }
                throw Self.classify(TunnelRefusal(status: status, contentType: head.value("content-type"), body: body), origin: origin)
            }
            return stream
        } catch {
            await stream.close()
            throw error
        }
    }

    /// A refusal that needs signing in goes up as it is; the daemon's own
    /// is an ordinary upstream answer; a 5xx or an unreadable status is a
    /// passing failure; anything else is the edge refusing tunnels.
    static func classify(_ refusal: TunnelRefusal, origin: String, support: TunnelSupport = .shared) -> any Error {
        if refusal.requiresSignIn { return refusal }
        if refusal.isHappyError { return BrowserError.upstream(refusal.status) }
        guard TunnelSupport.isDefinitive(status: refusal.status) else {
            return refusal.status >= 500 ? BrowserError.upstream(refusal.status) : BrowserError.unavailable
        }
        support.set(.blocked, for: origin)
        return BrowserError.tunnelsBlocked
    }
}
