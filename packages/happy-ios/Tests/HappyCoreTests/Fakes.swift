import Foundation
import XCTest
@testable import HappyCore
import HappyWire

/// An HTTP server in a dictionary: routes are "METHOD /path" and answer
/// with a closure, so a test can inspect the request and vary the reply.
final class FakeHTTP: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) throws -> (Int, Data)

    private let lock = NSLock()
    private var routes: [String: Handler] = [:]
    private var _requests: [HTTPRequest] = []

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func requests(_ route: String) -> [HTTPRequest] {
        requests.filter { "\($0.method) \($0.url.path)" == route }
    }

    func on(_ route: String, _ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        routes[route] = handler
    }

    func on<T: Encodable & Sendable>(_ route: String, json: T, status: Int = 200) {
        on(route) { _ in (status, try JSONEncoder().encode(json)) }
    }

    func onRaw(_ route: String, _ body: String, status: Int = 200) {
        on(route) { _ in (status, Data(body.utf8)) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let handler: Handler? = {
            lock.lock()
            defer { lock.unlock() }
            _requests.append(request)
            return routes["\(request.method) \(request.url.path)"]
        }()
        guard let handler else {
            return HTTPResponse(status: 404, body: Data("no route \(request.method) \(request.url.path)".utf8))
        }
        let (status, body) = try handler(request)
        return HTTPResponse(status: status, body: body)
    }
}

extension HTTPRequest {
    func query(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    func jsonBody<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: XCTUnwrap(body))
    }
}

/// A WebSocket whose server side is scripted by the test.
final class FakeWebSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [WebSocketFrame] = []
    private var receivers: [CheckedContinuation<WebSocketFrame, Error>] = []
    private var closed = false
    private var closedByServer = false
    private var _sent: [String] = []
    private var _sentBinary: [Data] = []
    private var _closes: [WebSocketClosure] = []
    private var _closure: WebSocketClosure?
    private var holding = false
    private var heldSenders: [CheckedContinuation<Void, Error>] = []

    /// Text frames sent, in order.
    var sent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    /// Binary frames sent, in order.
    var sentBinary: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _sentBinary
    }

    /// Each close(code:reason:) the client made.
    var closes: [WebSocketClosure] {
        lock.lock()
        defer { lock.unlock() }
        return _closes
    }

    var closure: WebSocketClosure? {
        lock.lock()
        defer { lock.unlock() }
        return _closure
    }

    /// Server → client frame.
    func push(_ text: String) {
        deliver(.text(text))
    }

    /// Server → client binary frame.
    func push(binary: Data) {
        deliver(.binary(binary))
    }

    private func deliver(_ frame: WebSocketFrame) {
        lock.lock()
        if let receiver = receivers.first {
            receivers.removeFirst()
            lock.unlock()
            receiver.resume(returning: frame)
        } else {
            inbox.append(frame)
            lock.unlock()
        }
    }

    /// The server closes the socket: frames it sent first still arrive, then
    /// receives throw and `closure` reports the code.
    func serverClose(code: Int, reason: String) async {
        lock.withLock {
            _closure = WebSocketClosure(code: code, reason: reason)
            closedByServer = true
        }
        await close()
    }

    /// Sends stop completing, like a stalled network, until `releaseSends`.
    func holdSends() {
        lock.withLock { holding = true }
    }

    func releaseSends() {
        let held = lock.withLock {
            holding = false
            defer { heldSenders = [] }
            return heldSenders
        }
        for sender in held { sender.resume() }
    }

    private func waitIfHeld() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if holding {
                heldSenders.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func send(_ text: String) async throws {
        try await waitIfHeld()
        try lock.withLock {
            if closed { throw WebSocketError.closed }
            _sent.append(text)
        }
    }

    func send(binary: Data) async throws {
        try await waitIfHeld()
        try lock.withLock {
            if closed { throw WebSocketError.closed }
            _sentBinary.append(binary)
        }
    }

    func receive() async throws -> String {
        switch try await receiveFrame() {
        case .text(let text): return text
        case .binary: throw WebSocketError.binaryFrameUnsupported
        }
    }

    func receiveFrame() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed, !closedByServer || inbox.isEmpty {
                lock.unlock()
                continuation.resume(throwing: WebSocketError.closed)
            } else if !inbox.isEmpty {
                let frame = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
            } else {
                receivers.append(continuation)
                lock.unlock()
            }
        }
    }

    func close(code: Int, reason: String) async {
        lock.withLock { _closes.append(WebSocketClosure(code: code, reason: reason)) }
        await close()
    }

    func close() async {
        let (pending, held) = lock.withLock {
            closed = true
            holding = false
            defer { receivers = []; heldSenders = [] }
            return (receivers, heldSenders)
        }
        for receiver in pending {
            receiver.resume(throwing: WebSocketError.closed)
        }
        for sender in held {
            sender.resume(throwing: WebSocketError.closed)
        }
    }
}

final class FakeConnector: WebSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sockets: [FakeWebSocket] = []
    private(set) var urls: [URL] = []

    func connect(to url: URL) async throws -> WebSocketConnection {
        let socket = FakeWebSocket()
        lock.withLock {
            sockets.append(socket)
            urls.append(url)
        }
        return socket
    }

    var latest: FakeWebSocket? {
        lock.lock()
        defer { lock.unlock() }
        return sockets.last
    }
}

/// Polls until `condition` holds, for state reached through actors.
func eventually(
    timeout: Duration = .seconds(2),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async throws -> Bool
) async rethrows {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("condition not met in time", file: file, line: line)
}

let testServer = URL(string: "https://api.example.test")!

func testAPI(_ http: FakeHTTP, token: String? = "token-1") -> HappyAPI {
    let api = HappyAPI(serverURL: testServer, clientID: "ios/9.9.9", transport: http)
    return token.map(api.authenticated(token:)) ?? api
}
