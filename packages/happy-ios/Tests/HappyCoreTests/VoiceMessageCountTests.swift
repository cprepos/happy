import Foundation
@testable import HappyCore
import HappyStore
import HappyWire
import XCTest

private struct Sender: ChatSending {
    var refuses = false
    func send(_ message: OutgoingMessage, sessionId: String) async throws -> String {
        struct Refused: Error {}
        if refuses { throw Refused() }
        return "accepted"
    }
    func retry(localId: String) async throws {}
    func discard(localId: String) async throws {}
}

/// `voice_message_count` is how many messages the user has sent with voice
/// across calls, and the prompt's onboarding phases go by it
/// (realtimeClientTools.ts, RealtimeSession.ts).
final class VoiceMessageCountTests: XCTestCase {
    private let send = #"{"sessionId":"a","message":"go"}"#

    private func account(connector: FakeConnector = FakeConnector(), settings: LocalSettings = LocalSettings(storage: InMemoryKeyValueStore())) throws -> AccountSession {
        let store = try LocalStore.inMemory()
        try store.upsertSessions([ChatRecords.storeSession("a")])
        return try AccountSession(credentials: Credentials(token: "token", secret: Data(repeating: 7, count: 32)), store: store,
                                  dependencies: .init(serverURL: URL(string: "https://example.test")!, clientID: "test", transport: FakeHTTP(), connector: connector),
                                  localSettings: settings)
    }

    /// A new one per call, as the app makes.
    private func context(_ account: AccountSession, sending: ChatSending = Sender()) -> VoiceContext {
        let sync = LegacySyncEngine(api: testAPI(FakeHTTP()), store: account.store, keys: ServerFixture().keys)
        let actions = SessionActions(api: testAPI(FakeHTTP()), store: account.store, sync: sync, rpc: FakeRPC())
        return VoiceContext(account: account, sessionId: "a", sending: sending, actions: actions)
    }

    func testOnlyASentMessageCounts() async throws {
        let account = try account()
        let context = context(account)
        for body in ["{}", #"{"sessionId":"a","message":" "}"#, #"{"sessionId":"nope","message":"go"}"#] {
            _ = await context.tool(name: "sendMessageToSession", parameters: Data(body.utf8))
            XCTAssertEqual(account.localSettings.voiceMessageCount, 0, body)
        }
        let refusing = self.context(account, sending: Sender(refuses: true))
        let refused = await refusing.tool(name: "sendMessageToSession", parameters: Data(send.utf8))
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(account.localSettings.voiceMessageCount, 0)
        let sent = await context.tool(name: "sendMessageToSession", parameters: Data(send.utf8))
        XCTAssertFalse(sent.isError)
        XCTAssertEqual(account.localSettings.voiceMessageCount, 1)
        await refusing.stop()
        await context.stop()
        await account.stop()
    }

    func testTheCountCarriesIntoTheNextCall() async throws {
        let account = try account()
        for _ in 0..<2 {
            let call = context(account)
            _ = await call.tool(name: "sendMessageToSession", parameters: Data(send.utf8))
            await call.stop()
        }
        XCTAssertEqual(account.localSettings.voiceMessageCount, 2)
        await account.stop()
    }

    func testTheCountSurvivesARelaunchAndGoesAtSignOut() {
        let storage = InMemoryKeyValueStore()
        XCTAssertEqual(LocalSettings(storage: storage).voiceMessageCount, 0)
        LocalSettings(storage: storage).voiceMessageCount = 3
        let relaunched = LocalSettings(storage: storage)
        XCTAssertEqual(relaunched.voiceMessageCount, 3)
        relaunched.clear()
        XCTAssertEqual(LocalSettings(storage: storage).voiceMessageCount, 0)
    }

    /// The agent hears the stored count in its prompt, and the count after it
    /// in the first update, on a client built the way the app builds one.
    func testACallStartsFromTheStoredCount() async throws {
        let connector = FakeConnector()
        let account = try account(connector: connector)
        account.localSettings.voiceMessageCount = 5
        let context = context(account)
        let client = VoiceStreamClient(account: account, context: context, start: VoiceStart(sessionId: "a", context: "", backend: .stream))
        let starting = Task { try await client.start() }
        await eventually { connector.latest?.sent.isEmpty == false }
        let socket = try XCTUnwrap(connector.latest)
        socket.push(#"{"type":"ready","conversationId":"conv"}"#)
        _ = try await starting.value
        socket.push(#"{"type":"agent","present":true}"#)

        let config = try await rpc(socket, id: "1", method: "happy.getConfig", payload: "")
        XCTAssertTrue(config.contains("- voice_message_count: 5"), config)

        _ = try await rpc(socket, id: "2", method: "sendMessageToSession", payload: send)
        await eventually { socket.sent.contains { $0.contains("happy.context") } }
        let update = try socket.sent.map { try JSONValue.decode(Data($0.utf8)) }.first { $0["topic"] == .string("happy.context") }
        XCTAssertEqual(update?["text"], .string("# Runtime counters updated\n- voice_message_count: 6"))
        XCTAssertEqual(account.localSettings.voiceMessageCount, 6)

        await client.end()
        await context.stop()
        await account.stop()
    }

    private func rpc(_ socket: FakeWebSocket, id: String, method: String, payload: String) async throws -> String {
        let body = try JSONEncoder().encode(["type": "rpc", "id": id, "method": method, "payload": payload])
        socket.push(String(decoding: body, as: UTF8.self))
        let isReply: @Sendable (String) -> Bool = { $0.contains("rpcResult") && $0.contains(#""id":"\#(id)""#) }
        await eventually { socket.sent.contains(where: isReply) }
        let reply = try JSONValue.decode(Data(try XCTUnwrap(socket.sent.first(where: isReply)).utf8))
        return try XCTUnwrap(reply["result"]?.stringValue)
    }
}

/// The count lives in the same per-account settings the rest of the app
/// reads, which is what keeps it across launches and clears it at sign-out.
@MainActor
final class VoiceMessageCountAccountTests: XCTestCase {
    func testTheAccountsSessionCountsInThatAccountsSettings() async throws {
        let first = Credentials(token: "first", secret: Data(repeating: 3, count: 32))
        let second = Credentials(token: "second", secret: Data(repeating: 7, count: 32))
        let keychain = AccountsKeychain()
        let storage: [String: KeyValueStore] = [
            try accountID(first): InMemoryKeyValueStore(),
            try accountID(second): InMemoryKeyValueStore(),
        ]
        let account = AccountController(serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: SecureStoreCredentialStore(backend: keychain), storeDirectory: nil,
            accountCredentialStore: KeychainAccountCredentialStore(backend: keychain),
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            localSettingsFactory: { storage[$0]! },
            transport: FakeHTTP(), connector: FakeConnector())

        try await account.signIn(first)
        try XCTUnwrap(account.session).localSettings.voiceMessageCount = 4
        XCTAssertEqual(account.localSettings.voiceMessageCount, 4)

        account.beginAddingAccount()
        try await account.signIn(second)
        XCTAssertEqual(try XCTUnwrap(account.session).localSettings.voiceMessageCount, 0)
        await account.session?.stop()
    }
}
