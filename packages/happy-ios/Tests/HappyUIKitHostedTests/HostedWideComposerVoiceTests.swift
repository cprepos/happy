#if canImport(UIKit)
import Foundation
import HappyCore
import HappyStore
@testable import HappyUI
import UIKit
import XCTest

private struct WideVoiceOffline: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// An iPad-wide chat's composer: its send, with nothing typed, starts
/// voice the way the phone's primary action does (AgentInput.tsx's
/// `handleSendPress` calling `onMicPress`), and is a plain send while the
/// call runs.
@MainActor
final class HostedWideComposerVoiceTests: XCTestCase {
    private let record = SessionRecord(
        id: "wide-voice", seq: 0, createdAt: 1, updatedAt: 1, active: true, activeAt: 1, projectId: nil,
        metadataVersion: 1, metadataCipher: "c", metadata: .object(["flavor": .string("claude")]),
        agentStateVersion: 1, agentStateCipher: nil, agentState: nil, dataKeyCipher: nil, decryptable: true
    )

    private func sendButton(in view: UIView) -> DesktopSendButton? {
        (view as? DesktopSendButton) ?? view.subviews.lazy.compactMap(sendButton).first
    }

    private func until(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testTheEmptyWideSendStartsVoiceThroughThePrimaryPath() async throws {
        let store = try LocalStore.inMemory()
        try store.upsertSessions([record])
        let account = try AccountSession(
            credentials: Credentials(token: "t", secret: Data(repeating: 6, count: 32)),
            store: store,
            dependencies: .init(serverURL: URL(string: "https://api.example.test")!, clientID: "ios/test", transport: WideVoiceOffline())
        )

        let scene = try await hostedActiveScene()
        let hostWindow = scene.keyWindow
        let screen = UIViewController()
        let window = hostedKeyWindow(in: scene, root: screen)
        // iPad width on any simulator: wide is the window's width.
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        addTeardownBlock { @MainActor in
            VoiceCoordinator.shared.stop()
            screen.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            hostWindow?.makeKey()
        }

        let composer = SessionComposerView(
            environment: ChatComposerEnvironment(sessionId: record.id, account: account, sender: account.sender, controls: account.actions),
            restoreTimeout: .seconds(3600)
        )
        composer.update(ChatComposerState(session: ChatSessionState(record: record, settings: AccountSettings())))
        screen.view.addSubview(composer)
        composer.frame = CGRect(x: 0, y: 400, width: 1024, height: composer.composerHeight(fitting: 1024))
        composer.layoutIfNeeded()
        let restored = try await until { composer.isRestored }
        XCTAssertTrue(restored)

        let card = try XCTUnwrap(composer.subviews.compactMap { $0 as? AgentInputCardView }.first)
        XCTAssertNotNil(card.configuration.desktop, "the flat panel at 1024")
        let button = try XCTUnwrap(sendButton(in: card))
        XCTAssertFalse(button.voiceView.isHidden)
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.accessibilityLabel, Strings.Voice.title)
        XCTAssertEqual(VoiceCoordinator.shared.state(for: account), .idle)

        button.sendActions(for: .touchUpInside)

        // Started, its screen up over the chat, as from the phone's button.
        XCTAssertEqual(VoiceCoordinator.shared.state(for: account), .connecting)
        let presented = try await until {
            (screen.presentedViewController as? UINavigationController)?.viewControllers.first is VoiceStatusViewController
        }
        XCTAssertTrue(presented, "no voice screen: \(String(describing: screen.presentedViewController))")
        // While it runs SessionView passes no `onMicPress`: a plain send.
        XCTAssertEqual(card.configuration.desktop?.send.glyph, .arrow)
        XCTAssertTrue(button.voiceView.isHidden)
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.accessibilityLabel, Strings.Composer.send)

        // Offline, the call fails; the button is voice again.
        let ended = try await until {
            if case .failed = VoiceCoordinator.shared.state(for: account) { return true }
            return false
        }
        XCTAssertTrue(ended, "\(VoiceCoordinator.shared.state(for: account))")
        XCTAssertEqual(card.configuration.desktop?.send.glyph, .voice)
        XCTAssertFalse(button.voiceView.isHidden)
    }

    /// With text the same button sends; it never opens voice.
    func testWithTextTheWideSendDoesNotStartVoice() async throws {
        let store = try LocalStore.inMemory()
        try store.upsertSessions([record])
        let account = try AccountSession(
            credentials: Credentials(token: "t", secret: Data(repeating: 7, count: 32)),
            store: store,
            dependencies: .init(serverURL: URL(string: "https://api.example.test")!, clientID: "ios/test", transport: WideVoiceOffline())
        )
        let scene = try await hostedActiveScene()
        let hostWindow = scene.keyWindow
        let screen = UIViewController()
        let window = hostedKeyWindow(in: scene, root: screen)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        addTeardownBlock { @MainActor in
            VoiceCoordinator.shared.stop()
            screen.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            hostWindow?.makeKey()
        }
        let composer = SessionComposerView(
            environment: ChatComposerEnvironment(sessionId: record.id, account: account, sender: account.sender, controls: account.actions),
            restoreTimeout: .seconds(3600)
        )
        composer.update(ChatComposerState(session: ChatSessionState(record: record, settings: AccountSettings())))
        screen.view.addSubview(composer)
        composer.frame = CGRect(x: 0, y: 400, width: 1024, height: composer.composerHeight(fitting: 1024))
        composer.layoutIfNeeded()
        let restored = try await until { composer.isRestored }
        XCTAssertTrue(restored)

        let card = try XCTUnwrap(composer.subviews.compactMap { $0 as? AgentInputCardView }.first)
        card.text = "hello"
        composer.agentInputCardDidChangeText(card)
        let button = try XCTUnwrap(sendButton(in: card))
        XCTAssertTrue(button.voiceView.isHidden)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(VoiceCoordinator.shared.state(for: account), .idle)
        XCTAssertNil(screen.presentedViewController)
    }
}
#endif
