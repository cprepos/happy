import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One frame off a WebSocket.
public enum WebSocketFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

/// The close the peer sent, as the socket reports it.
public struct WebSocketClosure: Equatable, Sendable {
    public let code: Int
    public let reason: String

    public init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }
}

/// One open WebSocket. Text frames are what every socket carries; binary
/// frames and close codes are for the sockets that use them, and the defaults
/// below keep a text-only socket a complete one.
public protocol WebSocketConnection: Sendable {
    func send(_ text: String) async throws
    /// The next text frame. Throws when the socket closes.
    func receive() async throws -> String
    func close() async

    func send(binary: Data) async throws
    /// The next frame of either kind. Throws when the socket closes.
    func receiveFrame() async throws -> WebSocketFrame
    func close(code: Int, reason: String) async
    /// How the peer closed the socket; nil while open or when it is unknown.
    var closure: WebSocketClosure? { get }
}

extension WebSocketConnection {
    public func send(binary: Data) async throws {
        throw WebSocketError.binaryFrameUnsupported
    }

    public func receiveFrame() async throws -> WebSocketFrame {
        .text(try await receive())
    }

    public func close(code: Int, reason: String) async {
        await close()
    }

    public var closure: WebSocketClosure? { nil }
}

public protocol WebSocketConnector: Sendable {
    func connect(to url: URL) async throws -> WebSocketConnection
}

public enum WebSocketError: Error, Equatable, Sendable {
    case binaryFrameUnsupported
    case closed
}

public struct URLSessionWebSocketConnector: WebSocketConnector {
    let session: URLSession

    public init() {
        session = NetworkSession.make()
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func connect(to url: URL) async throws -> WebSocketConnection {
        let task = session.webSocketTask(with: url)
        // Session metadata can be large (see the server's maxHttpBufferSize).
        task.maximumMessageSize = 8 * 1024 * 1024
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    // URLSessionWebSocketTask is safe to use from any thread.
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data:
            throw WebSocketError.binaryFrameUnsupported
        @unknown default:
            throw WebSocketError.binaryFrameUnsupported
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }

    func send(binary: Data) async throws {
        try await task.send(.data(binary))
    }

    func receiveFrame() async throws -> WebSocketFrame {
        switch try await task.receive() {
        case .string(let text):
            return .text(text)
        case .data(let data):
            return .binary(data)
        @unknown default:
            throw WebSocketError.binaryFrameUnsupported
        }
    }

    func close(code: Int, reason: String) async {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: Data(reason.utf8))
    }

    var closure: WebSocketClosure? {
        guard task.closeCode != .invalid else { return nil }
        return WebSocketClosure(code: task.closeCode.rawValue, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }
}
