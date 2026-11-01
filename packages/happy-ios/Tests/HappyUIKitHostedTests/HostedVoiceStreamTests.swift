#if canImport(UIKit)
import HappyCore
@testable import HappyUI
import XCTest

final class VoicePlaybackBufferTests: XCTestCase {
    private func render(_ buffer: VoicePlaybackBuffer, _ frames: Int) -> (samples: [Float], audible: Bool) {
        var output = [Float](repeating: -1, count: frames)
        let audible = output.withUnsafeMutableBufferPointer { buffer.render(into: $0.baseAddress!, frames: frames) }
        return (output, audible)
    }

    func testAudioPlaysAtItsTimeAndTheClockFollowsTheFramesRendered() {
        let buffer = VoicePlaybackBuffer(rate: 100)
        XCTAssertEqual(buffer.now, 0)
        XCTAssertTrue(buffer.write([1, 2], when: 0.025))
        XCTAssertEqual(render(buffer, 2).samples, [0, 0])
        XCTAssertEqual(buffer.now, 0.02)
        XCTAssertEqual(render(buffer, 3).samples, [1, 2, 0])
        XCTAssertEqual(buffer.now, 0.05)
    }

    func testNothingPlaysTwiceWhenTheTimelineWraps() {
        let buffer = VoicePlaybackBuffer(rate: 100, capacityLog2: 2)
        buffer.write([1, 2, 3, 4], when: 0)
        XCTAssertEqual(render(buffer, 4).samples, [1, 2, 3, 4])
        XCTAssertEqual(render(buffer, 4).samples, [0, 0, 0, 0])
        buffer.write([5, 6], when: 0.09)
        XCTAssertEqual(render(buffer, 4).samples, [0, 5, 6, 0])
    }

    func testAChunkPastTheCapacityIsDroppedAndAudioBehindTheClockIsCut() {
        let buffer = VoicePlaybackBuffer(rate: 100, capacityLog2: 2)
        XCTAssertFalse(buffer.write([1, 2, 3, 4, 5], when: 0))
        XCTAssertEqual(render(buffer, 2).samples, [0, 0])
        XCTAssertTrue(buffer.write([1, 2, 3], when: 0.01))
        XCTAssertEqual(render(buffer, 2).samples, [2, 3])
    }

    func testFlushFadesTheNextFramesAndDropsTheRest() {
        let buffer = VoicePlaybackBuffer(rate: 100)
        buffer.write([Float](repeating: 1, count: 8), when: 0)
        XCTAssertEqual(render(buffer, 1).samples, [1])
        buffer.flush(fadeFrames: 4)
        XCTAssertEqual(render(buffer, 7).samples, [1, 0.75, 0.5, 0.25, 0, 0, 0])
    }

    func testASecondFlushDuringAFadeNeverRaisesTheLevel() {
        let buffer = VoicePlaybackBuffer(rate: 100)
        buffer.write([Float](repeating: 1, count: 8), when: 0)
        buffer.flush(fadeFrames: 4)
        XCTAssertEqual(render(buffer, 2).samples, [1, 0.75])
        buffer.flush(fadeFrames: 4)
        XCTAssertEqual(render(buffer, 3).samples, [0.5, 0.25, 0])
    }

    func testAudioAfterAFlushPlaysAtFullLevel() {
        let buffer = VoicePlaybackBuffer(rate: 100)
        buffer.write([1, 1], when: 0)
        buffer.flush(fadeFrames: 2)
        buffer.write([1, 1], when: 0.04)
        XCTAssertEqual(render(buffer, 6).samples, [1, 0.5, 0, 0, 1, 1])
    }

    func testRenderSaysWhetherAudioIsLeft() {
        let buffer = VoicePlaybackBuffer(rate: 100)
        XCTAssertFalse(render(buffer, 1).audible)
        buffer.write([1], when: 0.01)
        XCTAssertTrue(render(buffer, 1).audible)
        XCTAssertFalse(render(buffer, 1).audible)
    }

    /// The real scheduler on this buffer: frames land back to back after the start target.
    func testSchedulerFramesPlayGaplessAfterTheStartTarget() {
        let buffer = VoicePlaybackBuffer(rate: VoiceStreamAudio.downlinkRate)
        var scheduler = VoicePlaybackScheduler(contextRate: VoiceStreamAudio.downlinkRate)
        let frame = VoiceStreamAudio.data([Int16](repeating: 16384, count: VoiceStreamAudio.downlinkFrameSamples))
        for _ in 0..<2 {
            let chunk = scheduler.push(frame, now: buffer.now)
            XCTAssertTrue(buffer.write(chunk.samples, when: chunk.when))
        }
        // 40 ms is 960 frames, then two 480-frame chunks.
        let samples = render(buffer, 960 + 960 + 2).samples
        XCTAssertEqual(Array(samples[0..<960]), [Float](repeating: 0, count: 960))
        XCTAssertEqual(samples[960], 0, "the restart fades in")
        XCTAssertEqual(Array(samples[(960 + 96)..<(960 + 960)]), [Float](repeating: 0.5, count: 960 - 96))
        XCTAssertEqual(Array(samples[(960 + 960)...]), [0, 0])
    }
}

