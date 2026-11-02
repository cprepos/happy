import Foundation
@testable import HappyCore
import HappyStore
import HappyWire
import XCTest

private actor Heard {
    private(set) var updates: [VoiceContextUpdate] = []
    func add(_ update: VoiceContextUpdate) { updates.append(update) }
    var contexts: [String] { updates.map(\.context).filter { !$0.isEmpty } }
    var prompts: [String] { updates.flatMap(\.prompts) }
}

private struct AcceptingSender: ChatSending {
    func send(_ message: OutgoingMessage, sessionId: String) async throws -> String { "accepted" }
    func retry(localId: String) async throws {}
    func discard(localId: String) async throws {}
}

/// What the agent is told during a call, at the level of the actor that decides.
final class VoiceContextUpdatesTests: XCTestCase {
    /// `Session became focused:\s*(\S+)` in happy_voice/context.py, which this
    /// app must not change: what it captures becomes the agent's default target.
    func testTheFocusLineParsesToTheBareSessionId() throws {
        let line = VoiceContext.focusLine("session-1")
        let regex = try NSRegularExpression(pattern: #"Session became focused:\s*(\S+)"#)
        let match = try XCTUnwrap(regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)))
        XCTAssertEqual(Range(match.range(at: 1), in: line).map { String(line[$0]) }, "session-1")
    }

    private struct Fixture {
        let context: VoiceContext
        let account: AccountSession
        let store: LocalStore
        let heard = Heard()

        func finish() async {
            await context.stop()
            await account.stop()
        }
    }

    private func fixture(focused: String = "a", sessions: [String] = ["a", "b"]) throws -> Fixture {
        let store = try LocalStore.inMemory()
        try store.upsertSessions(sessions.map { ChatRecords.storeSession($0) })
        let account = try AccountSession(credentials: Credentials(token: "token", secret: Data(repeating: 7, count: 32)), store: store,
                                         dependencies: .init(serverURL: URL(string: "https://example.test")!, clientID: "test", transport: FakeHTTP(), connector: FakeConnector()))
        let sync = LegacySyncEngine(api: testAPI(FakeHTTP()), store: store, keys: ServerFixture().keys)
        let actions = SessionActions(api: testAPI(FakeHTTP()), store: store, sync: sync, rpc: FakeRPC())
        return Fixture(context: VoiceContext(account: account, sessionId: focused, sending: AcceptingSender(), actions: actions), account: account, store: store)
    }

    private func attach(_ fixture: Fixture) async {
        let heard = fixture.heard
        await fixture.context.attach { await heard.add($0) }
    }

    func testACallStartsQuietlyWithSeveralActiveSessions() async throws {
        let fixture = try fixture()
        for id in ["a", "b"] {
            try fixture.store.applyMessagePage(sessionId: id, messages: [ChatRecords.stored(ChatRecords.user("\(id)-1", text: "old in \(id)"), seq: 1, sessionId: id)])
        }
        _ = try await fixture.context.initial()
        let heard = fixture.heard
        await fixture.context.start { await heard.add($0) }
        try await Task.sleep(for: .milliseconds(200))
        let updates = await heard.updates
        XCTAssertEqual(updates, [], "what the prompt holds or nothing has happened in isn't sent")
        await fixture.finish()
    }

    func testTheOpeningContextKeepsItsWords() async throws {
        let fixture = try fixture()
        try fixture.store.applyMessagePage(sessionId: "a", messages: [ChatRecords.stored(ChatRecords.user("a-1", text: "old"), seq: 1, sessionId: "a")])
        let start = try await fixture.context.initial()
        XCTAssertEqual(start.context, "Available sessions:\n- a: No summary\n- b: No summary\n\nCURRENT SESSION: a\nProject: \nSummary: \n\nUser: old")
        await fixture.finish()
    }

    func testTheDirectoryIsNotSentAgainWhenASessionChanges() async throws {
        let fixture = try fixture()
        _ = try await fixture.context.initial()
        await attach(fixture)
        let renamed = ChatRecords.storeSession("b", metadata: .object(["summary": .object(["text": .string("renamed")])]))
        await fixture.context.home(LegacyHomeSnapshot(machines: MachinesSnapshot(synced: true, machines: []), sessions: [ChatRecords.storeSession("a"), renamed]))
        let contexts = await fixture.heard.contexts
        XCTAssertEqual(contexts, [])
        await fixture.finish()
    }

    func testAFlipToDoneBringsTheHistoryOnceThenThePrompt() async throws {
        let fixture = try fixture()
        try fixture.store.applyMessagePage(sessionId: "b", messages: [ChatRecords.stored(ChatRecords.user("b-1", text: "old in b"), seq: 1, sessionId: "b")])
        _ = try await fixture.context.initial()
        await attach(fixture)
        var busy = ChatRecords.storeSession("b"); busy.thinking = true
        let idle = ChatRecords.storeSession("b")
        let a = ChatRecords.storeSession("a")
        for record in [busy, idle, busy, idle] {
            await fixture.context.home(LegacyHomeSnapshot(machines: MachinesSnapshot(synced: true, machines: []), sessions: [a, record]))
        }
        let contexts = await fixture.heard.contexts.filter { $0.hasPrefix("SESSION: b") }
        XCTAssertEqual(contexts, ["SESSION: b\nProject: \nSummary: \n\nUser: old in b"])
        let updates = await fixture.heard.updates
        XCTAssertEqual(updates.first?.context, contexts.first, "the agent has the history before it is asked to report")
        let prompts = await fixture.heard.prompts
        XCTAssertEqual(prompts.count, 2, "each flip is its own completion")
        await fixture.finish()
    }

    func testFocusBringsTheHistoryThenTheBareLineAndTheHistoryOnlyOnce() async throws {
        let fixture = try fixture()
        try fixture.store.applyMessagePage(sessionId: "b", messages: [ChatRecords.stored(ChatRecords.user("b-1", text: "old in b"), seq: 1, sessionId: "b")])
        _ = try await fixture.context.initial()
        await attach(fixture)
        await fixture.context.focus("b")
        await fixture.context.focus("a")
        await fixture.context.focus("b")
        let contexts = await fixture.heard.contexts.filter { !$0.hasPrefix("Messages") }
        XCTAssertEqual(contexts, [
            "SESSION: b\nProject: \nSummary: \n\nUser: old in b",
            "Session became focused: b",
            "Session became focused: a",
            "Session became focused: b",
        ])
        await fixture.finish()
    }

    func testTheFirstFocusedSessionIsNotDumpedAgain() async throws {
        let fixture = try fixture()
        try fixture.store.applyMessagePage(sessionId: "a", messages: [ChatRecords.stored(ChatRecords.user("a-1", text: "old"), seq: 1, sessionId: "a")])
        _ = try await fixture.context.initial()
        await attach(fixture)
        var feed = fixture.account.chatFeed.snapshots(sessionId: "a").makeAsyncIterator()
        let first = await feed.next()
        let stored = try XCTUnwrap(first)
        let new = ChatMessage.userText(UserTextMessage(id: "a-2", createdAt: 2, text: "new"))
        await fixture.context.chat(stored)
        await fixture.context.chat(LegacyChatSnapshot(sessionId: "a", messages: stored.messages + [new]))
        let contexts = await fixture.heard.contexts
        XCTAssertEqual(contexts, ["Messages in session a:\nUser: new"])
        await fixture.finish()
    }

    private func tool(_ state: ToolCall.State) -> ChatMessage {
        .toolCall(ToolCallMessage(id: "tool", createdAt: 1, tool: ToolCall(name: "Read", state: state, input: .object([:]), createdAt: 1, description: "file.ts")))
    }

    func testAToolCallsArrivalAndResultReachTheAgentOnce() async throws {
        let fixture = try fixture()
        _ = try await fixture.context.initial()
        await attach(fixture)
        await fixture.context.chat(LegacyChatSnapshot(sessionId: "a"))
        await fixture.context.chat(LegacyChatSnapshot(sessionId: "a", messages: [tool(.running)]))
        await fixture.context.chat(LegacyChatSnapshot(sessionId: "a", messages: [tool(.completed)]))
        let contexts = await fixture.heard.contexts
        XCTAssertEqual(contexts, ["Messages in session a:\nCoding agent uses Read: file.ts"])
        await fixture.finish()
    }

    func testARepeatedContextStillLetsItsPromptThrough() async throws {
        let fixture = try fixture()
        _ = try await fixture.context.initial()
        await attach(fixture)
        let done = ChatMessage.agentEvent(AgentEventMessage(id: "ready", createdAt: 2, event: .ready))
        await fixture.context.chat(LegacyChatSnapshot(sessionId: "a", messages: [tool(.running)]))
        await fixture.context.chat(LegacyChatSnapshot(sessionId: "a", messages: [tool(.completed), done]))
        let prompts = await fixture.heard.prompts
        XCTAssertEqual(prompts.count, 1)
        await fixture.finish()
    }

    func testABackgroundSessionsFirstMessageBringsItsHistory() async throws {
        let fixture = try fixture()
        _ = try await fixture.context.initial()
        await attach(fixture)
        let old = ChatMessage.userText(UserTextMessage(id: "b-1", createdAt: 1, text: "old"))
        let new = ChatMessage.userText(UserTextMessage(id: "b-2", createdAt: 2, text: "new"))
        await fixture.context.chat(LegacyChatSnapshot(sessionId: "b", messages: [old]))
        var heard = await fixture.heard.contexts
        XCTAssertEqual(heard, [])
        await fixture.context.chat(LegacyChatSnapshot(sessionId: "b", messages: [old, new]))
        heard = await fixture.heard.contexts
        XCTAssertEqual(heard, ["SESSION: b\nProject: \nSummary: \n\nUser: old\n\nUser: new"])
        await fixture.finish()
    }
}
