import Foundation
import XCTest
import HappyStore
import HappyWire
@testable import HappyCore

/// The harness's name on home's rows: which name, on which rows, and that a
/// change of it reaches the row it is on and no other.
final class HomeRowHarnessTests: XCTestCase {
    private static let own = "/work/project"
    private static let worktree = "/work/project/.dev/worktree/feature-x"

    private func record(_ index: Int, path: String = HomeRowHarnessTests.worktree, flavor: String? = nil, rig: Bool = false, extra: [String: JSONValue] = [:]) -> SessionRecord {
        var record = ApplyPerfFixtures.session(index)
        var metadata = record.metadata?.objectValue ?? [:]
        metadata["path"] = .string(path)
        if let flavor { metadata["flavor"] = .string(flavor) }
        if rig { metadata["client"] = .object(["id": .string("rig")]) }
        metadata.merge(extra) { $1 }
        record.metadata = .object(metadata)
        return record
    }

    private func flavored(_ record: SessionRecord, _ flavor: String) -> SessionRecord {
        var record = record
        var metadata = record.metadata?.objectValue ?? [:]
        metadata["flavor"] = .string(flavor)
        record.metadata = .object(metadata)
        return record
    }

    private func snapshot(_ sessions: [SessionRecord], grouping: String) -> LegacyHomeSnapshot {
        var snapshot = LegacyHomeSnapshot(machines: MachinesSnapshot(synced: true, machines: [ApplyPerfFixtures.machine]), sessions: sessions, sessionsSynced: true)
        snapshot.settings = SettingsSnapshot(pending: ["sessionListGrouping": .string(grouping)])
        return snapshot
    }

    private func list(_ snapshot: LegacyHomeSnapshot) throws -> HomeListModel {
        try XCTUnwrap(ApplyPerfFixtures.derive(snapshot, after: nil)?.output.content.list)
    }

    private func flatRows(_ model: HomeListModel) -> [String: SessionRow] {
        var rows: [String: SessionRow] = [:]
        for case .flat(.session(let row)) in model.rows { rows[row.id] = row }
        return rows
    }

    private func worktrees(_ model: HomeListModel) -> [ProjectWorktree] {
        model.rows.compactMap { row in
            if case .project(.worktree(let worktree, _)) = row { return worktree }
            return nil
        }
    }

    // MARK: Names

    func testTheNamesOnAFlatRow() throws {
        let rows = flatRows(try list(snapshot([
            record(0, flavor: "opencode"),
            record(1),
            record(2, flavor: "something-new"),
            record(3, rig: true),
            record(4, flavor: "codex"),
        ], grouping: "flat")))
        XCTAssertEqual(rows[ApplyPerfFixtures.session(0).id]?.harnessName, "OpenCode")
        XCTAssertEqual(rows[ApplyPerfFixtures.session(1).id]?.harnessName, "Claude Code", "no flavor is Claude Code")
        XCTAssertEqual(rows[ApplyPerfFixtures.session(2).id]?.harnessName, "something-new", "an unknown flavor goes by itself")
        XCTAssertEqual(rows[ApplyPerfFixtures.session(3).id]?.harnessName, "Happy", "Happy Agent")
        XCTAssertEqual(rows[ApplyPerfFixtures.session(4).id]?.harnessName, "Codex")
    }

    func testTheNamesOnAWorktreeRow() throws {
        func name(_ session: SessionRecord) throws -> String? {
            let rows = worktrees(try list(snapshot([session, record(9, path: Self.own)], grouping: "project")))
            XCTAssertEqual(rows.count, 1)
            return rows.first?.harnessName
        }
        XCTAssertEqual(try name(record(0, flavor: "opencode")), "OpenCode")
        XCTAssertEqual(try name(record(0)), "Claude Code")
        XCTAssertEqual(try name(record(0, flavor: "something-new")), "something-new")
        XCTAssertEqual(try name(record(0, rig: true)), "Happy")
    }

    // MARK: Which rows

