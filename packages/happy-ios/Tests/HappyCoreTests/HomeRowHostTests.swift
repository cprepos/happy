import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// The computer's name on the flat list's rows (flatSessionList.ts
/// `hasMultipleHosts`, FlatSessionRow.tsx): only when there is more than one
/// computer to tell apart.
final class HomeRowHostTests: XCTestCase {
    private typealias Fixture = LegacyHomeFixtures

    private func snapshot(_ sessions: [SessionRecord], machines: [MachineRecord]? = nil, hidesArchive: Bool = false, grouping: String = "flat") -> LegacyHomeSnapshot {
        LegacyHomeSnapshot(
            machines: MachinesSnapshot(synced: true, machines: machines ?? [
                Fixture.machine("m1", active: true, name: "Studio"),
                Fixture.machine("m2", active: true, name: "Laptop"),
            ]),
            sessions: sessions,
            settings: SettingsSnapshot(pending: ["sessionListGrouping": .string(grouping), "hideInactiveSessions": .bool(hidesArchive)]),
            sessionsSynced: true
        )
    }

    private func session(_ id: String, machine: String?, extra: [String: JSONValue] = [:]) -> SessionRecord {
        Fixture.session(id, machine: machine, path: "/work/\(id)", active: true, metadata: extra)
    }

    private func archived(_ id: String, machine: String) -> SessionRecord {
        let record = Fixture.session(id, machine: machine, path: "/work/\(id)", active: false)
        XCTAssertTrue(record.isArchived)
        return record
    }

    private func flatRows(_ snapshot: LegacyHomeSnapshot) -> [String: SessionRow] {
        var rows: [String: SessionRow] = [:]
        for item in SessionList(snapshot, clock: ApplyPerfFixtures.clock).items {
            if case .session(let row) = item { rows[row.id] = row }
        }
        return rows
    }

    private func derive(_ snapshot: LegacyHomeSnapshot, after applied: HomeDerivation.Applied) -> (output: HomeUpdate, state: HomeDerivation.Applied)? {
        HomeDerivation.derive(HomeDerivation.Input(snapshot: snapshot, clock: ApplyPerfFixtures.clock), applied: applied)
    }

    func testOneComputerIsNeverNamed() {
        let rows = flatRows(snapshot([session("a", machine: "m1"), session("b", machine: "m1"), session("c", machine: nil)]))
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.values.allSatisfy { $0.hostName == nil })
    }

    func testTwoComputersNameEveryChat() {
        let rows = flatRows(snapshot([session("a", machine: "m1"), session("b", machine: "m2")]))
        XCTAssertEqual(rows["a"]?.hostName, "Studio")
        XCTAssertEqual(rows["b"]?.hostName, "Laptop")
    }

    /// Two computers that share a name are still two places the work can be.
    func testItCountsMachinesNotNames() {
        let twins = [Fixture.machine("m1", active: true, name: "Mac"), Fixture.machine("m2", active: true, name: "Mac")]
        let rows = flatRows(snapshot([session("a", machine: "m1"), session("b", machine: "m2")], machines: twins))
        XCTAssertEqual(rows["a"]?.hostName, "Mac")
        XCTAssertEqual(rows["b"]?.hostName, "Mac")
    }

    /// The other computer may only be in the archive.
    func testTheArchiveCounts() {
        let rows = flatRows(snapshot([session("a", machine: "m1"), archived("z", machine: "m2")]))
        XCTAssertEqual(rows["a"]?.hostName, "Studio")
        XCTAssertEqual(rows["z"]?.hostName, "Laptop")
    }

    /// Hiding the archive doesn't change which account this is, so opening
    /// it doesn't move every row.
    func testAHiddenArchiveCountsToo() {
        let rows = flatRows(snapshot([session("a", machine: "m1"), archived("z", machine: "m2")], hidesArchive: true))
        XCTAssertEqual(rows["a"]?.hostName, "Studio")
        XCTAssertNil(rows["z"])
    }

    func testABotNeitherCountsNorShowsOne() {
        let bot: [String: JSONValue] = ["bot": .object(["id": .string("b"), "name": .string("Helper"), "username": .string("helper"), "orderKey": .string("a")])]
        let alone = flatRows(snapshot([session("a", machine: "m1"), session("b", machine: "m2", extra: bot)]))
        XCTAssertNil(alone["a"]?.hostName)
        let spread = flatRows(snapshot([session("a", machine: "m1"), session("c", machine: "m2"), session("b", machine: "m2", extra: bot)]))
        XCTAssertEqual(spread["a"]?.hostName, "Studio")
        XCTAssertNil(spread["b"]?.hostName)
    }

    func testTheNameFallsThroughDisplayNameHostAndTheChatsOwnHost() {
        var hostOnly = Fixture.machine("m1", active: true, name: "")
        hostOnly.metadata = .object(["displayName": .string(""), "host": .string("studio.local")])
        let rows = flatRows(snapshot([
            session("a", machine: "m1"),
            session("b", machine: "gone", extra: ["host": .string("old.local")]),
            session("c", machine: "gone"),
        ], machines: [hostOnly]))
        XCTAssertEqual(rows["a"]?.hostName, "studio.local")
        XCTAssertEqual(rows["b"]?.hostName, "old.local")
        XCTAssertNil(rows["c"]?.hostName)
    }

    func testRenamingAComputerReconfiguresOnlyItsRows() throws {
        let sessions = [session("a", machine: "m1"), session("b", machine: "m2"), session("c", machine: "m1")]
        let first = try XCTUnwrap(derive(snapshot(sessions), after: HomeDerivation.Applied()))
        let index = try XCTUnwrap(first.output.content.list?.ids.firstIndex(of: .session("b")))
        let renamed = [Fixture.machine("m1", active: true, name: "Studio"), Fixture.machine("m2", active: true, name: "Air")]
        let second = try XCTUnwrap(derive(snapshot(sessions, machines: renamed), after: first.state))
        XCTAssertEqual(second.output.changeset, RowChangeset(reconfigures: [index]))
    }

    /// The project list draws no host on its rows, so a host's name is never
    /// a reason to touch its chats' rows.
    func testTheProjectListCarriesNoHost() throws {
        let bot: [String: JSONValue] = ["bot": .object(["id": .string("b"), "name": .string("Helper"), "username": .string("helper"), "orderKey": .string("a")])]
        let first = try XCTUnwrap(derive(snapshot([session("b", machine: "m1", extra: bot), session("c", machine: "m2", extra: bot)], grouping: "project"), after: HomeDerivation.Applied()))
        for row in first.output.content.list?.rows ?? [] {
            if case .project(.bot(let session)) = row { XCTAssertNil(session.hostName) }
        }
    }
}
