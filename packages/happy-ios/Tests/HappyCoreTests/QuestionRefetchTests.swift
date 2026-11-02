import Foundation
import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// What the chat's two-second fallback for a stuck question relies on: the
/// socket missed the agent state holding the question, and a pull of the
/// sessions brings it in.
final class QuestionRefetchTests: XCTestCase {
    func testPullingSessionsRecoversAgentStateTheSocketMissed() async throws {
        let fixture = ServerFixture()
        let http = FakeHTTP()
        let store = try LocalStore.inMemory()
        final class Clock: @unchecked Sendable { var now: Int64 = 1_000_000 }
        let clock = Clock()
        let engine = LegacySyncEngine(api: testAPI(http), store: store, keys: fixture.keys, now: { clock.now })
        http.onRaw("GET /v1/machines", "[]")
        http.onRaw("GET /v1/account/settings", #"{"settings":null,"settingsVersion":0}"#)

        let t0: Int64 = 1_760_000_000_000
        let state: JSONValue = .object(["requests": .object(["perm-q": .object(["tool": .string("AskUserQuestion"), "createdAt": .number(1)])])])
        http.on("GET /v2/sessions") { request in
            guard request.query("changedSince") != nil else {
                return (200, try JSONEncoder().encode(SessionsPage(sessions: [fixture.session("s", updatedAt: t0)], nextCursor: nil, hasNext: false)))
            }
            var session = fixture.session("s", updatedAt: t0 + 100)
            session.agentState = fixture.seal(state)
            session.agentStateVersion = 1
            return (200, try JSONEncoder().encode(SessionsPage(sessions: [session], nextCursor: nil, hasNext: false)))
        }

        await engine.run(.sessions)
        XCTAssertNil(try store.session(id: "s")?.agentState)

        clock.now += 60_000
        await engine.run(.sessions)
        XCTAssertEqual(try store.session(id: "s")?.agentState, state)
        await engine.stop()
    }
}
