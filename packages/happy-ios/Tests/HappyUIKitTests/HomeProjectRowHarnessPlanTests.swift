#if canImport(UIKit)
@testable import HappyCore
import HappyLayout
@testable import HappyUI
import UIKit
import XCTest

/// The harness's name on the grouped list's rows as their plans draw them,
/// with the fonts the phone uses: on the row, its line whole, and spoken.
@MainActor
final class HomeProjectRowHarnessPlanTests: XCTestCase {
    private static func entry(harness: String?) -> ProjectHomeEntry {
        ProjectHomeEntry(
            id: "p",
            name: "happy-with-a-rather-long-project-name",
            sessionId: harness == nil ? nil : "s",
            avatar: SessionAvatar(seed: "s"),
            worktreeCount: 1,
            activity: HomeActivity(unread: true),
            live: true,
            changes: HomeRowMeasurerTests.changes,
            origin: WorkspaceOrigin(machineId: "m", projectId: nil, path: "/work/happy"),
            harnessName: harness
        )
    }

    private static func worktree(harness: String?, changes: GitLineChanges? = HomeRowMeasurerTests.changes) -> ProjectWorktree {
        ProjectWorktree(
            id: "w",
            title: "a-rather-long-worktree-name-that-truncates",
            sessionId: "s",
            activity: HomeActivity(unread: true),
            changes: changes,
            harnessName: harness
        )
    }

    private func texts(_ plan: HomeRowDrawing) -> [String: CGRect] {
        var found: [String: CGRect] = [:]
        for case .text(let value, _, _, let frame) in plan.marks { found[value] = frame }
        return found
    }

    private func drawn(_ value: String, _ plan: HomeRowDrawing) -> Int {
        var count = 0
        for case .text(let text, _, _, _) in plan.marks where text == value { count += 1 }
        return count
    }

    func testAProjectDrawsAndSpeaksItsHarnessAtEveryTextSize() async {
        for category in [UIContentSizeCategory.extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge] {
            let text = TextEnvironment(scale: TextScale(TextSizeCategory(category)), displayScale: 3)
            let environment = await HomeTextEnvironment.make(text)
            let rows: [(HomeListRow, String)] = [
                (.project(.project(Self.entry(harness: "Claude Code"))), "happy-with-a-rather-long-project-name, Claude Code"),
            ]
            for (row, label) in rows {
                for width in [CGFloat(320), 393, 430] {
                    let at = "\(category.rawValue) \(width) \(label)"
                    let plan = await Task.detached { HomeRowDrawing.make(row, width: width, grouped: true, selected: false, carded: true, environment: environment, dark: false) }.value
                    XCTAssertEqual(plan.accessibilityLabel, label, at)
                    let found = texts(plan)
                    let harness = found["Claude Code"]
                    XCTAssertNotNil(harness, at)
                    guard let harness else { continue }
                    XCTAssertGreaterThan(harness.width, 0, at)
                    XCTAssertEqual(harness.height, TextStyles.sessionHarness.oneLine(in: text), at)
                    for (value, frame) in found {
                        XCTAssertTrue(CGRect(origin: .zero, size: plan.size).insetBy(dx: -0.001, dy: -0.001).contains(frame), "\(value) runs out of the row, \(at)")
                    }
                    // Clear of the rest of the row's text.
                    for (value, frame) in found where value != "Claude Code" {
                        XCTAssertFalse(harness.intersects(frame), "\(value) is under the harness, \(at)")
                    }
                    // Its whole width, wherever the row has that much.
                    let natural = HomeRowMeasurer.measure("Claude Code", style: TextStyles.sessionHarness, in: text, width: .greatestFiniteMagnitude, maxLines: 1).width
                    let room = HomeCardLayout.contentWidth(width) - ProjectListMetrics.nameX - ProjectListMetrics.paddingX
                    if natural <= room {
                        XCTAssertEqual(harness.width, natural, accuracy: 0.001, at)
                    } else {
                        // Longer than any row this wide: what fits, up to its edge.
                        XCTAssertLessThanOrEqual(harness.width, room, at)
                    }
                }
            }
        }
    }

