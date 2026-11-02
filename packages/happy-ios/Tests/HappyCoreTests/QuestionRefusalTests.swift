import Foundation
import XCTest
@testable import HappyCore
import HappyCrypto
import HappyStore
import HappyWire

/// The agent turns down a reply to its question with `{ error }`, not a
/// failed RPC (`throwCommunicationError`, ops.ts): that must not read as sent.
final class QuestionRefusalTests: XCTestCase {
    private var fixture: ServerFixture!
    private var store: LocalStore!
    private var sync: LegacySyncEngine!
    private var rpc: FakeRPC!
    private var sessions: SessionActions!

    override func setUpWithError() throws {
        fixture = ServerFixture()
        let http = FakeHTTP()
        store = try LocalStore.inMemory()
        sync = LegacySyncEngine(api: testAPI(http), store: store, keys: fixture.keys, now: { 500 })
        rpc = FakeRPC()
        sessions = SessionActions(api: testAPI(http), store: store, sync: sync, rpc: rpc, now: { 500 })
        try store.upsertSessions([RecordDecoder(keyRing: KeyRing(keys: fixture.keys)).session(fixture.session("s", seq: 7, updatedAt: 1))])
    }

    override func tearDown() async throws { await sync.stop() }

    private func replies(_ value: JSONValue) {
        let key = fixture.dataKey
        rpc.answer = { _ in RPCCallResult(ok: true, result: try RecordCipher(key: key).encrypt(value)) }
    }

    private func sent() throws -> JSONValue? {
        let call = try XCTUnwrap(rpc.calls.last)
        XCTAssertEqual(call.method, "s:communication")
        return RecordCipher(key: fixture.dataKey).decrypt(base64: call.params)
    }

    private func assertRefused(_ reason: String, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("a refusal read as sent", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SessionActionError, .failed(reason), file: file, line: line)
        }
    }

    func testARefusedAnswerThrowsTheAgentsWords() async throws {
        replies(.object(["error": .string("This question is no longer waiting for an answer")]))
        await assertRefused("This question is no longer waiting for an answer") { [sessions] in
            try await sessions!.answerQuestion(sessionId: "s", id: "q", answers: .object(["q1": .string("yes")]), kind: "input")
        }
        // What went out is as it was.
        XCTAssertEqual(try sent(), .object(["id": .string("q"), "kind": .string("input"), "status": .string("answered"), "answers": .object(["q1": .string("yes")])]))
    }

    func testARefusedDismissalThrowsToo() async throws {
        replies(.object(["error": .string("Gone")]))
        await assertRefused("Gone") { [sessions] in try await sessions!.cancelQuestion(sessionId: "s", id: "q") }
        XCTAssertEqual(try sent(), .object(["id": .string("q"), "kind": .string("form"), "status": .string("cancelled")]))
    }

    func testAnAcceptedReplyDoesNot() async throws {
        replies(.object(["success": .bool(true)]))
        try await sessions.answerQuestion(sessionId: "s", id: "q", answers: .object([:]))
        try await sessions.cancelQuestion(sessionId: "s", id: "q")
    }

    /// Only a string `error` is a refusal, as in ops.ts.
    func testAnErrorThatIsNotAStringIsNoRefusal() async throws {
        replies(.object(["error": .null, "message": .string("noted")]))
        try await sessions.answerQuestion(sessionId: "s", id: "q", answers: .object([:]))
    }
}
