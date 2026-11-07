import Foundation
import XCTest
@testable import HappyCore
import HappyWire

/// A chat's one live view: which link it is, what the bridge says of it, and
/// the feed every view of it reads.
final class LiveBrowserFeedTests: XCTestCase {
    private static let a = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"
    private static let b = "d35b825e18ea32bebed6f63e89ce2047"
    private static func live(_ id: String) -> String { "http://localhost:6090/live/\(id)" }

    // MARK: The latest link

    func testTheNewestLinkIsTheChatsLiveView() {
        let texts = ["First: \(Self.live(Self.a))", "Nothing here", "Then \(Self.live(Self.b)) and done.", "Later words."]
        XCTAssertEqual(LiveBrowserLink.latest(in: texts)?.id, Self.b)
        // Within a message, the last link wins.
        XCTAssertEqual(LiveBrowserLink.latest(in: ["\(Self.live(Self.a)) then \(Self.live(Self.b))"])?.id, Self.b)
        XCTAssertNil(LiveBrowserLink.latest(in: ["no links", "`\(Self.live(Self.a))`"]))
        XCTAssertNil(LiveBrowserLink.latest(in: [String]()))
        // A link still arriving at the end of the last text waits.
        XCTAssertEqual(LiveBrowserLink.latest(in: [Self.live(Self.a), "Now \(Self.live(Self.b))"], openLast: true)?.id, Self.a)
    }

    func testASnapshotsLiveViewIsTheAgentsNewestLink() throws {
        var snapshot = ChatSnapshot()
        XCTAssertNil(snapshot.latestLiveBrowser)
        let a = try XCTUnwrap(LiveBrowserLink(id: Self.a)), b = try XCTUnwrap(LiveBrowserLink(id: Self.b))
        snapshot.items = [
            ChatItem(id: "1", role: .agent, pieces: [.text("Watch"), .liveBrowser(id: a.id, url: a.url)], delivery: .sent),
            ChatItem(id: "2", role: .agent, pieces: [.liveBrowser(id: b.id, url: b.url), .text("now")], delivery: .sent),
            ChatItem(id: "3", role: .agent, pieces: [.text("Done.")], delivery: .sent),
        ]
        XCTAssertEqual(snapshot.latestLiveBrowser, b)
        // What the person pasted is not the agent's live view.
        snapshot.items.append(ChatItem(id: "4", role: .user, pieces: [.liveBrowser(id: a.id, url: a.url)], delivery: .sent))
        XCTAssertEqual(snapshot.latestLiveBrowser, b)
    }

