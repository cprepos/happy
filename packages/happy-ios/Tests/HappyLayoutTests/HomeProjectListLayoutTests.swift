import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import HappyLayout
import XCTest

/// The home list grouped by project, on a 3x phone (hairline 1/3, so the
/// tree line is 2/3 wide).
final class ProjectListLayoutTests: XCTestCase {
    private let hairline: CGFloat = 1.0 / 3

    func testProjectCardWithEverythingTrailing() {
        let layout = ProjectCardLayout(.init(
            width: 393,
            hairline: hairline,
            name: text("happy", lineHeight: 22, maxLines: 1),
            showsDot: true,
            changes: fixed(60, 18),
            showsAdd: true,
            showsTree: true
        ))
        assertSize(layout.size, CGSize(width: 393, height: 52))
        assertFrame(layout.avatar, rect(16, 12, 28, 28))
        // The stem drops from under the avatar to the row's foot.
        assertFrame(layout.stem, rect(29.667, 40, 0.667, 12))
        assertFrame(layout.add, rect(349, 10, 28, 32))
        assertFrame(layout.changes, rect(281, 17, 60, 18))
        assertFrame(layout.dot, rect(266, 22.5, 7, 7))
        assertFrame(layout.name, rect(56, 15, 202, 22))
    }

    func testABareProjectCardGivesTheNameTheRow() {
        let layout = ProjectCardLayout(.init(
            width: 393,
            hairline: hairline,
            name: text("happy", lineHeight: 22, maxLines: 1),
            showsDot: false,
            changes: nil,
            showsAdd: false,
            showsTree: false
        ))
        XCTAssertNil(layout.stem)
        XCTAssertNil(layout.dot)
        XCTAssertNil(layout.changes)
        XCTAssertNil(layout.add)
        assertFrame(layout.name, rect(56, 15, 321, 22))
    }

    // MARK: The harness

    /// ProjectRowText: 202 of lane less the name's margin and 88.
    func testAProjectCardNamesItsHarnessAtTheLanesRightEdge() {
        let layout = ProjectCardLayout(.init(
            width: 393,
            hairline: hairline,
            name: text("happy", lineHeight: 22, maxLines: 1),
            harness: text("Claude Code", lineHeight: 18, maxLines: 1),
            showsDot: true,
            changes: fixed(60, 18),
            showsAdd: true,
            showsTree: true
        ))
        assertSize(layout.size, CGSize(width: 393, height: 52))
        assertFrame(layout.name, rect(56, 15, 106, 22))
        assertFrame(layout.harness, rect(170, 17, 88, 18))
        assertFrame(layout.dot, rect(266, 22.5, 7, 7))
        assertFrame(layout.changes, rect(281, 17, 60, 18))
        assertFrame(layout.add, rect(349, 10, 28, 32))
    }

    func testAProjectCardsNameTruncatesAndItsHarnessDoesNot() {
        let layout = ProjectCardLayout(.init(
            width: 393,
            hairline: hairline,
            name: text(String(repeating: "x", count: 60), lineHeight: 22, maxLines: 1),
            harness: text("Claude Code", lineHeight: 18, maxLines: 1),
            showsDot: true,
            changes: fixed(60, 18),
            showsAdd: true,
            showsTree: true
        ))
        assertFrame(layout.name, rect(56, 15, 106, 22))
        assertFrame(layout.harness, rect(170, 17, 88, 18))
    }

    func testAProjectWithOnlyWorktreesHasNoHarnessAndItsNameTheLane() {
        let layout = ProjectCardLayout(.init(
            width: 393,
            hairline: hairline,
            name: text("happy", lineHeight: 22, maxLines: 1),
            showsDot: true,
            changes: fixed(60, 18),
            showsAdd: true,
            showsTree: true
        ))
        XCTAssertNil(layout.harness)
        assertFrame(layout.name, rect(56, 15, 202, 22))
    }

    /// 320 wide, the lane is 129: 88 and the margin leave 33, under the 44
    /// a long name keeps. The name and the harness stack and the row grows.
    func testOnANarrowRowTheHarnessDropsUnderALongName() {
        let layout = ProjectCardLayout(.init(
            width: 320,
            hairline: hairline,
            name: text("happy-coder", lineHeight: 22, maxLines: 1),
            harness: text("Claude Code", lineHeight: 18, maxLines: 1),
            showsDot: true,
            changes: fixed(60, 18),
            showsAdd: true,
            showsTree: true
        ))
        assertSize(layout.size, CGSize(width: 320, height: 64))
        assertFrame(layout.avatar, rect(16, 18, 28, 28))
        assertFrame(layout.stem, rect(29.667, 46, 0.667, 18))
        assertFrame(layout.name, rect(56, 12, 129, 22))
        assertFrame(layout.harness, rect(56, 34, 88, 18))
        assertFrame(layout.dot, rect(193, 28.5, 7, 7))
        assertFrame(layout.changes, rect(208, 23, 60, 18))
        assertFrame(layout.add, rect(276, 16, 28, 32))
    }

