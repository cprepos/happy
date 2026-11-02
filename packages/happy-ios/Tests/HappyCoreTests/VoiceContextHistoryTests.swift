import Foundation
import HappyStore
import HappyWire
import XCTest
@testable import HappyCore

/// A voice call must not open with every active session's history: at about
/// 84K characters the first token came after the caller had hung up.
final class VoiceContextHistoryTests: XCTestCase {
    private func history(_ count: Int) -> [ChatMessage] {
        (0..<count).map { ChatMessage.userText(UserTextMessage(id: "m\($0)", createdAt: Int64($0), text: "text-\($0)")) }
    }

    private func pending(_ id: String) -> ChatMessage {
        .toolCall(ToolCallMessage(id: "tool-\(id)", createdAt: 1_000, tool: ToolCall(
            name: "Bash", state: .running, input: .object([:]), createdAt: 1_000,
            permission: ToolPermission(id: id, status: .pending))))
    }

    func testFirstSnapshotOfLongHistorySendsNoHistoryKeepsPermissionAndForwardsWhatFollows() {
        let long = history(200) + [pending("permission")]
        var reducer = VoiceContextReducer()

        let first = reducer.apply(LegacyChatSnapshot(sessionId: "s", messages: long, isLoaded: true))
        XCTAssertEqual(first.context, "")
        XCTAssertEqual(first.prompts.count, 1)
        XCTAssertTrue(first.prompts[0].contains("requestId=permission"))

        let next = ChatMessage.agentText(AgentTextMessage(id: "new", createdAt: 2_000, text: "new reply", isThinking: false))
        let second = reducer.apply(LegacyChatSnapshot(sessionId: "s", messages: long + [next], isLoaded: true))
        XCTAssertEqual(second.context, "Messages in session s:\nCoding agent: new reply")
        XCTAssertEqual(second.prompts, [])
    }

    func testAPermissionRaisedAfterTheBaselineIsForwarded() {
        var reducer = VoiceContextReducer()
        XCTAssertEqual(reducer.apply(LegacyChatSnapshot(sessionId: "s", messages: history(3), isLoaded: true)), VoiceContextUpdate())
        let update = reducer.apply(LegacyChatSnapshot(sessionId: "s", messages: history(3) + [pending("later")], isLoaded: true))
        XCTAssertEqual(update.prompts.count, 1)
        XCTAssertTrue(update.prompts[0].contains("requestId=later"))
    }

    /// A session the app hasn't pulled yet starts empty, so "first snapshot"
    /// alone would bring the whole dump back the moment the pull lands.
    func testHistoryPulledDuringTheCallIsStillNotNews() {
        var reducer = VoiceContextReducer()
        XCTAssertEqual(reducer.apply(LegacyChatSnapshot(sessionId: "s", isLoaded: false)), VoiceContextUpdate())
        XCTAssertEqual(reducer.apply(LegacyChatSnapshot(sessionId: "s", messages: history(30), isLoaded: false)), VoiceContextUpdate())
        XCTAssertEqual(reducer.apply(LegacyChatSnapshot(sessionId: "s", messages: history(60), isLoaded: true)), VoiceContextUpdate())
        let update = reducer.apply(LegacyChatSnapshot(sessionId: "s", messages: history(61), isLoaded: true))
        XCTAssertEqual(update.context, "Messages in session s:\nUser: text-60")
    }

    func testPromptedBaselineForwardsOnlyLaterMessagesAndStillAsksAboutPermissions() {
        let prompted = history(60) + [pending("waiting")]
        var reducer = VoiceContextReducer(prompted: LegacyChatSnapshot(sessionId: "s", messages: prompted, isLoaded: true))
        let later = ChatMessage.userText(UserTextMessage(id: "later", createdAt: 3_000, text: "while connecting"))
        let update = reducer.apply(LegacyChatSnapshot(sessionId: "s", messages: prompted + [later], isLoaded: true))
        XCTAssertEqual(update.context, "Messages in session s:\nUser: while connecting")
        XCTAssertEqual(update.prompts.count, 1)
        XCTAssertTrue(update.prompts[0].contains("requestId=waiting"))
    }

