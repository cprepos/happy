#if canImport(UIKit)
import Foundation
import HappyCore
import HappyStore
import HappyWire
@testable import HappyUI
import UIKit
import XCTest

private struct OpencodeComposeOffline: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
}

private struct OpencodeComposeNoSocket: WebSocketConnector {
    func connect(to url: URL) async throws -> WebSocketConnection { throw URLError(.notConnectedToInternet) }
}

/// The empty chat compose opens on an account of three computers, all
/// reporting OpenCode, one of them offline: computer, folder, harness, mode and
/// model before the first send, with the keyboard up. With
/// `HAPPY_PREVIEW_DIR` set, it writes what it showed and holds the screen long
/// enough for a real screenshot, as a window's own drawing has no keyboard.
@MainActor
final class HostedOpencodeComposeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LegacyFonts.registerBundledFonts()
    }

    private nonisolated static func seed(_ store: LocalStore) throws {
        try SeededAccount.seed(store)
        try store.addPendingSettings(["sessionListGrouping": .string("flat")])
        guard let seeded = try store.machines().first, let template = try store.sessions().first else { return }
        let availability: JSONValue = .object(["claude": .bool(true), "codex": .bool(true), "opencode": .bool(true)])

        var own = seeded
        var ownFields = own.metadata?.objectValue ?? [:]
        ownFields["cliAvailability"] = availability
        own.metadata = .object(ownFields)
        own.metadataVersion += 1
        try store.upsertMachine(own)

        for (index, computer) in [("studio-mac", "Studio Mac", true), ("old-mini", "Old Mini", false)].enumerated() {
            var machine = seeded
            machine.id = computer.0
            machine.createdAt -= Int64(index + 1)
            machine.active = computer.2
            var metadata = machine.metadata?.objectValue ?? [:]
            metadata["displayName"] = .string(computer.1)
            metadata["host"] = .string(computer.0)
            metadata["cliAvailability"] = availability
            machine.metadata = .object(metadata)
            try store.upsertMachine(machine)

            var row = template
            row.id = "chat-on-\(computer.0)"
            var fields = row.metadata?.objectValue ?? [:]
            fields["machineId"] = .string(computer.0)
            fields["host"] = .string(computer.0)
            fields["path"] = .string("/Users/harness/Developer/site")
            row.metadata = .object(fields)
            try store.upsertSessions([row])
        }
    }

    func testOpenCodeIsPickableInTheEmptyChatWithTheKeyboardUp() async throws {
        let controller = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil,
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: OpencodeComposeOffline(), connector: OpencodeComposeNoSocket()
        )
        try await controller.signIn(Credentials(token: "t", secret: Data(repeating: 7, count: 32)))
        let account = try XCTUnwrap(controller.session)
        let store = account.store
        try await Task.detached { [store] in try HostedOpencodeComposeTests.seed(store) }.value
        let drafts = NewSessionDraftStore.shared(for: controller.localSettings)
        drafts.setMachineId(SeededAccount.machineId)
        drafts.setPath(SeededAccount.project)
        drafts.setInput("")

        let context = AppContext(account: controller, variant: .production, version: "test")
        let home = LegacyHomeViewController(context: context, session: account)
        let navigation = UINavigationController(rootViewController: home)
        AppCoordinator.applyAppearance(to: navigation.navigationBar)
        let scene = try await hostedActiveScene()
        let window = hostedKeyWindow(in: scene, root: navigation)
        defer { window.isHidden = true }
        window.overrideUserInterfaceStyle = .light
        window.layoutIfNeeded()
        try await until { home.children.contains { $0 is SessionListViewController } && home.canCompose }

        home.compose()
        try await until { navigation.transitionCoordinator == nil && navigation.topViewController is LegacyChatViewController }
        let chat = try XCTUnwrap(navigation.topViewController as? LegacyChatViewController)
        try await until { chat.contentInstalled && Self.subview(AgentInputCardView.self, in: chat.view) != nil }
        let card = try XCTUnwrap(Self.subview(AgentInputCardView.self, in: chat.view))
        try await until { card.textView.isFirstResponder }
        let panel = try XCTUnwrap(Self.subview(NewWorkPanel.self, in: chat.view))
        let start = try XCTUnwrap(chat.composeStart)

        // Every computer, the offline one too.
        let computers = Self.actions(start.machineMenuElements()).map(\.title)
        XCTAssertEqual(computers.count, 3, "\(computers)")
        XCTAssertTrue(computers.contains { $0.contains("Old Mini") }, "\(computers)")
        XCTAssertFalse(panel.machine.isHidden, "three computers: it asks which")

        // OpenCode, straight after Codex as nothing here reports Antigravity.
        let harnesses = Self.actions(start.harnessMenuElements())
        XCTAssertEqual(harnesses.map(\.title), ["Claude Code", "Codex", "OpenCode"])
        try XCTUnwrap(harnesses.first { $0.title == "OpenCode" }).performWithSender(nil, target: nil)
        try await until { panel.harness.title == "OpenCode" }
        XCTAssertEqual(start.drafts.draft.agentType, .opencode)

        // Its controls, before any session exists: Build and Plan, each in
        // auto and ask, on the panel's row, as the card draws no chip for them
        // on a phone (HostedComposeModeTests), and no effort.
        try await until { panel.modeRow.title == "Build-auto" }
        XCTAssertFalse(panel.modeRow.isHidden)
        XCTAssertEqual(Self.actions(start.modeMenuElements()).map(\.title), ["Build-auto", "Build-ask", "Plan-auto", "Plan-ask"])
        XCTAssertFalse(panel.harness.isHidden)
        XCTAssertFalse(panel.folder.isHidden)
        XCTAssertNotNil(card.configuration.model?.menu, "the model must be pickable before a session exists")
        XCTAssertNil(card.configuration.effort?.menu, "OpenCode has no effort")
        XCTAssertEqual(start.drafts.draft.permissionMode, OpencodeModes.defaultPermissionMode)

        let keyboard = try await waitForKeyboard(in: chat.view)
        XCTAssertTrue(keyboard, "no software keyboard came up: turn off the simulator's hardware keyboard")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThanOrEqual(card.convert(card.bounds, to: chat.view).maxY, chat.view.keyboardLayoutGuide.layoutFrame.minY + 0.5, "the composer sits above the keyboard")
        await keep(window, "harness-empty-chat-keyboard-up")
    }

    private func waitForKeyboard(in view: UIView) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while view.keyboardLayoutGuide.layoutFrame.height <= 100, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return view.keyboardLayoutGuide.layoutFrame.height > 100
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func keep(_ window: UIWindow, _ name: String) async {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["HAPPY_PREVIEW_DIR"] else { return }
        try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        try? await Task.sleep(for: .seconds(6))
    }

    private static func actions(_ elements: [UIMenuElement]) -> [UIAction] {
        elements.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let menu = element as? UIMenu { return actions(menu.children) }
            return []
        }
    }

    private static func subview<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = subview(type, in: child) { return match }
        }
        return nil
    }
}
#endif
