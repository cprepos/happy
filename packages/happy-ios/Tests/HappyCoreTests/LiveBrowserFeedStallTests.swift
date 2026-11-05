import Foundation
import XCTest
@testable import HappyCore

/// The player's bigger and smaller: the feed keeps reading through every
/// switch, and a read the tunnel never answers no longer stops the picture
/// for good.
final class LiveBrowserFeedStallTests: XCTestCase {
    private static let a = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"

    @MainActor
    func testTogglingSizeKeepsThePictureComing() async throws {
        let transport = StallTransport()
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        let player = NSObject()
        var shown: [Data] = []
        feed.attach(player, frames: true) { feed in if let frame = feed.frame, frame != shown.last { shown.append(frame) } }
        try await until { shown.count >= 1 }
        for round in 0..<6 {
            feed.set(player, fast: round % 2 == 0)
            XCTAssertTrue(feed.isPolling, "round \(round)")
            let seen = shown.count
            try await until { shown.count > seen }
        }
        feed.detach(player)
    }

    @MainActor
    func testAFrameReadThatNeverAnswersIsGivenUpOn() async throws {
        let transport = StallTransport()
        let feed = LiveBrowserFeed(link: try XCTUnwrap(LiveBrowserLink(id: Self.a))) { transport }
        feed.requestTimeout = .milliseconds(150)
        let player = NSObject()
        var shown: [Data] = []
        feed.attach(player, frames: true, fast: true) { feed in if let frame = feed.frame, frame != shown.last { shown.append(frame) } }
        try await until { shown.count >= 1 }
        // The next frame read hangs, deaf to cancellation, as a stalled
        // tunnel did; then the size switches while it hangs.
        transport.stallNextFrame = true
        try await until { transport.stalled > 0 }
        let seen = shown.count
        feed.set(player, fast: false)
        feed.set(player, fast: true)
        feed.set(player, fast: false)
        try await until { shown.count > seen }
        XCTAssertTrue(feed.isPolling)
        XCTAssertNotEqual(feed.phase, .unreachable)
        feed.detach(player)
        transport.release()
    }

    func testWithinAnswersTimesOutAndCancels() async throws {
        let quick = try await LiveBrowserFeed.within(.seconds(5)) { 7 }
        XCTAssertEqual(quick, 7)
        do {
            _ = try await LiveBrowserFeed.within(.milliseconds(50)) { () async throws -> Int in
                try? await Task.sleep(for: .seconds(30))
                return 1
            }
            XCTFail("answered")
        } catch {
            XCTAssertEqual(error as? BrowserError, .timeout)
        }
        let task = Task { try await LiveBrowserFeed.within(.seconds(30)) { () async throws -> Int in try await Task.sleep(for: .seconds(30)); return 1 } }
        task.cancel()
        do { _ = try await task.value; XCTFail("answered") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
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

/// A bridge whose every frame differs, and whose next frame read can hang
/// until released, ignoring cancellation.
private final class StallTransport: LiveBrowserTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var _stallNextFrame = false
    private var _stalled = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var stallNextFrame: Bool {
        get { lock.withLock { _stallNextFrame } }
        set { lock.withLock { _stallNextFrame = newValue } }
    }
    var stalled: Int { lock.withLock { _stalled } }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in defer { waiters = [] }; return waiters }
        waiting.forEach { $0.resume() }
    }

    func send(method: String, url: URL, body: Data?, accept: String) async throws -> Data {
        guard url.lastPathComponent == "frame.jpg" else { return Data(#"{"status":"watching"}"#.utf8) }
        let stall = lock.withLock { () -> Bool in
            guard _stallNextFrame else { return false }
            _stallNextFrame = false
            _stalled += 1
            return true
        }
        if stall {
            await withCheckedContinuation { continuation in lock.withLock { waiters.append(continuation) } }
        }
        let n = lock.withLock { () -> Int in count += 1; return count }
        return Data("frame \(n)".utf8)
    }

    func stop() async {}
}
