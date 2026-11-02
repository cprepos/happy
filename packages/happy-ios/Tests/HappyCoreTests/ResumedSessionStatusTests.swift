import Foundation
import XCTest
import HappyStore
import HappyWire
@testable import HappyCore

/// Everything that says whether a session is alive comes from the one flag a
/// beat sets, so the first beat of a resumed agent has to clear them together,
/// with nothing but the beat to go on.
final class ResumedSessionStatusTests: XCTestCase {
    private actor Seen {
        var active: [Bool] = []
        func append(_ value: Bool) { active.append(value) }
    }

    private func metadata(_ lifecycle: String) -> JSONValue {
        .object(["machineId": .string("m1"), "opencodeSessionId": .string("o1"), "lifecycleState": .string(lifecycle)])
    }

    private func machine(activeAt: Int64) -> MachineRecord {
        MachineRecord(
            id: "m1", seq: 0, createdAt: 1, updatedAt: 1, active: true, activeAt: activeAt,
            metadataVersion: 1, metadataCipher: "c",
            metadata: .object(["resumeSupport": .object(["rpcAvailable": .bool(true)])]),
            daemonStateVersion: 0, daemonStateCipher: nil, daemonState: nil, dataKeyCipher: "k", decryptable: true
        )
    }

    private func assertStopped(_ store: LocalStore, _ machine: MachineRecord, line: UInt = #line) throws {
        let session = try XCTUnwrap(store.session(id: "s"), line: line)
        XCTAssertEqual(SessionState(session), .disconnected, line: line)
        XCTAssertEqual(InactiveSessionHint(session: session, machine: machine)?.action, .resume, line: line)
        XCTAssertEqual(SessionDetails.resumeAvailability(session, machine: machine), .available, line: line)
        XCTAssertTrue(session.isArchivedOnServer, line: line)
    }

    private func assertAlive(_ store: LocalStore, _ machine: MachineRecord, line: UInt = #line) throws {
        let session = try XCTUnwrap(store.session(id: "s"), line: line)
        XCTAssertNotEqual(SessionState(session), .disconnected, line: line)
        XCTAssertNil(InactiveSessionHint(session: session, machine: machine), line: line)
        XCTAssertEqual(SessionDetails.resumeAvailability(session, machine: machine), .hidden, line: line)
        XCTAssertFalse(session.isArchivedOnServer, line: line)
        XCTAssertEqual(try store.sessions().first { $0.id == "s" }?.active, true, "what the lists read", line: line)
        XCTAssertEqual(try store.sessionDetail(sessionId: "s").session?.active, true, "what session info reads", line: line)
    }

    func testTheFirstBeatOfAResumedAgentClearsEveryStoppedSign() async throws {
        let store = try LocalStore.inMemory()
        let clock = LegacySyncEngineTests.Clock()
        clock.now = 1_000_000
        let computer = machine(activeAt: clock.now)
        try store.upsertMachine(computer)

        // Stopped: its owner archived the metadata as it went.
        var row = ChatRecords.storeSession(metadata: metadata("archived"))
        row.active = false
        row.activeAt = clock.now
        row.updatedAt = clock.now
        try store.upsertSessions([row])
        let presence = SessionPresence(store: store, now: { clock.now })
        await presence.tick()
        try assertStopped(store, computer)

        // The open chat's stream, listening from before the resume.
        let seen = Seen()
        let stream = store.sessionDetailSnapshots(sessionId: "s")
        let reader = Task { for await value in stream { await seen.append(value.session?.active ?? false) } }
        defer { reader.cancel() }

        // The new owner's metadata says running, which alone changes nothing:
        // the agent can be answering already and only a beat says it's up.
        clock.now += 2_000
        row.metadata = metadata("running")
        row.metadataVersion = 2
        row.updatedAt = clock.now
        try store.upsertSessions([row])
        try assertStopped(store, computer)

        clock.now += 1_000
        await presence.activity(id: "s", active: true, activeAt: clock.now, thinking: false)
        try assertAlive(store, computer)

        var waited = 0
        while await seen.active.last != true, waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let last = await seen.active.last
        XCTAssertEqual(last, true, "the open chat hears it without leaving the screen")
    }
}
