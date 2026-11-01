import Foundation
@testable import HappyCore
import XCTest

/// A socket as it was before binary frames: text and close, nothing else.
private final class TextOnlySocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var _closes = 0
    var closes: Int { lock.withLock { _closes } }
    func send(_ text: String) async throws {}
    func receive() async throws -> String { "text" }
    func close() async { lock.withLock { _closes += 1 } }
}

final class WebSocketFrameTests: XCTestCase {
    func testTextOnlySocketGetsDefaults() async throws {
        let socket = TextOnlySocket()
        let frame = try await socket.receiveFrame()
        XCTAssertEqual(frame, .text("text"))
        do {
            try await socket.send(binary: Data([1]))
            XCTFail("a text socket cannot send binary")
        } catch {
            XCTAssertEqual(error as? WebSocketError, .binaryFrameUnsupported)
        }
        await socket.close(code: 1000, reason: "end")
        XCTAssertEqual(socket.closes, 1)
        XCTAssertNil(socket.closure)
    }

    func testMeteredSocketCountsBinaryFramesOnItsChannel() async throws {
        let metrics = ConnectionMetrics()
        let base = FakeConnector()
        let connector = MeteredWebSocketConnector(base: base, metrics: metrics, channel: .voice)
        let socket = try await connector.connect(to: URL(string: "wss://example.test/v1/voice/stream")!)
        let fake = try XCTUnwrap(base.latest)

        try await socket.send(binary: Data(count: 640))
        try await socket.send("hello")
        fake.push(binary: Data(count: 960))
        fake.push("text")
        let binary = try await socket.receiveFrame()
        let text = try await socket.receiveFrame()
        XCTAssertEqual(binary, .binary(Data(count: 960)))
        XCTAssertEqual(text, .text("text"))
        XCTAssertEqual(fake.sentBinary, [Data(count: 640)])
        XCTAssertEqual(fake.sent, ["hello"])

        await fake.serverClose(code: 1011, reason: "boom")
        XCTAssertEqual(socket.closure, WebSocketClosure(code: 1011, reason: "boom"))
        do {
            _ = try await socket.receiveFrame()
            XCTFail("a closed socket throws")
        } catch {}

        let totals = await metrics.snapshot().totals
        XCTAssertEqual(totals.count(.bytesSent, .voice), 645)
        XCTAssertEqual(totals.count(.bytesReceived, .voice), 964)
        XCTAssertEqual(totals.count(.connectionsOpened, .voice), 1)
        XCTAssertEqual(totals.count(.connectionsClosed, .voice), 1)
        XCTAssertEqual(ConnectionChannel.voice.name, "Voice")
    }

    func testMeteredSocketPassesCloseCodeAndReason() async throws {
        let metrics = ConnectionMetrics()
        let base = FakeConnector()
        let connector = MeteredWebSocketConnector(base: base, metrics: metrics, channel: .voice)
        let socket = try await connector.connect(to: URL(string: "wss://example.test/")!)
        await socket.close(code: 1000, reason: "end")
        XCTAssertEqual(base.latest?.closes, [WebSocketClosure(code: 1000, reason: "end")])
        let totals = await metrics.snapshot().totals
        XCTAssertEqual(totals.count(.connectionsClosed, .voice), 1)
    }

    func testSocketKeepsFramesDeliveredBeforeTheClose() async throws {
        let socket = FakeWebSocket()
        socket.push("last words")
        await socket.serverClose(code: 1008, reason: "unauthorized")
        let frame = try await socket.receiveFrame()
        XCTAssertEqual(frame, .text("last words"))
    }
}
