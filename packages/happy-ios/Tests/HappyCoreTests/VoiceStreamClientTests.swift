import Foundation
@testable import HappyCore
import HappyWire
import XCTest

private let frame640 = Data(repeating: 1, count: 640)

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}

private final class FailingConnector: WebSocketConnector, @unchecked Sendable {
    struct Failure: Error {}
    func connect(to url: URL) async throws -> WebSocketConnection { throw Failure() }
}

final class VoiceStreamClientTests: XCTestCase {
    private let connector = FakeConnector()
    private let events = Recorder<VoiceStreamEvent>()
    private let tools = Recorder<String>()

    private func client(
        serverURL: String = "https://example.test",
        config: VoiceAgentConfig = VoiceAgentConfig(systemPrompt: "prompt", firstMessage: "hi", initialContext: "ctx", language: "pl", sessionId: "s"),
        readyTimeout: Duration = .seconds(15),
        voiceMessageCount: Int = 0,
        toolResult: VoiceToolResult = VoiceToolResult("sent")
    ) -> VoiceStreamClient {
        let tools = tools
        let client = VoiceStreamClient(serverURL: URL(string: serverURL)!, token: "secret-token", config: config, connector: connector,
                                       readyTimeout: readyTimeout, voiceMessageCount: voiceMessageCount) { name, parameters in
            tools.append("\(name) \(String(decoding: parameters, as: UTF8.self))")
            return toolResult
        }
        let events = events
        let stream = client.events
        Task { for await event in stream { events.append(event) } }
        return client
    }

    private func socket() async throws -> FakeWebSocket {
        let connector = connector
        await eventually { connector.latest != nil }
        let socket = try XCTUnwrap(connector.latest)
        await eventually { !socket.sent.isEmpty }
        return socket
    }