    /// The same 33 is all of a short name: both stay on one line.
    func testOnANarrowRowAShortNameKeepsTheHarnessBesideIt() {
        let layout = ProjectCardLayout(.init(
            width: 320,
            hairline: hairline,
            name: text("hi", lineHeight: 22, maxLines: 1),
            harness: text("Claude Code", lineHeight: 18, maxLines: 1),
            showsDot: true,
            changes: fixed(60, 18),
            showsAdd: true,
            showsTree: true
        ))
        assertSize(layout.size, CGSize(width: 320, height: 52))
        assertFrame(layout.name, rect(56, 15, 33, 22))
        assertFrame(layout.harness, rect(97, 17, 88, 18))
    }

    /// 200 wide, the trailing items leave 9: too short for the harness or the
    /// name. Both go under the trailing items, on lines to the row's edge.
    func testWhereTheTrailingItemsTakeTheLaneTheTextGoesUnderThem() {
        let layout = ProjectCardLayout(.init(
            width: 200,
            hairline: hairline,
            name: text("happy", lineHeight: 22, maxLines: 1),
            harness: text("Claude Code", lineHeight: 18, maxLines: 1),
            showsDot: true,
            changes: fixed(60, 18),
            showsAdd: true,
            showsTree: true
        ))
        assertSize(layout.size, CGSize(width: 200, height: 96))
        assertFrame(layout.avatar, rect(16, 34, 28, 28))
        assertFrame(layout.stem, rect(29.667, 62, 0.667, 34))
        assertFrame(layout.dot, rect(73, 24.5, 7, 7))
        assertFrame(layout.changes, rect(88, 19, 60, 18))
        assertFrame(layout.add, rect(156, 12, 28, 32))
        assertFrame(layout.name, rect(56, 44, 128, 22))
        assertFrame(layout.harness, rect(56, 66, 88, 18))
    }

    func testWhereTheTrailingItemsTakeAWorktreesLaneTheTextGoesUnderThem() {
        let layout = WorktreeRowLayout(.init(
            width: 200,
            hairline: hairline,
            label: text("fix-login", lineHeight: 21, maxLines: 1),
            harness: text("Claude Code", lineHeight: 18, maxLines: 1),
            showsDot: true,
            changes: fixed(52, 18),
            last: false
        ))
        assertSize(layout.size, CGSize(width: 200, height: 81))
        assertFrame(layout.trunk, rect(29.667, 0, 0.667, 81))
        assertFrame(layout.dot, rect(117, 17.5, 7, 7))
        assertFrame(layout.changes, rect(132, 12, 52, 18))
        assertFrame(layout.label, rect(56, 30, 128, 21))
        assertFrame(layout.harness, rect(56, 51, 88, 18))
    }

    /// Wider than the row has room for, the harness is held to the row's edge.
    func testAnEnormousHarnessStopsAtTheRowsEdge() {
        let layout = ProjectCardLayout(.init(
            width: 320,
            hairline: hairline,
            name: text("happy", lineHeight: 22, maxLines: 1),
            harness: text(String(repeating: "x", count: 60), lineHeight: 18, maxLines: 1),
            showsDot: true,
            changes: fixed(60, 18),
            showsAdd: true,
            showsTree: true
        ))
        assertSize(layout.size, CGSize(width: 320, height: 96))
        assertFrame(layout.add, rect(276, 12, 28, 32))
        assertFrame(layout.name, rect(56, 44, 248, 22))
        assertFrame(layout.harness, rect(56, 66, 248, 18))
    }

    func testAWorktreeNamesItsHarnessBesideItsChanges() {
        let layout = WorktreeRowLayout(.init(
            width: 393,
            hairline: hairline,
            label: text("fix-login", lineHeight: 21, maxLines: 1),
            harness: text("Codex", lineHeight: 18, maxLines: 1),
            showsDot: false,
            changes: fixed(52, 18),
            last: false
        ))
        assertSize(layout.size, CGSize(width: 393, height: 48))
        assertFrame(layout.label, rect(56, 13.5, 213, 21))
        assertFrame(layout.harness, rect(277, 15, 40, 18))
        assertFrame(layout.changes, rect(325, 15, 52, 18))
    }