final class VoiceUplinkPacerTests: XCTestCase {
    private func frame(_ value: UInt8) -> Data { Data([value]) }

    func testBurstComesOutOneAtATimeInOrder() {
        var pacer = VoiceUplinkPacer()
        for value in 0..<5 { pacer.push(frame(UInt8(value))) }
        XCTAssertEqual((0..<6).map { _ in pacer.next() }, (0..<5).map { frame(UInt8($0)) } + [nil])
    }

    func testPastTheLimitTheOldestGo() {
        var pacer = VoiceUplinkPacer(limit: 2)
        for value in 0..<3 { pacer.push(frame(UInt8(value))) }
        XCTAssertEqual(pacer.count, 2)
        XCTAssertEqual(pacer.next(), frame(1))
    }
}

@MainActor
final class StreamVoiceConnectionTests: XCTestCase {
    private let uplink = Data(count: VoiceStreamAudio.uplinkFrameBytes)
    private let downlink = Data(repeating: 1, count: 960)
    private var order: VoiceTestOrder!
    private var socket: VoiceTestSocket!
    private var audio: VoiceTestAudio!
    private var activities: [VoiceActivity] = []
    private var disconnects = 0

    override func setUp() async throws {
        order = VoiceTestOrder()
        socket = VoiceTestSocket(order: order)
        audio = VoiceTestAudio(order: order)
        activities = []
        disconnects = 0
    }

    private func start() async throws -> StreamVoiceConnection {
        let client = VoiceStreamClient(serverURL: URL(string: "https://example.com")!, token: "t", config: VoiceAgentConfig(),
                                       connector: VoiceTestConnector(socket: socket)) { _, _ in VoiceToolResult("ok") }
        return try await StreamVoiceConnection.connect(client: client, audio: audio, activity: { [weak self] in
            self?.activities.append($0)
        }, disconnected: { [weak self] in
            self?.disconnects += 1
        })
    }

    private func connected() async throws -> StreamVoiceConnection {
        socket.onHello = { [socket] in socket?.push(#"{"type":"ready","conversationId":"c"}"#) }
        return try await start()
    }

    private func eventually(_ what: String = "condition", _ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), what)
    }

    func testMuteStopsSendingTheMicrophoneLocally() async throws {
        let connection = try await connected()
        audio.handlers?.frame(uplink)
        await eventually { socket.binary.count == 1 }
        try await connection.setMuted(true)
        audio.handlers?.frame(uplink)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(socket.binary.count, 1)
        try await connection.setMuted(false)
        audio.handlers?.frame(uplink)
        await eventually { socket.binary.count == 2 }
        XCTAssertFalse(socket.texts.contains { $0.contains("mute") }, "the protocol has no mute message")
        await connection.end()
    }

