#if canImport(UIKit)
import Foundation
import HappyCore
import HappyStore
import HappyWire
@testable import HappyUI
import UIKit
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

/// A chat's Voice row on its info screen and the picker it opens: the row is
/// there while Happy Server carries the call, and a choice lands in
/// `voiceBySession` for that chat alone.
@MainActor
final class HostedChatVoiceTests: XCTestCase {
    private static let sessionId = "voice-session"

    private func rig() async throws -> (AccountSession, AppContext) {
        let controller = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()),
            clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(),
            storeDirectory: nil,
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: NoNetwork(),
            connector: NoSockets()
        )
        try await controller.signIn(Credentials(token: "t", secret: Data(repeating: 4, count: 32)))
        let session = try XCTUnwrap(controller.session)
        let store = session.store
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let record = SessionRecord(
            id: Self.sessionId, seq: 1, createdAt: now, updatedAt: now,
            active: true, activeAt: now, projectId: nil,
            metadataVersion: 1, metadataCipher: "test",
            metadata: .object(["path": .string("/Users/test/happy"), "host": .string("test-mac"), "flavor": .string("claude")]),
            agentStateVersion: 1, agentStateCipher: nil, agentState: .object(["controlledByUser": .bool(false)]),
            dataKeyCipher: nil, decryptable: true
        )
        try await Task.detached { try store.upsertSessions([record]) }.value
        return (session, AppContext(account: controller, variant: .development, version: "test"))
    }

    private func info(_ session: AccountSession, _ context: AppContext, config: VoiceConfig?) async throws -> (SessionInfoViewController, UINavigationController) {
        let screen = SessionInfoViewController(context: context, session: session, sessionId: Self.sessionId)
        screen.fetchVoiceConfig = {
            guard let config else { throw URLError(.notConnectedToInternet) }
            return config
        }
        let navigation = UINavigationController(rootViewController: screen)
        AppCoordinator.applyAppearance(to: navigation.navigationBar)
        let scene = try await hostedActiveScene()
        let hostWindow = scene.keyWindow
        let window = hostedKeyWindow(in: scene, root: navigation)
        addTeardownBlock { @MainActor in
            window.isHidden = true
            hostWindow?.makeKey()
        }
        window.layoutIfNeeded()
        return (screen, navigation)
    }

    private func until(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func quickActions(_ screen: SessionInfoViewController) -> [SettingsRow] {
        screen.sections.sections.first { $0.id == "quick-actions" }?.rows ?? []
    }

    private func voiceRow(_ screen: SessionInfoViewController) -> SettingsRow? {
        quickActions(screen).first { $0.id == "voice" }
    }

    private func picker(in navigation: UINavigationController) async throws -> VoicePresetViewController {
        let opened = try await until { navigation.topViewController is VoicePresetViewController && navigation.transitionCoordinator == nil }
        XCTAssertTrue(opened, "the picker didn't open: \(navigation.viewControllers)")
        let picker = try XCTUnwrap(navigation.topViewController as? VoicePresetViewController)
        let filled = try await until { picker.shownRow("voice-preset:default") != nil }
        XCTAssertTrue(filled, "the picker never showed its rows")
        return picker
    }

    func testChoosingAndClearingAChatsVoice() async throws {
        let (session, context) = try await rig()
        var latest = SettingsSnapshot()
        let observation = session.store.observeSettings { latest = $0 }
        session.updateSettings([
            "voiceAssistantVoice": .string("onyx"),
            "voiceBySession": .object(["another-chat": .string("emma")]),
        ])
        let (screen, navigation) = try await info(session, context, config: VoiceConfig(backends: [.stream], defaultBackend: .stream))

        let shown = try await until { self.voiceRow(screen) != nil }
        XCTAssertTrue(shown, "no Voice row: \(quickActions(screen).map(\.id))")
        // Under Changes, as info.tsx has it, saying Use default.
        XCTAssertEqual(Array(quickActions(screen).map(\.id).prefix(2)), ["changes", "voice"])
        XCTAssertEqual(voiceRow(screen)?.title, Strings.Voice.voice)
        XCTAssertEqual(voiceRow(screen)?.value, Strings.Voice.useDefault)

        voiceRow(screen)?.action?()
        let first = try await picker(in: navigation)
        XCTAssertEqual(first.title, Strings.Voice.voice)
        XCTAssertEqual(first.shownRowIDs.first?.count, VoicePreset.all.count + 1)
        XCTAssertEqual(first.shownRow("voice-preset:default")?.title, Strings.Voice.useDefault)
        XCTAssertEqual(first.shownRow("voice-preset:default")?.subtitle, Strings.Voice.useDefaultSubtitle(name: "Onyx"))
        XCTAssertEqual(first.shownRow("voice-preset:default")?.value, "✓")
        first.view.layoutIfNeeded()
        XCTAssertEqual(first.shownFooters, ["\(Strings.Voice.chatVoiceTitle). \(Strings.Voice.chatVoiceFooter) \(Strings.Voice.voicesFooter)"])

        first.tapRow("voice-preset:fable")
        let chosen = try await until {
            AccountSettings(latest).voiceBySession == [Self.sessionId: "fable", "another-chat": "emma"] && self.voiceRow(screen)?.value == "Fable"
        }
        XCTAssertTrue(chosen, "\(AccountSettings(latest).voiceBySession), \(String(describing: voiceRow(screen)?.value))")
        // Back on the info screen, and the default untouched.
        let back = try await until { navigation.topViewController === screen && navigation.transitionCoordinator == nil }
        XCTAssertTrue(back)
        XCTAssertEqual(AccountSettings(latest).voiceAssistantVoice, "onyx")

        voiceRow(screen)?.action?()
        let second = try await picker(in: navigation)
        let ticked = try await until { second.shownRow("voice-preset:fable")?.value == "✓" }
        XCTAssertTrue(ticked)
        XCTAssertNil(second.shownRow("voice-preset:default")?.value)
        second.tapRow("voice-preset:default")
        let cleared = try await until {
            AccountSettings(latest).voiceBySession == ["another-chat": "emma"] && self.voiceRow(screen)?.value == Strings.Voice.useDefault
        }
        XCTAssertTrue(cleared, "\(AccountSettings(latest).voiceBySession)")
        withExtendedLifetime(observation) {}
    }

    func testNoRowOnElevenLabs() async throws {
        let (session, context) = try await rig()
        let (screen, _) = try await info(session, context, config: .elevenLabsOnly)
        let shown = try await until { !self.quickActions(screen).isEmpty }
        XCTAssertTrue(shown)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(voiceRow(screen))
    }

    /// Offline, the saved service decides until the server answers.
    func testOfflineTheSavedServiceDecides() async throws {
        let (session, context) = try await rig()
        session.updateSettings(["voiceBackend": .string("stream")])
        let (screen, _) = try await info(session, context, config: nil)
        let shown = try await until { self.voiceRow(screen) != nil }
        XCTAssertTrue(shown, "no Voice row: \(quickActions(screen).map(\.id))")
    }
}
#endif
