#if canImport(UIKit)
import Foundation

/// Voice in a Happy account's sessions: the relay's ElevenLabs
/// conversation (`VoiceCoordinator`), with its grant, the session's
/// context and the relay's voice subscription. When off: no
/// microphone button, and nothing asks for the microphone, a grant, the
/// session's context or a subscription. Upstream ships it off; this fork
/// keeps it on, for the self-hosted voice stack. An agent connection's call
/// (`CallController`) is apart and stays on. Debug runs can turn it off
/// (`HAPPY_RELAY_VOICE=0`).
@MainActor
enum LegacyVoice {
    /// Tests turn it on and off.
    static var isEnabled: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HAPPY_RELAY_VOICE"] != "0"
        #else
        return true
        #endif
    }()
}
#endif
