#if canImport(UIKit)
import Foundation
import GRDB
@testable import HappyCore
import HappyLayout
import HappyStore
@testable import HappyUI
import UIKit
import XCTest

private struct VoiceOffline: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// The flat panel's send as the voice button: AgentInput.tsx draws
/// `icon-voice-white.png` on the filled button when the composer is empty
/// and `onMicPress` is set, and the arrow again once there is text.
@MainActor
final class AgentInputDesktopVoiceCardTests: XCTestCase {
    private func sendButton(in view: UIView) -> DesktopSendButton? {
        (view as? DesktopSendButton) ?? view.subviews.lazy.compactMap(sendButton).first
    }

    private func resolved(_ color: UIColor?, in view: UIView) -> UIColor? {
        color?.resolvedColor(with: view.traitCollection)
    }

    private func card(send: AgentInputDesktopSend) -> AgentInputCardView {
        let card = AgentInputCardView(configuration: AgentInputCardConfiguration(
            placeholder: "Type a message ...", showsAdd: true,
            desktop: AgentInputDesktopConfiguration(settings: AgentInputSettingsMenu(sections: []), showsStop: true, send: send)
        ))
        card.frame = CGRect(x: 0, y: 0, width: 800, height: card.height(fitting: 800))
        card.layoutIfNeeded()
        return card
    }

    func testTheVoiceButtonIsSendsFrameWithTheVoiceGlyph() throws {
        let card = card(send: AgentInputDesktopSend(hasText: false, hasComposerContent: false, isSendBlocked: false, canVoice: true))
        let layout = try XCTUnwrap(card.desktopLayout(width: 800))
        let button = try XCTUnwrap(sendButton(in: card))
        XCTAssertEqual(button.convert(button.bounds, to: card), layout.send)
        XCTAssertEqual(button.voiceView.frame, AgentInputDesktopLayout.sendVoiceGlyph)
        XCTAssertEqual(button.voiceView.frame, CGRect(x: 4, y: 4, width: 24, height: 24))
        XCTAssertFalse(button.voiceView.isHidden)
        XCTAssertNotNil(button.voiceView.image, "icon-voice-white is in HappyUI's bundle")
        XCTAssertEqual(button.voiceView.image?.renderingMode, .alwaysTemplate)
        XCTAssertEqual(resolved(button.voiceView.tintColor, in: button), resolved(UIColor(Palette.composerSendIcon), in: button))
        XCTAssertEqual(resolved(button.backgroundColor, in: button), resolved(UIColor(Palette.composerSendFill), in: button), "sendButtonActive")
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.accessibilityLabel, Strings.Voice.title)
    }

    func testTextTurnsItBackIntoSend() throws {
        let card = card(send: AgentInputDesktopSend(hasText: false, hasComposerContent: false, isSendBlocked: false, canVoice: true))
        var configuration = card.configuration
        configuration.desktop?.send = AgentInputDesktopSend(hasText: true, hasComposerContent: true, isSendBlocked: false, canVoice: true)
        card.configuration = configuration
        card.layoutIfNeeded()
        let button = try XCTUnwrap(sendButton(in: card))
        XCTAssertTrue(button.voiceView.isHidden)
        XCTAssertEqual(button.accessibilityLabel, Strings.Composer.send)
        XCTAssertEqual(button.convert(button.bounds, to: card), try XCTUnwrap(card.desktopLayout(width: 800)).send, "the same button")
    }

    func testWithoutVoiceTheEmptyButtonIsAPlainSend() throws {
        let card = card(send: AgentInputDesktopSend(hasText: false, hasComposerContent: false, isSendBlocked: false))
        let button = try XCTUnwrap(sendButton(in: card))
        XCTAssertTrue(button.voiceView.isHidden)
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(resolved(button.backgroundColor, in: button), resolved(UIColor(Palette.composerSendDisabled), in: button))
        XCTAssertEqual(button.accessibilityLabel, Strings.Composer.send)
    }

    // MARK: The chat's composer

    private let record = SessionRecord(
        id: "s", seq: 0, createdAt: 1, updatedAt: 1, active: true, activeAt: 1, projectId: nil,
        metadataVersion: 1, metadataCipher: "c", metadata: .object(["flavor": .string("claude")]),
        agentStateVersion: 1, agentStateCipher: nil, agentState: nil, dataKeyCipher: nil, decryptable: true
    )

    private func account() throws -> AccountSession {
        let store = try LocalStore(writer: DatabaseQueue())
        try store.upsertSessions([record])
        return try AccountSession(
            credentials: Credentials(token: "t", secret: Data(repeating: 1, count: 32)),
            store: store,
            dependencies: .init(serverURL: URL(string: "https://api.example.test")!, clientID: "ios/test", transport: VoiceOffline())
        )
    }

    private func composer(width: CGFloat) async throws -> (SessionComposerView, AgentInputCardView) {
        let account = try account()
        let composer = SessionComposerView(
            environment: ChatComposerEnvironment(sessionId: "s", account: account, sender: account.sender, controls: account.actions),
            restoreTimeout: .seconds(3600)
        )
        // Not in a window: its own width is the window's.
        composer.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        composer.update(ChatComposerState(session: ChatSessionState(record: record, settings: AccountSettings())))
        for _ in 0..<2000 where !composer.isRestored {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(composer.isRestored)
        let card = try XCTUnwrap(composer.subviews.compactMap { $0 as? AgentInputCardView }.first)
        return (composer, card)
    }

    /// An iPad-wide chat: the flat panel's send is voice while the
    /// composer is empty and send once there is text, as the phone's
    /// primary action is.
    func testTheWideComposerResolvesVoiceWhenEmptyAndSendWithText() async throws {
        let (composer, card) = try await composer(width: 1024)
        let empty = try XCTUnwrap(card.configuration.desktop?.send)
        XCTAssertEqual(empty.glyph, .voice)
        XCTAssertTrue(empty.startsVoice)
        XCTAssertEqual(empty.fill, .active)

        // As typing does: a programmatic `text` doesn't call the delegate.
        card.text = "hello"
        composer.agentInputCardDidChangeText(card)
        let text = try XCTUnwrap(card.configuration.desktop?.send)
        XCTAssertEqual(text.glyph, .arrow)
        XCTAssertFalse(text.startsVoice)
        XCTAssertTrue(text.isEnabled)

        card.text = "  "
        composer.agentInputCardDidChangeText(card)
        XCTAssertEqual(card.configuration.desktop?.send.glyph, .voice, "whitespace is not content")
    }

    /// The phone keeps its primary action and has no flat panel.
    func testThePhoneComposerKeepsTheVoicePrimaryAction() async throws {
        let (_, card) = try await composer(width: 393)
        XCTAssertNil(card.configuration.desktop)
        XCTAssertEqual(card.configuration.primaryAction, .voice)
        XCTAssertEqual(card.configuration.primaryAccessibilityLabel, Strings.Voice.title)
    }
}
#endif
