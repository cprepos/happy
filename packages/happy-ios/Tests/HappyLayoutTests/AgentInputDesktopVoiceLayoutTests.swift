import Foundation
import HappyLayout
import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The wide send button as the voice button: `icon-voice-white.png` 24
/// centred in the 32-point round button, which stays where send is.
final class AgentInputDesktopVoiceLayoutTests: XCTestCase {
    func testTheVoiceGlyphIsCentredInSend() {
        XCTAssertEqual(AgentInputDesktopLayout.Metrics.voiceIconSize, 24)
        assertFrame(AgentInputDesktopLayout.sendVoiceGlyph, rect(4, 4, 24, 24))
    }

    func testSendKeepsItsFrameOnAnEmptyPanel() {
        // An empty composer: the voice button is send's frame, at the row's end.
        let layout = AgentInputDesktopLayout(.init(
            width: 800, textContentHeight: 38, hasText: false, showsSettings: true, stopContentWidth: 16, imageContentWidth: 16
        ))
        assertFrame(layout.actionRow, rect(8, 48, 784, 40))
        assertFrame(layout.send, rect(760, 52, 32, 32))
    }
}