    /// A client whose call is ready, nothing else sent but hello.
    private func readyClient(
        config: VoiceAgentConfig = VoiceAgentConfig(systemPrompt: "prompt", firstMessage: "hi", initialContext: "ctx", language: "pl", sessionId: "s"),
        voiceMessageCount: Int = 0,
        toolResult: VoiceToolResult = VoiceToolResult("sent")
    ) async throws -> (VoiceStreamClient, FakeWebSocket) {
        let client = client(config: config, voiceMessageCount: voiceMessageCount, toolResult: toolResult)
        let starting = Task { try await client.start() }
        let socket = try await socket()
        socket.push(#"{"type":"ready","conversationId":"conv"}"#)
        _ = try await starting.value
        return (client, socket)
    }

    private func parsed(_ text: String) throws -> JSONValue {
        try JSONValue.decode(Data(text.utf8))
    }

    private func texts(_ socket: FakeWebSocket) throws -> [JSONValue] {
        try socket.sent.map { try parsed($0) }
    }

    /// Sends one RPC and waits for its reply.
    private func rpc(_ socket: FakeWebSocket, id: String, method: String, payload: String) async throws -> JSONValue {
        let body = try JSONEncoder().encode(["type": "rpc", "id": id, "method": method, "payload": payload])
        socket.push(String(decoding: body, as: UTF8.self))
        await eventually { socket.sent.contains { $0.contains("rpcResult") && $0.contains(#""id":"\#(id)""#) } }
        let reply = socket.sent.first { $0.contains("rpcResult") && $0.contains(#""id":"\#(id)""#) }
        return try parsed(try XCTUnwrap(reply))
    }

    private func assertFails(_ client: VoiceStreamClient, socketAction: (FakeWebSocket) async -> Void, _ check: (Error) -> Void, line: UInt = #line) async throws {
        let starting = Task { try await client.start() }
        await socketAction(try await socket())
        do {
            _ = try await starting.value
            XCTFail("started", line: line)
        } catch {
            check(error)
        }
    }

    // MARK: URL

    func testURLMatchesTheExpoClient() {
        let table = [
            ("https://example.test", "wss://example.test/v1/voice/stream"),
            ("https://example.test/", "wss://example.test/v1/voice/stream"),
            ("http://localhost:3005", "ws://localhost:3005/v1/voice/stream"),
            ("https://example.test/base", "wss://example.test/base/v1/voice/stream"),
            ("https://example.test/base/?a=1#frag", "wss://example.test/base/v1/voice/stream"),
            ("wss://example.test/x", "wss://example.test/x/v1/voice/stream"),
            ("ws://example.test", "wss://example.test/v1/voice/stream"),
        ]
        for (input, expected) in table {
            XCTAssertEqual(VoiceStreamClient.url(serverURL: URL(string: input)!)?.absoluteString, expected, input)
        }
    }

    // MARK: Handshake

    func testHandshakeSendsTheTokenOnlyInHelloAndReturnsTheConversation() async throws {
        let client = client()
        let starting = Task { try await client.start() }
        let socket = try await socket()
        XCTAssertEqual(connector.urls.first?.absoluteString, "wss://example.test/v1/voice/stream")
        XCTAssertEqual(socket.sent.count, 1)
        XCTAssertEqual(try parsed(socket.sent[0]), .object([
            "type": .string("hello"), "token": .string("secret-token"), "sessionId": .string("s"), "language": .string("pl"),
        ]))
        socket.push(#"{"type":"ready","conversationId":"conv"}"#)
        let conversation = try await starting.value
        XCTAssertEqual(conversation, "conv")
        XCTAssertEqual(connector.sockets.count, 1)
        await client.end()
    }

    func testHelloOmitsEmptySessionAndLanguage() async throws {
        let client = client(config: VoiceAgentConfig())
        let starting = Task { try await client.start() }
        let socket = try await socket()
        XCTAssertEqual(try parsed(socket.sent[0]), .object(["type": .string("hello"), "token": .string("secret-token")]))
        starting.cancel()
        _ = try? await starting.value
    }

    func testAClientStartsOnceAndNeverReconnects() async throws {
        let (client, socket) = try await readyClient()
        do { _ = try await client.start(); XCTFail("started twice") }
        catch { XCTAssertEqual(error as? VoiceStreamError, .alreadyStarted) }
        await socket.serverClose(code: 1011, reason: "gone")
        let events = events
        await eventually { events.values.last == .ended(nil) }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(connector.sockets.count, 1)
    }

    func testReadyTimeoutFailsTheStartAndClosesTheSocket() async throws {
        let client = client(readyTimeout: .milliseconds(30))
        let starting = Task { try await client.start() }
        let socket = try await socket()
        do { _ = try await starting.value; XCTFail("started") }
        catch { XCTAssertEqual(error as? VoiceStreamError, .timedOut) }
        await eventually { socket.closes == [WebSocketClosure(code: 1000, reason: "end")] }
        XCTAssertEqual(events.values, [])
    }

    func testConnectionFailureFailsTheStart() async {
        let client = VoiceStreamClient(serverURL: URL(string: "https://example.test")!, token: "t", config: VoiceAgentConfig(),
                                       connector: FailingConnector()) { _, _ in VoiceToolResult("") }
        do { _ = try await client.start(); XCTFail("started") }
        catch { XCTAssertTrue(error is FailingConnector.Failure) }
    }

    func testCloseBeforeReadyFailsTheStart() async throws {
        try await assertFails(client(), socketAction: { await $0.serverClose(code: 1011, reason: "boom") }) { error in
            XCTAssertEqual(error as? VoiceStreamError, .closed(WebSocketClosure(code: 1011, reason: "boom")))
        }
        XCTAssertEqual(events.values, [])
    }

    func testCancellingTheStartThrowsCancellation() async throws {
        let client = client()
        let starting = Task { try await client.start() }
        let socket = try await socket()
        starting.cancel()
        do { _ = try await starting.value; XCTFail("started") }
        catch { XCTAssertTrue(error is CancellationError) }
        await eventually { !socket.closes.isEmpty }
    }

    func testEndBeforeReadyFailsTheStart() async throws {
        let client = client()
        let starting = Task { try await client.start() }
        let socket = try await socket()
        await client.end()
        do { _ = try await starting.value; XCTFail("started") }
        catch { XCTAssertEqual(error as? VoiceStreamError, .ended) }
        XCTAssertEqual(socket.closes, [WebSocketClosure(code: 1000, reason: "end")])
    }

    // MARK: Server errors, every code on the wire

    func testUnauthorizedBeforeReadyIsTheAuthFailure() async throws {
        try await assertFails(client(), socketAction: { $0.push(#"{"type":"error","code":"unauthorized","message":"no"}"#) }) { error in
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
    }

    func testOtherCodesBeforeReadyAreServerErrors() async throws {
        for code in ["bad_request", "unavailable", "internal"] {
            let connector = FakeConnector()
            let client = VoiceStreamClient(serverURL: URL(string: "https://example.test")!, token: "t", config: VoiceAgentConfig(), connector: connector) { _, _ in VoiceToolResult("") }
            let starting = Task { try await client.start() }
            await eventually { connector.latest?.sent.isEmpty == false }
            connector.latest?.push(#"{"type":"error","code":"\#(code)","message":"why"}"#)
            do { _ = try await starting.value; XCTFail(code) }
            catch { XCTAssertEqual(error as? VoiceStreamError, .server(code: code, message: "why")) }
        }
    }

    func testErrorsAfterReadyEndTheCallWithAFailureWhenTheSocketCloses() async throws {
        for (code, close, failure) in [("unauthorized", 1008, VoiceFailure.authentication), ("bad_request", 1008, .connection), ("unavailable", 1011, .connection), ("internal", 1011, .connection)] {
            let connector = FakeConnector()
            let events = Recorder<VoiceStreamEvent>()
            let client = VoiceStreamClient(serverURL: URL(string: "https://example.test")!, token: "t", config: VoiceAgentConfig(), connector: connector) { _, _ in VoiceToolResult("") }
            let stream = client.events
            Task { for await event in stream { events.append(event) } }
            let starting = Task { try await client.start() }
            await eventually { connector.latest?.sent.isEmpty == false }
            let socket = try XCTUnwrap(connector.latest)
            socket.push(#"{"type":"ready","conversationId":"c"}"#)
            _ = try await starting.value
            socket.push(#"{"type":"error","code":"\#(code)","message":"why"}"#)
            await socket.serverClose(code: close, reason: code)
            await eventually { events.values.last == .ended(failure) }
            XCTAssertFalse(client.sendAudio(frame640))
        }
    }

    func testARoomClosingIsAPlainEnd() async throws {
        let (client, socket) = try await readyClient()
        await socket.serverClose(code: 1000, reason: "room closed")
        let events = events
        await eventually { events.values == [.ended(nil)] }
        await client.end()
        XCTAssertEqual(events.values, [.ended(nil)])
    }

    // MARK: Uplink

    func testOnlyExactFramesGoUp() async throws {
        let (client, socket) = try await readyClient()
        XCTAssertFalse(client.sendAudio(Data(count: 639)))
        XCTAssertFalse(client.sendAudio(Data(count: 641)))
        XCTAssertFalse(client.sendAudio(Data()))
        XCTAssertTrue(client.sendAudio(frame640))
        await eventually { socket.sentBinary.count == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(socket.sentBinary, [frame640])
        await client.end()
    }

    func testFramesAreDroppedUntilReady() async throws {
        let client = client()
        XCTAssertFalse(client.sendAudio(frame640))
        let starting = Task { try await client.start() }
        let socket = try await socket()
        XCTAssertFalse(client.sendAudio(frame640))
        socket.push(#"{"type":"ready","conversationId":"c"}"#)
        _ = try await starting.value
        XCTAssertTrue(client.sendAudio(frame640))
        await eventually { socket.sentBinary.count == 1 }
        await client.end()
        XCTAssertFalse(client.sendAudio(frame640))
        XCTAssertEqual(socket.sentBinary.count, 1)
    }

    func testAStalledSocketDropsFramesBeyondTheCap() async throws {
        let (client, socket) = try await readyClient()
        try? await Task.sleep(for: .milliseconds(30)) // hello is off the books
        socket.holdSends()
        // Accepted while at most 32000 bytes are pending: 50 frames reach exactly that.
        let accepted = (0..<60).filter { _ in client.sendAudio(frame640) }.count
        XCTAssertEqual(accepted, 51)
        socket.releaseSends()
        await eventually { socket.sentBinary.count == 51 }
        await eventually { client.sendAudio(frame640) }
        await client.end()
    }

    // MARK: Downlink

    func testDownlinkIsDeliveredOnlyAfterReady() async throws {
        let client = client()
        let starting = Task { try await client.start() }
        let socket = try await socket()
        socket.push(binary: Data([1, 2]))
        socket.push(#"{"type":"ready","conversationId":"c"}"#)
        socket.push(binary: Data([3, 4]))
        _ = try await starting.value
        let events = events
        await eventually { events.values == [.audio(Data([3, 4]))] }
        await client.end()
    }

    func testUnknownAndMalformedServerMessagesAreIgnored() async throws {
        let (client, socket) = try await readyClient()
        for text in [
            "not json", "[]", "{}", #"{"type":"mystery"}"#, #"{"type":12}"#,
            #"{"type":"agent"}"#, #"{"type":"agent","present":"yes"}"#, #"{"type":"agent","present":true,"state":"dancing"}"#,
            #"{"type":"rpc","id":"1"}"#, #"{"type":"rpc","id":"1","method":"m"}"#,
            #"{"type":"error","code":"mystery","message":"x"}"#, #"{"type":"error","code":"internal"}"#,
            #"{"type":"ready"}"#,
        ] {
            socket.push(text)
        }
        socket.push(#"{"type":"flush"}"#)
        let events = events
        await eventually { events.values == [.flush] }
        XCTAssertEqual(socket.sent.count, 1)
        XCTAssertTrue(client.sendAudio(frame640))
        await client.end()
        XCTAssertEqual(events.values, [.flush, .ended(nil)])
    }

    func testSpeakingIsReportedOnChangeAndFlushPassesThrough() async throws {
        let (client, socket) = try await readyClient()
        for text in [
            #"{"type":"agent","present":true,"state":"listening"}"#,
            #"{"type":"agent","present":true,"state":"speaking"}"#,
            #"{"type":"agent","present":true,"state":"speaking"}"#,
            #"{"type":"flush"}"#,
            #"{"type":"agent","present":true,"state":"thinking"}"#,
            #"{"type":"agent","present":true,"state":"speaking"}"#,
            #"{"type":"agent","present":false,"state":"speaking"}"#,
        ] {
            socket.push(text)
        }
        let events = events
        await eventually { events.values.count == 5 }
        XCTAssertEqual(events.values, [.agentSpeaking(true), .flush, .agentSpeaking(false), .agentSpeaking(true), .agentSpeaking(false)])
        await client.end()
    }

    // MARK: Publish queue

    func testTextAndContextUseTheirTopicsOnceTheAgentIsPresent() async throws {
        let (client, socket) = try await readyClient()
        socket.push(#"{"type":"agent","present":true}"#)
        socket.push(#"{"type":"flush"}"#) // Handled once the agent is known to be present.
        let events = events
        await eventually { events.values == [.flush] }
        client.sendText("say")
        client.sendContext("know")
        await eventually { socket.sent.count == 3 }
        XCTAssertEqual(try Array(texts(socket).dropFirst()), [
            .object(["type": .string("text"), "topic": .string("happy.text"), "text": .string("say")]),
            .object(["type": .string("text"), "topic": .string("happy.context"), "text": .string("know")]),
        ])
        await client.end()
    }

    func testMessagesWaitForReadyAndTheAgentKeepingTheNewest100() async throws {
        let client = client()
        for i in 0..<105 { client.sendContext("m\(i)") }
        let starting = Task { try await client.start() }
        let socket = try await socket()
        socket.push(#"{"type":"ready","conversationId":"c"}"#)
        _ = try await starting.value
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(socket.sent.count, 1, "held until the agent is present")
        client.sendContext("m105")
        socket.push(#"{"type":"agent","present":true}"#)
        await eventually { socket.sent.count == 101 }
        let sent = try texts(socket).dropFirst().map { $0["text"]?.stringValue }
        XCTAssertEqual(sent, (6...105).map { "m\($0)" })
        await client.end()
    }

    func testAgentPresentBeforeReadyFlushesOnReady() async throws {
        let client = client()
        client.sendText("early")
        let starting = Task { try await client.start() }
        let socket = try await socket()
        socket.push(#"{"type":"agent","present":true}"#)
        socket.push(#"{"type":"ready","conversationId":"c"}"#)
        _ = try await starting.value
        await eventually { socket.sent.count == 2 }
        XCTAssertEqual(try parsed(socket.sent[1])["text"], .string("early"))
        await client.end()
    }

    func testAnAgentLeavingHoldsMessagesAgain() async throws {
        let (client, socket) = try await readyClient()
        socket.push(#"{"type":"agent","present":true}"#)
        socket.push(#"{"type":"flush"}"#)
        let events = events
        await eventually { events.values == [.flush] }
        socket.push(#"{"type":"agent","present":false}"#)
        socket.push(#"{"type":"flush"}"#)
        await eventually { events.values == [.flush, .flush] }
        client.sendText("later")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(socket.sent.count, 1)
        socket.push(#"{"type":"agent","present":true}"#)
        await eventually { socket.sent.count == 2 }
        await client.end()
    }

    // MARK: The agent's calls

    func testGetConfigRepliesWithTheAgentConfig() async throws {
        let config = VoiceAgentConfig(systemPrompt: "prompt/with slash", firstMessage: "hi", initialContext: "ctx", language: nil, sessionId: "s", voice: "am_onyx", speed: 0.85)
        let (client, socket) = try await readyClient(config: config)
        let reply = try await rpc(socket, id: "1", method: "happy.getConfig", payload: "")
        XCTAssertNil(reply["error"])
        XCTAssertEqual(reply["type"], .string("rpcResult"))
        let result = try XCTUnwrap(reply["result"]?.stringValue)
        XCTAssertTrue(result.contains("prompt/with slash"))
        XCTAssertEqual(try parsed(result), .object([
            "systemPrompt": .string("prompt/with slash"), "firstMessage": .string("hi"), "initialContext": .string("ctx"),
            "language": .null, "sessionId": .string("s"), "voice": .string("am_onyx"), "speed": .number(0.85),
        ]))
        await client.end()
    }

    func testAToolReplyIsItsTextEvenWhenItIsAnErrorString() async throws {
        let (client, socket) = try await readyClient(toolResult: VoiceToolResult("error (invalid parameters)", isError: true))
        let reply = try await rpc(socket, id: "1", method: "processPermissionRequest", payload: #"{"requestId":"r","decision":"allow"}"#)
        XCTAssertEqual(reply, .object(["type": .string("rpcResult"), "id": .string("1"), "result": .string("error (invalid parameters)")]))
        XCTAssertEqual(tools.values, [#"processPermissionRequest {"requestId":"r","decision":"allow"}"#])
        await client.end()
    }

    func testAnEmptyPayloadIsAnEmptyObject() async throws {
        let (client, socket) = try await readyClient()
        _ = try await rpc(socket, id: "1", method: "sendMessageToSession", payload: "")
        XCTAssertEqual(tools.values, ["sendMessageToSession {}"])
        await client.end()
    }

    func testABadPayloadAndAnUnknownMethodGetAnError() async throws {
        let (client, socket) = try await readyClient()
        let bad = try await rpc(socket, id: "1", method: "sendMessageToSession", payload: "{nope")
        XCTAssertEqual(bad, .object(["type": .string("rpcResult"), "id": .string("1"), "error": .string("payload is not valid JSON")]))
        let unknown = try await rpc(socket, id: "2", method: "somethingElse", payload: "{}")
        XCTAssertEqual(unknown, .object(["type": .string("rpcResult"), "id": .string("2"), "error": .string("unknown method somethingElse")]))
        XCTAssertEqual(tools.values, [])
        await client.end()
    }

    func testASentMessageUpdatesTheRuntimeCounter() async throws {
        let (client, socket) = try await readyClient(voiceMessageCount: 4)
        socket.push(#"{"type":"agent","present":true}"#)
        socket.push(#"{"type":"flush"}"#)
        let events = events
        await eventually { events.values == [.flush] }
        _ = try await rpc(socket, id: "1", method: "sendMessageToSession", payload: #"{"sessionId":"s","message":"x"}"#)
        let context = try texts(socket).first { $0["topic"] == .string("happy.context") }
        XCTAssertEqual(context?["text"], .string("# Runtime counters updated\n- voice_message_count: 5"))
        await client.end()
    }

    func testAFailedSendDoesNotCount() async throws {
        let (client, socket) = try await readyClient(toolResult: VoiceToolResult("error (invalid parameters)", isError: true))
        socket.push(#"{"type":"agent","present":true}"#)
        _ = try await rpc(socket, id: "1", method: "sendMessageToSession", payload: "{}")
        XCTAssertFalse(socket.sent.contains { $0.contains("happy.context") })
        await client.end()
    }

    // MARK: End

    func testEndTellsTheServerThenClosesOnce() async throws {
        let (client, socket) = try await readyClient()
        await client.end()
        await client.end()
        XCTAssertEqual(try parsed(try XCTUnwrap(socket.sent.last)), .object(["type": .string("end")]))
        XCTAssertEqual(socket.closes.first, WebSocketClosure(code: 1000, reason: "end"))
        let events = events
        await eventually { events.values == [.ended(nil)] }
    }

    func testEndClosesEvenWhenTheSocketIsStalled() async throws {
        let (client, socket) = try await readyClient()
        socket.holdSends()
        XCTAssertTrue(client.sendAudio(frame640))
        await client.end()
        XCTAssertEqual(socket.closes.first, WebSocketClosure(code: 1000, reason: "end"))
    }
}
