#if canImport(UIKit)
import Foundation
import HappyCore
import HappyLayout
import HappyStore
import HappyWire
@testable import HappyUI
import UIKit
import UltraView
import XCTest

private struct NoNetwork: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private struct NoSockets: WebSocketConnector {
    func connect(to url: URL) async throws -> WebSocketConnection {
        throw URLError(.notConnectedToInternet)
    }
}

/// The app's own home says which harness a worktree's chat is on, grouped
/// by project and flat, in plans made by the app's own derivation. With
/// `HAPPY_PREVIEW_DIR` set, each grouping is kept as a picture and held on
/// screen a while for a simulator screenshot.
@MainActor
final class HostedHomeRowHarnessTests: XCTestCase {
    nonisolated private static let longName = "a-worktree-with-a-name-long-enough-to-give-way"

    override func setUp() {
        super.setUp()
        LegacyFonts.registerBundledFonts()
    }

    nonisolated private static func chat(_ id: String, title: String, worktree: String, flavor: String, minutes: Int64) -> SessionRecord {
        let at = SeededAccount.base + minutes * 60_000
        return SessionRecord(
            id: id, seq: 0, createdAt: at, updatedAt: at,
            active: true, activeAt: Int64(Date().timeIntervalSince1970 * 1000), projectId: nil,
            metadataVersion: 1, metadataCipher: "harness",
            metadata: .object([
                "path": .string(SeededAccount.project + "/.dev/worktree/" + worktree), "host": .string("harness-mac"), "homeDir": .string(SeededAccount.home),
                "machineId": .string(SeededAccount.machineId), "flavor": .string(flavor),
                "summary": .object(["text": .string(title), "updatedAt": .number(Double(at))]),
                "lastMeaningfulMessageAt": .number(Double(at)),
            ]),
            agentStateVersion: 1, agentStateCipher: nil, agentState: .object(["controlledByUser": .bool(false)]),
            dataKeyCipher: nil, decryptable: true
        )
    }

    private func until(seconds: Double = 20, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    private func subview<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews { if let found = subview(type, in: child) { return found } }
        return nil
    }

    /// Home on the phone's stack, for an account holding the seed and these chats.
    private func home(account: AccountController) async throws -> (UIWindow, UIViewController) {
        let context = AppContext(account: account, variant: .preview, version: "test")
        let scene = try await hostedActiveScene()
        let hostWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let coordinator = AppCoordinator(window: window, context: context)
        coordinator.start()
        addTeardownBlock { @MainActor in
            _ = coordinator
            window.isHidden = true
            hostWindow?.makeKey()
        }
        var root: UIViewController?
        let shown = try await until {
            window.layoutIfNeeded()
            var queue = [window.rootViewController].compactMap { $0 }
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if let navigation = next as? UINavigationController, let first = navigation.viewControllers.first as? LegacyHomeViewController {
                    root = first
                    return true
                }
                queue += next.children
            }
            return false
        }
        XCTAssertTrue(shown, "no home")
        window.overrideUserInterfaceStyle = .light
        return (window, try XCTUnwrap(root))
    }

    private func labels(_ root: UIViewController) -> [String] {
        let items = subview(HomeUltraListView.self, in: root.view)?.list.items ?? []
        return items.compactMap { ($0 as? HomeUltraRow)?.plan.accessibilityLabel }
    }

    private func keep(_ window: UIWindow, _ name: String) async throws {
        window.layoutIfNeeded()
        // Lets the rows draw.
        try await Task.sleep(for: .seconds(1))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["HAPPY_PREVIEW_DIR"] else { return }
        try image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        try await Task.sleep(for: .seconds(15))
    }

    func testAWorktreeRowSaysItsHarnessInBothGroupings() async throws {
        let account = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil,
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: NoNetwork(), connector: NoSockets())
        try await account.signIn(Credentials(token: "t", secret: Data(repeating: 9, count: 32)))
        let store = try XCTUnwrap(account.session).store
        let chats = [
            Self.chat("harness-opencode", title: "Harness on the row", worktree: "feature-x", flavor: "opencode", minutes: 10),
            Self.chat("harness-long", title: "A long worktree name", worktree: Self.longName, flavor: "codex", minutes: 9),
        ]
        try await Task.detached {
            try SeededAccount.seed(store)
            try store.upsertSessions(chats)
        }.value
        let (window, root) = try await home(account: account)

        let grouped = try await until {
            let labels = labels(root)
            return labels.contains("feature-x, OpenCode") && labels.contains("\(Self.longName), Codex") && labels.contains("chat-nav, Claude Code")
        }
        XCTAssertTrue(grouped, "the project list's worktrees: \(labels(root))")
        try await keep(window, "home-row-harness-project")

        try await Task.detached { try store.addPendingSettings(["sessionListGrouping": .string("flat")]) }.value
        // A flat row's label starts with its chat and its project, so this is never the project list's.
        let flat = try await until {
            let labels = labels(root)
            return labels.contains { $0.hasPrefix("Harness on the row, happy, feature-x, OpenCode") } && labels.contains { $0.hasPrefix("Tab strip layout, happy, chat-nav, Claude Code") }
        }
        XCTAssertTrue(flat, "the flat rows: \(labels(root))")
        let own = labels(root).first { $0.hasPrefix("Release notes") }
        XCTAssertNotNil(own)
        XCTAssertEqual(own?.contains("Claude Code"), true, "a row with no worktree still says its harness: \(own ?? "")")
        try await keep(window, "home-row-harness-flat")
    }
}
#endif
