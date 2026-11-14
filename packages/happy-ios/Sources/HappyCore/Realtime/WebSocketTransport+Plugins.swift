import Foundation

// Our plugins' additions to the WebSocket transport: binary frames and the
// peer's close code, for the voice stream. The protocol's own requirements
// stay in WebSocketTransport.swift; these defaults keep a text-only socket
// a complete one. Kept here so upstream merges do not conflict there.

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
