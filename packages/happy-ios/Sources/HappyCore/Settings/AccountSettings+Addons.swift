import Foundation
import HappyWire

/// Our plugins' additions to the account's synced settings: the voice
/// settings and grouping by computer, kept out of AccountSettings.swift so
/// upstream merges do not conflict there. Enter to send is the device's
/// (`LocalSettings.enterToSend`), not the synced `agentInputEnterToSend`.
extension AccountSettings {
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
