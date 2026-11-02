import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import HappyLayout
import XCTest

/// RigActivityBar.tsx's chevrons and panel, and AgentRow's frames. Text here is
/// 8 pt a character; the numbers are worked out by hand from the RN styles.
final class RigActivityPanelLayoutTests: XCTestCase {
    private func title(_ string: String = "Fix") -> Measurable { text(string, lineHeight: 15, maxLines: 1) }
    private func number(_ string: String) -> Measurable { text(string, lineHeight: 13, maxLines: 1) }
    private func typeLabel(_ string: String) -> Measurable { text(string, lineHeight: 11, maxLines: 1) }

    // MARK: The counts

    func testACountThatOpensThePanelHasItsChevronAfterIt() {
        let layout = RigActivityLayout(width: 393, items: [
            .init(label: text("2 agents", lineHeight: 13), hasChevron: true),
            .init(label: text("1 tasks", lineHeight: 13)),
        ])
        assertFrame(layout.icons[0], rect(16, 5.5, 12, 12))
        assertFrame(layout.labels[0], rect(32, 5, 64, 13))
        assertFrame(layout.chevrons[0], rect(100, 6.5, 10, 10))
        assertFrame(layout.items[0], rect(16, 5, 94, 13))
        // 10 after the chevron, and no chevron of its own.
        assertFrame(layout.icons[1], rect(120, 5.5, 12, 12))
        assertFrame(layout.labels[1], rect(136, 5, 56, 13))
        XCTAssertNil(layout.chevrons[1])
        assertFrame(layout.items[1], rect(120, 5, 72, 13))
        XCTAssertEqual(layout.size.height, 23)
        XCTAssertNil(layout.divider)
        XCTAssertTrue(layout.rows.isEmpty)
    }

    func testTheChevronCountsWhenTheLineWraps() {
        // 12 + 4 + 136 + 14 is 166 wide, to 182 of the 184 it may reach; the next
        // count goes under it.
        let layout = RigActivityLayout(width: 200, items: [
            .init(label: text("17 chars of label", lineHeight: 13), hasChevron: true),
            .init(label: text("x", lineHeight: 13)),
        ])
        assertFrame(layout.items[0], rect(16, 5, 166, 13))
        assertFrame(layout.items[1], rect(16, 28, 24, 13))
        XCTAssertEqual(layout.size.height, 46)
    }

    func testPlainLabelsMakeNoChevronsAndAnEmptyBarHasNoHeight() {
        let layout = RigActivityLayout(width: 200, labels: [text("3 tasks", lineHeight: 13)])
        XCTAssertEqual(layout.chevrons, [nil])
        assertFrame(layout.items[0], rect(16, 5, 72, 13))
        let row = RigAgentRowLayout.Input(title: title(), elapsed: number("1s"))
        XCTAssertEqual(RigActivityLayout(width: 200, items: [], rows: [row]).size.height, 0)
    }

    // MARK: The panel

    func testThePanelSitsUnderTheCountsWithItsHairline() {
        let layout = RigActivityLayout(
            width: 393,
            items: [.init(label: text("1 running", lineHeight: 13), hasChevron: true)],
            rows: [
                .init(title: title("A"), elapsed: number("1s")),
                .init(title: title("B"), elapsed: number("2s")),
            ])
        // Counts end at 18; 6 down the hairline, 0.5 tall; 4 more and the rows.
        assertFrame(layout.divider, rect(16, 24, 361, 0.5))
        assertFrame(layout.rows[0].frame, rect(16, 28.5, 361, 23))
        assertFrame(layout.rows[1].frame, rect(16, 51.5, 361, 23))
        XCTAssertEqual(layout.size.height, 79.5)
    }

    // MARK: A row

    func testAFullHeaderFillsItsLine() {
        let row = RigAgentRowLayout(x: 16, y: 0, width: 361, .init(
            title: title("Fix the build"), type: typeLabel("Explore"), elapsed: number("1m 5s"), tokens: number("1.2k tok")))
        assertFrame(row.frame, rect(16, 0, 361, 23))
        assertFrame(row.dot, rect(4, 8.5, 6, 6))
        // Content 353. Fixed: 6 dot + 6 + 6 + 12 chevron = 30.
        // Tokens 64 + 6, elapsed 40 + 6, badge 66 + 6: title 323 - 188 = 135.
        assertFrame(row.title, rect(16, 4, 135, 15))
        assertFrame(row.badge, rect(157, 5, 66, 13))
        assertFrame(row.type, rect(162, 6, 56, 11))
        assertFrame(row.elapsed, rect(229, 5, 40, 13))
        assertFrame(row.tokens, rect(275, 5, 64, 13))
        assertFrame(row.chevron, rect(345, 5.5, 12, 12))
        XCTAssertEqual(row.chevron.maxX, 357, "4 inside the row's 361")
    }