    func testDownlinkAudioPlaysAndFlushClears() async throws {
        let connection = try await connected()
        socket.push(binary: downlink)
        socket.push(#"{"type":"flush"}"#)
        await eventually { order.events.suffix(2) == ["play", "flush"] }
        XCTAssertEqual(audio.played, [downlink])
        await connection.end()
    }

    func testAgentStateAndMicrophoneLevelDriveTheActivity() async throws {
        let connection = try await connected()
        audio.handlers?.speaking(true)
        await eventually { activities.last == .userSpeaking }
        socket.push(#"{"type":"agent","present":true,"state":"speaking"}"#)
        await eventually { activities.last == .agentSpeaking }
        socket.push(#"{"type":"agent","present":true,"state":"listening"}"#)
        await eventually { activities.last == .listening }
        await connection.end()
    }

    func testAMutedMicrophoneDoesNotShowTheUserSpeaking() async throws {
        let connection = try await connected()
        try await connection.setMuted(true)
        audio.handlers?.speaking(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(activities.contains(.userSpeaking))
        await connection.end()
    }

    func testContextAndPromptGoOutUnderTheirTopics() async throws {
        let connection = try await connected()
        socket.push(#"{"type":"agent","present":true}"#)
        try await connection.context("c1")
        try await connection.prompt("p1")
        await eventually { socket.texts.contains { $0.contains("happy.context") && $0.contains("c1") } }
        await eventually { socket.texts.contains { $0.contains("happy.text") && $0.contains("p1") } }
        await connection.end()
    }

    func testServerErrorAfterReadyEndsTheCallAsAFailure() async throws {
        let connection = try await connected()
        socket.push(#"{"type":"error","code":"unavailable","message":"gone"}"#)
        socket.serverClose(code: 1011, reason: "gone")
        await eventually { disconnects == 1 }
        XCTAssertEqual(connection.failure, .connection)
        XCTAssertTrue(order.events.contains("audio stop"))
        await connection.end()
        XCTAssertEqual(disconnects, 1)
    }

    func testAuthFailureDuringTheCallIsAnAuthenticationFailure() async throws {
        let connection = try await connected()
        socket.push(#"{"type":"error","code":"unauthorized","message":"no"}"#)
        socket.serverClose(code: 1008, reason: "no")
        await eventually { disconnects == 1 }
        XCTAssertEqual(connection.failure, .authentication)
        await connection.end()
    }

    func testRoomClosingIsAPlainEnd() async throws {
        let connection = try await connected()
        socket.serverClose(code: 1000, reason: "room closed")
        await eventually { disconnects == 1 }
        XCTAssertNil(connection.failure)
        await connection.end()
    }

    func testAudioGivingOutEndsTheCallAsAFailure() async throws {
        let connection = try await connected()
        audio.handlers?.failed()
        await eventually { disconnects == 1 }
        XCTAssertEqual(connection.failure, .connection)
        XCTAssertTrue(order.events.contains("end sent"))
        await connection.end()
    }

    func testEndStopsTheMicrophoneBeforeEndingTheCallAndIsNotADisconnect() async throws {
        let connection = try await connected()
        await connection.end()
        let stop = try XCTUnwrap(order.events.firstIndex(of: "audio stop"))
        let end = try XCTUnwrap(order.events.firstIndex(of: "end sent"))
        XCTAssertLessThan(stop, end)
        XCTAssertEqual(disconnects, 0)
        await connection.end()
    }

    func testUnauthorizedBeforeReadyFailsTheStartAndReleasesTheAudio() async throws {
        socket.onHello = { [socket] in socket?.push(#"{"type":"error","code":"unauthorized","message":"no"}"#) }
        do {
            _ = try await start()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        XCTAssertTrue(order.events.contains("audio stop"))
    }

    func testAudioFailingToStartFailsTheStartAndClosesTheSocket() async throws {
        // Held until the socket is open, or the start could fail before there is one to close.
        let (hello, helloSent) = AsyncStream.makeStream(of: Void.self)
        socket.onHello = { helloSent.finish() }
        audio.onStart = { _ in for await _ in hello {} }
        audio.startError = VoiceAudioError.noMicrophone
        let began = ContinuousClock.now
        do {
            _ = try await start()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? VoiceAudioError, .noMicrophone)
        }
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(5), "must not wait out the handshake's 15 s timeout")
        XCTAssertTrue(order.events.contains("audio stop"))
        await eventually("socket closed") { order.events.contains("socket closed") }
    }

    /// `ready` never comes, so only the failure can end this start before its timeout.
    func testAudioGivingOutDuringTheHandshakeFailsTheStartAndClosesTheSocket() async throws {
        let starting = Task { try await start() }
        await eventually("handshake waiting, audio started") {
            order.events.contains("audio started") && socket.texts.contains { $0.contains(#""type":"hello""#) }
        }
        audio.handlers?.failed()
        do {
            _ = try await starting.value
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? VoiceAudioError, .noMicrophone)
        }
        XCTAssertTrue(order.events.contains("audio stop"))
        await eventually("socket closed") { order.events.contains("socket closed") }
        XCTAssertEqual(disconnects, 0, "the start reports it, not a disconnect")
    }

    /// The handshake is done and nothing is left to interrupt, so the failure
    /// has to be remembered until the start finishes.
    func testAudioGivingOutAfterReadyButBeforeItsStartReturnsFailsTheStart() async throws {
        socket.onHello = { [socket] in socket?.push(#"{"type":"ready","conversationId":"c"}"#) }
        audio.onStart = { [socket, uplink] handlers in
            // The client only takes frames once it is ready.
            while socket?.binary.isEmpty == true {
                handlers.frame(uplink)
                try? await Task.sleep(for: .milliseconds(5))
            }
            handlers.failed()
        }
        do {
            _ = try await start()
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? VoiceAudioError, .noMicrophone)
        }
        XCTAssertTrue(order.events.contains("audio stop"))
        await eventually("socket closed") { order.events.contains("socket closed") }
        XCTAssertEqual(disconnects, 0, "the start reports it, not a disconnect")
    }

    func testFramesBeforeReadyAreNotSent() async throws {
        socket.onHello = { [audio, uplink, socket] in
            audio?.handlers?.frame(uplink)
            socket?.push(#"{"type":"ready","conversationId":"c"}"#)
        }
        let connection = try await start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(socket.binary.count, 0)
        await connection.end()
    }

    func testCoordinatorHasNoBackendWithoutACall() {
        VoiceCoordinator.shared.stop()
        XCTAssertNil(VoiceCoordinator.shared.activeBackend)
    }
}

private final class VoiceTestOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var events: [String] { lock.withLock { values } }
    func add(_ event: String) { lock.withLock { values.append(event) } }
}

private final class VoiceTestAudio: VoiceAudio, @unchecked Sendable {
    private let lock = NSLock()
    private let order: VoiceTestOrder
    private var _handlers: VoiceAudioHandlers?
    private var _played: [Data] = []
    private var _startError: Error?
    private var _onStart: (@Sendable (VoiceAudioHandlers) async -> Void)?

    init(order: VoiceTestOrder) { self.order = order }

    var handlers: VoiceAudioHandlers? { lock.withLock { _handlers } }
    var played: [Data] { lock.withLock { _played } }
    var startError: Error? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }
    /// Runs inside `start`, before it returns or throws.
    var onStart: (@Sendable (VoiceAudioHandlers) async -> Void)? {
        get { lock.withLock { _onStart } }
        set { lock.withLock { _onStart = newValue } }
    }

    func start(_ handlers: VoiceAudioHandlers) async throws {
        lock.withLock { _handlers = handlers }
        await onStart?(handlers)
        if let startError { throw startError }
        order.add("audio started")
    }
    func play(_ frame: Data) {
        lock.withLock { _played.append(frame) }
        order.add("play")
    }
    func flush() { order.add("flush") }
    func stop() async { order.add("audio stop") }
}

private struct VoiceTestConnector: WebSocketConnector {
    let socket: VoiceTestSocket
    func connect(to url: URL) async throws -> WebSocketConnection { socket }
}

private final class VoiceTestSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let order: VoiceTestOrder
    private var inbox: [WebSocketFrame] = []
    private var waiting: CheckedContinuation<WebSocketFrame, Error>?
    private var isClosed = false
    private var _texts: [String] = []
    private var _binary: [Data] = []
    private var _closure: WebSocketClosure?
    private var _onHello: (@Sendable () -> Void)?

    init(order: VoiceTestOrder) { self.order = order }

    var texts: [String] { lock.withLock { _texts } }
    var binary: [Data] { lock.withLock { _binary } }
    var closure: WebSocketClosure? { lock.withLock { _closure } }
    var onHello: (@Sendable () -> Void)? {
        get { lock.withLock { _onHello } }
        set { lock.withLock { _onHello = newValue } }
    }

    func push(_ text: String) { deliver(.text(text)) }
    func push(binary: Data) { deliver(.binary(binary)) }

    private func deliver(_ frame: WebSocketFrame) {
        let receiver: CheckedContinuation<WebSocketFrame, Error>? = lock.withLock {
            guard let waiting else {
                inbox.append(frame)
                return nil
            }
            self.waiting = nil
            return waiting
        }
        receiver?.resume(returning: frame)
    }

    func serverClose(code: Int, reason: String) {
        let receiver: CheckedContinuation<WebSocketFrame, Error>? = lock.withLock {
            _closure = WebSocketClosure(code: code, reason: reason)
            isClosed = true
            let receiver = waiting
            waiting = nil
            return receiver
        }
        receiver?.resume(throwing: WebSocketError.closed)
    }

    func send(_ text: String) async throws {
        lock.withLock { _texts.append(text) }
        if text.contains(#""type":"end""#) { order.add("end sent") }
        if text.contains(#""type":"hello""#) { onHello?() }
    }

    func send(binary: Data) async throws { lock.withLock { _binary.append(binary) } }

    func receive() async throws -> String {
        guard case .text(let text) = try await receiveFrame() else { throw WebSocketError.binaryFrameUnsupported }
        return text
    }

    func receiveFrame() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<WebSocketFrame, Error>? = lock.withLock {
                if !inbox.isEmpty { return .success(inbox.removeFirst()) }
                if isClosed { return .failure(WebSocketError.closed) }
                waiting = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func close() async { await close(code: 1000, reason: "end") }

    func close(code: Int, reason: String) async {
        order.add("socket closed")
        let receiver: CheckedContinuation<WebSocketFrame, Error>? = lock.withLock {
            isClosed = true
            let receiver = waiting
            waiting = nil
            return receiver
        }
        receiver?.resume(throwing: WebSocketError.closed)
    }
}
#endif
