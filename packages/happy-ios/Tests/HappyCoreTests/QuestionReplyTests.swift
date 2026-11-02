import Foundation
import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// What answering and dismissing a question send, and what the agent's reply
/// means (ops.ts's sessionDeny and throwCommunicationError).
final class QuestionReplyTests: XCTestCase {
    var fixture: ServerFixture!
    var sync: LegacySyncEngine!
    var rpc: FakeRPC!
    var sessions: SessionActions!

    override func setUpWithError() throws {
        fixture = ServerFixture()
        let http = FakeHTTP()
        let store = try LocalStore.inMemory()
        sync = LegacySyncEngine(api: testAPI(http), store: store, keys: fixture.keys, now: { 500 })
        rpc = FakeRPC()
        sessions = SessionActions(api: testAPI(http), store: store, sync: sync, rpc: rpc, now: { 500 })
        try store.upsertSessions([RecordDecoder(keyRing: KeyRing(keys: fixture.keys)).session(fixture.session("s", seq: 7, updatedAt: 1))])
    }

    override func tearDown() async throws { await sync.stop() }

    private func reply(_ value: JSONValue) {
        let key = fixture.dataKey
        rpc.answer = { _ in RPCCallResult(ok: true, result: try RecordCipher(key: key).encrypt(value)) }
    }

    private func assertLastPermission(_ params: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws {
        let call = try XCTUnwrap(rpc.calls.last, file: file, line: line)
        XCTAssertEqual(call.method, "s:permission", file: file, line: line)
        XCTAssertEqual(RecordCipher(key: fixture.dataKey).decrypt(base64: call.params), params, file: file, line: line)
    }

    func testDismissingAskUserQuestionSendsTheReason() async throws {
        reply(.null)
        try await sessions.deny(sessionId: "s", permissionId: "p", reason: InlineQuestionForm.dismissReason)
        try assertLastPermission(.object([
            "id": .string("p"), "approved": .bool(false), "reason": .string(InlineQuestionForm.dismissReason),
        ]))
    }

    func testAnOrdinaryDenySendsNoReason() async throws {
        reply(.null)
        try await sessions.deny(sessionId: "s", permissionId: "p")
        try assertLastPermission(.object(["id": .string("p"), "approved": .bool(false)]))
    }

    func testAnErrorInTheReplyFailsAnAnswer() async throws {
        reply(.object(["error": .string("Already answered")]))
        do {
            try await sessions.answerQuestion(sessionId: "s", id: "q", answers: .object([:]))
            XCTFail("the reply said it failed")
        } catch {
            XCTAssertEqual(error as? SessionActionError, .failed("Already answered"))
        }
    }

    func testAnErrorInTheReplyFailsACancel() async throws {
        reply(.object(["error": .string("Already answered")]))
        do {
            try await sessions.cancelQuestion(sessionId: "s", id: "q")
            XCTFail("the reply said it failed")
        } catch {
            XCTAssertEqual(error as? SessionActionError, .failed("Already answered"))
        }
    }

    func testOtherRepliesAreSuccess() async throws {
        // Only a string `error` counts, as in throwCommunicationError.
        let others: [JSONValue] = [
            .null, .bool(true), .object(["ok": .bool(true)]), .object(["message": .string("noted")]), .object(["error": .number(1)]),
        ]
        for other in others {
            reply(other)
            try await sessions.answerQuestion(sessionId: "s", id: "q", answers: .object([:]))
            try await sessions.cancelQuestion(sessionId: "s", id: "q")
        }
    }
}
