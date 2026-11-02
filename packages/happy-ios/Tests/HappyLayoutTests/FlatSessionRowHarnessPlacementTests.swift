import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import HappyLayout
import XCTest

/// Where a flat row has the harness: after a worktree, or as its own text.
final class FlatSessionRowHarnessPlacementTests: XCTestCase {
    private func line(_ natural: CGFloat, height: CGFloat = 18) -> Measurable {
        Measurable { CGSize(width: min(natural, $0), height: height) }
    }

    private func row(
        workspace: CGFloat?,
        host: CGFloat? = nil,
        leading: CGFloat? = nil,
        after: CGFloat? = nil,
        lines: FlatSessionRowLayout.Lines = .designed
    ) -> FlatSessionRowLayout {
        FlatSessionRowLayout(.init(
            width: 393,
            title: line(200, height: lines.title),
            timestamp: line(40, height: 22),
            project: line(100, height: lines.project),
            workspace: workspace.map { line($0, height: lines.workspace) },
            leadingHarness: leading.map { line($0, height: lines.workspace) },
            host: host.map { line($0, height: lines.workspace) },
            branchIcon: CGSize(width: 13, height: 13),
            showsDivider: false,
            lines: lines,
            harness: after.map { HomeRowHarnessText(name: line($0, height: lines.workspace), separator: line(4, height: lines.workspace)) }
        ))
    }

    private func assertFrame(_ frame: CGRect?, _ x: CGFloat, _ width: CGFloat, line: UInt = #line) {
        XCTAssertEqual(frame?.minX ?? -1, x, accuracy: 0.001, line: line)
        XCTAssertEqual(frame?.width ?? -1, width, accuracy: 0.001, line: line)
    }

    func testAHarnessOfItsOwnKeepsTheDesignedHeight() {
        XCTAssertEqual(row(workspace: nil, leading: 88).size.height, 81)
        XCTAssertEqual(row(workspace: nil).size.height, 81)
    }

    /// Past the designed size it holds a line, as a worktree's row does.
    func testAHarnessOfItsOwnIsAsTallAsARowWithAWorktree() {
        let large = FlatSessionRowLayout.Lines(title: 30, project: 28, workspace: 32)
        XCTAssertEqual(row(workspace: nil, leading: 88, lines: large).size.height, row(workspace: 72, after: 60, lines: large).size.height)
        XCTAssertGreaterThan(row(workspace: nil, leading: 88, lines: large).size.height, row(workspace: nil, lines: large).size.height)
    }

    func testAHarnessOfItsOwnStartsTheLineWithNoSeparator() {
        let layout = row(workspace: nil, leading: 88)
        assertFrame(layout.harness, 88, 88)
        XCTAssertNil(layout.harnessSeparator)
        XCTAssertNil(layout.branchIcon)
    }

    /// Grouped by host: the harness, then the worktree, no separator.
    func testAHarnessOfItsOwnStaysAheadOfAWorktree() {
        let layout = row(workspace: 72, leading: 88)
        assertFrame(layout.harness, 88, 88)
        assertFrame(layout.workspace, 180, 72)
        XCTAssertNil(layout.harnessSeparator)
    }

    func testTheRowHasOneHarnessWhenGivenBoth() {
        let layout = row(workspace: 72, leading: 88, after: 60)
        assertFrame(layout.harness, 88, 88)
        XCTAssertNil(layout.harnessSeparator)
    }

    /// `🖥 Studio feature-x · OpenCode ⑂`
    func testTheComputerStandsAheadOfAWorktreeAndItsHarness() {
        let layout = row(workspace: 72, host: 50, after: 60)
        assertFrame(layout.hostIcon, 88, 13)
        assertFrame(layout.host, 105, 50)
        assertFrame(layout.workspace, 159, 72)
        assertFrame(layout.harnessSeparator, 235, 4)
        assertFrame(layout.harness, 243, 60)
        assertFrame(layout.branchIcon, 307, 13)
    }

    /// The computer and the worktree share what the harness leaves, 179 here;
    /// the harness and the glyph end the line at the row's edge.
    func testTooWideTheComputerAndTheWorktreeGiveWayAndTheHarnessDoesNot() {
        let layout = row(workspace: 300, host: 200, after: 60)
        assertFrame(layout.host, 105, 71.6)
        assertFrame(layout.workspace, 180.6, 107.4)
        assertFrame(layout.harnessSeparator, 292, 4)
        assertFrame(layout.harness, 300, 60)
        assertFrame(layout.branchIcon, 364, 13)
    }

    func testWithNoWorktreeAHarnessToFollowItDrawsNothing() {
        let layout = row(workspace: nil, host: 50, after: 60)
        XCTAssertNil(layout.harness)
        XCTAssertNil(layout.harnessSeparator)
    }
}