    /// 240 wide, the lane is 93 and the name would be left nothing.
    func testOnANarrowRowAWorktreesHarnessDropsUnderIt() {
        let layout = WorktreeRowLayout(.init(
            width: 240,
            hairline: hairline,
            label: text("fix-login", lineHeight: 21, maxLines: 1),
            harness: text("Claude Code", lineHeight: 18, maxLines: 1),
            showsDot: true,
            changes: fixed(52, 18),
            last: false
        ))
        assertSize(layout.size, CGSize(width: 240, height: 63))
        assertFrame(layout.trunk, rect(29.667, 0, 0.667, 63))
        assertFrame(layout.elbow, rect(30, 31.167, 14, 0.667))
        assertFrame(layout.label, rect(56, 12, 93, 21))
        assertFrame(layout.harness, rect(56, 33, 88, 18))
    }

    /// A harness taller than the name holds the row up as the name does.
    func testATallHarnessHoldsTheRowUp() {
        let layout = WorktreeRowLayout(.init(
            width: 393,
            hairline: hairline,
            label: text("fix-login", lineHeight: 21, maxLines: 1),
            harness: text("Codex", lineHeight: 30, maxLines: 1),
            showsDot: false,
            changes: nil,
            last: false
        ))
        assertSize(layout.size, CGSize(width: 393, height: 54))
        assertFrame(layout.label, rect(56, 16.5, 265, 21))
        assertFrame(layout.harness, rect(329, 12, 40, 30))
    }

    func testAToggleHasNoHarness() {
        let layout = WorktreeRowLayout(.init(
            width: 393,
            hairline: hairline,
            label: text("Show all 5 workspaces", lineHeight: 20, maxLines: 1),
            chevron: CGSize(width: 12, height: 12),
            showsDot: false,
            changes: nil,
            last: true
        ))
        XCTAssertNil(layout.harness)
    }

    func testWorktreeBranchesOffTheTrunk() {
        let layout = WorktreeRowLayout(.init(
            width: 393,
            hairline: hairline,
            label: text("fix-login", lineHeight: 21, maxLines: 1),
            showsDot: false,
            changes: fixed(52, 18),
            last: false
        ))
        assertSize(layout.size, CGSize(width: 393, height: 48))
        assertFrame(layout.trunk, rect(29.667, 0, 0.667, 48))
        assertFrame(layout.elbow, rect(30, 23.667, 14, 0.667))
        XCTAssertNil(layout.chevron)
        XCTAssertNil(layout.dot)
        assertFrame(layout.changes, rect(325, 15, 52, 18))
        assertFrame(layout.label, rect(56, 13.5, 261, 21))
    }

    func testTheLastWorktreeStopsTheTrunkAtItsElbow() {
        let layout = WorktreeRowLayout(.init(
            width: 393,
            hairline: hairline,
            label: text("fix-login", lineHeight: 21, maxLines: 1),
            showsDot: false,
            changes: nil,
            last: true
        ))
        assertFrame(layout.trunk, rect(29.667, 0, 0.667, 24))
        // An empty trailing column still keeps its margin.
        assertFrame(layout.label, rect(56, 13.5, 313, 21))
    }

    func testTheToggleLeadsWithItsChevronAndHugsItsLabel() {
        let layout = WorktreeRowLayout(.init(
            width: 393,
            hairline: hairline,
            label: text("Show all 5 workspaces", lineHeight: 20, maxLines: 1),
            chevron: CGSize(width: 12, height: 12),
            showsDot: true,
            changes: nil,
            last: true
        ))
        assertFrame(layout.chevron, rect(56, 18, 12, 12))
        assertFrame(layout.label, rect(73, 14, 168, 20))
        assertFrame(layout.dot, rect(370, 20.5, 7, 7))
    }

    func testALongToggleLabelIsClampedToItsLane() {
        let layout = WorktreeRowLayout(.init(
            width: 200,
            hairline: hairline,
            label: text("Show all 12 workspaces", lineHeight: 20, maxLines: 1),
            chevron: CGSize(width: 12, height: 12),
            showsDot: false,
            changes: nil,
            last: true
        ))
        // 200 - 16 - 8 = 176 is the lane's right edge.
        assertFrame(layout.label, rect(73, 14, 103, 20))
    }

    func testChatRowWithATimestamp() {
        let layout = ProjectChatRowLayout(
            width: 393,
            name: text("Ops bot", lineHeight: 22, maxLines: 1),
            corner: text("12:55", lineHeight: 18, maxLines: 1)
        )
        assertSize(layout.size, CGSize(width: 393, height: 48))
        assertFrame(layout.avatar, rect(16, 10, 28, 28))
        assertFrame(layout.corner, rect(337, 15, 40, 18))
        assertFrame(layout.name, rect(56, 13, 273, 22))
    }

