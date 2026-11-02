import Foundation
import HappyWire

/// A chat's Voice row on its info screen (info.tsx). There is no row when the
/// chat's voice wouldn't be heard: presets are the voice stream's, so as on
/// Settings' Voice page it shows only while Happy Server carries the call.
public struct ChatVoice: Equatable, Sendable {
    /// The chat's own voice; nil follows the account's default ("Use default").
    public let preset: VoicePreset?

    public init?(sessionId: String, settings: AccountSettings, config: VoiceConfig?) {
        guard settings.activeVoiceBackend(config: config) == .stream else { return nil }
        preset = settings.chatVoice(sessionId: sessionId)
    }
}

extension AccountSettings {
    /// The agent of one's own a call would use, as `VoiceContext` reads it.
    public var voiceCallAgentId: String? {
        guard bool("voiceBypassToken"), let id = string("voiceCustomAgentId"), !id.isEmpty else { return nil }
        return id
    }

    /// The service a call would use, or the saved one until the server has
    /// answered (`config` nil).
    public func activeVoiceBackend(config: VoiceConfig?) -> VoiceBackend? {
        guard let config else { return voiceBackend }
        return config.selection(saved: voiceBackend, customAgentId: voiceCallAgentId).backend
    }

    /// The chat's override. An id this build doesn't know reads as none, as it
    /// does when a call starts (`VoicePreset.resolve`).
    public func chatVoice(sessionId: String) -> VoicePreset? {
        VoicePreset.find(voiceBySession[sessionId])
    }

    /// The settings delta that gives a chat its voice, or takes its override
    /// away for nil. It carries the whole map, the other chats' overrides too.
    public func chatVoiceDelta(sessionId: String, presetId: String?) -> [String: JSONValue] {
        let next = VoicePreset.settingOverride(voiceBySession, sessionId: sessionId, presetId: presetId)
        return ["voiceBySession": .object(next.mapValues(JSONValue.string))]
    }
}
