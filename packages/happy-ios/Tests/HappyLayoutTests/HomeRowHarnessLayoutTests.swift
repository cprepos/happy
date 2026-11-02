import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import HappyLayout
import XCTest

/// `feature-x · OpenCode` on a worktree's line, in the project list's
/// worktree rows and on the flat list's third row.
final class HomeRowHarnessLayoutTests: XCTestCase {
    private let long = String(repeating: "a", count: 60)

    private func harness(_ name: String = "OpenCode", line: CGFloat = 20) -> HomeRowHarnessText {
        HomeRowHarnessText(name: text(name, lineHeight: line, maxLines: 1), separator: text("·", lineHeight: line, maxLines: 1))
    }

    private func worktree(_ name: String = "feature-x", changes: Measurable? = nil, line: CGFloat = 20, harness: HomeRowHarnessText?) -> WorktreeRowLayout {
        WorktreeRowLayout(.init(width: 393, hairline: 1.0 / 3, label: text(name, lineHeight: line, maxLines: 1), showsDot: false, changes: changes, last: false, harness: harness))
    }

    private func flat(_ name: String = "feature-x", changes: CGSize? = nil, lines: FlatSessionRowLayout.Lines = .designed, harness: HomeRowHarnessText?) -> FlatSessionRowLayout {
        FlatSessionRowLayout(.init(
            width: 393,
            title: fixed(200, lines.title),
            timestamp: fixed(40, 22),
            project: fixed(100, lines.project),
            workspace: text(name, lineHeight: lines.workspace, maxLines: 1),
            branchIcon: CGSize(width: 13, height: 13),
            changes: changes,
            draftIcon: nil,
            showsDivider: false,
            lines: lines,
            harness: harness
        ))
    }

    // MARK: Worktree rows

    func testAWorktreeNameHugsItsTextAndTheHarnessFollows() {
        let row = worktree(harness: harness())
        assertFrame(row.label, rect(56, 14, 72, 20))
        assertFrame(row.harnessSeparator, rect(132, 14, 8, 20))
        assertFrame(row.harness, rect(144, 14, 64, 20))
    }

    func testALongWorktreeNameTruncatesAndTheHarnessKeepsItsWidth() {
        let row = worktree(long, harness: harness())
        assertFrame(row.label, rect(56, 14, 233, 20))
        assertFrame(row.harnessSeparator, rect(293, 14, 8, 20))
        assertFrame(row.harness, rect(305, 14, 64, 20))
    }

    func testTheHarnessStopsAtTheTrailingColumn() {
        let row = worktree(long, changes: fixed(52, 18), harness: harness())
        assertFrame(row.label, rect(56, 14, 181, 20))
        assertFrame(row.harnessSeparator, rect(241, 14, 8, 20))
        assertFrame(row.harness, rect(253, 14, 64, 20))
    }

    func testAHarnessWiderThanTheLaneIsClampedAndStandsAlone() {
        let row = worktree(harness: harness(long))
        XCTAssertEqual(row.label.width, 0)
        XCTAssertNil(row.harnessSeparator)
        assertFrame(row.harness, rect(56, 14, 313, 20))
    }

    func testAHarnessThatLeavesOnlyTheSeparatorDropsTheName() {
        // 39 characters are 312, and the gaps and the separator take the last of the lane.
        let row = worktree(harness: harness(String(repeating: "a", count: 39)))
        XCTAssertEqual(row.label.width, 0)
        XCTAssertNil(row.harnessSeparator)
        assertFrame(row.harness, rect(56, 14, 312, 20))
    }

    func testAWorktreeRowWithoutAHarnessKeepsTheWholeLane() {
        let row = worktree(harness: nil)
        assertFrame(row.label, rect(56, 14, 313, 20))
        XCTAssertNil(row.harnessSeparator)
        XCTAssertNil(row.harness)
    }

    func testTheHarnessDoesNotMoveAWorktreeRowsHeight() {
        for line in [20, 40, 80] as [CGFloat] {
            for name in ["feature-x", long] {
                let with = worktree(name, line: line, harness: harness(line: line))
                let without = worktree(name, line: line, harness: nil)
                XCTAssertEqual(with.size, without.size, "at \(line)")
                XCTAssertEqual(with.harness?.midY, without.label.midY, "at \(line)")
            }
        }
    }

    // MARK: Flat rows

    func testAFlatRowsWorkspaceAndHarnessShareTheLineAheadOfTheBranchIcon() {
        let row = flat(harness: harness(line: 18))
        assertFrame(row.workspace, rect(88, 53, 72, 18))
        assertFrame(row.harnessSeparator, rect(164, 53, 8, 18))
        assertFrame(row.harness, rect(176, 53, 64, 18))
        assertFrame(row.branchIcon, rect(244, 55.5, 13, 13))
    }

    func testALongWorkspaceTruncatesAheadOfTheHarnessAndTheIconStaysInTheLane() {
        let row = flat(long, harness: harness(line: 18))
        // 289 wide, less the icon and its gap, is a 272 lane, and the harness keeps 80 of it.
        assertFrame(row.workspace, rect(88, 53, 192, 18))
        assertFrame(row.harnessSeparator, rect(284, 53, 8, 18))
        assertFrame(row.harness, rect(296, 53, 64, 18))
        assertFrame(row.branchIcon, rect(364, 55.5, 13, 13))
    }

    func testAFlatRowsHarnessStopsAtTheLineCounts() throws {
        let row = flat(long, changes: CGSize(width: 40, height: 16), harness: harness(line: 18))
        let counts = try XCTUnwrap(row.changes)
        let icon = try XCTUnwrap(row.branchIcon)
        XCTAssertEqual(icon.maxX, counts.minX - FlatSessionRowLayout.Metrics.changesPaddingLeft)
        assertFrame(row.harness, CGRect(x: icon.minX - 4 - 64, y: 53, width: 64, height: 18))
    }

    func testAFlatRowsHarnessWiderThanTheLaneIsClampedAndStandsAlone() {
        let row = flat(harness: harness(long, line: 18))
        XCTAssertEqual(row.workspace?.width, 0)
        XCTAssertNil(row.harnessSeparator)
        assertFrame(row.harness, rect(88, 53, 272, 18))
        assertFrame(row.branchIcon, rect(364, 55.5, 13, 13))
    }

    func testAFlatRowWithoutAWorkspaceDrawsNoHarness() {
        let row = FlatSessionRowLayout(.init(
            width: 393, title: fixed(200, 22), timestamp: fixed(40, 22), project: fixed(100, 18), workspace: nil,
            branchIcon: CGSize(width: 13, height: 13), changes: nil, draftIcon: nil, showsDivider: false, lines: .designed,
            harness: harness(line: 18)
        ))
        XCTAssertNil(row.harnessSeparator)
        XCTAssertNil(row.harness)
    }

    func testTheHarnessDoesNotMoveAFlatRowsHeight() {
        let scales: [CGFloat] = [1, 2, 4]
        for scale in scales {
            let designed = FlatSessionRowLayout.Lines.designed
            let lines = FlatSessionRowLayout.Lines(title: designed.title * scale, project: designed.project * scale, workspace: designed.workspace * scale, changes: designed.changes * scale)
            for name in ["feature-x", long] {
                let with = flat(name, lines: lines, harness: harness(line: lines.workspace))
                let without = flat(name, lines: lines, harness: nil)
                XCTAssertEqual(with.size, without.size, "at \(scale)x")
                XCTAssertEqual(with.harness?.midY, without.workspace?.midY, "at \(scale)x")
            }
        }
    }
}
