import Foundation
@testable import HappyCore
import HappyCrypto
import HappyStore
import HappyWire
import XCTest

@MainActor
private final class StreamConnection: VoiceConnection {
    var failure: VoiceFailure?
    func end() async {}
    func setMuted(_ muted: Bool) async throws {}
    func context(_ text: String) async throws {}
    func prompt(_ text: String) async throws {}
}

@MainActor
final class VoiceStreamSessionTests: XCTestCase {
    private let stream = VoiceStart(sessionId: "s", context: "", backend: .stream)

    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("voice state did not settle")
    }

    func testOnlyAHostedElevenLabsCallNeedsAGrant() {
        XCTAssertTrue(VoiceStart(sessionId: "s", context: "").needsGrant)
        XCTAssertFalse(VoiceStart(sessionId: "s", context: "", customAgentId: "agent").needsGrant)
        XCTAssertFalse(stream.needsGrant)
    }

    func testTheStreamSkipsTheGrant() async {
        let connection = StreamConnection()
        let session = VoiceSession(permission: { true }, credentials: {
            XCTFail("grant requested for the stream")
            throw APIError.unauthorized
        }, connect: { grant, request, _, _ in
            XCTAssertNil(grant)
            XCTAssertEqual(request.backend, .stream)
            return connection
        })
        session.start(stream)
        await until { session.state == .active(activity: .listening, muted: false) }
        session.stop()
    }

    private func start(_ server: String, expecting state: VoiceState, line: UInt = #line) async throws {
        let connector = FakeConnector()
        let session = VoiceSession(permission: { true }, credentials: { throw APIError.unauthorized }, connect: { _, _, _, _ in
            let client = VoiceStreamClient(serverURL: URL(string: "https://example.test")!, token: "t", config: VoiceAgentConfig(), connector: connector) { _, _ in VoiceToolResult("") }
            _ = try await client.start()
            return StreamConnection()
        })
        session.start(stream)
        await eventually { connector.latest?.sent.isEmpty == false }
        connector.latest?.push(server)
        await until { session.state == state }
    }

    func testRefusalsBeforeReadyReachTheSessionsFailures() async throws {
        try await start(#"{"type":"error","code":"unauthorized","message":"no"}"#, expecting: .failed(.authentication))
        for code in ["bad_request", "unavailable", "internal"] {
            try await start(#"{"type":"error","code":"\#(code)","message":"no"}"#, expecting: .failed(.unavailable))
        }
    }

    func testAConnectionsFailureBecomesTheSessionsFailure() async {
        let connection = StreamConnection()
        var disconnected: (@MainActor () -> Void)?
        let session = VoiceSession(permission: { true }, credentials: { throw APIError.unauthorized }, connect: { _, _, _, disconnect in
            disconnected = disconnect
            return connection
        })
        session.start(stream)
        await until { session.state == .active(activity: .listening, muted: false) }
        connection.failure = .connection
        disconnected?()
        XCTAssertEqual(session.state, .failed(.connection))
    }

    func testAPlainDisconnectIsIdle() async {
        var disconnected: (@MainActor () -> Void)?
        let session = VoiceSession(permission: { true }, credentials: { throw APIError.unauthorized }, connect: { _, _, _, disconnect in
            disconnected = disconnect
            return StreamConnection()
        })
        session.start(stream)
        await until { session.state == .active(activity: .listening, muted: false) }
        disconnected?()
        XCTAssertEqual(session.state, .idle)
    }

    func testActivityTrackerFavoursTheAgentAndHoldsTheUserThroughSilence() async {
        var seen: [VoiceActivity] = []
        let tracker = VoiceActivityTracker { seen.append($0) }
        tracker.vad(0.9)
        XCTAssertEqual(seen, [.userSpeaking])
        tracker.vad(0.1)
        XCTAssertEqual(seen, [.userSpeaking], "still speaking inside the hangover")
        await until { seen == [.userSpeaking, .listening] }
        tracker.agentSpeaking(true)
        tracker.vad(0.9)
        XCTAssertEqual(seen, [.userSpeaking, .listening, .agentSpeaking])
        tracker.agentSpeaking(false)
        XCTAssertEqual(seen.last, .listening)
    }
}

private actor SendProbe: ChatSending {
    var fails = false
    func failing() { fails = true }
    func send(_ message: OutgoingMessage, sessionId: String) async throws -> String {
        struct Refused: Error {}
        if fails { throw Refused() }
        return "accepted"
    }
    func retry(localId: String) async throws {}
    func discard(localId: String) async throws {}
}

/// The strings the agent hears back, which it is prompted around. They must
/// stay those of happy-app's realtimeClientTools.ts.
final class VoiceStreamToolTests: XCTestCase {
    private func fixture() throws -> (VoiceContext, AccountSession, SendProbe, FakeRPC) {
        let server = ServerFixture()
        let store = try LocalStore.inMemory()
        var record = RecordDecoder(keyRing: KeyRing(keys: server.keys)).session(server.session("s", updatedAt: 1))
        record.agentState = .object(["requests": .object(["permission": .object(["tool": .string("Bash")])])])
        try store.upsertSessions([record])
        let account = try AccountSession(credentials: Credentials(token: "token", secret: Data(repeating: 7, count: 32)), store: store,
                                         dependencies: .init(serverURL: URL(string: "https://example.test")!, clientID: "test", transport: FakeHTTP(), connector: FakeConnector()))
        let rpc = FakeRPC()
        rpc.answer = { _ in RPCCallResult(ok: true, result: server.seal(.null)) }
        let sync = LegacySyncEngine(api: testAPI(FakeHTTP()), store: store, keys: server.keys)
        let actions = SessionActions(api: testAPI(FakeHTTP()), store: store, sync: sync, rpc: rpc)
        let sender = SendProbe()
        return (VoiceContext(account: account, sessionId: "s", sending: sender, actions: actions), account, sender, rpc)
    }

    private func call(_ context: VoiceContext, _ name: String, _ body: String) async -> VoiceToolResult {
        await context.tool(name: name, parameters: Data(body.utf8))
    }

    func testSendStrings() async throws {
        let (context, account, sender, _) = try fixture()
        let table: [(String, String, Bool)] = [
            (#"{"sessionId":"s","message":"go"}"#, "sent [DO NOT say anything else, simply say 'sent']", false),
            (#"{}"#, "error (invalid parameters)", true),
            (#"{"sessionId":"","message":"go"}"#, "error (invalid parameters)", true),
            (#"{"sessionId":"s","message":""}"#, "error (invalid parameters)", true),
            (#"{"sessionId":"nope","message":"go"}"#, "error (unknown session id; use a sessionId from the session list in your context)", true),
        ]
        for (body, text, isError) in table {
            let result = await call(context, "sendMessageToSession", body)
            XCTAssertEqual(result.text, text, body)
            XCTAssertEqual(result.isError, isError, body)
        }
        await sender.failing()
        let failed = await call(context, "sendMessageToSession", #"{"sessionId":"s","message":"go"}"#)
        XCTAssertEqual(failed.text, "error (the message could not be sent to the session)")
        XCTAssertTrue(failed.isError)
        await context.stop(); await account.stop()
    }

    func testPermissionStrings() async throws {
        let (context, account, _, rpc) = try fixture()
        let table: [(String, String)] = [
            (#"{"requestId":"permission","decision":"allow"}"#, "done [DO NOT say anything else, simply say 'done']"),
            (#"{"requestId":"permission","decision":"deny"}"#, "done [DO NOT say anything else, simply say 'done']"),
            (#"{}"#, "error (invalid parameters)"),
            (#"{"requestId":"permission","decision":"always"}"#, "error (invalid parameters)"),
            (#"{"requestId":"","decision":"allow"}"#, "error (invalid parameters)"),
            (#"{"requestId":"nope","decision":"allow"}"#, "error (permission request not found)"),
        ]
        for (body, text) in table {
            let result = await call(context, "processPermissionRequest", body)
            XCTAssertEqual(result.text, text, body)
        }
        rpc.answer = { _ in throw URLError(.notConnectedToInternet) }
        let allow = await call(context, "processPermissionRequest", #"{"requestId":"permission","decision":"allow"}"#)
        XCTAssertEqual(allow.text, "error (failed to allow permission)")
        let deny = await call(context, "processPermissionRequest", #"{"requestId":"permission","decision":"deny"}"#)
        XCTAssertEqual(deny.text, "error (failed to deny permission)")
        await context.stop(); await account.stop()
    }

    func testUnknownToolAndEndedSession() async throws {
        let (context, account, _, _) = try fixture()
        let unknown = await call(context, "mystery", "{}")
        XCTAssertEqual(unknown.text, "error (unknown client tool)")
        await context.stop()
        let ended = await call(context, "sendMessageToSession", #"{"sessionId":"s","message":"go"}"#)
        XCTAssertEqual(ended.text, "error (voice session ended)")
        await account.stop()
    }

    func testInitialPicksTheBackendLanguageAndPreset() async throws {
        let (context, account, _, _) = try fixture()
        let config = VoiceConfig(backends: [.stream, .elevenlabs], defaultBackend: .stream)
        try account.store.addPendingSettings([
            "voiceAssistantLanguage": .string("pt-BR"),
            "voiceAssistantVoice": .string("onyx"),
            "voiceBySession": .object(["s": .string("deep")]),
            "voiceBackend": .string("elevenlabs"),
        ])
        let saved = try await context.initial(config: config)
        XCTAssertEqual(saved.backend, .elevenlabs)
        XCTAssertEqual(saved.language, "pt")
        XCTAssertEqual(saved.voicePreset?.id, "deep")
        XCTAssertFalse(saved.savedBackendUnavailable)
        XCTAssertTrue(saved.needsGrant)

        try account.store.addPendingSettings(["voiceBackend": .string("stream")])
        let chosen = try await context.initial(config: config)
        XCTAssertEqual(chosen.backend, .stream)
        XCTAssertEqual(chosen.language, "pt-br")
        XCTAssertFalse(chosen.needsGrant)

        let forced = try await context.initial()
        XCTAssertEqual(forced.backend, .elevenlabs)
        XCTAssertTrue(forced.savedBackendUnavailable)

        do {
            _ = try await context.initial(config: VoiceConfig(backends: [], defaultBackend: .stream))
            XCTFail("nothing can carry the call")
        } catch {
            XCTAssertTrue(error is VoiceBackendUnavailable)
        }
        await context.stop(); await account.stop()
    }

    func testAnAccountCountsVoiceSocketsOnTheirOwnChannel() async throws {
        let (context, account, _, _) = try fixture()
        let client = VoiceStreamClient(account: account, context: context, start: VoiceStart(sessionId: "s", context: "", backend: .stream))
        let starting = Task { try await client.start() }
        try? await Task.sleep(for: .milliseconds(20))
        starting.cancel()
        _ = try? await starting.value
        let totals = await account.metrics.snapshot().totals
        XCTAssertTrue(totals.channelsUsed.contains(.voice))
        await context.stop(); await account.stop()
    }
}
