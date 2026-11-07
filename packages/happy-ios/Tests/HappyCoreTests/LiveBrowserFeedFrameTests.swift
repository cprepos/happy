import Foundation
import XCTest
@testable import HappyCore

/// The picture's own loop: frames back to back, one read at a time, small
/// as fast as large, never held by the state; and `isWaiting` while none
/// has come or the one asked for is slow.
final class LiveBrowserFeedFrameTests: XCTestCase {
    private static let a = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"

    @MainActor
    private func feed(_ transport: FrameTransport) throws -> LiveBrowserFeed {
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        feed.frameGap = .milliseconds(20)
        feed.waitingAfter = .milliseconds(150)
        return feed
    }

    @MainActor
    func testTheSmallPlayerReadsFramesBackToBack() async throws {
        let transport = FrameTransport()
        let feed = try feed(transport)
        let player = NSObject()
        // Small: not `fast`.
        feed.attach(player, frames: true, fast: false) { _ in }
        XCTAssertTrue(feed.isFraming)
        XCTAssertEqual(feed.currentInterval, LiveBrowserFeed.fastInterval)
        try await until { feed.frame != nil }
        try await Task.sleep(for: .milliseconds(500))
        // At a 1 s state interval, a frame per poll would be one or two.
        XCTAssertGreaterThan(feed.frameReads, 8, "frames come back to back, not on the state's clock")
        XCTAssertLessThanOrEqual(feed.polls, 2)
        XCTAssertEqual(transport.mostFramesAtOnce, 1, "one frame read at a time")
        feed.detach(player)
        XCTAssertFalse(feed.isFraming)
        let reads = feed.frameReads
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(feed.frameReads, reads)
    }

    @MainActor
    func testSmallAndLargeReadFramesAlike() async throws {
        var rates: [Int] = []
        for fast in [false, true] {
            let transport = FrameTransport()
            transport.frameDelay = .milliseconds(10)
            let feed = try feed(transport)
            let player = NSObject()
            feed.attach(player, frames: true, fast: fast) { _ in }
            try await until { feed.frame != nil }
            let start = feed.frameReads
            try await Task.sleep(for: .milliseconds(400))
            rates.append(feed.frameReads - start)
            feed.detach(player)
        }
        XCTAssertGreaterThan(rates[0], 5)
        XCTAssertGreaterThan(rates[0] * 2, rates[1], "small reads at about large's pace: \(rates)")
    }

    @MainActor
    func testASlowStateDoesNotHoldThePicture() async throws {
        let transport = FrameTransport()
        // The first state answers; every one after takes most of a second.
        transport.stateDelay = .milliseconds(800)
        let feed = try feed(transport)
        let player = NSObject()
        var shown = 0
        feed.attach(player, frames: true) { feed in if feed.frame != nil { shown += 1 } }
        try await until { feed.phase.isRunning }
        let reads = feed.frameReads
        try await until { feed.frameReads >= reads + 5 }
        XCTAssertLessThanOrEqual(feed.polls, 2, "the second state read still out; frames all the same")
        XCTAssertGreaterThan(shown, 0)
        feed.detach(player)
    }

    @MainActor
    func testItWaitsForTheFirstFrameAndForASlowOne() async throws {
        let transport = FrameTransport()
        transport.holdFrames = true
        let feed = try feed(transport)
        let player = NSObject()
        var waits: [Bool] = []
        feed.attach(player, frames: true) { feed in if waits.last != feed.isWaiting { waits.append(feed.isWaiting) } }
        // Nothing yet: waiting from the start.
        XCTAssertTrue(feed.isWaiting)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(feed.isWaiting)
        transport.holdFrames = false
        transport.releaseFrames()
        try await until { feed.frame != nil && !feed.isWaiting }

        // A frame read the bridge holds (an action under way): waiting,
        // the last frame kept, once `waitingAfter` has gone by.
        let last = feed.frame
        transport.holdFrames = true
        try await until { transport.held > 0 }
        XCTAssertFalse(feed.isWaiting, "not at once: a frame takes a moment")
        try await until { feed.isWaiting }
        XCTAssertEqual(feed.frame, last)
        transport.holdFrames = false
        transport.releaseFrames()
        try await until { !feed.isWaiting && feed.frame != last }
        XCTAssertEqual(waits.first, true)
        XCTAssertTrue(waits.contains(false))
        XCTAssertEqual(waits.last, false)
        feed.detach(player)
        transport.releaseFrames()
    }

