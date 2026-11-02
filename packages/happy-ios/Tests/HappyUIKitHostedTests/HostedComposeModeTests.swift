#if canImport(UIKit)
import Foundation
import HappyCore
import HappyLayout
import HappyStore
import HappyWire
@testable import HappyUI
import UIKit
import XCTest

private struct ModeOffline: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
}

private struct ModeNoSocket: WebSocketConnector {
    func connect(to url: URL) async throws -> WebSocketConnection { throw URLError(.notConnectedToInternet) }
}

/// The machine: a spawn writes the new session's row, as sync would.
private struct ModeMachine: HomeOps {
    let store: LocalStore

    func machineSpawnNewSession(options: SpawnSessionOptions) async -> SpawnSessionResult {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let record = SessionRecord(
            id: HostedComposeModeTests.newSessionId, seq: 0, createdAt: now, updatedAt: now,
            active: true, activeAt: now, projectId: nil,
            metadataVersion: 1, metadataCipher: "harness",
            metadata: .object([
                "path": .string(SeededAccount.project), "host": .string("harness-mac"), "homeDir": .string(SeededAccount.home),
                "machineId": .string(SeededAccount.machineId), "flavor": .string(options.agent ?? "claude"), "version": .string("1.3.0"),
            ]),
            agentStateVersion: 1, agentStateCipher: nil, agentState: .object(["controlledByUser": .bool(false)]),
            dataKeyCipher: nil, decryptable: true
        )
        try? await Task.detached { [store] in try store.upsertSessions([record]) }.value
        return .success(sessionId: HostedComposeModeTests.newSessionId)
    }
    func machineResumeSession(machineId: String, sessionId: String, model: String?, permissionMode: String?) async -> SpawnSessionResult { .error(errorMessage: "") }
    func forkAndSpawn(source: ForkSource, options: ForkOptions) async -> SpawnSessionResult { .error(errorMessage: "") }
    func machineStopSession(machineId: String, sessionId: String) async -> MachineOperationResult { try! JSONDecoder().decode(MachineOperationResult.self, from: Data(#"{"success":true}"#.utf8)) }
    func machineBash(machineId: String, command: String, cwd: String) async throws -> SessionBashResponse { throw URLError(.cannotConnectToHost) }
}

private struct ModeSessionOps: HomeSessionOps {
    func sessionKill(sessionId: String) async throws -> SessionKillResponse { throw URLError(.cannotConnectToHost) }
    func sessionSetAgentModes(sessionId: String, patch: SessionAgentModesPatch, transport: any MetadataUpdateTransport) async throws {}
    func sessionSetAvatar(sessionId: String, picture: SessionAvatarPicture) async throws {}
    func archive(sessionId: String) async throws {}
    func ensureSessionReady(sessionId: String) async throws {}
    func uploadSessionBlob(sessionId: String, name: String, bytes: Data) async throws -> (ref: String, size: Int) { throw URLError(.cannotConnectToHost) }
}

/// The empty chat's Mode row, through the screen the compose button opens: what
/// it offers, what a pick does to the first message, and whether it all fits
/// with the keyboard up. The fit tests assert on whichever simulator runs them;
/// the one that matters is the iPhone SE (3rd generation), 375x667.
@MainActor
final class HostedComposeModeTests: XCTestCase {
    nonisolated static let newSessionId = "compose-mode-session"
    nonisolated static let happyAgentId = "mode-happy-agent"

    /// What a Happy Agent beside the seeded computer reports.
    enum HappyAgent {
        case none
        /// Makes tasks and bots, so Session | Bot | Task heads the panel.
        case withModes
        /// Reports no operating modes: a harness with none to pick.
        case withoutModes
    }

    override func setUp() {
        super.setUp()
        LegacyFonts.registerBundledFonts()
    }

    override func tearDown() {
        LegacyComposeStart.makeStarter = { SessionStarter.make(for: $0) }
        super.tearDown()
    }

    private nonisolated static func seed(_ store: LocalStore, machines: Int, happyAgent: HappyAgent) throws {
        try SeededAccount.seed(store)
        try store.addPendingSettings(["sessionListGrouping": .string("flat")])
        guard let seeded = try store.machines().first, let template = try store.sessions().first else { return }
        let availability: JSONValue = .object(["claude": .bool(true), "codex": .bool(true), "opencode": .bool(true)])
        var own = seeded
        var ownFields = own.metadata?.objectValue ?? [:]
        ownFields["cliAvailability"] = availability
        ownFields["happyCliVersion"] = .string("1.3.0")
        own.metadata = .object(ownFields)
        own.metadataVersion += 1
        try store.upsertMachine(own)

        for index in 1..<max(1, machines) {
            let id = "mode-computer-\(index)"
            var machine = own
            machine.id = id
            machine.createdAt -= Int64(index)
            machine.active = index == 1
            var fields = machine.metadata?.objectValue ?? [:]
            fields["displayName"] = .string("Computer \(index)")
            fields["host"] = .string(id)
            machine.metadata = .object(fields)
            try store.upsertMachine(machine)
            var row = template
            row.id = "chat-on-\(id)"
            var rowFields = row.metadata?.objectValue ?? [:]
            rowFields["machineId"] = .string(id)
            rowFields["host"] = .string(id)
            rowFields["path"] = .string("/Users/harness/Developer/site")
            row.metadata = .object(rowFields)
            try store.upsertSessions([row])
        }

        guard happyAgent != .none else { return }
        var agent = own
        agent.id = happyAgentId
        agent.createdAt += 1
        var metadata: [String: JSONValue] = [
            "host": .string("harness-mac"), "homeDir": .string(SeededAccount.home),
            "machineKind": .string("rig"), "siblingMachineId": .string(SeededAccount.machineId),
            "capabilities": .object(["newSession": .bool(true), "bots": .bool(true), "tasks": .bool(true), "worktrees": .bool(false)]),
            "defaults": .object(["providerId": .string("codex"), "modelId": .string("gpt")]),
            "models": .array([
                .object(["providerId": .string("codex"), "id": .string("gpt"), "name": .string("GPT"), "providerName": .string("OpenAI"),
                         "thinkingLevels": .array([.string("medium")]), "defaultThinkingLevel": .string("medium")]),
            ]),
        ]
        if happyAgent == .withModes {
            metadata["operatingModes"] = .array([
                .object(["code": .string("auto"), "value": .string("Auto")]),
                .object(["code": .string("read_only"), "value": .string("Read only")]),
            ])
        }
        agent.metadata = .object(metadata)
        try store.upsertMachine(agent)
    }

    private struct Screen {
        var navigation: UINavigationController
        var window: UIWindow
        var account: AccountSession
        var chat: LegacyChatViewController
        var card: AgentInputCardView
        var panel: NewWorkPanel
        var start: LegacyComposeStart
    }

    private func emptyChat(machines: Int = 1, happyAgent: HappyAgent = .none) async throws -> Screen {
        let controller = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil,
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: ModeOffline(), connector: ModeNoSocket()
        )
        try await controller.signIn(Credentials(token: "t", secret: Data(repeating: 7, count: 32)))
        let account = try XCTUnwrap(controller.session)
        let store = account.store
        try await Task.detached { [store] in try HostedComposeModeTests.seed(store, machines: machines, happyAgent: happyAgent) }.value
        let drafts = NewSessionDraftStore.shared(for: controller.localSettings)
        drafts.setMachineId(SeededAccount.machineId)
        drafts.setPath(SeededAccount.project)
        drafts.setInput("")
        if happyAgent != .none { drafts.pickAgentType(.claude) }
        LegacyComposeStart.makeStarter = { account in
            SessionStarter(environment: .init(
                ops: ModeMachine(store: account.store),
                sessionOps: ModeSessionOps(),
                sender: account.sender,
                metadataTransport: account.realtime,
                saveInitialModes: { [sender = account.sender] in try await sender.saveInitialModes(sessionId: $0, patch: $1) },
                refreshSessions: {},
                paintBotFace: { _ in throw URLError(.cannotConnectToHost) },
                attachmentPlan: { [sender = account.sender] message, sessionId in try await sender.attachmentPlan(for: message, sessionId: sessionId) },
                spawnRequests: account.spawnRequests
            ))
        }
        let context = AppContext(account: controller, variant: .production, version: "test")
        let home = LegacyHomeViewController(context: context, session: account)
        let navigation = UINavigationController(rootViewController: home)
        AppCoordinator.applyAppearance(to: navigation.navigationBar)
        let scene = try await hostedActiveScene()
        let window = hostedKeyWindow(in: scene, root: navigation)
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
        return Screen(navigation: navigation, window: window, account: account, chat: chat, card: card, panel: panel, start: start)
    }

    private func pickHarness(_ title: String, _ screen: Screen) async throws {
        let action = try XCTUnwrap(Self.actions(screen.start.harnessMenuElements()).first { $0.title == title }, title)
        action.performWithSender(nil, target: nil)
        try await until { screen.panel.harness.title == title }
    }

    private func pickMode(_ title: String, _ screen: Screen) async throws {
        let action = try XCTUnwrap(Self.actions(screen.start.modeMenuElements()).first { $0.title == title }, title)
        action.performWithSender(nil, target: nil)
        try await until { screen.panel.modeRow.title == title }
    }

    /// Sends through the card, and returns the first message in the session's
    /// outbox.
    private func send(_ text: String, _ screen: Screen) async throws -> OutboxRecord {
        screen.card.setText(text, selection: NSRange(location: (text as NSString).length, length: 0))
        screen.card.delegate?.agentInputCardDidChangeText(screen.card)
        screen.card.delegate?.agentInputCardDidPressSend(screen.card)
        try await until { !screen.chat.isComposing }
        let store = screen.account.store
        let outbox = try await Task.detached { try store.pendingOutbox() }.value
        return try XCTUnwrap(outbox.first { $0.sessionId == Self.newSessionId && $0.kind == .message })
    }

    // MARK: What it offers

    func testTheRowShowsOpenCodesModesUnderTheHarness() async throws {
        let screen = try await emptyChat()
        defer { screen.window.isHidden = true }
        try await pickHarness("OpenCode", screen)
        let panel = screen.panel
        try await until { panel.modeRow.title == "Build-auto" }
        XCTAssertFalse(panel.modeRow.isHidden)
        let actions = Self.actions(screen.start.modeMenuElements())
        XCTAssertEqual(actions.map(\.title), ["Build-auto", "Build-ask", "Plan-auto", "Plan-ask"])
        XCTAssertEqual(actions.filter { $0.state == .on }.map(\.title), ["Build-auto"])

        screen.chat.view.setNeedsLayout()
        screen.chat.view.layoutIfNeeded()
        XCTAssertEqual(panel.modeRow.frame.minY, panel.harness.frame.maxY + NewWorkLayout.Metrics.rowGap, accuracy: 0.5, "straight under the harness")
        XCTAssertEqual(panel.modeRow.frame.width, panel.harness.frame.width)

        // The pick shows, on the row and in its menu.
        try await pickMode("Plan-ask", screen)
        XCTAssertEqual(screen.start.drafts.draft.permissionMode, "plan:ask")
        XCTAssertEqual(Self.actions(screen.start.modeMenuElements()).filter { $0.state == .on }.map(\.title), ["Plan-ask"])
    }

    func testLockedLikeTheOtherRows() async throws {
        let screen = try await emptyChat()
        defer { screen.window.isHidden = true }
        try await until { !screen.panel.modeRow.isHidden }
        screen.panel.isLocked = true
        XCTAssertFalse(screen.panel.modeRow.isEnabled)
        XCTAssertFalse(screen.panel.harness.isEnabled)
        screen.panel.isLocked = false
        XCTAssertTrue(screen.panel.modeRow.isEnabled)
        XCTAssertTrue(screen.panel.harness.isEnabled)
    }

    // MARK: The first message

    func testPickingAskMakesTheFirstMessageCarryAsk() async throws {
        let screen = try await emptyChat()
        defer { screen.window.isHidden = true }
        try await pickHarness("OpenCode", screen)
        try await pickMode("Build-ask", screen)
        let first = try await send("Look around", screen)
        XCTAssertEqual(first.payload["meta"]?["permissionMode"]?.stringValue, "build:ask")
    }

    func testPickingAutoMakesTheFirstMessageCarryAuto() async throws {
        let screen = try await emptyChat()
        defer { screen.window.isHidden = true }
        try await pickHarness("OpenCode", screen)
        // Away and back, so this is a pick and not the default.
        try await pickMode("Plan-ask", screen)
        try await pickMode("Plan-auto", screen)
        let first = try await send("Look around", screen)
        XCTAssertEqual(first.payload["meta"]?["permissionMode"]?.stringValue, "plan:auto")
    }

    func testClaudeCanStartInPlan() async throws {
        let screen = try await emptyChat()
        defer { screen.window.isHidden = true }
        try await pickHarness("Claude Code", screen)
        try await pickMode("Plan", screen)
        let first = try await send("Think first", screen)
        XCTAssertEqual(first.payload["meta"]?["permissionMode"]?.stringValue, "plan")
    }

    // MARK: Following the harness

    func testSwitchingHarnessUpdatesTheRowAndClearsAModeThatDoesNotApply() async throws {
        let screen = try await emptyChat()
        defer { screen.window.isHidden = true }
        try await pickHarness("OpenCode", screen)
        try await pickMode("Plan-ask", screen)

        try await pickHarness("Claude Code", screen)
        let panel = screen.panel
        try await until { panel.modeRow.title != "Plan-ask" }
        let claude = Self.actions(screen.start.modeMenuElements()).map(\.title)
        XCTAssertTrue(claude.contains("Plan"), "\(claude)")
        XCTAssertFalse(claude.contains("Plan-ask"), "\(claude)")
        XCTAssertFalse(screen.start.drafts.draft.permissionMode?.contains(":") ?? false, "OpenCode's mode stayed in the draft: \(String(describing: screen.start.drafts.draft.permissionMode))")
        XCTAssertTrue(claude.contains(panel.modeRow.title), "\(panel.modeRow.title) isn't one of \(claude)")

        try await pickHarness("Codex", screen)
        try await until { Self.actions(screen.start.modeMenuElements()).contains { $0.title == "Workspace" } }
        XCTAssertFalse(panel.modeRow.isHidden)

        // Back: its default, not the pick that was cleared.
        try await pickHarness("OpenCode", screen)
        try await until { panel.modeRow.title == "Build-auto" }
        XCTAssertEqual(screen.start.drafts.draft.permissionMode, "build:auto")
    }

    func testAHarnessWithNoModesHidesTheRow() async throws {
        let screen = try await emptyChat(happyAgent: .withoutModes)
        defer { screen.window.isHidden = true }
        let panel = screen.panel
        try await until { !panel.modeRow.isHidden }
        let before = panel.layout(width: screen.chat.view.bounds.width, top: 100, bottom: 700).rows.count

        try await pickHarness("Happy", screen)
        try await until { panel.modeRow.isHidden }
        XCTAssertNil(screen.start.modeName)
        XCTAssertTrue(screen.start.modeMenuElements().isEmpty)
        XCTAssertEqual(panel.layout(width: screen.chat.view.bounds.width, top: 100, bottom: 700).rows.count, before - 1, "its row went from the layout")

        // And back when the harness has them again.
        try await pickHarness("OpenCode", screen)
        try await until { !panel.modeRow.isHidden && panel.modeRow.title == "Build-auto" }
    }

    /// A task has no harness row, so no mode either; Session brings both back.
    func testATaskAsksNoMode() async throws {
        let screen = try await emptyChat(happyAgent: .withModes)
        defer { screen.window.isHidden = true }
        let panel = screen.panel
        try await until { screen.start.kinds.contains(.task) && !panel.kind.isHidden }
        screen.start.setKind(.task)
        try await until { panel.sessionKind == .task }
        XCTAssertTrue(panel.modeRow.isHidden)
        XCTAssertTrue(panel.harness.isHidden)
        screen.start.setKind(.session)
        try await until { panel.sessionKind == .session }
        XCTAssertFalse(panel.modeRow.isHidden)
    }

    // MARK: Keyboard up

    /// Computer, folder, harness and mode between the bar and the composer.
    func testFourRowsFitWithTheKeyboardUp() async throws {
        let screen = try await emptyChat(machines: 3)
        defer { screen.window.isHidden = true }
        try await pickHarness("OpenCode", screen)
        try await assertFits(screen, rows: [screen.panel.machine, screen.panel.folder, screen.panel.harness, screen.panel.modeRow], name: "four-rows")
    }

    /// The worst a phone asks: Session | Bot | Task over the same four.
    func testTheKindAndFourRowsFitWithTheKeyboardUp() async throws {
        let screen = try await emptyChat(machines: 3, happyAgent: .withModes)
        defer { screen.window.isHidden = true }
        let panel = screen.panel
        try await until { !panel.kind.isHidden }
        XCTAssertFalse(panel.machine.isHidden)
        try await assertFits(screen, rows: [panel.machine, panel.folder, panel.harness, panel.modeRow], name: "kind-and-four-rows")
        let kind = panel.kind.convert(panel.kind.bounds, to: screen.chat.view)
        XCTAssertLessThanOrEqual(kind.maxY, panel.machine.convert(panel.machine.bounds, to: screen.chat.view).minY)
    }

    private func assertFits(_ screen: Screen, rows: [UIView], name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let view: UIView = screen.chat.view
        let deadline = ContinuousClock.now + .seconds(5)
        while view.keyboardLayoutGuide.layoutFrame.height <= 100, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(view.keyboardLayoutGuide.layoutFrame.height, 100, "no software keyboard came up", file: file, line: line)
        try await Task.sleep(for: .milliseconds(500))
        view.layoutIfNeeded()

        let panel = screen.panel
        let card = screen.card.convert(screen.card.bounds, to: view)
        let barFoot = screen.navigation.navigationBar.convert(screen.navigation.navigationBar.bounds, to: view).maxY
        let frames = rows.map { $0.convert($0.bounds, to: view) }
        let report = "\(name): window \(screen.window.bounds.size), bar foot \(barFoot), keyboard top \(view.keyboardLayoutGuide.layoutFrame.minY), card \(card), panel \(panel.frame), rows \(frames.map(\.height))"
        print("MODE-ROW-FIT \(report)")
        XCTContext.runActivity(named: report) { _ in }

        XCTAssertFalse(panel.isHidden, "the panel gave up: \(report)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, barFoot, report, file: file, line: line)
        XCTAssertLessThanOrEqual(panel.frame.maxY, card.minY, report, file: file, line: line)
        XCTAssertLessThanOrEqual(card.maxY, view.keyboardLayoutGuide.layoutFrame.minY + 0.5, report, file: file, line: line)
        for (index, frame) in frames.enumerated() {
            XCTAssertFalse(rows[index].isHidden, "row \(index): \(report)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.height, NewWorkLayout.Metrics.compactRowHeight, report, file: file, line: line)
            if index > 0 { XCTAssertGreaterThan(frame.minY, frames[index - 1].maxY, report, file: file, line: line) }
        }
        let image = UIGraphicsImageRenderer(bounds: screen.window.bounds).image { _ in
            _ = screen.window.drawHierarchy(in: screen.window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["HAPPY_PREVIEW_DIR"] {
            try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            try? await Task.sleep(for: .seconds(4))
        }
    }

    // MARK: Helpers

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
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
