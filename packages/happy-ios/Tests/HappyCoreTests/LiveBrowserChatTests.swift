import Foundation
import XCTest
@testable import HappyCore

/// A chat's browser by its session (`GET /live/chat/<key>`), and what the
/// bridge says of a browser that runs one per chat: asleep, starting, and
/// Take control waking it.
final class LiveBrowserChatTests: XCTestCase {
    private static let a = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"
    private static let b = "0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e"
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
        XCTAssertEqual(chat.state, LiveBrowserState(status: .watching, url: "https://news.example/", title: "News", pod: .running, live: true))
        XCTAssertTrue(chat.running)

        // The one field the red line keys off: live false is asleep, with
        // its reason, whatever pod and status say.
        let dead = try JSONDecoder().decode(LiveBrowserChat.self, from: Data(#"{"id":"\#(Self.a)","live":false,"live_reason":"session_not_answering","status":"watching","pod":"dead"}"#.utf8))
        XCTAssertFalse(dead.running)
        XCTAssertEqual(dead.state.pod, .dead)
        XCTAssertEqual(dead.state.liveReason, "session_not_answering")
        XCTAssertTrue(dead.state.asleep)
        XCTAssertFalse(dead.state.runs)

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

    // MARK: The bridge's origin

    /// A Mac chat's link names `localhost`, which its computer no longer
    /// reaches (the workspace proxy answers 502): the feed moves to the LAN
    /// origin at once, keeps it, and shows the browser.
    @MainActor
    func testTheFeedMovesToTheOriginThatAnswers() async throws {
        let transport = PodTransport()
        transport.state = #"{"status":"watching","live":true,"pod":"running"}"#
        transport.unreachable = [LiveBrowserLink.localOrigin]
        let link = try XCTUnwrap(LiveBrowserLink(id: Self.a, origin: LiveBrowserLink.localOrigin))
        let feed = LiveBrowserFeed(link: link) { transport }
        feed.frameGap = .milliseconds(10)
        let owner = NSObject()
        feed.attach(owner, frames: true) { _ in }
        try await until { feed.phase.state != nil && feed.frame != nil }
        XCTAssertEqual(feed.link, link, "still the chat's link")
        XCTAssertEqual(feed.activeLink.origin, LiveBrowserLink.lanOrigin)
        XCTAssertEqual(feed.originMoves, 1)
        XCTAssertEqual(transport.origins.first, LiveBrowserLink.localOrigin)
        let asked = transport.origins.count
        try await until { transport.origins.count > asked + 3 }
        XCTAssertEqual(Set(transport.origins.dropFirst(asked)), [LiveBrowserLink.lanOrigin], "kept")
        XCTAssertEqual(feed.originMoves, 1)
        feed.detach(owner)
    }

    /// And the other way, a chat on the bridge's own computer whose link
    /// names the LAN listener that refuses it.
    @MainActor
    func testTheFeedMovesToLocalhostWhenTheLANIsRefused() async throws {
        let transport = PodTransport()
        transport.state = #"{"status":"watching","live":true}"#
        transport.unreachable = [LiveBrowserLink.lanOrigin]
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a, origin: LiveBrowserLink.lanOrigin))) { transport }
        feed.attach(NSObject()) { _ in }
        try await until { feed.phase.state != nil }
        XCTAssertEqual(feed.activeLink.origin, LiveBrowserLink.localOrigin)
        XCTAssertFalse(feed.phase.isOver)
    }

    /// Take control (and Release) go where the feed reads, and a post the
    /// bridge never got is sent again at the next origin.
    @MainActor
    func testTakeAndReleaseGoToTheOriginThatAnswers() async throws {
        let transport = PodTransport()
        transport.unreachable = [LiveBrowserLink.localOrigin]
        transport.takes = [#"{"status":"user","pod":"running","novnc_url":"http://192.168.2.72:6090/live/\#(Self.a)/vnc/vnc.html"}"#]
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a, origin: LiveBrowserLink.localOrigin))) { transport }
        let take = try await feed.take(timeout: .seconds(5), retry: .milliseconds(20))
        XCTAssertNotNil(take.novncURL)
        XCTAssertEqual(transport.posts, ["\(LiveBrowserLink.localOrigin) take", "\(LiveBrowserLink.lanOrigin) take"])
        XCTAssertEqual(feed.activeLink.origin, LiveBrowserLink.lanOrigin)
        _ = try? await feed.release()
        let after = transport.posts.dropFirst(2)
        XCTAssertTrue(after.contains("\(LiveBrowserLink.lanOrigin) release"), "\(transport.posts)")
        XCTAssertFalse(after.contains { $0.hasPrefix(LiveBrowserLink.localOrigin) }, "straight to the one that answered")
    }

    /// Once a frame shows, nothing the bridge does in passing brings the
    /// spinner back: the page changing, the origin refusing and the feed
    /// moving to the other one, a moment with neither answering. Only no
    /// good frame for `waitingAfter` does.
    @MainActor
    func testAShownFrameStaysUpThroughRefreshesAndRetries() async throws {
        let transport = PodTransport()
        transport.state = #"{"status":"watching","live":true,"url":"https://example.com/a"}"#
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a, origin: LiveBrowserLink.lanOrigin))) { transport }
        feed.frameGap = .milliseconds(10)
        feed.waitingAfter = .seconds(2)
        var shown = false
        var spunAfter = 0
        var lostState = 0
        let owner = NSObject()
        feed.attach(owner, frames: true, fast: true) { feed in
            if feed.frame != nil, !feed.isWaiting { shown = true }
            guard shown else { return }
            if feed.isWaiting { spunAfter += 1 }
            if feed.phase.state == nil { lostState += 1 }
        }
        XCTAssertTrue(feed.isWaiting, "no frame yet: the first connect spins")
        try await until { shown }
        // A reload: the page changes.
        transport.state = #"{"status":"watching","live":true,"url":"https://example.com/b"}"#
        try await until { feed.phase.state?.url == "https://example.com/b" }
        // The origin it reads at answers 502: retried at the other.
        transport.unreachable = [LiveBrowserLink.lanOrigin]
        let reads = feed.frameReads
        try await until { feed.originMoves == 1 && feed.frameReads > reads + 3 }
        XCTAssertEqual(feed.activeLink.origin, LiveBrowserLink.localOrigin)
        // Neither answers, for less than `waitingAfter`.
        transport.unreachable = Set(LiveBrowserLink.origins)
        try await Task.sleep(for: .milliseconds(300))
        transport.unreachable = []
        let back = feed.frameReads
        try await until { feed.frameReads > back + 3 }
        XCTAssertEqual(spunAfter, 0, "no spinner over a shown frame")
        XCTAssertEqual(lostState, 0, "never back to connecting")
        XCTAssertFalse(feed.isWaiting)
        XCTAssertNotNil(feed.frame)
        // No good frame for `waitingAfter`: now it spins, the frame kept.
        transport.unreachable = Set(LiveBrowserLink.origins)
        try await until { feed.isWaiting }
        XCTAssertNotNil(feed.frame)
        feed.detach(owner)
    }

    /// What the bridge itself says is never a reason to move: a gone
    /// link, an asleep frame, a refused approval, the workspace's 501.
    func testOnlyANonAnswerMovesTheOrigin() {
        for code in [404, 410, 409, 400, 503, 501] { XCTAssertFalse(LiveBrowserFeed.missesOrigin(BrowserError.upstream(code)), "\(code)") }
        for code in [502, 504, 500, 403] { XCTAssertTrue(LiveBrowserFeed.missesOrigin(BrowserError.upstream(code)), "\(code)") }
        XCTAssertTrue(LiveBrowserFeed.missesOrigin(BrowserError.timeout))
        XCTAssertTrue(LiveBrowserFeed.missesOrigin(BrowserError.malformed))
        XCTAssertTrue(LiveBrowserFeed.missesOrigin(URLError(.networkConnectionLost)))
        XCTAssertFalse(LiveBrowserFeed.missesOrigin(BrowserError.unavailable))
        XCTAssertFalse(LiveBrowserFeed.missesOrigin(CancellationError()))
    }

    /// Both origins down: still the chat's feed, asked again, unreachable
    /// rather than over.
    @MainActor
    func testWithNeitherOriginAnsweringItKeepsAsking() async throws {
        let transport = PodTransport()
        transport.unreachable = Set(LiveBrowserLink.origins)
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        feed.attach(NSObject()) { _ in }
        try await until { feed.phase == .unreachable && transport.origins.count >= 4 }
        XCTAssertEqual(Set(transport.origins), Set(LiveBrowserLink.origins))
        XCTAssertFalse(feed.phase.isOver)
    }

    func testALinkNamesItsBridgeOriginOneOfTwo() throws {
        let lan = try XCTUnwrap(LiveBrowserLink(id: Self.a, origin: LiveBrowserLink.lanOrigin))
        XCTAssertEqual(lan.url.absoluteString, "http://192.168.2.72:6090/live/\(Self.a)")
        XCTAssertEqual(lan.frameURL.absoluteString, "http://192.168.2.72:6090/live/\(Self.a)/frame.jpg")
        XCTAssertEqual(LiveBrowserLink(id: Self.a)?.origin, LiveBrowserLink.localOrigin)
        XCTAssertNil(LiveBrowserLink(id: Self.a, origin: "http://192.168.2.73:6090"), "no other origin")
        XCTAssertEqual(LiveBrowserLink(url: lan.url), lan)
        XCTAssertNil(LiveBrowserLink(url: try XCTUnwrap(URL(string: "http://evil.example:6090/live/\(Self.a)"))))
        XCTAssertEqual(LiveBrowserLink.chatURL(key: Self.key, origin: LiveBrowserLink.lanOrigin)?.absoluteString, "http://192.168.2.72:6090/live/chat/\(Self.key)")

        let text = "local http://localhost:6090/live/\(Self.a) and [lan](http://192.168.2.72:6090/live/\(Self.b)) not http://192.168.2.7:6090/live/\(Self.a)0 nor http://10.0.0.1:6090/live/\(Self.b)"
        let links = LiveBrowserLink.split(text).compactMap { if case .link(let link) = $0 { link } else { nil } }
        XCTAssertEqual(links.map(\.origin), [LiveBrowserLink.localOrigin, LiveBrowserLink.lanOrigin])
        XCTAssertEqual(links.map(\.id), [Self.a, Self.b])
        XCTAssertFalse(LiveBrowserLink.mayContainLink("http://10.0.0.1:6090/live/\(Self.a)"))
        XCTAssertEqual(LiveBrowserLink.latest(inResult: .string("Live view: http://192.168.2.72:6090/live/\(Self.b)")), LiveBrowserLink(id: Self.b, origin: LiveBrowserLink.lanOrigin))
    }

    /// A Mac chat: its computer reaches the bridge on the LAN, so the
    /// lookup's first origin answers and the link names it.
    @MainActor
    func testTheLookupKeepsTheLANOriginWhenItAnswers() async throws {
        let transport = PodTransport()
        transport.chat = #"{"id":"\#(Self.a)","live":true,"status":"watching"}"#
        transport.unreachable = [LiveBrowserLink.localOrigin]
        let watch = try XCTUnwrap(LiveBrowserChatWatch(key: Self.key, interval: .milliseconds(20)) { transport })
        watch.setVisible(true)
        try await until { watch.answer.chat != nil }
        XCTAssertEqual(watch.answer.chat?.link.origin, LiveBrowserLink.lanOrigin)
        let polls = watch.polls
        try await until { watch.polls > polls + 1 }
        XCTAssertEqual(Set(transport.origins), [LiveBrowserLink.lanOrigin])
        watch.close()
    }

    /// A chat on the bridge's own computer: the LAN listener refuses it,
    /// so the lookup moves to localhost at once and stays there.
    @MainActor
    func testTheLookupMovesToLocalhostWhenTheLANIsRefused() async throws {
        let transport = PodTransport()
        transport.chat = #"{"id":"\#(Self.a)","live":true,"status":"watching"}"#
        transport.unreachable = [LiveBrowserLink.lanOrigin]
        let watch = try XCTUnwrap(LiveBrowserChatWatch(key: Self.key, interval: .milliseconds(20), idleInterval: .seconds(10)) { transport })
        watch.setVisible(true)
        try await until { watch.answer.chat != nil }
        XCTAssertEqual(watch.answer.chat?.link.origin, LiveBrowserLink.localOrigin)
        XCTAssertEqual(watch.origin, LiveBrowserLink.localOrigin)
        XCTAssertEqual(Array(transport.origins.prefix(2)), [LiveBrowserLink.lanOrigin, LiveBrowserLink.localOrigin])
        let polls = watch.polls
        try await until { watch.polls > polls + 1 }
        XCTAssertEqual(transport.origins.dropFirst().filter { $0 == LiveBrowserLink.lanOrigin }.count, 0, "kept")
        watch.close()
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

    /// A chat asked by its Happy session's key, then its agent's: the
    /// key that names a link is kept.
    @MainActor
    func testTheLookupTriesItsKeysInOrderAndKeepsTheOneFound() async throws {
        let identity = LiveBrowserChatIdentity.agent(id: "agent1", happySession: "happy1")
        let keys = identity.keys()
        XCTAssertEqual(keys, [LiveBrowserLink.chatKey(happySession: "happy1"), LiveBrowserLink.chatKey(agent: "agent1")])
        XCTAssertEqual(LiveBrowserChatIdentity.agent(id: "agent1", happySession: nil).keys(), [LiveBrowserLink.chatKey(agent: "agent1")])
        let transport = PodTransport()
        transport.chat = #"{"id":"\#(Self.a)","live":true,"status":"watching"}"#
        transport.chatKey = keys[1]
        let watch = try XCTUnwrap(LiveBrowserChatWatch(keys: keys, interval: .milliseconds(20)) { transport })
        watch.setVisible(true)
        try await until { watch.answer.chat?.link.id == Self.a }
        XCTAssertEqual(Array(transport.gets.prefix(2)), keys.map { "/live/chat/\($0)" })
        XCTAssertEqual(watch.key, keys[1])
        let polls = watch.polls
        try await until { watch.polls > polls + 1 }
        XCTAssertEqual(watch.key, keys[1], "kept")
        watch.close()
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
    func testTheLookupWaitsForAComputerAndBacksOffOnARefusal() async throws {
        var transport: PodTransport?
        let watch = try XCTUnwrap(LiveBrowserChatWatch(key: Self.key, interval: .milliseconds(20), idleInterval: .milliseconds(200)) { transport })
        watch.setVisible(true)
        XCTAssertFalse(watch.isPolling, "no computer yet")
        let refusing = PodTransport()
        refusing.failure = .upstream(501)
        transport = refusing
        watch.reconsider()
        // Asked again, at the idle pace, never given up on.
        try await until { refusing.gets.count == 1 && watch.backingOff }
        XCTAssertTrue(watch.isPolling)
        XCTAssertEqual(watch.answer, .unknown)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(refusing.gets.count, 1, "not at the fast pace")
        try await until { refusing.gets.count >= 2 }
        // The workspace comes back.
        refusing.failure = nil
        refusing.chat = #"{"id":"\#(Self.a)","live":true,"status":"watching"}"#
        try await until { watch.answer.chat != nil && !watch.backingOff }
        watch.setVisible(false)
        try await until { !watch.isPolling }
        // Another failure keeps the last answer and asks again.
        let flaky = PodTransport()
        flaky.chat = #"{"id":"\#(Self.a)","live":true,"status":"watching"}"#
        transport = flaky
        watch.setVisible(true)
        try await until { watch.answer.chat != nil }
        flaky.failure = .timeout
        let polls = watch.polls
        try await until { watch.polls > polls + 1 }
        XCTAssertNotNil(watch.answer.chat)
        XCTAssertTrue(watch.isPolling)
        watch.close()
    }

    /// Nothing runs, so the next lookup is the idle one, far off:
    /// `checkNow` asks at once anyway.
    @MainActor
    func testCheckNowAsksAtOnceDuringTheIdleWait() async throws {
        let transport = PodTransport()
        transport.chat = #"{"id":"\#(Self.a)","live":false,"status":"watching","pod":"asleep"}"#
        let watch = try XCTUnwrap(LiveBrowserChatWatch(key: Self.key, interval: .milliseconds(20), idleInterval: .seconds(10)) { transport })
        watch.setVisible(true)
        try await until { watch.answer.chat?.running == false }
        let polls = watch.polls
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(watch.polls, polls, "the idle wait")
        // The agent wakes it.
        transport.chat = #"{"id":"\#(Self.a)","live":true,"status":"watching","pod":"running"}"#
        watch.checkNow()
        try await until { watch.answer.chat?.running == true }
        watch.close()
    }

    /// While the player shows, the lookup is asked every `interval` even
    /// though nothing runs; no longer once it goes.
    @MainActor
    func testAnEagerWatchAsksOftenWhileNotRunning() async throws {
        let transport = PodTransport()
        transport.chat = #"{"id":"\#(Self.a)","live":false,"status":"watching","pod":"asleep"}"#
        let watch = try XCTUnwrap(LiveBrowserChatWatch(key: Self.key, interval: .milliseconds(20), idleInterval: .seconds(10)) { transport })
        watch.setVisible(true)
        try await until { watch.answer.chat?.running == false }
        XCTAssertEqual(watch.currentInterval, .seconds(10))
        let idle = watch.polls
        watch.eager = true
        XCTAssertEqual(watch.currentInterval, .milliseconds(20))
        try await until { watch.polls > idle + 3 }
        XCTAssertEqual(watch.answer.chat?.running, false)
        // Woken: the next quick lookup sees it.
        transport.chat = #"{"id":"\#(Self.a)","live":true,"status":"watching","pod":"running"}"#
        try await until { watch.answer.chat?.running == true }
        transport.chat = #"{"id":"\#(Self.a)","live":false,"status":"watching","pod":"asleep"}"#
        try await until { watch.answer.chat?.running == false }
        watch.eager = false
        XCTAssertEqual(watch.currentInterval, .seconds(10))
        try await Task.sleep(for: .milliseconds(100))
        let calm = watch.polls
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(watch.polls, calm, "back to the idle wait")
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
    /// The only key `chat` answers for, when set; others are no_link.
    var chatKey: String?
    var frameStatus: Int?
    var failure: BrowserError?
    /// `/take`'s answers in turn; the last repeats.
    var takes: [String] = []
    var takeCount = 0
    var gets: [String] = []
    /// Every GET's origin, in order.
    var origins: [String] = []
    /// Origins the computer can't reach: answered 502, as the workspace
    /// proxy does when it can't connect.
    var unreachable: Set<String> = []
    var stops = 0

    /// Every POST's origin and last path part, in order.
    var posts: [String] = []

    func send(method: String, url: URL, body: Data?, accept: String) async throws -> Data {
        if method == "POST" {
            let origin = "\(url.scheme!)://\(url.host!):\(url.port!)"
            posts.append("\(origin) \(url.lastPathComponent)")
            if unreachable.contains(origin) { throw BrowserError.upstream(502) }
            guard url.lastPathComponent == "take", !takes.isEmpty else { throw BrowserError.upstream(404) }
            let answer = takes[min(takeCount, takes.count - 1)]
            takeCount += 1
            return Data(answer.utf8)
        }
        gets.append(url.path)
        let origin = "\(url.scheme!)://\(url.host!):\(url.port!)"
        origins.append(origin)
        if unreachable.contains(origin) { throw BrowserError.upstream(502) }
        if let failure { throw failure }
        if url.path.hasPrefix("/live/chat/") {
            guard let chat, chatKey.map({ url.lastPathComponent == $0 }) ?? true else { throw BrowserError.upstream(404) }
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
