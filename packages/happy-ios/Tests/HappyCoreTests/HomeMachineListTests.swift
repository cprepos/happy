import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// The home list grouped by host (`sessionListGrouping: 'machine'`,
/// projectHomeList.ts `buildMachineHomeRows`).
final class HomeMachineListTests: XCTestCase {
    private typealias Fixture = LegacyHomeFixtures

    private let bot: [String: JSONValue] = ["bot": .object(["id": .string("b"), "name": .string("Helper"), "username": .string("helper"), "orderKey": .string("a")])]
    private let task: [String: JSONValue] = ["task": .object(["id": .string("t"), "name": .string("Fix"), "folderName": .string("fix"), "orderKey": .string("a")])]

    private func snapshot(_ sessions: [SessionRecord], machines: [MachineRecord]? = nil, grouping: String = "machine", hidesArchive: Bool = false) -> LegacyHomeSnapshot {
        LegacyHomeSnapshot(
            machines: MachinesSnapshot(synced: true, machines: machines ?? [Fixture.machine("m1", active: true, name: "Studio"), Fixture.machine("m2", active: true, name: "Laptop")]),
            sessions: sessions,
            settings: SettingsSnapshot(pending: ["sessionListGrouping": .string(grouping), "hideInactiveSessions": .bool(hidesArchive)]),
            sessionsSynced: true
        )
    }

    private func list(_ snapshot: LegacyHomeSnapshot) -> SessionList {
        SessionList(snapshot, clock: ApplyPerfFixtures.clock)
    }

    private func model(_ snapshot: LegacyHomeSnapshot, drafts: Set<String> = []) -> HomeListModel {
        HomeListModel(list(snapshot), offline: nil, expandedProjects: [], draftSessionIds: drafts)
    }

    private func shape(_ snapshot: LegacyHomeSnapshot) -> [String] {
        model(snapshot).rows.map { row in
            guard case .project(let row) = row else { return "flat" }
            return HomeMachineListTests.name(row)
        }
    }

    private static func name(_ row: ProjectHomeRow) -> String {
        switch row {
        case .machine(_, let name): "machine:\(name)"
        case .section: "gap"
        case .bot(let row): "bot:\(row.id)"
        case .task(let row): "task:\(row.id)"
        case .chat(let row): "chat:\(row.id)"
        case .project(let entry): "project:\(entry.name)"
        case .worktree(let worktree, _): "worktree:\(worktree.title)"
        case .worktreeToggle: "toggle"
        case .archiveToggle(let hidden): hidden ? "archive:show" : "archive:hide"
        case .archiveHeader: "day"
        case .archived(let row): "archived:\(row.id)"
        }
    }

    private func chat(_ model: HomeListModel, _ id: String) -> SessionRow? {
        for row in model.rows {
            if case .project(.chat(let session)) = row, session.id == id { return session }
        }
        return nil
    }

    private func derive(_ snapshot: LegacyHomeSnapshot, after applied: HomeDerivation.Applied) -> (output: HomeUpdate, state: HomeDerivation.Applied)? {
        HomeDerivation.derive(HomeDerivation.Input(snapshot: snapshot, clock: ApplyPerfFixtures.clock), applied: applied)
    }

    // MARK: The setting

    func testASyncedMachineIsReadAsItselfAndAnythingUnknownIsFlat() {
        func parsed(_ value: String?) -> SessionListGrouping {
            AccountSettings(SettingsSnapshot(pending: value.map { ["sessionListGrouping": .string($0)] } ?? [:])).sessionListGrouping
        }
        XCTAssertEqual(parsed("machine"), .machine)
        XCTAssertEqual(parsed("project"), .project)
        XCTAssertEqual(parsed("flat"), .flat)
        XCTAssertEqual(parsed("elsewhere"), .flat)
        XCTAssertEqual(parsed(nil), .flat)
    }

    /// Appearance's row cycles all three, so a tap never drops a synced
    /// `machine` on the way to some other two-way choice.
    func testATapCyclesEveryGroupingInAppearancesOrder() {
        XCTAssertEqual(SessionListGrouping.flat.next, .project)
        XCTAssertEqual(SessionListGrouping.project.next, .machine)
        XCTAssertEqual(SessionListGrouping.machine.next, .flat)
        XCTAssertEqual(SessionListGrouping.allCases.count, 3)
    }

    func testTheListKnowsItsGroupingAndOnlyTheFlatOneHasNoSections() {
        let sessions = [Fixture.session("a", machine: "m1", path: "/work/a")]
        XCTAssertEqual(list(snapshot(sessions)).grouping, .machine)
        XCTAssertNotNil(list(snapshot(sessions)).projects)
        XCTAssertNotNil(list(snapshot(sessions, grouping: "project")).projects)
        XCTAssertNil(list(snapshot(sessions, grouping: "flat")).projects)
        XCTAssertTrue(model(snapshot(sessions)).grouped)
    }