    /// The whole path, on a real store and feeds: the session the call opened
    /// on stays in the prompt and nothing repeats a history at call start.
    func testCallStartsWithOnlyThePromptAndAFocusBringsThatSessionsHistoryOnce() async throws {
        let store = try LocalStore.inMemory()
        try store.upsertSessions([
            ChatRecords.storeSession("s", seq: 60),
            ChatRecords.storeSession("other", seq: 60),
            ChatRecords.storeSession("third", seq: 60, agentState: ChatRecords.permissionState("call-third")),
        ])
        for session in ["s", "other", "third"] {
            var rows = (1...59).map { ChatRecords.stored(ChatRecords.user("\(session)-\($0)", at: Int64($0), text: "\(session)-old-\($0)"), seq: $0, sessionId: session) }
            rows.append(ChatRecords.stored(ChatRecords.call("\(session)-call", call: "call-\(session)", at: 60), seq: 60, sessionId: session))
            try store.applyMessagePage(sessionId: session, messages: rows)
        }
        let account = try AccountSession(
            credentials: Credentials(token: "token", secret: Data(repeating: 7, count: 32)), store: store,
            dependencies: .init(serverURL: URL(string: "https://example.test")!, clientID: "test", transport: FakeHTTP(), connector: FakeConnector()))
        let context = VoiceContext(account: account, sessionId: "s")
        let updates = VoiceUpdateLog()

        let start = try await context.initial()
        XCTAssertTrue(start.context.contains("CURRENT SESSION: s\n"))
        XCTAssertTrue(start.context.contains("s-old-59"))
        XCTAssertTrue(start.context.contains("s-old-11\n"))
        XCTAssertFalse(start.context.contains("other-old"))
        let prompt = VoiceSystemPrompt.build(initialContext: start.context)
        XCTAssertTrue(prompt.contains("s-old-59"))

        try store.applyMessagePage(sessionId: "s", messages: [
            ChatRecords.stored(ChatRecords.user("s-between", at: 61, text: "s-between-text"), seq: 61, sessionId: "s"),
        ])
        await context.start { await updates.append($0) }

        await eventually(timeout: .seconds(20)) { await updates.contexts.contains { $0.contains("s-between-text") } }
        await eventually(timeout: .seconds(20)) { await updates.prompts.contains { $0.contains("requestId=call-third") } }
        try store.applyMessagePage(sessionId: "other", messages: [
            ChatRecords.stored(ChatRecords.user("other-new", at: 61, text: "other-new-text"), seq: 61, sessionId: "other"),
        ])
        await eventually(timeout: .seconds(20)) { await updates.contexts.contains { $0.contains("other-new-text") } }
        let atStart = await updates.contexts
        XCTAssertFalse(atStart.contains { $0.contains("-old-") }, "\(atStart)")

        await context.focus("other")
        await eventually(timeout: .seconds(20)) { await updates.contexts.contains { $0.contains("other-old-59") } }
        await context.focus("s")
        await context.focus("other")
        await context.stop()
        let all = await updates.contexts
        XCTAssertEqual(all.filter { $0.contains("other-old-59") }.count, 1, "\(all)")
        XCTAssertFalse(all.contains { $0.contains("s-old-") || $0.contains("third-old-") }, "\(all)")
        XCTAssertEqual(all.filter { $0.hasPrefix("Session became focused: other") }.count, 2)
    }
}

private actor VoiceUpdateLog {
    private(set) var contexts: [String] = []
    private(set) var prompts: [String] = []
    func append(_ update: VoiceContextUpdate) {
        if !update.context.isEmpty { contexts.append(update.context) }
        prompts.append(contentsOf: update.prompts)
    }
}
