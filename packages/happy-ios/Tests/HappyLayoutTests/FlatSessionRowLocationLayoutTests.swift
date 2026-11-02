import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import HappyLayout

/// The flat row's third line (FlatSessionRow.tsx `workspaceLocation`): what
/// runs the chat, then the workspace, in the width the meta leaves.
final class FlatSessionRowLocationLayoutTests: XCTestCase {
    /// A one-line label: its natural width, truncated at what it is offered.
    private func line(_ natural: CGFloat, height: CGFloat = 18) -> Measurable {
        Measurable { CGSize(width: min(natural, $0), height: height) }
    }

    private func row(
        width: CGFloat = 393,
        workspace: CGFloat?,
        harness: CGFloat? = 88,
        changes: CGSize? = nil,
        draft: CGSize? = nil
    ) -> FlatSessionRowLayout {
        FlatSessionRowLayout(.init(
            width: width,
            title: line(100, height: 22),
            timestamp: line(56, height: 22),
            project: line(80, height: 20),
            workspace: workspace.map { line($0) },
            harness: harness.map { line($0) },
            changes: changes,
            draftIcon: draft,
            showsDivider: false
        ))
    }

    func testTheHarnessLeadsTheWorkspaceAndItsBranch() {
        let layout = row(workspace: 72)
        XCTAssertEqual(layout.harness, CGRect(x: 88, y: 53, width: 88, height: 18))
        XCTAssertEqual(layout.workspace, CGRect(x: 180, y: 53, width: 72, height: 18))
        XCTAssertEqual(layout.branchIcon, CGRect(x: 256, y: 55.5, width: 13, height: 13))
        XCTAssertEqual(layout.size.height, 81)
    }

    func testAHarnessAloneIsAtTheColumnsStart() {
        let layout = row(workspace: nil)
        XCTAssertEqual(layout.harness, CGRect(x: 88, y: 53, width: 88, height: 18))
        XCTAssertNil(layout.workspace)
        XCTAssertNil(layout.branchIcon)
    }

    func testWithoutAHarnessTheWorkspaceStaysWhereItWas() {
        let layout = row(workspace: 72, harness: nil)
        XCTAssertNil(layout.harness)
        XCTAssertEqual(layout.workspace, CGRect(x: 88, y: 53, width: 72, height: 18))
        XCTAssertEqual(layout.branchIcon, CGRect(x: 164, y: 55.5, width: 13, height: 13))
    }

    /// 289 of column: 88 for the harness, 4, 180 for the workspace, 4, 13.
    func testTheWorkspaceTruncatesAndTheHarnessDoesNot() {
        let layout = row(workspace: 800)
        XCTAssertEqual(layout.harness?.width, 88)
        XCTAssertEqual(layout.workspace, CGRect(x: 180, y: 53, width: 180, height: 18))
        XCTAssertEqual(layout.branchIcon?.maxX, 377)
    }

    /// The counts and the draft glyph keep their width; the workspace pays.
    func testTheMetaTakesItsWidthFromTheWorkspaceNotTheHarness() {
        let layout = row(workspace: 800, changes: CGSize(width: 60, height: 14.3), draft: CGSize(width: 13, height: 13))
        XCTAssertEqual(layout.harness?.width, 88)
        XCTAssertEqual(layout.draftIcon?.minX, 296)
        XCTAssertEqual(layout.workspace?.width, 99)
        XCTAssertEqual(layout.branchIcon?.maxX, 296)
    }

    /// A harness wider than all the row has is held to the row, and the
    /// workspace has nothing.
    func testAnEnormousHarnessStopsAtTheRow() {
        let layout = row(workspace: 72, harness: 500)
        XCTAssertEqual(layout.harness?.width, 289)
        XCTAssertEqual(layout.workspace?.width, 0)
    }

    /// The name is a line of the row: at large text it holds the row up even
    /// without a workspace, and its height is `height(...)`'s.
    func testTheHarnessHoldsTheRowUpLikeAWorkspace() {
        let lines = FlatSessionRowLayout.Lines(title: 40, project: 36, workspace: 32)
        let with = FlatSessionRowLayout.height(lines: lines, workspace: false, harness: true)
        let without = FlatSessionRowLayout.height(lines: lines, workspace: false)
        XCTAssertEqual(with, 10 + 40 + 36 + 1 + 32 + 10)
        XCTAssertEqual(without, 10 + 40 + 36 + 1 + 18 + 10)
        let layout = FlatSessionRowLayout(.init(
            width: 393,
            title: line(100, height: 40),
            timestamp: line(56, height: 40),
            project: line(80, height: 36),
            workspace: nil,
            harness: line(88, height: 32),
            showsDivider: false,
            lines: lines
        ))
        XCTAssertEqual(layout.size.height, with)
        XCTAssertEqual(layout.harness, CGRect(x: 88, y: 10 + 40 + 36 + 1, width: 88, height: 32))
    }

    /// The row takes the workspace's line for the harness's, which holds
    /// only while the two styles share a size and a line height.
    func testTheHarnessStyleIsTheWorkspacesLineAndOnlyHeavier() {
        XCTAssertEqual(TextStyles.sessionHarness, TextStyle(.semiBold, size: 13, lineHeight: 18))
        XCTAssertEqual(TextStyles.sessionWorkspace, TextStyle(.regular, size: 13, lineHeight: 18))
    }
}
