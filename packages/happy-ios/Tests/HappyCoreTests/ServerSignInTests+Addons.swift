import Foundation
import XCTest
import HappyCrypto
import HappyWire
@testable import HappyCore

// Our WebSocket tunnel and tunnel-support tests, kept out of
// ServerSignInTests.swift so upstream merges do not conflict there.

/// A byte stream whose far side the test scripts. A copy of
/// ServerSignInTests.swift's private `Pipe`.
private final class Pipe: BrowserStream, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Data]
    private(set) var written: [Data] = []
    let authority = "happy.acme.example"
    init(_ reads: [Data]) { pending = reads }
    func read(maximumBytes: Int) async throws -> Data { lock.withLock { pending.isEmpty ? Data() : pending.removeFirst() } }
    func write(_ data: Data) async throws { lock.withLock { written.append(data) } }
    func close() async {}
    var writes: [Data] { lock.withLock { written } }
}

final class WebSocketTunnelAddonsTests: XCTestCase {
    private let key = Data(repeating: 9, count: 16)
    private let mask: @Sendable () -> [UInt8] = { [1, 2, 3, 4] }
    private var accept: String { Hashing.sha1(Data((key.base64EncodedString() + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)).base64EncodedString() }

    func testAnUpgradeInsideATunnelNamesItsHostAndProtocolAndNoToken() async throws {
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: binary\r\n\r\n"
        let pipe = Pipe([Data(head.utf8)])
        _ = try await WebSocketTunnel.open(pipe, path: "/live/abc/vnc/websockify", credential: nil, host: "192.168.2.10:7790",
                                           protocols: ["binary"], key: key, mask: mask, keepalive: false)
        let request = String(decoding: pipe.writes[0], as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("GET /live/abc/vnc/websockify HTTP/1.1\r\nHost: 192.168.2.10:7790\r\n"))
        XCTAssertFalse(request.contains("Authorization"))
        XCTAssertTrue(request.contains("\r\nSec-WebSocket-Version: 13\r\n"))
        XCTAssertTrue(request.contains("\r\nSec-WebSocket-Protocol: binary\r\n"))
        XCTAssertTrue(request.hasSuffix("\r\n\r\n"))
        // Header injection is refused before anything is written.
        let bad = Pipe([Data(head.utf8)])
        await XCTAssertThrowsAsync(try await WebSocketTunnel.open(bad, path: "/x", credential: nil, host: "a\r\nX: y", key: key, keepalive: false))
        await XCTAssertThrowsAsync(try await WebSocketTunnel.open(bad, path: "/x", credential: nil, protocols: ["a b"], key: key, keepalive: false))
        XCTAssertTrue(bad.writes.isEmpty)
    }
}

final class TunnelSupportAddonsTests: XCTestCase {
    /// Only an edge's settled answer blocks: a 5xx from whatever fronts the
    /// daemon, or a reply with no readable status (a dropped or timed-out
    /// head), is a passing failure and the next preview tries again.
    func testAPassingFailureNeverBlocksTheOrigin() {
        let support = TunnelSupport()
        let origin = "https://flaky.example"
        let gateway = AgentHTTPTransport.classify(TunnelRefusal(status: 504, contentType: "text/html", body: Data()), origin: origin, support: support)
        XCTAssertEqual(gateway as? BrowserError, .upstream(504))
        let dropped = AgentHTTPTransport.classify(TunnelRefusal(status: 0, contentType: nil, body: Data()), origin: origin, support: support)
        XCTAssertEqual(dropped as? BrowserError, .unavailable)
        XCTAssertNil(support.mode(origin))
        support.set(.connect, for: origin)
        XCTAssertEqual(support.mode(origin), .connect)
    }

    /// A block lasts a minute, and `forget()` lifts it at once.
    func testABlockExpiresAndForgetLiftsIt() {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Date(timeIntervalSince1970: 1_000_000)
            var now: Date { lock.withLock { value } }
            func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
        }
        let clock = Clock()
        let support = TunnelSupport(now: { clock.now })
        let origin = "https://edge.example"
        let edge = AgentHTTPTransport.classify(TunnelRefusal(status: 405, contentType: "text/html", body: Data()), origin: origin, support: support)
        XCTAssertEqual(edge as? BrowserError, .tunnelsBlocked)
        clock.advance(TunnelSupport.blockedFor - 1)
        XCTAssertEqual(support.mode(origin), .blocked)
        support.set(.connect, for: origin)
        XCTAssertEqual(support.mode(origin), .blocked, "a block isn't overwritten while it lasts")
        clock.advance(1)
        XCTAssertNil(support.mode(origin), "past its minute the origin is learned again")
        support.set(.blocked, for: origin)
        XCTAssertEqual(support.mode(origin), .blocked)
        support.forget()
        XCTAssertNil(support.mode(origin))
    }
}