    func testABrowserToolsResultCarriesTheLiveViewTheAgentNeverPosted() throws {
        let a = try XCTUnwrap(LiveBrowserLink(id: Self.a)), b = try XCTUnwrap(LiveBrowserLink(id: Self.b))
        // As the bridge adds it: first, before auto-browser's own JSON.
        let output = "Live view of browser session 6a80ac99d644: \(Self.live(Self.b))\nIf you have not posted this link in chat yet, post it on its own line.\n{\"id\": \"6a80ac99d644\", \"takeover_url\": \"http://localhost:6080/vnc.html\"}"
        XCTAssertEqual(LiveBrowserLink.latest(inResult: .object(["output": .string(output)])), b)
        XCTAssertEqual(LiveBrowserLink.latest(inResult: .object(["output": .string(#"{"link":"\#(Self.live(Self.a))","status":"watching"}"#)])), a)
        XCTAssertEqual(LiveBrowserLink.latest(inResult: .array([.string("`\(Self.live(Self.a))`")])), a, "a result is no Markdown")
        XCTAssertNil(LiveBrowserLink.latest(inResult: .object(["output": .string("\(Self.live(Self.a))/frame.jpg")])))
        XCTAssertNil(LiveBrowserLink.latest(inResult: nil))

        var snapshot = ChatSnapshot()
        let tool = ChatItem.Tool(name: "mcp__browser__browser_create_session", status: "completed", callId: "c1", result: .object(["output": .string(output)]))
        snapshot.items = [
            ChatItem(id: "1", role: .agent, pieces: [.liveBrowser(id: a.id, url: a.url)], delivery: .sent),
            ChatItem(id: "c1", role: .tool(tool), pieces: [], delivery: .sent),
            ChatItem(id: "3", role: .agent, pieces: [.text("Searching.")], delivery: .sent),
        ]
        XCTAssertEqual(snapshot.latestLiveBrowser, b, "the newer session, though the agent posted only the old one")
        snapshot.items.append(ChatItem(id: "4", role: .agent, pieces: [.liveBrowser(id: a.id, url: a.url)], delivery: .sent))
        XCTAssertEqual(snapshot.latestLiveBrowser, a, "a link posted after it is newer")
    }

    // MARK: The bridge's answers

    func testTheStateReadsWhoHasControlAndTheLastAction() throws {
        let state = try JSONDecoder().decode(LiveBrowserState.self, from: Data(#"{"status":"user","reason":"user_took_control","title":"Log in","last_action":{"kind":"click","target":"Sign in","at":1762300000000}}"#.utf8))
        XCTAssertEqual(state, LiveBrowserState(status: .user, reason: "user_took_control", title: "Log in", lastAction: .init(kind: "click", target: "Sign in", at: 1762300000000)))
        XCTAssertTrue(state.held)
        XCTAssertFalse(state.ended)
        XCTAssertTrue(LiveBrowserState(status: .takeover).held)
        XCTAssertFalse(LiveBrowserState(status: .watching).held)
        XCTAssertTrue(LiveBrowserState(status: .done).ended)
        // A null or malformed action is no action.
        XCTAssertNil(try JSONDecoder().decode(LiveBrowserState.self, from: Data(#"{"status":"watching","last_action":null}"#.utf8)).lastAction)
        XCTAssertNil(try JSONDecoder().decode(LiveBrowserState.self, from: Data(#"{"status":"watching","last_action":{"target":3}}"#.utf8)).lastAction)
    }

    func testTheStateReadsAPendingApproval() throws {
        let decode = { (json: String) in try JSONDecoder().decode(LiveBrowserState.self, from: Data(json.utf8)) }
        let state = try JSONDecoder().decode(LiveBrowserState.self, from: Data(#"""
        {"status":"watching","approval":{"id":"a1b2c3d4e5f6","kind":"account_change","summary":"The agent wants to change account settings.",
         "details":["Type text (12 characters, hidden)","Page: accounts.example.com/settings",3,""],"asked_at":1762300000000,"later":true}}
        """#.utf8))
        let approval = try XCTUnwrap(state.approval)
        XCTAssertEqual(approval, LiveBrowserState.Approval(id: "a1b2c3d4e5f6", kind: "account_change", summary: "The agent wants to change account settings.",
                                                           details: ["Type text (12 characters, hidden)", "Page: accounts.example.com/settings"], askedAt: 1762300000000))
        XCTAssertEqual(state.pendingApproval, approval)
        XCTAssertEqual(approval.text, "The agent wants to change account settings.\nType text (12 characters, hidden)\nPage: accounts.example.com/settings")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: approval.decisionBody) as? [String: String], ["approval_id": "a1b2c3d4e5f6"])

        // None, null, or malformed is no approval, and never costs the state.
        XCTAssertNil(try decode(#"{"status":"watching"}"#).approval)
        XCTAssertNil(try decode(#"{"status":"watching","approval":null}"#).approval)
        XCTAssertNil(try decode(#"{"status":"watching","approval":{"kind":"post"}}"#).approval)
        XCTAssertNil(try decode(#"{"status":"watching","approval":{"id":""}}"#).approval)
        XCTAssertNil(try decode(#"{"status":"watching","approval":"yes"}"#).approval)
        XCTAssertEqual(try decode(#"{"status":"takeover","approval":[1]}"#).status, .takeover)
        // Only an id: a generic summary, kind write.
        let bare = try XCTUnwrap(try decode(#"{"status":"watching","approval":{"id":"x1"}}"#).approval)
        XCTAssertEqual(bare.kind, "write")
        XCTAssertFalse(bare.summary.isEmpty)
        XCTAssertEqual(bare.details, [])
        // A done link asks nothing.
        XCTAssertNil(try decode(#"{"status":"done","approval":{"id":"x1","summary":"s"}}"#).pendingApproval)
    }

    func testApproveAndDenyAreTheLinksOwn() throws {
        let link = try XCTUnwrap(LiveBrowserLink(id: Self.a))
        XCTAssertEqual(link.approveURL.absoluteString, "\(Self.live(Self.a))/approve")
        XCTAssertEqual(link.denyURL.absoluteString, "\(Self.live(Self.a))/deny")
    }

    func testTakeAndReleaseAreTheLinksOwn() throws {
        let link = try XCTUnwrap(LiveBrowserLink(id: Self.a))
        XCTAssertEqual(link.takeURL.absoluteString, "\(Self.live(Self.a))/take")
        XCTAssertEqual(link.releaseURL.absoluteString, "\(Self.live(Self.a))/release")
        let take = try JSONDecoder().decode(LiveBrowserTake.self, from: Data(#"{"status":"user","title":"Log in","novnc_url":"http://localhost:6080/vnc.html?autoconnect=1#password=x"}"#.utf8))
        XCTAssertEqual(take.state, LiveBrowserState(status: .user, title: "Log in"))
        XCTAssertEqual(take.novncURL?.host, "localhost")
        XCTAssertNil(try JSONDecoder().decode(LiveBrowserTake.self, from: Data(#"{"status":"user"}"#.utf8)).novncURL)
    }

    // MARK: The feed

    @MainActor
    func testItPollsOnlyWhileSomethingShowsIt() async throws {
        let transport = FakeTransport()
        transport.state = #"{"status":"watching","title":"News"}"#
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        let owner = NSObject()
        var updates = 0
        feed.attach(owner, visible: false) { _ in updates += 1 }
        XCTAssertFalse(feed.isPolling)
        feed.set(owner, visible: true)
        XCTAssertTrue(feed.isPolling)
        try await until { feed.phase.state?.title == "News" }
        XCTAssertGreaterThan(updates, 0)
        // Only the state, until something shows the picture.
        XCTAssertTrue(transport.paths.allSatisfy { $0.hasSuffix("/state") })
        feed.set(owner, frames: true)
        try await until { feed.frame != nil }
        XCTAssertEqual(feed.frame, Data("png".utf8))
        // The small player reads as fast as the large one.
        XCTAssertEqual(feed.currentInterval, LiveBrowserFeed.fastInterval)
        feed.set(owner, frames: false)
        XCTAssertEqual(feed.currentInterval, LiveBrowserFeed.interval)
        feed.set(owner, fast: true)
        XCTAssertEqual(feed.currentInterval, LiveBrowserFeed.fastInterval)
        feed.set(owner, visible: false)
        XCTAssertFalse(feed.isPolling)
        try await until { transport.stops > 0 }
        let polls = feed.polls
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(feed.polls, polls)
    }

    @MainActor
    func testAGoneObserverStopsIt() async throws {
        let transport = FakeTransport()
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        var owner: NSObject? = NSObject()
        feed.attach(owner!) { _ in }
        XCTAssertTrue(feed.isPolling)
        owner = nil
        feed.attach(NSObject(), visible: false) { _ in } // anything that reconsiders
        XCTAssertFalse(feed.isPolling)
    }

    @MainActor
    func testItStopsForGoodOnceTheBrowserIsOver() async throws {
        for (status, phase) in [(404, LiveBrowserFeed.Phase.ended), (410, .expired), (501, .unavailable)] {
            let transport = FakeTransport()
            transport.failure = .upstream(status)
            let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
            let owner = NSObject()
            feed.attach(owner) { _ in }
            try await until { feed.phase == phase }
            try await until { !feed.isPolling }
            XCTAssertTrue(feed.phase.isOver)
            feed.set(owner, visible: false)
            feed.set(owner, visible: true)
            XCTAssertFalse(feed.isPolling, "\(status)")
        }
        let transport = FakeTransport()
        transport.state = #"{"status":"done","reason":"session_closed"}"#
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        feed.attach(NSObject()) { _ in }
        try await until { feed.phase.isOver && !feed.isPolling }
        XCTAssertEqual(feed.phase.state?.reason, "session_closed")
    }

    @MainActor
    func testAChatWithNoComputerIsUnavailable() async throws {
        let owner = NSObject()
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { RefusedLiveBrowserTransport() }
        feed.attach(owner) { _ in }
        try await until { feed.phase == .unavailable && !feed.isPolling }
        do { try await feed.take(); XCTFail("refused") } catch {}
    }

    @MainActor
    func testAnUnreachableBridgeIsTriedAgain() async throws {
        let transport = FakeTransport()
        transport.failure = .timeout
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        let owner = NSObject()
        feed.attach(owner) { _ in }
        try await until { feed.phase == .unreachable }
        XCTAssertTrue(feed.isPolling)
        XCTAssertFalse(feed.phase.isOver)
        feed.detach(owner)
    }

    @MainActor
    func testConnectingTooLongIsNotRespondingAndRetryReadsAgain() async throws {
        let transport = FakeTransport()
        transport.failure = .upstream(503)
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        feed.stuckLimit = .milliseconds(300)
        let owner = NSObject()
        feed.attach(owner) { _ in }
        try await until { feed.phase == .notResponding && !feed.isPolling }
        XCTAssertFalse(feed.phase.isOver)
        XCTAssertFalse(feed.phase.isRunning)
        let asked = transport.paths.count
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertEqual(transport.paths.count, asked, "not asked again on its own")

        transport.failure = nil
        feed.retry()
        try await until { feed.phase.isRunning }
        feed.detach(owner)
    }

    @MainActor
    func testARestingFeedReadsNothingUntilRetried() async throws {
        let transport = FakeTransport()
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        let owner = NSObject()
        feed.attach(owner, frames: true) { _ in }
        try await until { feed.phase.isRunning }
        let asleep = LiveBrowserState(status: .watching, url: "https://news.example/", pod: .asleep, live: false)
        feed.rest(asleep)
        XCTAssertEqual(feed.phase, .dormant(asleep))
        XCTAssertFalse(feed.isPolling)
        let asked = transport.paths.count
        feed.set(owner, visible: true)
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertEqual(transport.paths.count, asked, "no state, no frames while it rests")
        feed.retry()
        try await until { transport.paths.count > asked && feed.phase.isRunning }
        feed.detach(owner)
    }

    @MainActor
    func testRunningIsTheBridgesLiveAlone() throws {
        let decode = { (json: String) in try JSONDecoder().decode(LiveBrowserState.self, from: Data(json.utf8)) }
        XCTAssertTrue(try decode(#"{"status":"watching","pod":"running","live":true}"#).runs)
        XCTAssertFalse(try decode(#"{"status":"watching","pod":"running","live":false}"#).runs, "pod says running; live says no")
        XCTAssertTrue(try decode(#"{"status":"watching","pod":"running","live":false}"#).asleep)
        XCTAssertFalse(try decode(#"{"status":"done","live":false}"#).runs)
        XCTAssertTrue(try decode(#"{"status":"watching","pod":"starting","live":true}"#).runs)
        // A bridge with no `live`: status and pod.
        XCTAssertTrue(try decode(#"{"status":"watching"}"#).runs)
        XCTAssertFalse(try decode(#"{"status":"watching","pod":"dead"}"#).runs)
    }

    @MainActor
    func testNavigatePostsTheActionAndDecodesWhereThePageIs() async throws {
        let transport = FakeTransport()
        transport.posts["/nav"] = #"{"ok":true,"url":"https://example.com/","title":"Example","can_go_back":null,"can_go_forward":null,"timed_out":true}"#
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        let reply = try await feed.navigate(.goto("example.com"))
        XCTAssertEqual(reply, LiveBrowserNavResult(url: "https://example.com/", title: "Example", timedOut: true))
        XCTAssertEqual(transport.posted, ["/nav"])
        let body = try XCTUnwrap(transport.bodies.first ?? nil)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["action": "goto", "url": "example.com"])
        XCTAssertEqual(String(decoding: LiveBrowserNavigation.back.body, as: UTF8.self), #"{"action":"back"}"#)

        transport.posts["/nav"] = nil
        do { try await feed.navigate(.reload); XCTFail("refused") } catch BrowserError.upstream(404) {}
    }

    @MainActor
    func testTakeAndReleasePostAndMoveThePhase() async throws {
        let transport = FakeTransport()
        transport.posts["/take"] = #"{"status":"user","novnc_url":"http://localhost:6080/vnc.html"}"#
        transport.posts["/release"] = #"{"status":"watching"}"#
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        let take = try await feed.take()
        XCTAssertEqual(take.novncURL?.absoluteString, "http://localhost:6080/vnc.html")
        XCTAssertEqual(feed.phase, .live(LiveBrowserState(status: .user)))
        try await feed.release()
        XCTAssertEqual(feed.phase, .live(LiveBrowserState(status: .watching)))
        XCTAssertEqual(transport.posted, ["/take", "/release"])
        // A bridge from before `/release` is asked with `/done`.
        transport.posts["/release"] = nil
        transport.posts["/done"] = #"{"status":"watching"}"#
        try await feed.release()
        XCTAssertEqual(transport.posted, ["/take", "/release", "/release", "/done"])
        transport.posts["/take"] = nil
        do { try await feed.take(); XCTFail("took") } catch { XCTAssertEqual(error as? BrowserError, .upstream(404)) }
    }

    @MainActor
    func testDecidePostsTheApprovalsIdAndMovesThePhase() async throws {
        let transport = FakeTransport()
        let approval = LiveBrowserState.Approval(id: "ap1", kind: "post", summary: "The agent wants to post or send something.")
        transport.posts["/approve"] = #"{"ok":true,"approval_status":"approved","status":"watching","approval":null}"#
        transport.posts["/deny"] = #"{"ok":true,"approval_status":"denied","status":"watching","approval":null}"#
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        try await feed.decide(approval, approve: true)
        XCTAssertEqual(transport.posted, ["/approve"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(transport.bodies.last ?? nil)) as? [String: String], ["approval_id": "ap1"])
        XCTAssertEqual(feed.phase, .live(LiveBrowserState(status: .watching)))
        try await feed.decide(approval, approve: false)
        XCTAssertEqual(transport.posted, ["/approve", "/deny"])

        // No longer waiting (decided elsewhere): 409, and the card goes at once.
        transport.posts["/take"] = #"{"status":"watching","approval":{"id":"ap2","summary":"s"},"novnc_url":"http://localhost:6080/vnc.html"}"#
        try await feed.take()
        XCTAssertEqual(feed.phase.state?.approval?.id, "ap2")
        transport.postFailures["/approve"] = .upstream(409)
        do {
            try await feed.decide(LiveBrowserState.Approval(id: "ap2", summary: "s"), approve: true)
            XCTFail("decided")
        } catch { XCTAssertEqual(error as? BrowserError, .upstream(409)) }
        XCTAssertNil(feed.phase.state?.approval)
    }

    @MainActor
    func testEndPostsAndTheFeedIsOver() async throws {
        let transport = FakeTransport()
        transport.posts["/end"] = #"{"status":"done","reason":"user_ended"}"#
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        XCTAssertEqual(feed.link.endURL.absoluteString, "\(Self.live(Self.a))/end")
        try await feed.end()
        XCTAssertEqual(transport.posted, ["/end"])
        XCTAssertEqual(feed.phase.state?.status, .done)
        XCTAssertEqual(feed.phase.state?.reason, "user_ended")
        XCTAssertTrue(feed.phase.isOver)
    }

    @MainActor
    func testSleepPostsAndTheBrowserIsAsleepNotOver() async throws {
        let transport = FakeTransport()
        transport.posts["/sleep"] = #"{"status":"watching","reason":"user_slept","pod":"asleep","live":false,"live_reason":"asleep"}"#
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        XCTAssertEqual(feed.link.sleepURL.absoluteString, "\(Self.live(Self.a))/sleep")
        try await feed.sleep()
        XCTAssertEqual(transport.posted, ["/sleep"])
        XCTAssertEqual(feed.phase.state?.status, .watching)
        XCTAssertEqual(feed.phase.state?.asleep, true)
        XCTAssertFalse(feed.phase.isOver)
    }

    @MainActor
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out", file: file, line: line)
    }
}

/// The bridge, as a test sets it up: unsynchronised, read on the main actor.
private final class FakeTransport: LiveBrowserTransport, @unchecked Sendable {
    var state = #"{"status":"watching"}"#
    var failure: BrowserError?
    var posts: [String: String] = [:]
    var postFailures: [String: BrowserError] = [:]
    var posted: [String] = []
    var bodies: [Data?] = []
    var paths: [String] = []
    var stops = 0

    func send(method: String, url: URL, body: Data?, accept: String) async throws -> Data {
        let suffix = "/" + url.lastPathComponent
        if method == "POST" {
            posted.append(suffix)
            bodies.append(body)
            if let failure = postFailures[suffix] { throw failure }
            guard let answer = posts[suffix] else { throw BrowserError.upstream(404) }
            return Data(answer.utf8)
        }
        paths.append(url.path)
        if let failure { throw failure }
        return suffix == "/frame.jpg" ? Data("png".utf8) : Data(state.utf8)
    }

    func stop() async { stops += 1 }
}
