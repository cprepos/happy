#if canImport(UIKit)
import HappyCore
import HappyLayout
@testable import HappyUI
import UIKit
import XCTest

/// RigActivityBar.tsx's panel: its fallback pill opens it, a row opens on its
/// prompt and progress, and an agent that finishes leaves.
@MainActor
final class ChatRigActivityPanelTests: XCTestCase {
    private let agent = SubagentInfo(
        id: "a", title: "Fix", type: "Explore", prompt: "look", summary: "found", tokens: 1200,
        startedAt: Int64(Date().timeIntervalSince1970 * 1000), lastToolName: "Grep")

    private func makeBar() -> ChatRigActivityView {
        let bar = ChatRigActivityView(frame: CGRect(x: 0, y: 0, width: 393, height: 200))
        bar.traitOverrides.displayScale = 3
        return bar
    }

    private func measured(_ bar: ChatRigActivityView) async throws -> ChatRigActivityPlan {
        _ = bar.barMeasurable.height(fitting: 393)
        await bar.measure.measured()
        return try XCTUnwrap(bar.measure.plan)
    }

    func testAgentsWithoutIndicatorsOpenAndCloseThePanel() async throws {
        let bar = makeBar()
        XCTAssertTrue(bar.show([], running: [agent]))
        XCTAssertFalse(bar.content.isEmpty)
        let closed = try await measured(bar)
        XCTAssertEqual(closed.labels.count, 1)
        XCTAssertEqual(closed.layout.chevrons.compactMap { $0 }.count, 1)
        XCTAssertTrue(closed.rows.isEmpty)
        XCTAssertNil(closed.layout.divider)

        bar.togglePanel()
        let open = try await measured(bar)
        XCTAssertEqual(open.rows.map(\.content.id), ["a"])
        XCTAssertNotNil(open.layout.divider)
        XCTAssertGreaterThan(open.layout.size.height, closed.layout.size.height)

        bar.togglePanel()
        let closedAgain = try await measured(bar)
        XCTAssertTrue(closedAgain.rows.isEmpty)
        XCTAssertEqual(closedAgain.layout.size.height, closed.layout.size.height)
    }

    func testARowOpensOnItsPromptAndProgress() async throws {
        let bar = makeBar()
        bar.show([], running: [agent])
        bar.togglePanel()
        let folded = try await measured(bar)
        XCTAssertNil(folded.rows[0].prompt)

        bar.toggleAgent("a")
        let open = try await measured(bar)
        XCTAssertNotNil(open.rows[0].prompt)
        XCTAssertNotNil(open.rows[0].summary)
        XCTAssertNotNil(open.rows[0].lastTool)
        XCTAssertGreaterThan(open.layout.size.height, folded.layout.size.height)
    }

    func testAClosedPanelsNumbersChangeNothingDrawn() {
        let bar = makeBar()
        bar.show([], running: [agent])
        var later = agent
        later.tokens = 9000
        XCTAssertFalse(bar.show([], running: [later]))
        XCTAssertEqual(bar.content.agents.first?.tokens, 9000, "kept for when it opens")
    }

    func testAFinishedAgentLeavesAndIsNotOpenWhenItComesBack() async throws {
        let bar = makeBar()
        bar.show([], running: [agent])
        bar.togglePanel()
        bar.toggleAgent("a")
        XCTAssertTrue(bar.show([], running: []))
        XCTAssertTrue(bar.content.isEmpty)
        bar.show([], running: [agent])
        let back = try await measured(bar)
        XCTAssertEqual(back.rows.count, 1)
        XCTAssertFalse(back.rows[0].expanded)
    }
}
#endif