    /// Each read slower than `waitingAfter` counted from the frame before
    /// it (the gap plus the read), though under it alone, every one the
    /// same picture: the bridge slow to capture an unchanged page, which is
    /// no stall. Never waiting once the first frame is up.
    @MainActor
    func testSlowAnswersOfAnUnchangedPageNeverWait() async throws {
        let transport = FrameTransport()
        transport.sameFrame = true
        transport.frameDelay = .milliseconds(300)
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        feed.frameGap = .milliseconds(150)
        feed.waitingAfter = .milliseconds(400)
        var shown = false
        var spunAfter = 0
        let player = NSObject()
        feed.attach(player, frames: true) { feed in
            if feed.frame != nil, !feed.isWaiting { shown = true }
            if shown, feed.isWaiting { spunAfter += 1 }
        }
        try await until { shown }
        let reads = feed.frameReads
        try await until { feed.frameReads >= reads + 5 }
        XCTAssertEqual(spunAfter, 0, "a slow answer, or the same picture again, is not waiting")
        XCTAssertFalse(feed.isWaiting)
        feed.detach(player)
    }

    @MainActor
    func testNoWaitingWithoutThePictureOrWhileAsleep() async throws {
        let transport = FrameTransport()
        transport.state = #"{"status":"watching","pod":"asleep","live":false}"#
        transport.holdFrames = true
        let feed = try feed(transport)
        let line = NSObject()
        feed.attach(line) { _ in }
        try await until { feed.phase.state != nil }
        XCTAssertFalse(feed.isFraming)
        XCTAssertFalse(feed.isWaiting, "nothing shows the picture")
        feed.set(line, frames: true)
        try await until { feed.phase.state?.asleep == true && !feed.isWaiting }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(feed.isWaiting, "asleep says so in words, not a spinner")
        XCTAssertEqual(transport.frameAsks, transport.held, "an asleep browser is asked no frames past the first")
        feed.detach(line)
        transport.releaseFrames()
    }

    @MainActor
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out", file: file, line: line)
    }
}

/// A bridge whose every frame differs, timed as a test sets it, counting
/// how many frame reads are open at once; frames can be held until
/// released.
private final class FrameTransport: LiveBrowserTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var states = 0
    private var open = 0
    private var _most = 0
    private var _held = 0
    private var _asks = 0
    private var _hold = false
    private var _state = #"{"status":"watching"}"#
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var frameDelay: Duration = .zero
    var stateDelay: Duration = .zero
    /// Every frame the same bytes: a page that does not change.
    var sameFrame = false

    var mostFramesAtOnce: Int { lock.withLock { _most } }
    var held: Int { lock.withLock { _held } }
    var frameAsks: Int { lock.withLock { _asks } }
    var holdFrames: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    var state: String {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    func releaseFrames() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in defer { waiters = [] }; return waiters }
        waiting.forEach { $0.resume() }
    }

    func send(method: String, url: URL, body: Data?, accept: String) async throws -> Data {
        guard url.lastPathComponent == "frame.jpg" else {
            let first = lock.withLock { () -> Bool in defer { states += 1 }; return states == 0 }
            if !first, stateDelay > .zero { try await Task.sleep(for: stateDelay) }
            return Data(state.utf8)
        }
        let hold = lock.withLock { () -> Bool in
            open += 1
            _asks += 1
            _most = max(_most, open)
            if _hold { _held += 1 }
            return _hold
        }
        defer { lock.withLock { open -= 1 } }
        if hold {
            await withCheckedContinuation { continuation in lock.withLock { waiters.append(continuation) } }
        }
        if frameDelay > .zero { try? await Task.sleep(for: frameDelay) }
        let n = lock.withLock { () -> Int in count += 1; return count }
        return Data((sameFrame ? "frame" : "frame \(n)").utf8)
    }

    func stop() async {}
}
