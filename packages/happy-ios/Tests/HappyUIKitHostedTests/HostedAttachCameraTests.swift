#if canImport(UIKit)
import HappyLayout
@testable import HappyUI
import UIKit
import XCTest

/// A camera that records what the cell asks of it, and on which thread.
private final class RecordingCaptureSource: AttachCaptureSource, @unchecked Sendable {
    enum Call: Equatable { case start, stop }

    let access: AttachCameraAccess
    @MainActor let preview = CALayer()
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _onMain = false

    @MainActor init(_ access: AttachCameraAccess) {
        self.access = access
        preview.backgroundColor = UIColor.systemTeal.cgColor
    }

    var calls: [Call] { lock.withLock { _calls } }
    /// Whether any call came on the main thread.
    var onMain: Bool { lock.withLock { _onMain } }

    func startRunning() -> Bool {
        record(.start)
        return true
    }

    func stopRunning() { record(.stop) }

    private func record(_ call: Call) {
        let main = Thread.isMainThread
        lock.withLock {
            _calls.append(call)
            _onMain = _onMain || main
        }
    }
}

/// The attach menu's camera cell: live once allowed, in a window and in
/// front, stopping as each of those ends, and never touching the camera
/// on the main thread. Without access it stays black with its glyph.
///
/// With `HAPPY_PREVIEW_DIR` set, the menu with a drawn stand-in for the
/// camera is kept there as `camera-tile-light.png` and `-dark.png`.
@MainActor
final class HostedAttachCameraTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    private func host(_ tile: AttachCameraTile) async throws -> UIView {
        let window = hostedKeyWindow(in: try await hostedActiveScene())
        self.window = window
        let root = try XCTUnwrap(window.rootViewController?.view)
        tile.frame = CGRect(x: 0, y: 100, width: 133, height: 267)
        root.addSubview(tile)
        window.layoutIfNeeded()
        return root
    }

    private func wait(_ seconds: Double = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "never reached the expected state", file: file, line: line)
    }

    /// The black and the glyph, over the preview until the first picture.
    private func fade(of tile: AttachCameraTile) -> UIView? {
        tile.fade
    }

    func testAllowedRunsOffTheMainThreadAndShowsThePreview() async throws {
        let source = RecordingCaptureSource(.authorized)
        let tile = AttachCameraTile(source: source)
        XCTAssertEqual(source.calls, [], "started before it had a window")
        _ = try await host(tile)
        try await wait { source.calls == [.start] && tile.live }
        XCTAssertFalse(source.onMain, "the camera started on the main thread")
        XCTAssertTrue(tile.running)
        XCTAssertNotNil(source.preview.superlayer, "the preview isn't in the cell")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(try XCTUnwrap(fade(of: tile)).alpha, 0, accuracy: 0.001, "the black never faded")

        // Telegram's glyph, top right.
        let glyph = tile.icon
        let expected = AttachCameraTileLayout(size: tile.bounds.size, screenWidth: 1, scale: tile.traitCollection.displayScale).glyph
        XCTAssertEqual(expected.minX, 100)
        XCTAssertEqual(glyph.frame.minX, expected.minX, accuracy: 0.001)
        XCTAssertEqual(glyph.frame.minY, expected.minY, accuracy: 0.001)
        XCTAssertEqual(glyph.frame.size, expected.size)
        // The preview fills the cell at a full-screen camera's aspect.
        XCTAssertEqual(source.preview.convert(source.preview.bounds, to: tile.layer).height, 267, accuracy: 0.01)

        tile.removeFromSuperview()
        try await wait { source.calls == [.start, .stop] }
        XCTAssertFalse(source.onMain, "the camera stopped on the main thread")
    }

    func testBackgroundStopsAndForegroundStartsAgain() async throws {
        let source = RecordingCaptureSource(.authorized)
        let tile = AttachCameraTile(source: source)
        _ = try await host(tile)
        try await wait { source.calls == [.start] }

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        try await wait { source.calls == [.start, .stop] }
        XCTAssertFalse(tile.running)

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        try await wait { source.calls == [.start, .stop, .start] }
        XCTAssertTrue(tile.running)
        XCTAssertFalse(source.onMain)
    }

    /// Telegram's `isCameraPreviewVisible`: scrolled out, held; back, live.
    func testScrollingOutPausesAndBackResumes() async throws {
        let source = RecordingCaptureSource(.authorized)
        let tile = AttachCameraTile(source: source)
        let window = hostedKeyWindow(in: try await hostedActiveScene())
        self.window = window
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 500))
        scroll.contentSize = CGSize(width: 402, height: 3000)
        window.rootViewController?.view.addSubview(scroll)
        tile.frame = CGRect(x: 0, y: 0, width: 133, height: 267)
        scroll.addSubview(tile)
        try await wait { source.calls == [.start] }

        scroll.contentOffset = CGPoint(x: 0, y: 300)
        XCTAssertFalse(tile.onScreen)
        try await wait { source.calls == [.start, .stop] }
        // Still partly in: still live.
        scroll.contentOffset = CGPoint(x: 0, y: 200)
        XCTAssertTrue(tile.onScreen)
        try await wait { source.calls == [.start, .stop, .start] }
    }

    /// A tap hands the camera to the full one at once.
    func testATapStopsTheCamera() async throws {
        let source = RecordingCaptureSource(.authorized)
        let tile = AttachCameraTile(source: source)
        var tapped = false
        tile.addAction(UIAction { _ in tapped = true }, for: .touchUpInside)
        _ = try await host(tile)
        try await wait { source.calls == [.start] }
        tile.sendActions(for: .touchUpInside)
        XCTAssertTrue(tapped)
        XCTAssertFalse(tile.running)
        try await wait { source.calls == [.start, .stop] }

        tile.start()
        try await wait { source.calls == [.start, .stop, .start] }
    }

    /// Not asked yet, denied, or no camera: black with the glyph, and the
    /// camera never touched (the cell never asks for access).
    func testWithoutAccessTheCellStaysStill() async throws {
        for access in [AttachCameraAccess.notDetermined, .denied, .unavailable] {
            let source = RecordingCaptureSource(access)
            let tile = AttachCameraTile(source: source)
            _ = try await host(tile)
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(source.calls, [], "\(access) touched the camera")
            XCTAssertFalse(tile.running)
            XCTAssertFalse(tile.live)
            XCTAssertEqual(try XCTUnwrap(fade(of: tile)).alpha, 1, "\(access) uncovered the preview")
            XCTAssertEqual(tile.accessibilityIdentifier, "attach-camera")
            tile.removeFromSuperview()
            window?.isHidden = true
        }
    }

    /// The menu with the drawn stand-in, for screenshots.
    func testTheMenuShowsTheCameraLive() async throws {
        AttachMenuEnvironment.captureSource = { FixtureAttachCaptureSource() }
        defer { AttachMenuEnvironment.captureSource = { CameraAttachCaptureSource() } }
        let root = UIViewController()
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: root)
        self.window = window
        let sheet = AttachSheetViewController(limit: 10, library: FixtureAttachLibrary(access: .authorized, count: 30), camera: true)
        root.present(sheet, animated: false)
        try await Task.sleep(for: .milliseconds(900))
        let tile = try XCTUnwrap(views(sheet.view).compactMap { $0 as? AttachCameraTile }.first)
        try await wait { tile.live }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNotNil(tile.source.preview.contents, "no stand-in frame")

        guard let directory = ProcessInfo.processInfo.environment["HAPPY_PREVIEW_DIR"] else { return }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("camera-tile-\(style == .dark ? "dark" : "light").png"))
        }
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
}
#endif
