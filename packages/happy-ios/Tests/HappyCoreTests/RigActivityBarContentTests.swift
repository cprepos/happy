import XCTest
@testable import HappyCore

/// RigActivityBar.tsx's pills and AgentRow's words.
final class RigActivityBarContentTests: XCTestCase {
    private let agents = [SubagentInfo(id: "a", startedAt: 200), SubagentInfo(id: "b", startedAt: 100)]

    func testNothingToSayIsAHiddenBar() {
        XCTAssertTrue(RigActivityBarContent(indicators: [], running: []).isEmpty)
    }

    func testIndicatorsAloneOpenNothing() {
        let content = RigActivityBarContent(
            indicators: [RigActivityIndicator(kind: .subagents, count: 3, queued: 1), RigActivityIndicator(kind: .tasks, count: 2)],
            running: [])
        XCTAssertEqual(content.items.map(\.opensPanel), [false, false])
        XCTAssertEqual(content.items.map(\.isFallback), [false, false])
        XCTAssertEqual(content.items[0].indicator.count, 3)
    }

    func testAgentsWithoutAnIndicatorAreTheFallbackPill() {
        let content = RigActivityBarContent(indicators: [], running: agents)
        XCTAssertEqual(content.items.count, 1)
        XCTAssertTrue(content.items[0].isFallback)
        XCTAssertTrue(content.items[0].opensPanel)
        XCTAssertEqual(content.items[0].indicator, RigActivityIndicator(kind: .subagents, count: 2))
    }

    func testTheFallbackPillComesAfterOtherIndicators() {
        let content = RigActivityBarContent(indicators: [RigActivityIndicator(kind: .processes, count: 1)], running: agents)
        XCTAssertEqual(content.items.map(\.indicator.kind), [.processes, .subagents])
        XCTAssertEqual(content.items.map(\.isFallback), [false, true])
        XCTAssertEqual(content.items.map(\.opensPanel), [false, true])
    }

    func testTheEventsCountBeatsTheMetadatasAndTheQueueStays() {
        let content = RigActivityBarContent(indicators: [RigActivityIndicator(kind: .subagents, count: 9, queued: 4)], running: agents)
        XCTAssertEqual(content.items.count, 1)
        XCTAssertFalse(content.items[0].isFallback)
        XCTAssertTrue(content.items[0].opensPanel)
        XCTAssertEqual(content.items[0].indicator, RigActivityIndicator(kind: .subagents, count: 2, queued: 4))
    }

    func testTheRowSaysWhatTheAgentReports() {
        let row = RigAgentRowContent(
            SubagentInfo(id: "a", title: "Fix", type: "Explore", prompt: "look", summary: "found", tokens: 1200, startedAt: 1000, spawnDepth: 2, lastToolName: "Grep"),
            now: 66_000)
        XCTAssertEqual(row.id, "a")
        XCTAssertEqual(row.title, "Fix")
        XCTAssertEqual(row.type, "Explore")
        XCTAssertEqual(row.elapsed, "1m 5s")
        XCTAssertEqual(row.tokens, "1.2k tok")
        XCTAssertEqual(row.prompt, "look")
        XCTAssertEqual(row.summary, "found")
        XCTAssertEqual(row.lastTool, "↳ Grep")
        XCTAssertTrue(row.indented)
    }

    func testTheRowLeavesOutWhatTheAgentHasNotReported() {
        let row = RigAgentRowContent(SubagentInfo(id: "a", startedAt: 1000), now: 1000)
        XCTAssertEqual(row.title, "Agent")
        XCTAssertNil(row.type)
        XCTAssertEqual(row.elapsed, "0s")
        XCTAssertNil(row.tokens)
        XCTAssertNil(row.prompt)
        XCTAssertNil(row.summary)
        XCTAssertNil(row.lastTool)
        XCTAssertFalse(row.indented)
    }

    func testTheTitleFallsBackToTheType() {
        XCTAssertEqual(RigAgentRowContent(SubagentInfo(id: "a", type: "Explore", startedAt: 0), now: 0).title, "Explore")
    }

    func testOnlyASpawnedAgentIsIndented() {
        func indented(_ depth: Int?) -> Bool {
            RigAgentRowContent(SubagentInfo(id: "a", startedAt: 0, spawnDepth: depth), now: 0).indented
        }
        XCTAssertFalse(indented(nil))
        XCTAssertFalse(indented(0))
        XCTAssertFalse(indented(1))
        XCTAssertTrue(indented(2))
    }

    func testAClockBehindTheRecordReadsNoTime() {
        XCTAssertEqual(RigAgentRowContent(SubagentInfo(id: "a", startedAt: 5000), now: 1000).elapsed, "0s")
    }

    func testDurations() {
        XCTAssertEqual(RigAgentRowContent.duration(ms: 0), "0s")
        XCTAssertEqual(RigAgentRowContent.duration(ms: 499), "0s")
        XCTAssertEqual(RigAgentRowContent.duration(ms: 500), "1s")
        XCTAssertEqual(RigAgentRowContent.duration(ms: 42_000), "42s")
        XCTAssertEqual(RigAgentRowContent.duration(ms: 59_499), "59s")
        XCTAssertEqual(RigAgentRowContent.duration(ms: 59_500), "1m 0s")
        XCTAssertEqual(RigAgentRowContent.duration(ms: 65_000), "1m 5s")
        XCTAssertEqual(RigAgentRowContent.duration(ms: 3_725_000), "62m 5s")
    }

    func testTokens() {
        XCTAssertEqual(RigAgentRowContent.tokens(0), "0")
        XCTAssertEqual(RigAgentRowContent.tokens(999), "999")
        XCTAssertEqual(RigAgentRowContent.tokens(1000), "1.0k")
        XCTAssertEqual(RigAgentRowContent.tokens(1234), "1.2k")
        // toFixed's own rollover, kept.
        XCTAssertEqual(RigAgentRowContent.tokens(999_950), "1000.0k")
        XCTAssertEqual(RigAgentRowContent.tokens(1_000_000), "1.0M")
        XCTAssertEqual(RigAgentRowContent.tokens(3_400_000), "3.4M")
        XCTAssertEqual(RigAgentRowContent.tokens(Int.max).hasSuffix("M"), true, "a wild count doesn't trap")
    }
}