    func testAMinimalHeaderHasNoBadgeOrTokens() {
        let row = RigAgentRowLayout(x: 0, y: 10, width: 100, .init(title: title(), elapsed: number("1s")))
        assertFrame(row.frame, rect(0, 10, 100, 23))
        XCTAssertNil(row.badge)
        XCTAssertNil(row.type)
        XCTAssertNil(row.tokens)
        // Content 92: 92 - 30 - 16 - 6 = 40.
        assertFrame(row.title, rect(16, 4, 40, 15))
        assertFrame(row.elapsed, rect(62, 5, 16, 13))
        assertFrame(row.chevron, rect(84, 5.5, 12, 12))
    }

    func testASpawnedAgentSits16In() {
        let row = RigAgentRowLayout(x: 16, y: 0, width: 361, .init(title: title(), elapsed: number("1s"), indented: true))
        assertFrame(row.frame, rect(32, 0, 345, 23))
        assertFrame(row.chevron, rect(329, 5.5, 12, 12))
    }

    func testExpandedTheDetailsFollowInOrder() {
        let row = RigAgentRowLayout(x: 16, y: 0, width: 361, .init(
            title: title(), elapsed: number("1s"), expanded: true,
            prompt: text("look", lineHeight: 14, maxLines: 3),
            summary: text("found", lineHeight: 14, maxLines: 2),
            lastTool: text("tool", lineHeight: 13)))
        // Line ends at 19; 4 more.
        assertFrame(row.prompt, rect(16, 23, 32, 14))
        assertFrame(row.summary, rect(16, 39, 40, 14))
        assertFrame(row.lastTool, rect(16, 55, 32, 13))
        assertFrame(row.frame, rect(16, 0, 361, 72))
    }

    func testExpandedALongPromptWrapsToItsLinesInTheNarrowerWidth() {
        // 80 wide: content 72, details 60, so 7 characters a line at 56.
        let row = RigAgentRowLayout(x: 0, y: 0, width: 80, .init(
            title: title(), elapsed: number("1s"), expanded: true,
            prompt: text(String(repeating: "x", count: 100), lineHeight: 14, maxLines: 3)))
        assertFrame(row.prompt, rect(16, 23, 56, 42))
        assertFrame(row.frame, rect(0, 0, 80, 69))
    }

    func testExpandedWithNothingToSayIsTheGapAlone() {
        let row = RigAgentRowLayout(x: 0, y: 0, width: 200, .init(title: title(), elapsed: number("1s"), expanded: true))
        XCTAssertNil(row.prompt)
        XCTAssertNil(row.summary)
        XCTAssertNil(row.lastTool)
        assertFrame(row.frame, rect(0, 0, 200, 27))
    }

    func testCollapsedTheDetailsTakeNoRoom() {
        let row = RigAgentRowLayout(x: 0, y: 0, width: 200, .init(
            title: title(), elapsed: number("1s"), expanded: false, prompt: text("look", lineHeight: 14, maxLines: 3)))
        XCTAssertNil(row.prompt)
        assertFrame(row.frame, rect(0, 0, 200, 23))
    }

    func testALargerTextSizeSetsTheLinesHeight() {
        let row = RigAgentRowLayout(x: 0, y: 0, width: 300, .init(
            title: text("Fix", lineHeight: 30, maxLines: 1), elapsed: text("1s", lineHeight: 20, maxLines: 1)))
        assertFrame(row.title, rect(16, 4, 300 - 8 - 30 - 22, 30))
        assertFrame(row.elapsed, rect(262, 9, 16, 20))
        XCTAssertEqual(row.chevron.minY, 13)
        XCTAssertEqual(row.dot.minY, 16)
        XCTAssertEqual(row.frame.height, 38)
    }

    func testATooNarrowRowCutsItsPartsAndKeepsTheChevronInside() {
        let row = RigAgentRowLayout(x: 0, y: 0, width: 80, .init(
            title: title("A long title"), type: typeLabel("Explore"), elapsed: number("1m 5s"), tokens: number("1.2k tok")))
        // Content 72, 30 fixed: 42 for the rest; tokens get 36, the rest go.
        XCTAssertEqual(row.tokens?.width, 36)
        XCTAssertEqual(row.elapsed.width, 0)
        XCTAssertNil(row.badge)
        XCTAssertNil(row.type)
        XCTAssertEqual(row.title.width, 0)
        XCTAssertEqual(row.chevron.maxX, row.frame.width - 4, accuracy: 0.001)
    }

    func testNoWidthIsNoCrash() {
        let row = RigAgentRowLayout(x: 0, y: 0, width: 0, .init(
            title: title(), type: typeLabel("E"), elapsed: number("1s"), tokens: number("1"), indented: true, expanded: true,
            prompt: text("p", lineHeight: 14)))
        XCTAssertEqual(row.frame.width, 0)
        XCTAssertGreaterThanOrEqual(row.title.width, 0)
        XCTAssertGreaterThanOrEqual(row.elapsed.width, 0)
    }
}
