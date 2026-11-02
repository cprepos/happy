import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// The harness's name on a chat's row (FlatSessionRow.tsx), and that a list
/// which doesn't draw it never redraws for it.
final class HomeRowHarnessTests: XCTestCase {
    private typealias Fixture = LegacyHomeFixtures

    private func snapshot(_ sessions: [SessionRecord], grouping: String = "flat") -> LegacyHomeSnapshot {
        LegacyHomeSnapshot(
            machines: MachinesSnapshot(synced: true, machines: [Fixture.machine("m1", active: true, name: "Studio")]),
            sessions: sessions,
            settings: SettingsSnapshot(pending: ["sessionListGrouping": .string(grouping), "hideInactiveSessions": .bool(false)]),
            sessionsSynced: true
        )
    }

    private func session(_ id: String, flavor: String?, extra: [String: JSONValue] = [:], active: Bool = true) -> SessionRecord {
        var metadata = extra
        if let flavor { metadata["flavor"] = .string(flavor) }
        return Fixture.session(id, machine: "m1", path: "/work/\(id)", active: active, metadata: metadata)
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

    func testEveryChatNamesItsHarnessAndNoFlavorIsClaudeCode() {
        let rows = flatRows(snapshot([
            session("a", flavor: "claude"),
            session("b", flavor: "codex"),
            session("c", flavor: "agy"),
            session("d", flavor: nil),
            session("e", flavor: ""),
            session("f", flavor: "something-new"),
            session("g", flavor: "codex", active: false),
        ]))
        XCTAssertEqual(rows["a"]?.harnessName, "Claude Code")
        XCTAssertEqual(rows["b"]?.harnessName, "Codex")
        XCTAssertEqual(rows["c"]?.harnessName, "Antigravity")
        XCTAssertEqual(rows["d"]?.harnessName, "Claude Code")
        XCTAssertEqual(rows["e"]?.harnessName, "Claude Code")
        XCTAssertEqual(rows["f"]?.harnessName, "something-new")
        XCTAssertEqual(rows["g"]?.harnessName, "Codex")
    }

    func testAChangedHarnessReconfiguresOnlyItsFlatRow() throws {
        let before = snapshot([session("a", flavor: "claude"), session("b", flavor: "claude"), session("c", flavor: "claude")])
        let first = try XCTUnwrap(derive(before, after: HomeDerivation.Applied()))
        let index = try XCTUnwrap(first.output.content.list?.ids.firstIndex(of: .session("b")))
        let after = snapshot([session("a", flavor: "claude"), session("b", flavor: "codex"), session("c", flavor: "claude")])
        let second = try XCTUnwrap(derive(after, after: first.state))
        XCTAssertEqual(second.output.changeset, RowChangeset(reconfigures: [index]))
    }

    /// The project list's bots draw a name and a time: their harness is a
    /// field nothing renders, so it never causes an apply.
    func testAHarnessARowDoesNotDrawChangesNothing() throws {
        let bot: [String: JSONValue] = ["bot": .object(["id": .string("b"), "name": .string("Helper"), "username": .string("helper"), "orderKey": .string("a")])]
        let before = snapshot([session("b", flavor: "claude", extra: bot)], grouping: "project")
        let first = try XCTUnwrap(derive(before, after: HomeDerivation.Applied()))
        guard case .project(.bot(let row))? = first.output.content.list?.rows.first(where: { $0.sessionId == "b" }) else { return XCTFail("a bot's row") }
        XCTAssertNil(row.harnessName)
        let after = snapshot([session("b", flavor: "codex", extra: bot)], grouping: "project")
        XCTAssertNil(derive(after, after: first.state))
    }
}