    // MARK: The rows

    /// Project mode leaves a lone computer's heading off; this mode's only
    /// organising idea is the host, so it never does.
    func testALoneComputerStillHasItsHeading() {
        let lone = [Fixture.machine("m1", active: true, name: "Studio")]
        XCTAssertEqual(shape(snapshot([Fixture.session("a", machine: "m1", path: "/work/a")], machines: lone)), ["machine:Studio", "chat:a"])
    }

    func testEachComputerHeadsItsChatsWithNoCardsOrTree() {
        let rows = shape(snapshot([
            Fixture.session("a", machine: "m1", path: "/work/a", at: Fixture.now - 3 * Fixture.minute),
            Fixture.session("b", machine: "m2", path: "/work/b", at: Fixture.now - 2 * Fixture.minute),
            Fixture.session("c", machine: "m1", path: "/work/a/.dev/worktree/x", at: Fixture.now - Fixture.minute),
        ]))
        XCTAssertEqual(rows, ["machine:Studio", "chat:c", "chat:a", "machine:Laptop", "chat:b"])
    }

    func testBotsAndTasksKeepTheirPlaceAboveTheChats() {
        let rows = shape(snapshot([
            Fixture.session("a", machine: "m1", path: "/work/a"),
            Fixture.session("b", machine: "m1", path: "/work/b", metadata: bot),
            Fixture.session("t", machine: "m1", path: "/work/t", metadata: task),
        ], machines: [Fixture.machine("m1", active: true, name: "Studio")]))
        XCTAssertEqual(rows.first, "machine:Studio")
        XCTAssertEqual(rows.filter { $0.hasPrefix("chat:") }, ["chat:a"])
        XCTAssertEqual(rows.last, "chat:a")
        XCTAssertEqual(rows[rows.count - 2], "gap", "the chats' card is parted from the one above")
        XCTAssertTrue(rows.contains("bot:b"))
        XCTAssertTrue(rows.contains("task:t"))
    }

    func testAnEmptyComputerHasNoHeading() {
        XCTAssertEqual(shape(snapshot([Fixture.session("a", machine: "m1", path: "/work/a")])), ["machine:Studio", "chat:a"])
    }

    /// Happy Agent's chats stay on the list while stopped, so the newest
    /// one here is stopped and still comes after the live ones.
    func testLiveChatsComeFirstThenTheNewest() {
        let rig: [String: JSONValue] = ["client": .object(["id": .string("rig")])]
        let rows = shape(snapshot([
            Fixture.session("stopped", machine: "m1", path: "/work/s", active: false, at: Fixture.now - Fixture.minute, metadata: rig),
            Fixture.session("older", machine: "m1", path: "/work/o", active: true, at: Fixture.now - 3 * Fixture.minute),
            Fixture.session("newer", machine: "m1", path: "/work/n", active: true, at: Fixture.now - 2 * Fixture.minute, metadata: rig),
        ], machines: [Fixture.machine("m1", active: true, name: "Studio")]))
        XCTAssertEqual(rows, ["machine:Studio", "chat:newer", "chat:older", "chat:stopped"])
    }

    func testTheArchiveTrailsBehindItsToggle() {
        let sessions = [
            Fixture.session("a", machine: "m1", path: "/work/a"),
            Fixture.session("old", machine: "m2", path: "/work/old", active: false),
        ]
        XCTAssertEqual(shape(snapshot(sessions)), ["machine:Studio", "chat:a", "archive:hide", "archived:old"])
        XCTAssertEqual(shape(snapshot(sessions, hidesArchive: true)), ["machine:Studio", "chat:a", "archive:show"])
    }

    func testOnlyTheSectionsLastChatDropsItsHairline() throws {
        let built = model(snapshot([
            Fixture.session("a", machine: "m1", path: "/work/a", at: Fixture.now - Fixture.minute),
            Fixture.session("b", machine: "m1", path: "/work/b", at: Fixture.now - 2 * Fixture.minute),
            Fixture.session("c", machine: "m2", path: "/work/c", at: Fixture.now - 3 * Fixture.minute),
        ]))
        XCTAssertEqual(try XCTUnwrap(chat(built, "a")).showsDivider, true)
        XCTAssertEqual(try XCTUnwrap(chat(built, "b")).showsDivider, false)
        XCTAssertEqual(try XCTUnwrap(chat(built, "c")).showsDivider, false)
    }

    /// The row is the flat list's: it names the harness and keeps the draft
    /// and counts; the heading above already names the host.
    func testAChatDrawsWhatAFlatRowDrawsExceptTheHost() throws {
        let built = model(snapshot([
            Fixture.session("a", machine: "m1", path: "/work/a", metadata: ["flavor": .string("codex")]),
            Fixture.session("b", machine: "m2", path: "/work/b"),
        ]), drafts: ["a"])
        let row = try XCTUnwrap(chat(built, "a"))
        XCTAssertEqual(row.harnessName, "Codex")
        XCTAssertNil(row.hostName)
        XCTAssertTrue(row.hasDraft)
        XCTAssertEqual(row.lastActivityAt, 0)
        XCTAssertFalse(try XCTUnwrap(chat(built, "b")).hasDraft)
    }