    /// `name · harness`: the harness whole in the line's own style, its name
    /// giving way, and the row's height its own, at every text size. With no
    /// counts beside it, so the lane is the row's; `HomeRowHarnessLayoutTests`
    /// has the lane the counts leave.
    func testAWorktreeSaysItsHarnessAfterItsNameAtEveryTextSize() async throws {
        for category in [UIContentSizeCategory.extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge] {
            let text = TextEnvironment(scale: TextScale(TextSizeCategory(category)), displayScale: 3)
            let environment = await HomeTextEnvironment.make(text)
            let row = HomeListRow.project(.worktree(Self.worktree(harness: "Claude Code", changes: nil), last: false))
            let bare = HomeListRow.project(.worktree(Self.worktree(harness: nil, changes: nil), last: false))
            for width in [CGFloat(320), 393, 430] {
                let at = "\(category.rawValue) \(width)"
                let plan = await Task.detached { HomeRowDrawing.make(row, width: width, grouped: true, selected: false, carded: true, environment: environment, dark: false) }.value
                let without = await Task.detached { HomeRowDrawing.make(bare, width: width, grouped: true, selected: false, carded: true, environment: environment, dark: false) }.value
                XCTAssertEqual(plan.accessibilityLabel, "a-rather-long-worktree-name-that-truncates, Claude Code", at)
                XCTAssertEqual(plan.size.height, without.size.height, at)
                let harness = try XCTUnwrap(texts(plan)["Claude Code"], at)
                let natural = HomeRowMeasurer.measure("Claude Code", style: TextStyles.worktreeName, in: text, width: .greatestFiniteMagnitude, maxLines: 1).width
                let room = HomeCardLayout.contentWidth(width) - ProjectListMetrics.nameX - ProjectListMetrics.paddingX
                // Less the unread dot and the gaps around it.
                if natural <= room - 40 {
                    XCTAssertEqual(harness.width, natural, accuracy: 0.001, at)
                }
                XCTAssertTrue(CGRect(origin: .zero, size: plan.size).insetBy(dx: -0.001, dy: -0.001).contains(harness), at)
                if let separator = texts(plan)[HomeRowHarness.separator] {
                    XCTAssertLessThanOrEqual(separator.maxX, harness.minX, at)
                }
            }
        }
    }

    /// `feature-x · Codex`, once, after the worktree, spoken after it.
    func testAFlatRowWithAWorktreeSaysItsHarnessAfterIt() async throws {
        let environment = await HomeTextEnvironment.make(.init(scale: .standard, displayScale: 3))
        var row = HomeRowMeasurerTests.session(workspace: "feature-x")
        row.harnessName = "Codex"
        let chat = row
        let plan = await Task.detached { HomeRowDrawing.make(.flat(.session(chat)), width: 393, grouped: false, selected: false, carded: true, environment: environment, dark: false) }.value
        XCTAssertEqual(drawn("Codex", plan), 1)
        let found = texts(plan)
        let workspace = try XCTUnwrap(found["feature-x"])
        let separator = try XCTUnwrap(found[HomeRowHarness.separator])
        let harness = try XCTUnwrap(found["Codex"])
        XCTAssertLessThan(workspace.maxX, separator.minX)
        XCTAssertLessThan(separator.maxX, harness.minX)
        XCTAssertTrue(plan.accessibilityLabel.contains("feature-x, Codex"), plan.accessibilityLabel)
    }

    /// With no worktree to follow, the harness stands alone, once.
    func testAFlatRowWithNoWorktreeDrawsItsHarnessOnce() async {
        let environment = await HomeTextEnvironment.make(.init(scale: .standard, displayScale: 3))
        var row = HomeRowMeasurerTests.session(workspace: nil)
        row.harnessName = "Codex"
        let chat = row
        let plan = await Task.detached { HomeRowDrawing.make(.flat(.session(chat)), width: 393, grouped: false, selected: false, carded: true, environment: environment, dark: false) }.value
        XCTAssertEqual(drawn("Codex", plan), 1)
        XCTAssertNil(texts(plan)[HomeRowHarness.separator])
        XCTAssertTrue(plan.accessibilityLabel.contains("Codex"), plan.accessibilityLabel)
    }

    func testARowWithoutAHarnessDrawsAndSpeaksOnlyItsName() async {
        let environment = await HomeTextEnvironment.make(.init(scale: .standard, displayScale: 3))
        let entry = Self.entry(harness: nil)
        let plan = await Task.detached { HomeRowDrawing.make(.project(.project(entry)), width: 393, grouped: true, selected: false, carded: true, environment: environment, dark: false) }.value
        XCTAssertEqual(plan.accessibilityLabel, "happy-with-a-rather-long-project-name")
        XCTAssertNil(texts(plan)["Claude Code"])
    }

    /// A chat grouped by host is the flat list's row, harness and all.
    func testAChatGroupedByHostDrawsAndSpeaksItsHarness() async throws {
        let environment = await HomeTextEnvironment.make(.init(scale: .standard, displayScale: 3))
        var row = HomeRowMeasurerTests.session(workspace: "fix-login")
        row.harnessName = "Codex"
        let chat = row
        let plan = await Task.detached { HomeRowDrawing.make(.project(.chat(chat)), width: 393, grouped: true, selected: false, carded: true, environment: environment, dark: false) }.value
        let found = texts(plan)
        let harness = try XCTUnwrap(found["Codex"])
        let workspace = try XCTUnwrap(found["fix-login"])
        XCTAssertLessThan(harness.maxX, workspace.minX)
        XCTAssertTrue(plan.accessibilityLabel.contains("Codex"))
    }
}
#endif
