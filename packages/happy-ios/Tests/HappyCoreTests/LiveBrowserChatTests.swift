import Foundation
import XCTest
@testable import HappyCore

/// A chat's browser by its session (`GET /live/chat/<key>`), and what the
/// bridge says of a browser that runs one per chat: asleep, starting, and
/// Take control waking it.
final class LiveBrowserChatTests: XCTestCase {
    private static let a = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"
    private static let session = "cmhk2v9q40001ab12cd34ef56"
    /// sha256("happy:" + session)[:32], as the bridge's `chatKeyOf` makes it.
    private static let key = "fd23a0e71df7053618d8a037c7087e99"

    // MARK: The key

    func testTheChatKeyIsTheBridgesSha256OfTheHappySession() {
        XCTAssertEqual(LiveBrowserLink.chatKey(happySession: Self.session), Self.key)
        XCTAssertEqual(LiveBrowserLink.chatKey(happySession: ""), "ca263fe7cd896f177c9b066da3d1ecee")
        XCTAssertEqual(LiveBrowserLink.chatURL(key: Self.key)?.absoluteString, "http://localhost:6090/live/chat/\(Self.key)")
        // A Happy Agent chat: its Happy session's key, else the agent's.
        XCTAssertEqual(LiveBrowserLink.chatKey(agent: "agent1", happySession: Self.session), Self.key)
        XCTAssertEqual(LiveBrowserLink.chatKey(agent: "agent1"), "11c7e36d970d5afb85c8032af162939b")
        XCTAssertEqual(LiveBrowserLink.chatKey(agent: "agent1", happySession: ""), "11c7e36d970d5afb85c8032af162939b")
        XCTAssertNil(LiveBrowserLink.chatURL(key: "../state"))
        XCTAssertNil(LiveBrowserLink.chatURL(key: String(Self.key.dropLast())))
    }

    // MARK: Decoding

