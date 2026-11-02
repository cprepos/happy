import Foundation
import XCTest
@testable import HappyWire

/// sessionProtocol.ts's subagent lifecycle events, old and new.
final class SubagentEventDecodingTests: XCTestCase {
    private func event(_ json: String) throws -> SessionEvent {
        try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
    }

    private func roundTrip(_ event: SessionEvent) throws -> SessionEvent {
        try JSONDecoder().decode(SessionEvent.self, from: JSONEncoder().encode(event))
    }

    func testOlderRecordsStillDecode() throws {
        XCTAssertEqual(try event(#"{"t":"stop"}"#), .stop())
        XCTAssertEqual(try event(#"{"t":"start"}"#), .start())
        XCTAssertEqual(try event(#"{"t":"start","title":"Fix it"}"#), .start(title: "Fix it"))
    }

    func testStartCarriesWhatTheAgentReports() throws {
        let decoded = try event("""
        {"t":"start","title":"Fix it","subagentType":"Explore","model":"m","prompt":"look","spawnDepth":2,"parentTaskId":"p"}
        """)
        XCTAssertEqual(decoded, .start(title: "Fix it", subagentType: "Explore", model: "m", prompt: "look", spawnDepth: 2, parentTaskId: "p"))
        XCTAssertEqual(try roundTrip(decoded), decoded)
    }

    func testStopCarriesItsOutcome() throws {
        let decoded = try event("""
        {"t":"stop","status":"failed","summary":"gave up","tokens":120,"toolUses":3,"durationMs":1500.5}
        """)
        XCTAssertEqual(decoded, .stop(status: .failed, summary: "gave up", tokens: 120, toolUses: 3, durationMs: 1500.5))
        XCTAssertEqual(try roundTrip(decoded), decoded)
    }

    func testProgress() throws {
        let decoded = try event("""
        {"t":"progress","tokens":50,"toolUses":1,"durationMs":900,"lastToolName":"Grep","summary":"reading"}
        """)
        XCTAssertEqual(decoded, .progress(tokens: 50, toolUses: 1, durationMs: 900, lastToolName: "Grep", summary: "reading"))
        XCTAssertEqual(try roundTrip(decoded), decoded)
        XCTAssertEqual(try event(#"{"t":"progress"}"#), .progress())
    }

    func testAgents() throws {
        let decoded = try event("""
        {"t":"agents","agents":[{"id":"a","type":"Explore","description":"d","parentId":"b"},{"id":"b"}]}
        """)
        XCTAssertEqual(decoded, .agents([SessionAgentEntry(id: "a", type: "Explore", description: "d", parentId: "b"), SessionAgentEntry(id: "b")]))
        XCTAssertEqual(try roundTrip(decoded), decoded)
    }

    /// A newer producer's status, or a field of another shape, costs that
    /// field and never the boundary.
    func testAFieldOfAnotherShapeReadsAsAbsent() throws {
        XCTAssertEqual(try event(#"{"t":"stop","status":"exploded","tokens":"many"}"#), .stop())
        XCTAssertEqual(try event(#"{"t":"start","title":"T","spawnDepth":"deep"}"#), .start(title: "T"))
        XCTAssertEqual(try event(#"{"t":"progress","tokens":1.5,"lastToolName":3}"#), .progress())
        XCTAssertEqual(try event(#"{"t":"agents","agents":"none"}"#), .agents([]))
    }
}