    func testAChatRowOpensItsChatAndSitsInACard() {
        let built = model(snapshot([Fixture.session("a", machine: "m1", path: "/work/a")]))
        XCTAssertEqual(built.index(ofSession: "a"), 1)
        XCTAssertEqual(built.rows[1].sessionId, "a")
        XCTAssertTrue(built.rows[1].isCardRow)
        XCTAssertFalse(built.rows[0].isCardRow)
        XCTAssertEqual(built.places[1]?.first, true)
        XCTAssertEqual(built.places[1]?.last, true)
    }

    func testTheArchiveModelsKeepTheGroupedToggle() throws {
        let models = try XCTUnwrap(HomeArchiveModels.make(
            snapshot: snapshot([Fixture.session("a", machine: "m1", path: "/work/a"), Fixture.session("old", machine: "m1", path: "/work/old", active: false)]),
            expandedProjects: [], draftSessionIds: [], clock: ApplyPerfFixtures.clock, unknownMachine: "unknown"
        ))
        XCTAssertEqual(models.hidden.rows.last, .project(.archiveToggle(hidden: true)))
    }

    // MARK: What a change touches

    func testAChangedChatReconfiguresOnlyItsRow() throws {
        func sessions(title: String) -> [SessionRecord] {
            [
                Fixture.session("a", machine: "m1", path: "/work/a", at: Fixture.now - Fixture.minute),
                Fixture.session("b", machine: "m1", path: "/work/b", at: Fixture.now - 2 * Fixture.minute, title: title),
                Fixture.session("c", machine: "m2", path: "/work/c", at: Fixture.now - 3 * Fixture.minute),
            ]
        }
        let first = try XCTUnwrap(derive(snapshot(sessions(title: "one")), after: HomeDerivation.Applied()))
        let index = try XCTUnwrap(first.output.content.list?.ids.firstIndex(of: .project("chat-b")))
        let second = try XCTUnwrap(derive(snapshot(sessions(title: "two")), after: first.state))
        XCTAssertEqual(second.output.changeset, RowChangeset(reconfigures: [index]))
    }

    func testAChangedHarnessReconfiguresOnlyItsRow() throws {
        func sessions(flavor: String) -> [SessionRecord] {
            [
                Fixture.session("a", machine: "m1", path: "/work/a", at: Fixture.now - Fixture.minute),
                Fixture.session("b", machine: "m1", path: "/work/b", at: Fixture.now - 2 * Fixture.minute, metadata: ["flavor": .string(flavor)]),
            ]
        }
        let first = try XCTUnwrap(derive(snapshot(sessions(flavor: "claude")), after: HomeDerivation.Applied()))
        let index = try XCTUnwrap(first.output.content.list?.ids.firstIndex(of: .project("chat-b")))
        let second = try XCTUnwrap(derive(snapshot(sessions(flavor: "codex")), after: first.state))
        XCTAssertEqual(second.output.changeset, RowChangeset(reconfigures: [index]))
    }

    /// A bot's row draws a name and a time, whichever list it's in.
    func testWhatABotDoesNotDrawChangesNothing() throws {
        func sessions(flavor: String) -> [SessionRecord] {
            var metadata = bot
            metadata["flavor"] = .string(flavor)
            return [Fixture.session("b", machine: "m1", path: "/work/b", metadata: metadata)]
        }
        let first = try XCTUnwrap(derive(snapshot(sessions(flavor: "claude")), after: HomeDerivation.Applied()))
        XCTAssertNil(derive(snapshot(sessions(flavor: "codex")), after: first.state))
    }

    /// Only the flat list carries a host on its rows, so a computer's new
    /// name reaches its heading here and no chat.
    func testRenamingAComputerTouchesOnlyItsHeading() throws {
        let sessions = [
            Fixture.session("a", machine: "m1", path: "/work/a", at: Fixture.now - Fixture.minute),
            Fixture.session("b", machine: "m2", path: "/work/b", at: Fixture.now - 2 * Fixture.minute),
        ]
        let first = try XCTUnwrap(derive(snapshot(sessions), after: HomeDerivation.Applied()))
        let index = try XCTUnwrap(first.output.content.list?.ids.firstIndex(of: .project("machine-m2")))
        let renamed = [Fixture.machine("m1", active: true, name: "Studio"), Fixture.machine("m2", active: true, name: "Air")]
        let second = try XCTUnwrap(derive(snapshot(sessions, machines: renamed), after: first.state))
        XCTAssertEqual(second.output.changeset, RowChangeset(reconfigures: [index]))
    }
}
