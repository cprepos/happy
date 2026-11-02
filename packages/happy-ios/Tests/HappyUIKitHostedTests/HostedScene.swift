#if canImport(UIKit)
import UIKit
import XCTest

/// The host's window scene once it is in the foreground. These tests are
/// for what only a running application gives a view, so without one they
/// fail; they never skip.
@MainActor
func hostedActiveScene(file: StaticString = #filePath, line: UInt = #line) async throws -> UIWindowScene {
    HostedWindowSweeper.install()
    let deadline = ContinuousClock.now + .seconds(10)
    var found: UIWindowScene?
    while found == nil, ContinuousClock.now < deadline {
        found = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        if found == nil { try await Task.sleep(for: .milliseconds(50)) }
    }
    return try XCTUnwrap(found, "the host has no foreground active window scene", file: file, line: line)
}

/// Empties the windows a finished test left hidden and takes them out of
/// the scene. A hidden window is still one of its scene's, and the scene
/// keeps it, and so its whole screen, alive after the test that made it
/// lets go: by the end of a run nearly two hundred of them hold over
/// 40,000 layers that every frame's commit walks, so a later timing test
/// measures the leftovers, not its screen. Every test that makes a window
/// asks for the scene first, so the sweeper is in place before the first
/// window.
final class HostedWindowSweeper: NSObject, XCTestObservation {
    @MainActor private static var installed = false
    /// Windows that were there before any test: the host's own and UIKit's.
    @MainActor private static var host: Set<ObjectIdentifier> = []

    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        host = Set(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).map(ObjectIdentifier.init))
        XCTestObservationCenter.shared.addTestObserver(HostedWindowSweeper())
    }

    // After the test's teardown blocks, which are what hide its windows.
    func testCaseDidFinish(_ testCase: XCTestCase) {
        MainActor.assumeIsolated {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows where window.isHidden && type(of: window) == UIWindow.self
                    && !Self.host.contains(ObjectIdentifier(window)) {
                    window.rootViewController = nil
                    window.windowScene = nil
                }
            }
        }
    }
}

/// A window of `scene`, key and visible over the host's, with `root`, by
/// default an empty screen to put views on.
@MainActor
func hostedKeyWindow(in scene: UIWindowScene, root: UIViewController = UIViewController()) -> UIWindow {
    let window = UIWindow(windowScene: scene)
    window.rootViewController = root
    window.makeKeyAndVisible()
    return window
}

/// Calls back on every display frame, so a blocked main thread shows as a gap.
@MainActor
final class TickRecorder: NSObject {
    private var link: CADisplayLink?
    private let onTick: (CFTimeInterval) -> Void

    init(_ onTick: @escaping (CFTimeInterval) -> Void) {
        self.onTick = onTick
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) { onTick(link.timestamp) }

    func stop() {
        link?.invalidate()
        link = nil
    }
}
#endif
