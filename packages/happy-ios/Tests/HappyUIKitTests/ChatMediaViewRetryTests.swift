#if canImport(UIKit)
@testable import HappyUI
import UIKit
import XCTest

/// The computer coming back while a tile's read is still going: that read
/// began while it was away, so a failure after the retry asks once more.
@MainActor
final class ChatMediaViewRetryTests: XCTestCase {
    private final class Source: ChatMediaSource {
        var asks = 0
        var first: CheckedContinuation<UIImage?, Never>?
        func cachedImage(_ key: String, pixels: Int) -> UIImage? { nil }
        func image(_ key: String, pixels: Int) async -> UIImage? {
            asks += 1
            if asks == 1 { return await withCheckedContinuation { first = $0 } }
            return ChatMediaViewRetryTests.picture
        }
    }

    private final class Host: UIViewController, ChatMediaProviding {
        var source: ChatMediaSource?
        var chatMedia: ChatMediaSource? { source }
    }

    static let picture = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }

    private func until(_ what: String, _ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "never: \(what)", line: line)
    }

    private func tileReading(_ source: Source) async throws -> ChatMediaView {
        let host = Host()
        host.source = source
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = host
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        let tile = ChatMediaView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        host.view.addSubview(tile)
        tile.apply(ChatMedia(key: "tool/t/0", isVideo: true, thumbhash: nil, label: "clip.mp4"))
        tile.layoutIfNeeded()
        try await until("the first read") { source.first != nil }
        return tile
    }

    func testARetryDuringAReadThatFailsAsksAgain() async throws {
        let source = Source()
        let tile = try await tileReading(source)
        NotificationCenter.default.post(name: MediaLoader.retry, object: source)
        XCTAssertEqual(source.asks, 1, "the read still going isn't doubled")
        source.first?.resume(returning: nil)
        try await until("the picture from the second read") { tile.pictureImage != nil }
        XCTAssertEqual(source.asks, 2)
    }

    func testARetryDuringAReadThatWorksAsksNoMore() async throws {
        let source = Source()
        let tile = try await tileReading(source)
        NotificationCenter.default.post(name: MediaLoader.retry, object: source)
        source.first?.resume(returning: Self.picture)
        try await until("the picture from the first read") { tile.pictureImage != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(source.asks, 1)
    }
}
#endif