    func testAMixedWorktreeShowsItsNewestChatsHarness() throws {
        // session(0) is the newest, and what a tap opens.
        let rows = worktrees(try list(snapshot([
            record(0, flavor: "codex"),
            record(1, flavor: "opencode"),
            record(9, path: Self.own),
        ], grouping: "project")))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sessionId, ApplyPerfFixtures.session(0).id)
        XCTAssertEqual(rows.first?.harnessName, "Codex")
    }

    func testAFlatRowWithNoWorktreeKeepsNoHarness() throws {
        let rows = flatRows(try list(snapshot([record(0, path: Self.own, flavor: "opencode")], grouping: "flat")))
        XCTAssertNil(rows[ApplyPerfFixtures.session(0).id]?.workspaceName)
        XCTAssertNil(rows[ApplyPerfFixtures.session(0).id]?.harnessName)
    }

    func testABotInTheProjectListKeepsNoHarness() throws {
        let bot = record(0, path: Self.own, flavor: "opencode", extra: ["bot": .object(["username": .string("ops"), "name": .string("Ops")])])
        let model = try list(snapshot([bot, record(9, path: Self.own)], grouping: "project"))
        let bots: [SessionRow] = model.rows.compactMap { row in
            if case .project(.bot(let row)) = row { return row }
            return nil
        }
        XCTAssertEqual(bots.count, 1)
        XCTAssertNil(bots.first?.harnessName)
    }

    // MARK: Changes

    // These flavors have no avatar glyph, so only the harness's name differs
    // between them: a redraw is the name's doing.

    func testAChangeOfHarnessReconfiguresOneFlatRow() throws {
        var sessions = (0..<10).map { record($0, flavor: "one") }
        let applied = try XCTUnwrap(ApplyPerfFixtures.derive(snapshot(sessions, grouping: "flat"), after: nil)).state
        sessions[4] = flavored(sessions[4], "two")
        let update = try XCTUnwrap(ApplyPerfFixtures.derive(snapshot(sessions, grouping: "flat"), after: applied)).output
        let model = try XCTUnwrap(update.content.list)
        let index = try XCTUnwrap(model.ids.firstIndex(of: .session(sessions[4].id)))
        XCTAssertEqual(update.changeset, RowChangeset(reconfigures: [index]))
        XCTAssertEqual(flatRows(model)[sessions[4].id]?.harnessName, "two")
    }

    func testAChangeOfTheNewestChatsHarnessReconfiguresOneWorktreeRow() throws {
        var sessions = [record(0, flavor: "one"), record(1, flavor: "one"), record(9, path: Self.own, flavor: "one")]
        let applied = try XCTUnwrap(ApplyPerfFixtures.derive(snapshot(sessions, grouping: "project"), after: nil)).state
        sessions[0] = flavored(sessions[0], "two")
        let update = try XCTUnwrap(ApplyPerfFixtures.derive(snapshot(sessions, grouping: "project"), after: applied)).output
        let model = try XCTUnwrap(update.content.list)
        let index = try XCTUnwrap(model.rows.firstIndex { row in
            if case .project(.worktree) = row { return true }
            return false
        })
        XCTAssertEqual(update.changeset, RowChangeset(reconfigures: [index]))
        XCTAssertEqual(worktrees(model).first?.harnessName, "two")
    }

    func testAChangeOfAnOlderChatsHarnessTouchesNoRow() throws {
        var sessions = [record(0, flavor: "one"), record(1, flavor: "one"), record(9, path: Self.own, flavor: "one")]
        let applied = try XCTUnwrap(ApplyPerfFixtures.derive(snapshot(sessions, grouping: "project"), after: nil)).state
        sessions[1] = flavored(sessions[1], "two")
        let update = ApplyPerfFixtures.derive(snapshot(sessions, grouping: "project"), after: applied)?.output
        XCTAssertEqual(update?.changeset.touchedRows ?? 0, 0)
    }

    func testAChangeOfFlavorOnARowThatDrawsNoHarnessTouchesNoRow() throws {
        var sessions = [record(0, path: Self.own, flavor: "one"), record(1, flavor: "one")]
        let applied = try XCTUnwrap(ApplyPerfFixtures.derive(snapshot(sessions, grouping: "flat"), after: nil)).state
        sessions[0] = flavored(sessions[0], "two")
        let update = ApplyPerfFixtures.derive(snapshot(sessions, grouping: "flat"), after: applied)?.output
        XCTAssertEqual(update?.changeset.touchedRows ?? 0, 0)
    }
}