    func testChatRowWithADot() {
        let layout = ProjectChatRowLayout(
            width: 393,
            name: text("Ops bot", lineHeight: 22, maxLines: 1),
            corner: fixed(10, 10)
        )
        assertFrame(layout.corner, rect(367, 19, 10, 10))
        assertFrame(layout.name, rect(56, 13, 303, 22))
    }

    func testMachineHeaderStandsOverItsCardInLineWithTheAvatars() {
        let layout = MachineHeaderLayout(
            width: 393,
            icon: CGSize(width: 13, height: 13),
            name: text("MacBook Pro", lineHeight: 14, maxLines: 1)
        )
        assertFrame(layout.icon, rect(32, 20.5, 13, 13))
        assertFrame(layout.name, rect(51, 20, 88, 14))
        assertSize(layout.size, CGSize(width: 393, height: 42))
    }

    func testAMachineNameStopsAtTheCardsInset() {
        let layout = MachineHeaderLayout(
            width: 393,
            icon: CGSize(width: 13, height: 13),
            name: text(String(repeating: "x", count: 50), lineHeight: 14, maxLines: 1)
        )
        // 393 - 32 - 32 - 13 - 6.
        assertFrame(layout.name, rect(51, 20, 310, 14))
    }

    func testGitChangesSitOnOneCentreLine() {
        let all = GitChangesLayout(
            approximate: CGSize(width: 8, height: 14),
            added: CGSize(width: 24, height: 18),
            removed: CGSize(width: 16, height: 18)
        )
        assertFrame(all.approximate, rect(0, 2, 8, 14))
        assertFrame(all.added, rect(12, 0, 24, 18))
        assertFrame(all.removed, rect(40, 0, 16, 18))
        assertSize(all.size, CGSize(width: 56, height: 18))

        let added = GitChangesLayout(approximate: nil, added: CGSize(width: 24, height: 18), removed: nil)
        XCTAssertNil(added.approximate)
        XCTAssertNil(added.removed)
        assertFrame(added.added, rect(0, 0, 24, 18))
        assertSize(added.size, CGSize(width: 24, height: 18))
    }

    func testListHeaderStacksItsBanners() {
        let layout = HomeListHeaderLayout(width: 393, banners: [block(height: 80), block(height: 64)])
        XCTAssertEqual(layout.banners.count, 2)
        assertFrame(layout.banners[0], rect(0, 0, 393, 80))
        assertFrame(layout.banners[1], rect(0, 80, 393, 64))
        assertSize(layout.size, CGSize(width: 393, height: 144))
        assertSize(HomeListHeaderLayout(width: 393, banners: []).size, CGSize(width: 393, height: 0))
    }

    func testTheUnbandedArchiveToggle() {
        let layout = ArchiveToggleLayout(
            width: 393,
            label: text("Show archived", lineHeight: 18),
            paddingTop: ArchiveToggleLayout.unbanded.top,
            paddingBottom: ArchiveToggleLayout.unbanded.bottom
        )
        assertFrame(layout.leadingLine, rect(24, 28.835, 108.5, 0.33))
        assertFrame(layout.label, rect(144.5, 20, 104, 18))
        assertFrame(layout.trailingLine, rect(260.5, 28.835, 108.5, 0.33))
        assertSize(layout.size, CGSize(width: 393, height: 50))
    }
}

/// The glyph boxes come from `Icon.layout`: one line of the icon font
/// tall, so a hair taller than wide on a 3x screen.
final class SessionListIconBoxTests: XCTestCase {
    func testTheBranchIconCentresItsRNBox() {
        let layout = FlatSessionRowLayout(.init(
            width: 393,
            title: text("Fix the build", lineHeight: 22, maxLines: 1),
            timestamp: text("12:55", lineHeight: 22, maxLines: 1),
            project: text("happy", lineHeight: 20, maxLines: 1),
            workspace: text("fix-login", lineHeight: 18, maxLines: 1),
            branchIcon: CGSize(width: 13, height: 13.33),
            showsDivider: true
        ))
        assertFrame(layout.workspace, rect(88, 53, 72, 18))
        assertFrame(layout.branchIcon, rect(164, 55.335, 13, 13.33))
        XCTAssertEqual(layout.size.height, 81)
    }

    func testNoSessionsCentresTheTallerIconBox() {
        let layout = NoSessionsLayout(.init(
            size: phone,
            safeArea: phoneUnderBar,
            icon: CGSize(width: 56, height: 57.67),
            title: text("No sessions yet", lineHeight: 30),
            description: text("Start one on a connected machine.", lineHeight: 22),
            action: nil
        ))
        assertFrame(layout.icon, rect(168.5, 363.665, 56, 57.67))
        assertFrame(layout.title, rect(136.5, 441.335, 120, 30))
        assertFrame(layout.description, rect(64.5, 479.335, 264, 22))
    }
}

