import Foundation
import XCTest
@testable import HappyCore

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
    var posted: [String] = []
    var paths: [String] = []
    var stops = 0

    func send(method: String, url: URL, body: Data?, accept: String) async throws -> Data {
        let suffix = "/" + url.lastPathComponent
        if method == "POST" {
            posted.append(suffix)
            guard let answer = posts[suffix] else { throw BrowserError.upstream(404) }
            return Data(answer.utf8)
        }
        paths.append(url.path)
        if let failure { throw failure }
        return suffix == "/frame.jpg" ? Data("png".utf8) : Data(state.utf8)
    }

    func stop() async { stops += 1 }
}
