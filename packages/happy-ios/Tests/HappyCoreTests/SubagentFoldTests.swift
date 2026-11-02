import Foundation
import XCTest
import HappyStore
import HappyWire
@testable import HappyCore

/// The session's subagents, from storage.ts's fold.
final class SubagentFoldTests: XCTestCase {
    private let agent = "subagenta"

    private func record(_ id: String, at time: Int64, _ event: String, subagent: String? = "subagenta", role: String = "agent") -> NormalizedChatRecord? {
        ChatNormalizer.normalize(
            id: id, createdAt: time,
            raw: ChatRecords.session(id, at: time, role: role, parent: subagent, event: ChatRecords.json(event)))
    }

    private func fold(_ records: NormalizedChatRecord?...) -> ChatReducer {
        var reducer = ChatReducer()
        _ = reducer.reduce(records.compactMap { $0 })
        return reducer
    }

    func testStartFillsWhatTheAgentReports() {
        let reducer = fold(record("s", at: 100, #"{"t":"start","title":"Fix","subagentType":"Explore","model":"m","prompt":"look","spawnDepth":2,"parentTaskId":"p"}"#))
        XCTAssertEqual(
            reducer.subagents[agent],
            SubagentInfo(id: agent, title: "Fix", type: "Explore", model: "m", status: .running, prompt: "look", startedAt: 100, spawnDepth: 2, parentId: "p"))
    }

    func testProgressMergesOverTheStart() {
        let reducer = fold(
            record("s", at: 100, #"{"t":"start","title":"Fix"}"#),
            record("p1", at: 200, #"{"t":"progress","tokens":10,"toolUses":1,"durationMs":50,"lastToolName":"Grep","summary":"one"}"#),
            record("p2", at: 300, #"{"t":"progress","tokens":20,"lastToolName":"Read"}"#))
        XCTAssertEqual(
            reducer.subagents[agent],
            SubagentInfo(id: agent, title: "Fix", status: .running, summary: "one", tokens: 20, toolUses: 1, durationMs: 50, startedAt: 100, lastToolName: "Read"))
    }

    func testStopFinishesItAndAPlainStopCompletesIt() {
        let failed = fold(
            record("s", at: 100, #"{"t":"start"}"#),
            record("e", at: 200, #"{"t":"stop","status":"failed","summary":"gave up","tokens":5,"toolUses":2,"durationMs":100.5}"#))
        XCTAssertEqual(
            failed.subagents[agent],
            SubagentInfo(id: agent, status: .failed, summary: "gave up", tokens: 5, toolUses: 2, durationMs: 100.5, startedAt: 100))
        // The CLI's turn-end stop, and every older record, says nothing else.
        let plain = fold(record("s", at: 100, #"{"t":"start","title":"T"}"#), record("e", at: 200, #"{"t":"stop"}"#))
        XCTAssertEqual(plain.subagents[agent]?.status, .completed)
    }

    func testEmptyTextsCountAsAbsentAndZeroCounts() {
        let reducer = fold(
            record("s", at: 100, #"{"t":"start","title":"Keep","spawnDepth":0}"#),
            record("p", at: 200, #"{"t":"progress","summary":"","lastToolName":"","tokens":0}"#),
            record("r", at: 300, #"{"t":"start","title":""}"#))
        let info = reducer.subagents[agent]
        XCTAssertEqual(info?.title, "Keep")
        XCTAssertEqual(info?.spawnDepth, 0)
        XCTAssertEqual(info?.tokens, 0)
        XCTAssertNil(info?.summary)
        XCTAssertNil(info?.lastToolName)
    }

    func testAnOlderStartDoesNotBringAFinishedAgentBack() {
        let reducer = fold(
            record("e", at: 300, #"{"t":"stop","status":"completed","summary":"done"}"#),
            record("p", at: 200, #"{"t":"progress","summary":"working","lastToolName":"Grep"}"#),
            record("s", at: 100, #"{"t":"start","title":"Fix"}"#))
        let info = reducer.subagents[agent]
        XCTAssertEqual(info?.status, .completed)
        XCTAssertEqual(info?.startedAt, 100)
        XCTAssertEqual(info?.title, "Fix")
        // Older fields fill gaps and never replace what is newer.
        XCTAssertEqual(info?.summary, "done")
        XCTAssertEqual(info?.lastToolName, "Grep")
    }

    func testRecordsInAnyOrderFoldToTheSameAgent() {
        let start = record("s", at: 100, #"{"t":"start","title":"Fix"}"#)
        let progress = record("p", at: 200, #"{"t":"progress","tokens":10}"#)
        let stop = record("e", at: 300, #"{"t":"stop","tokens":20}"#)
        let expected = fold(start, progress, stop).subagents
        XCTAssertEqual(fold(stop, start, progress).subagents, expected)
        XCTAssertEqual(fold(progress, stop, start).subagents, expected)
        XCTAssertEqual(fold(stop, progress, start).subagents, expected)
    }

    func testAgentWhoseStartIsNotInYetRunsFromItsEarliestRecord() {
        let reducer = fold(record("p2", at: 300, #"{"t":"progress"}"#), record("p1", at: 200, #"{"t":"progress"}"#))
        XCTAssertEqual(reducer.subagents[agent]?.status, .running)
        XCTAssertEqual(reducer.subagents[agent]?.startedAt, 200)
    }

    func testAgentsKeepToTheirOwnEntries() {
        let reducer = fold(
            record("a", at: 100, #"{"t":"start","title":"A"}"#),
            record("b", at: 110, #"{"t":"start","title":"B"}"#, subagent: "subagentb"),
            record("e", at: 120, #"{"t":"stop"}"#))
        XCTAssertEqual(reducer.subagents[agent]?.status, .completed)
        XCTAssertEqual(reducer.subagents["subagentb"]?.status, .running)
        XCTAssertEqual(reducer.subagents["subagentb"]?.title, "B")
    }

    func testAReplayedRecordFoldsOnce() {
        var reducer = ChatReducer()
        let progress = record("p", at: 200, #"{"t":"progress","tokens":10}"#)!
        _ = reducer.reduce([progress])
        _ = reducer.reduce([record("q", at: 300, #"{"t":"progress","tokens":20}"#)!])
        _ = reducer.reduce([progress])
        XCTAssertEqual(reducer.subagents[agent]?.tokens, 20)
        XCTAssertEqual(reducer.processedRecordCount, 2)
    }

    func testLifecycleMakesNoRows() {
        let reducer = fold(
            record("s", at: 100, #"{"t":"start","title":"Fix"}"#),
            record("p", at: 200, #"{"t":"progress","tokens":10}"#),
            record("e", at: 300, #"{"t":"stop"}"#),
            record("a", at: 400, #"{"t":"agents","agents":[{"id":"x"}]}"#))
        XCTAssertTrue(reducer.messages.isEmpty)
    }

    /// typesRaw.ts: no subagent id, no event; `agents` is normalized but
    /// nothing folds it; only the agent may send them.
    func testNormalizerKeepsWhatTheFoldCanUse() {
        XCTAssertNil(record("s", at: 100, #"{"t":"start"}"#, subagent: nil))
        XCTAssertNil(record("e", at: 100, #"{"t":"stop"}"#, subagent: nil))
        XCTAssertNil(record("p", at: 100, #"{"t":"progress"}"#, subagent: nil))
        XCTAssertNil(record("a", at: 100, #"{"t":"agents","agents":[]}"#))
        XCTAssertEqual(record("p", at: 100, #"{"t":"progress","tokens":3}"#)?.body, .subagent(id: agent, event: .progress(tokens: 3)))
        guard case .unsupported = record("u", at: 100, #"{"t":"start"}"#, role: "user")?.body else {
            return XCTFail("a user's start is not a lifecycle event")
        }
    }

    func testRunningListsNewestFirstAndLeavesFinishedOnesOut() {
        let list = SubagentInfo.running([
            "old": SubagentInfo(id: "old", startedAt: 100),
            "new": SubagentInfo(id: "new", startedAt: 300),
            "done": SubagentInfo(id: "done", status: .completed, startedAt: 400),
            "failed": SubagentInfo(id: "failed", status: .failed, startedAt: 500),
            "tie-b": SubagentInfo(id: "tie-b", startedAt: 200),
            "tie-a": SubagentInfo(id: "tie-a", startedAt: 200),
        ])
        XCTAssertEqual(list.map(\.id), ["new", "tie-a", "tie-b", "old"])
    }
}

/// A subagent's records reach the chat screen as facts, not as rows.
final class SubagentFactsTests: XCTestCase {
    private func progress(_ id: String, at time: Int64, _ event: String) -> NormalizedChatRecord? {
        ChatNormalizer.normalize(
            id: id, createdAt: time,
            raw: ChatRecords.session(id, at: time, parent: "subagenta", event: ChatRecords.json(event)))
    }

    private func facts(_ reducer: ChatReducer) -> ChatSnapshotFacts {
        ChatSnapshotFacts(LegacyChatSnapshot(sessionId: "s", messages: reducer.messages, isLoaded: true, subagents: reducer.subagents))
    }

    func testProgressMovesTheFactsAndLeavesTheRows() {
        var reducer = ChatReducer()
        _ = reducer.reduce([ChatRecords.text("a1"), progress("s", at: 100, #"{"t":"start","title":"Fix"}"#)!])
        let before = reducer.messages
        let beforeFacts = facts(reducer)
        XCTAssertEqual(beforeFacts.runningSubagents.map(\.id), ["subagenta"])

        let reduction = reducer.reduce([progress("p", at: 200, #"{"t":"progress","tokens":10}"#)!])
        XCTAssertEqual(reducer.messages, before)
        XCTAssertTrue(reduction.messages.isEmpty)
        XCTAssertEqual(facts(reducer).runningSubagents.first?.tokens, 10)
        XCTAssertNotEqual(facts(reducer), beforeFacts)
    }

    /// Item 3's rule: once it is hidden, nothing about it causes an apply.
    func testAFinishedAgentsLateNumbersCauseNoApply() {
        var reducer = ChatReducer()
        _ = reducer.reduce([progress("s", at: 100, #"{"t":"start"}"#)!, progress("e", at: 200, #"{"t":"stop"}"#)!])
        let finished = facts(reducer)
        XCTAssertTrue(finished.runningSubagents.isEmpty)
        _ = reducer.reduce([progress("l", at: 300, #"{"t":"progress","tokens":99}"#)!])
        XCTAssertEqual(reducer.subagents["subagenta"]?.tokens, 99)
        XCTAssertEqual(facts(reducer), finished)
    }

    func testTheFeedCarriesThemOnItsSnapshot() throws {
        let store = try LocalStore.inMemory()
        try store.upsertSessions([ChatRecords.storeSession(seq: 2)])
        try store.applyMessagePage(
            sessionId: "s",
            messages: [
                ChatRecords.stored(progress("a", at: 100, #"{"t":"start","title":"Fix"}"#)!, seq: 1),
                ChatRecords.stored(progress("b", at: 200, #"{"t":"progress","tokens":10}"#)!, seq: 2),
            ])
        var state = FeedState(sessionId: "s")
        let snapshot = state.apply(try store.chatPage(sessionId: "s"))
        XCTAssertEqual(snapshot.subagents["subagenta"]?.title, "Fix")
        XCTAssertEqual(snapshot.subagents["subagenta"]?.tokens, 10)
        XCTAssertTrue(snapshot.messages.isEmpty)
    }
}
