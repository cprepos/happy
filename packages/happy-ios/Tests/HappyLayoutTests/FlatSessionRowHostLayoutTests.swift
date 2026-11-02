import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import HappyLayout

/// The computer's name on the flat row's third line (FlatSessionRow.tsx):
/// harness, glyph, name, workspace, branch glyph, every piece 4 apart.
final class FlatSessionRowHostLayoutTests: XCTestCase {
    private func line(_ natural: CGFloat, height: CGFloat = 18) -> Measurable {
        Measurable { CGSize(width: min(natural, $0), height: height) }
    }

    private func row(workspace: CGFloat?, host: CGFloat?, harness: CGFloat = 88) -> FlatSessionRowLayout {
        FlatSessionRowLayout(.init(
            width: 393,
            title: line(100, height: 22),
            timestamp: line(56, height: 22),
            project: line(80, height: 20),
            workspace: workspace.map { line($0) },
            leadingHarness: line(harness),
            host: host.map { line($0) },
            showsDivider: false
        ))
    }

    func testTheComputerSitsBetweenTheHarnessAndTheWorkspace() {
        let layout = row(workspace: 40, host: 50)
        XCTAssertEqual(layout.harness, CGRect(x: 88, y: 53, width: 88, height: 18))
        XCTAssertEqual(layout.hostIcon, CGRect(x: 180, y: 55.5, width: 13, height: 13))
        XCTAssertEqual(layout.host, CGRect(x: 197, y: 53, width: 50, height: 18))
        XCTAssertEqual(layout.workspace, CGRect(x: 251, y: 53, width: 40, height: 18))
        XCTAssertEqual(layout.branchIcon, CGRect(x: 295, y: 55.5, width: 13, height: 13))
        XCTAssertEqual(layout.size.height, 81)
    }

    func testWithoutAWorkspaceTheComputerEndsTheLine() {
        let layout = row(workspace: nil, host: 50)
        XCTAssertEqual(layout.hostIcon, CGRect(x: 180, y: 55.5, width: 13, height: 13))
        XCTAssertEqual(layout.host, CGRect(x: 197, y: 53, width: 50, height: 18))
        XCTAssertNil(layout.workspace)
        XCTAssertNil(layout.branchIcon)
    }

    func testWithoutAComputerNothingIsReserved() {
        let layout = row(workspace: 72, host: nil)
        XCTAssertNil(layout.hostIcon)
        XCTAssertNil(layout.host)
        XCTAssertEqual(layout.workspace, CGRect(x: 180, y: 53, width: 72, height: 18))
        XCTAssertEqual(layout.branchIcon, CGRect(x: 256, y: 55.5, width: 13, height: 13))
    }

    /// 289 of column, less 88 of harness, two glyphs and four gaps: 159 for
    /// names wanting 100 and 300, so they keep a quarter and three quarters.
    func testTooWideTheTwoNamesGiveWayInProportionAndTheHarnessDoesNot() {
        let layout = row(workspace: 300, host: 100)
        XCTAssertEqual(layout.harness?.width, 88)
        XCTAssertEqual(layout.host?.width, 39.75)
        XCTAssertEqual(layout.workspace?.width, 119.25)
        XCTAssertEqual(layout.branchIcon?.maxX, 377)
    }

    /// Only the overflow is shared: names that fit keep their full width.
    func testNamesThatFitAreNotTouched() {
        let layout = row(workspace: 100, host: 59)
        XCTAssertEqual(layout.host?.width, 59)
        XCTAssertEqual(layout.workspace?.width, 100)
        XCTAssertEqual(layout.branchIcon?.maxX, 377)
    }

    /// A lone name has all the room: there is nothing to share it with.
    func testAComputerAloneTakesWhatTheHarnessLeaves() {
        let layout = row(workspace: nil, host: 800)
        XCTAssertEqual(layout.host?.width, 180)
        XCTAssertEqual(layout.host?.maxX, 377)
    }

    func testAHarnessAsWideAsTheRowLeavesTheNamesNothing() {
        let layout = row(workspace: 72, host: 50, harness: 500)
        XCTAssertEqual(layout.harness?.width, 289)
        XCTAssertEqual(layout.host?.width, 0)
        XCTAssertEqual(layout.workspace?.width, 0)
    }

    /// At large text a computer holds the row up as a workspace does.
    func testTheComputerHoldsTheRowUp() {
        let lines = FlatSessionRowLayout.Lines(title: 40, project: 36, workspace: 32)
        XCTAssertEqual(
            FlatSessionRowLayout.height(lines: lines, workspace: false, host: true),
            FlatSessionRowLayout.height(lines: lines, workspace: true)
        )
        XCTAssertGreaterThan(
            FlatSessionRowLayout.height(lines: lines, workspace: false, host: true),
            FlatSessionRowLayout.height(lines: lines, workspace: false)
        )
    }
}
