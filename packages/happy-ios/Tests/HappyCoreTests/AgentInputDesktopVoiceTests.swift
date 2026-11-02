import HappyCore
import XCTest

/// AgentInput.tsx's wide send button with `onMicPress`: with nothing to
/// send it is the voice button, filled, and pressing it starts voice
/// (`handleSendPress`).
final class AgentInputDesktopVoiceTests: XCTestCase {
    private func send(text: Bool = false, pictures: Bool = false, blocked: Bool = false, disabled: Bool = false, voice: Bool) -> AgentInputDesktopSend {
        AgentInputDesktopSend(
            hasText: text, hasComposerContent: text || pictures, isSendBlocked: blocked, isSendDisabled: disabled, canVoice: voice
        )
    }

    func testAnEmptyComposerIsTheVoiceButton() {
        let voice = send(voice: true)
        XCTAssertEqual(voice.glyph, .voice)
        XCTAssertEqual(voice.fill, .active, "sendButtonActive, as `onMicPress && !isMicActive` makes it")
        XCTAssertTrue(voice.isEnabled)
        XCTAssertTrue(voice.startsVoice)
    }

    func testTextMakesItSendAgain() {
        let text = send(text: true, voice: true)
        XCTAssertEqual(text.glyph, .arrow)
        XCTAssertEqual(text.fill, .active)
        XCTAssertTrue(text.isEnabled)
        XCTAssertFalse(text.startsVoice)
    }

    func testPicturesAloneSendOnTheFilledButton() {
        let pictures = send(pictures: true, voice: true)
        XCTAssertEqual(pictures.glyph, .arrow, "a press sends them, so it shows the arrow")
        XCTAssertEqual(pictures.fill, .active)
        XCTAssertTrue(pictures.isEnabled)
        XCTAssertFalse(pictures.startsVoice)
    }

    /// SessionView passes no `onMicPress` while a call connects or runs:
    /// the plain, unpressable send of an empty composer.
    func testWhileACallRunsItIsAPlainSend() {
        XCTAssertEqual(send(voice: false), AgentInputDesktopSend(hasText: false, hasComposerContent: false, isSendBlocked: false))
        XCTAssertEqual(send(voice: false).glyph, .arrow)
        XCTAssertEqual(send(voice: false).fill, .inactive)
        XCTAssertFalse(send(voice: false).isEnabled)
        XCTAssertFalse(send(voice: false).startsVoice)
    }

    func testABlockedSendNeverStartsVoice() {
        let blocked = send(blocked: true, voice: true)
        XCTAssertEqual(blocked.glyph, .lock)
        XCTAssertEqual(blocked.fill, .locked)
        XCTAssertFalse(blocked.isEnabled, "`isSendBlocked ? hasComposerContent`")
        XCTAssertFalse(blocked.startsVoice)
    }

    func testADisabledSendNeverStartsVoice() {
        XCTAssertFalse(send(disabled: true, voice: true).isEnabled)
        XCTAssertFalse(send(disabled: true, voice: true).startsVoice)
        let sending = AgentInputDesktopSend(hasText: false, hasComposerContent: false, isSendBlocked: false, isSending: true, canVoice: true)
        XCTAssertEqual(sending.glyph, .spinner)
        XCTAssertFalse(sending.startsVoice)
    }
}