    func testTheLookupDecodesTheLinkLiveAndPod() throws {
        let body = #"{"id":"\#(Self.a)","live":true,"status":"watching","url":"https://news.example/","title":"News","pod":"running"}"#
        let chat = try JSONDecoder().decode(LiveBrowserChat.self, from: Data(body.utf8))
        XCTAssertEqual(chat.link.id, Self.a)
        XCTAssertEqual(chat.link.url.absoluteString, "http://localhost:6090/live/\(Self.a)", "through the workspace, never the public URL")
        XCTAssertTrue(chat.live)
        XCTAssertEqual(chat.state, LiveBrowserState(status: .watching, url: "https://news.example/", title: "News", pod: .running))

        let asleep = try JSONDecoder().decode(LiveBrowserChat.self, from: Data(#"{"id":"\#(Self.a)","live":false,"status":"watching","pod":"asleep"}"#.utf8))
        XCTAssertFalse(asleep.live)
        XCTAssertTrue(asleep.state.asleep)
        XCTAssertThrowsError(try JSONDecoder().decode(LiveBrowserChat.self, from: Data(#"{"id":"nope","live":true,"status":"watching"}"#.utf8)))
    }

    func testThePodField() throws {
        func state(_ json: String) throws -> LiveBrowserState { try JSONDecoder().decode(LiveBrowserState.self, from: Data(json.utf8)) }
        XCTAssertNil(try state(#"{"status":"watching"}"#).pod, "a bridge without pods")
        XCTAssertFalse(try state(#"{"status":"watching"}"#).asleep)
        XCTAssertEqual(try state(#"{"status":"watching","pod":"running"}"#).pod, .running)
        XCTAssertNil(try state(#"{"status":"watching","pod":"hibernating"}"#).pod, "a value a newer bridge adds")
        XCTAssertNil(try state(#"{"status":"watching","pod":3}"#).pod)
        for pod in ["asleep", "stopped", "crashed", "none"] {
            XCTAssertTrue(try state(#"{"status":"watching","pod":"\#(pod)"}"#).asleep, pod)
        }
        XCTAssertEqual(try state(#"{"status":"watching","pod":"none"}"#).pod, .unassigned)
        XCTAssertFalse(try state(#"{"status":"done","pod":"asleep"}"#).asleep, "over is over, not asleep")
        XCTAssertTrue(try state(#"{"status":"watching","pod":"starting"}"#).starting)
        XCTAssertFalse(try state(#"{"status":"watching","pod":"running"}"#).starting)
        // /take's 202 has no noVNC page and says starting.
        let waking = try JSONDecoder().decode(LiveBrowserTake.self, from: Data(#"{"status":"watching","pod":"starting"}"#.utf8))
        XCTAssertTrue(waking.waking)
        let ready = try JSONDecoder().decode(LiveBrowserTake.self, from: Data(#"{"status":"user","pod":"running","novnc_url":"http://localhost:6101/vnc.html"}"#.utf8))
        XCTAssertFalse(ready.waking)
    }

    // MARK: The feed

    @MainActor
    func testAFrame503IsAsleepNotUnreachable() async throws {
        let transport = PodTransport()
        transport.state = #"{"status":"watching","pod":"running"}"#
        transport.frameStatus = 503
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        let owner = NSObject()
        feed.attach(owner, frames: true) { _ in }
        try await until { feed.phase.state?.asleep == true }
        XCTAssertEqual(feed.phase.state?.pod, .asleep)
        XCTAssertFalse(feed.phase.isOver)
        XCTAssertTrue(feed.isPolling, "it wakes when the agent uses it: still read")
        feed.detach(owner)
    }

    @MainActor
    func testAnAsleepBrowserIsNotAskedForFrames() async throws {
        let transport = PodTransport()
        transport.state = #"{"status":"watching","pod":"asleep"}"#
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        let owner = NSObject()
        feed.attach(owner, frames: true) { _ in }
        try await until { feed.polls >= 2 }
        XCTAssertTrue(feed.phase.state?.asleep == true)
        XCTAssertFalse(transport.gets.contains { $0.hasSuffix("/frame.jpg") })
        feed.detach(owner)
    }

    @MainActor
    func testTakeWaitsForAnAsleepBrowserToWake() async throws {
        let transport = PodTransport()
        transport.takes = [
            #"{"status":"watching","pod":"starting"}"#,
            #"{"status":"watching","pod":"starting"}"#,
            #"{"status":"user","pod":"running","novnc_url":"http://localhost:6101/vnc.html"}"#,
        ]
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        var phases: [LiveBrowserFeed.Phase] = []
        let owner = NSObject()
        feed.attach(owner, visible: false) { phases.append($0.phase) }
        let take = try await feed.take(timeout: .seconds(5), retry: .milliseconds(20))
        XCTAssertEqual(take.novncURL?.absoluteString, "http://localhost:6101/vnc.html")
        XCTAssertEqual(transport.takeCount, 3)
        XCTAssertEqual(feed.phase.state?.status, .user)
        XCTAssertTrue(phases.contains { $0.state?.starting == true }, "it said starting while it waited")
        feed.detach(owner)
    }

    @MainActor
    func testTakeGivesUpOnABrowserThatNeverWakes() async throws {
        let transport = PodTransport()
        transport.takes = Array(repeating: #"{"status":"watching","pod":"starting"}"#, count: 100)
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        do {
            try await feed.take(timeout: .milliseconds(150), retry: .milliseconds(20))
            XCTFail("took")
        } catch {
            XCTAssertEqual(error as? BrowserError, .timeout)
        }
        XCTAssertGreaterThan(transport.takeCount, 1)
        XCTAssertLessThan(transport.takeCount, 10, "backoff")
    }

    // MARK: The lookup

    @MainActor
    func testTheLookupAsksOnlyWhileTheChatShows() async throws {
        let transport = PodTransport()
        transport.chat = #"{"id":"\#(Self.a)","live":true,"status":"watching","pod":"running"}"#
        let watch = try XCTUnwrap(LiveBrowserChatWatch(key: Self.key, interval: .milliseconds(20)) { transport })
        var answers: [LiveBrowserChatWatch.Answer] = []
        watch.onChange = { answers.append($0) }
        XCTAssertFalse(watch.isPolling)
        watch.setVisible(true)
        try await until { watch.answer.chat?.live == true }
        XCTAssertEqual(transport.gets.first, "/live/chat/\(Self.key)")
        XCTAssertEqual(answers.count, 1)
        // It falls asleep: live goes false.
        transport.chat = #"{"id":"\#(Self.a)","live":false,"status":"watching","pod":"asleep"}"#
        try await until { watch.answer.chat?.live == false }
        watch.setVisible(false)
        XCTAssertFalse(watch.isPolling)
        try await until { transport.stops > 0 }
        let polls = watch.polls
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(watch.polls, polls, "nothing while it doesn't show")
    }

    @MainActor
    func testNoLinkIsNoLineAndIsAskedAgain() async throws {
        let transport = PodTransport()
        let watch = try XCTUnwrap(LiveBrowserChatWatch(key: Self.key, interval: .milliseconds(20)) { transport })
        watch.setVisible(true)
        try await until { watch.answer == .noLink }
        let polls = watch.polls
        try await until { watch.polls > polls }
        // The agent starts a browser.
        transport.chat = #"{"id":"\#(Self.a)","live":true,"status":"watching"}"#
        try await until { watch.answer.chat?.link.id == Self.a }
        watch.close()
        XCTAssertFalse(watch.isPolling)
    }

    @MainActor
    func testTheLookupWaitsForAComputerAndStopsOnARefusal() async throws {
        var transport: PodTransport?
        let watch = try XCTUnwrap(LiveBrowserChatWatch(key: Self.key, interval: .milliseconds(20)) { transport })
        watch.setVisible(true)
        XCTAssertFalse(watch.isPolling, "no computer yet")
        let refusing = PodTransport()
        refusing.failure = .upstream(501)
        transport = refusing
        watch.reconsider()
        try await until { refusing.gets.count == 1 && !watch.isPolling }
        XCTAssertEqual(watch.answer, .unknown)
        // Another failure keeps the last answer and asks again.
        let flaky = PodTransport()
        flaky.chat = #"{"id":"\#(Self.a)","live":true,"status":"watching"}"#
        transport = flaky
        watch.reconsider()
        try await until { watch.answer.chat != nil }
        flaky.failure = .timeout
        let polls = watch.polls
        try await until { watch.polls > polls + 1 }
        XCTAssertNotNil(watch.answer.chat)
        XCTAssertTrue(watch.isPolling)
        watch.close()
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

/// A bridge with per-chat browsers, as a test sets it up: unsynchronised,
/// read on the main actor.
private final class PodTransport: LiveBrowserTransport, @unchecked Sendable {
    var state = #"{"status":"watching"}"#
    /// `/live/chat/<key>`'s answer; nil is 404 no_link.
    var chat: String?
    var frameStatus: Int?
    var failure: BrowserError?
    /// `/take`'s answers in turn; the last repeats.
    var takes: [String] = []
    var takeCount = 0
    var gets: [String] = []
    var stops = 0

    func send(method: String, url: URL, body: Data?, accept: String) async throws -> Data {
        if method == "POST" {
            guard url.lastPathComponent == "take", !takes.isEmpty else { throw BrowserError.upstream(404) }
            let answer = takes[min(takeCount, takes.count - 1)]
            takeCount += 1
            return Data(answer.utf8)
        }
        gets.append(url.path)
        if let failure { throw failure }
        if url.path.hasPrefix("/live/chat/") {
            guard let chat else { throw BrowserError.upstream(404) }
            return Data(chat.utf8)
        }
        if url.lastPathComponent == "frame.jpg" {
            if let frameStatus { throw BrowserError.upstream(frameStatus) }
            return Data("png".utf8)
        }
        return Data(state.utf8)
    }

    func stop() async { stops += 1 }
}
