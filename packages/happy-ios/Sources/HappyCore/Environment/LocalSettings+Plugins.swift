import Foundation

/// This fork's own local settings, kept out of LocalSettings.swift so
/// upstream merges don't conflict there. `clear()` calls `clearPluginKeys()`.
extension LocalSettings {
    enum PluginKeys {
        static let voiceMessageCount = "voice-message-count"
        static let legacyLinkComputers = "relayLinkComputers"
    }

    /// The fork's keys that sign-out clears, alongside upstream's list.
    static let pluginKeys = [PluginKeys.voiceMessageCount, PluginKeys.legacyLinkComputers]

    func clearPluginKeys() {
        for key in Self.pluginKeys {
            storage.set(nil, forKey: key)
        }
    }

    /// The paired computer each Happy CLI machine's links open through, by
    /// relay machine id to agent connection id (`LegacyLinkRoute`). This
    /// app's own; happy-app has no such setting.
    public var legacyLinkComputers: [String: String] {
        get {
            guard let json = storage.string(forKey: PluginKeys.legacyLinkComputers),
                  let value = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else {
                return [:]
            }
            return value
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            storage.set(newValue.isEmpty ? nil : String(decoding: data, as: UTF8.self), forKey: PluginKeys.legacyLinkComputers)
        }
    }

    /// How many messages the user has sent with voice, across calls
    /// (persistence.ts `voice-message-count`). The voice prompt's onboarding
    /// phases go by it, so a new call can't start back at zero.
    public var voiceMessageCount: Int {
        get { storage.string(forKey: PluginKeys.voiceMessageCount).flatMap(Int.init) ?? 0 }
        set { storage.set(String(newValue), forKey: PluginKeys.voiceMessageCount) }
    }
}
