import Foundation
import HappyWire

/// Our plugins' additions to the account's synced settings: Enter to
/// send, the voice settings, and grouping by computer, kept out of
/// AccountSettings.swift so upstream merges do not conflict there.
extension AccountSettings {
    /// A hardware keyboard's Return sends, and Shift, ⌘ or Control with it
    /// makes a new line (`agentInputEnterToSend`; the web's Enter to send).
    public var enterToSend: Bool { bool("agentInputEnterToSend") }

    /// nil follows the server's default, as does a backend this build doesn't know.
    public var voiceBackend: VoiceBackend? { string("voiceBackend").flatMap(VoiceBackend.init(rawValue:)) }
    /// The default voice preset's id; nil is the server's default voice.
    public var voiceAssistantVoice: String? { string("voiceAssistantVoice") }
    /// Per-chat voice preset ids, by session id.
    public var voiceBySession: [String: String] {
        (values["voiceBySession"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
    }
}

extension SessionListGrouping {
    /// What a tap on Appearance's row moves to (settings/appearance.tsx).
    public var next: SessionListGrouping {
        switch self {
        case .flat: .project
        case .project: .machine
        case .machine: .flat
        }
    }
}
