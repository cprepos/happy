import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// The harness's name on a chat's row (FlatSessionRow.tsx), and that a list
/// which doesn't draw it never redraws for it.
final class HomeRowHarnessNameTests: XCTestCase {
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

    // MARK: Grouped by project

    private func chat(_ id: String, path: String, flavor: String?, at: Int64 = Fixture.now - Fixture.minute, extra: [String: JSONValue] = [:]) -> SessionRecord {
        var metadata = extra
        if let flavor { metadata["flavor"] = .string(flavor) }
        return Fixture.session(id, machine: "m1", path: path, at: at, metadata: metadata)
    }

    private func projectRows(_ snapshot: LegacyHomeSnapshot) -> [ProjectHomeRow] {
        HomeListModel(SessionList(snapshot, clock: ApplyPerfFixtures.clock), offline: nil, expandedProjects: []).rows.compactMap {
            if case .project(let row) = $0 { return row }
            return nil
        }
    }

    /// The card and each worktree open a chat, and name what runs it, with
    /// the flat row's source and fallback.
    func testAProjectAndItsWorktreesNameTheirHarness() {
        let rows = projectRows(snapshot([
            chat("own", path: "/work/happy", flavor: "codex"),
            chat("wt", path: "/work/happy/.dev/worktree/fix-x", flavor: "agy"),
            chat("plain", path: "/work/plain", flavor: nil),
            chat("empty", path: "/work/plain/.dev/worktree/fix-y", flavor: ""),
        ], grouping: "project"))
        var names: [String: String?] = [:]
        for row in rows {
            switch row {
            case .project(let entry): names[entry.name] = entry.harnessName
            case .worktree(let worktree, _): names[worktree.title] = worktree.harnessName
            default: break
            }
        }
        XCTAssertEqual(names["happy"], "Codex")
        XCTAssertEqual(names["fix-x"], "Antigravity")
        XCTAssertEqual(names["plain"], "Claude Code")
        XCTAssertEqual(names["fix-y"], "Claude Code")
    }

    /// A card with no chat of its own opens nothing, so it names nothing.
    func testAProjectWithOnlyWorktreesNamesNoHarness() throws {
        let rows = projectRows(snapshot([chat("wt", path: "/work/happy/.dev/worktree/fix-x", flavor: "codex")], grouping: "project"))
        let entry = try XCTUnwrap(rows.lazy.compactMap { row -> ProjectHomeEntry? in
            if case .project(let entry) = row { return entry }
            return nil
        }.first)
        XCTAssertNil(entry.harnessName)
        XCTAssertNil(entry.sessionId)
    }

    /// A checkout with several chats names the one a tap opens: its first.
    func testACheckoutNamesTheHarnessOfTheChatATapOpens() throws {
        let rows = projectRows(snapshot([
            chat("old", path: "/work/happy", flavor: "claude", at: Fixture.now - 2 * Fixture.minute),
            chat("new", path: "/work/happy", flavor: "codex", at: Fixture.now - Fixture.minute),
            chat("wt-old", path: "/work/happy/.dev/worktree/fix-x", flavor: "codex", at: Fixture.now - 2 * Fixture.minute),
            chat("wt-new", path: "/work/happy/.dev/worktree/fix-x", flavor: "claude", at: Fixture.now - Fixture.minute),
        ], grouping: "project"))
        var checked = 0
        for row in rows {
            switch row {
            case .project(let entry):
                XCTAssertEqual(entry.sessionId, "new")
                XCTAssertEqual(entry.harnessName, "Codex")
                checked += 1
            case .worktree(let worktree, _):
                XCTAssertEqual(worktree.sessionId, "wt-new")
                XCTAssertEqual(worktree.harnessName, "Claude Code")
                checked += 1
            default: break
            }
        }
        XCTAssertEqual(checked, 2)
    }

    /// Only the rows that draw it have it: a bot and a task don't, and neither
    /// does the toggle. An archived chat does, so the archive says which
    /// harness ran each chat.
    func testBotsAndTasksNameNoHarnessButArchivedChatsDoGroupedByProject() {
        let bot: [String: JSONValue] = ["bot": .object(["id": .string("b"), "name": .string("Helper"), "username": .string("helper"), "orderKey": .string("a")])]
        let task: [String: JSONValue] = ["task": .object(["id": .string("t"), "name": .string("Fix"), "folderName": .string("fix"), "orderKey": .string("a")])]
        let rows = projectRows(snapshot([
            chat("bot", path: "/work/bot", flavor: "codex", extra: bot),
            chat("task", path: "/work/task", flavor: "codex", extra: task),
            session("old", flavor: "codex", active: false),
        ], grouping: "project"))
        var seen: Set<String> = []
        for row in rows {
            switch row {
            case .bot(let session), .task(let session):
                XCTAssertNil(session.harnessName, session.id)
                seen.insert(session.id)
            case .archived(let session):
                XCTAssertEqual(session.harnessName, "Codex", session.id)
                seen.insert(session.id)
            default: break
            }
        }
        XCTAssertEqual(seen, ["bot", "task", "old"])
    }

    func testAChangedHarnessReconfiguresOnlyTheRowThatNamesIt() throws {
        func sessions(own: String, worktree: String, other: String) -> [SessionRecord] {
            [
                chat("own", path: "/work/happy", flavor: own),
                chat("wt", path: "/work/happy/.dev/worktree/fix-x", flavor: worktree),
                chat("other", path: "/work/other", flavor: other),
            ]
        }
        let first = try XCTUnwrap(derive(snapshot(sessions(own: "claude", worktree: "claude", other: "claude"), grouping: "project"), after: HomeDerivation.Applied()))
        let list = try XCTUnwrap(first.output.content.list)
        let card = try XCTUnwrap(list.index(ofSession: "own"))
        let worktree = try XCTUnwrap(list.index(ofSession: "wt"))
        XCTAssertNotEqual(card, worktree)

        let cardChange = try XCTUnwrap(derive(snapshot(sessions(own: "codex", worktree: "claude", other: "claude"), grouping: "project"), after: first.state))
        XCTAssertEqual(cardChange.output.changeset, RowChangeset(reconfigures: [card]))
        let worktreeChange = try XCTUnwrap(derive(snapshot(sessions(own: "claude", worktree: "codex", other: "claude"), grouping: "project"), after: first.state))
        XCTAssertEqual(worktreeChange.output.changeset, RowChangeset(reconfigures: [worktree]))
    }

    /// A chat behind the newest one is on no row: its harness is unrendered.
    func testTheHarnessOfAChatNoRowOpensChangesNothing() throws {
        func sessions(behind: String) -> [SessionRecord] {
            [
                chat("new", path: "/work/happy", flavor: "claude", at: Fixture.now - Fixture.minute),
                chat("old", path: "/work/happy", flavor: behind, at: Fixture.now - 2 * Fixture.minute),
            ]
        }
        let first = try XCTUnwrap(derive(snapshot(sessions(behind: "claude"), grouping: "project"), after: HomeDerivation.Applied()))
        XCTAssertNil(derive(snapshot(sessions(behind: "codex"), grouping: "project"), after: first.state))
    }

    // MARK: Flat

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
