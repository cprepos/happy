import Foundation

/// This fork's own local settings, kept out of LocalSettings.swift so
/// upstream merges don't conflict there. `clear()` calls `clearAddonKeys()`.
extension LocalSettings {
    enum AddonKeys {
        static let voiceMessageCount = "voice-message-count"
        static let legacyLinkComputers = "relayLinkComputers"
        static let enterToSendOff = "hardwareKeyboardEnterToSendOff"
    }

    /// The fork's keys that sign-out clears, alongside upstream's list.
    static let addonKeys = [AddonKeys.voiceMessageCount, AddonKeys.legacyLinkComputers, AddonKeys.enterToSendOff]

    func clearAddonKeys() {
        for key in Self.addonKeys {
            storage.set(nil, forKey: key)
        }
    }

    /// The paired computer each Happy CLI machine's links open through, by
    /// relay machine id to agent connection id (`LegacyLinkRoute`). This
    /// app's own; happy-app has no such setting.
    public var legacyLinkComputers: [String: String] {
        get {
            guard let json = storage.string(forKey: AddonKeys.legacyLinkComputers),
                  let value = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else {
                return [:]
            }
            return value
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            storage.set(newValue.isEmpty ? nil : String(decoding: data, as: UTF8.self), forKey: AddonKeys.legacyLinkComputers)
        }
    }

    /// How many messages the user has sent with voice, across calls
    /// (persistence.ts `voice-message-count`). The voice prompt's onboarding
    /// phases go by it, so a new call can't start back at zero.
    public var voiceMessageCount: Int {
        get { storage.string(forKey: AddonKeys.voiceMessageCount).flatMap(Int.init) ?? 0 }
        set { storage.set(String(newValue), forKey: AddonKeys.voiceMessageCount) }
    }

    /// Posted, with these settings as its object, when `enterToSend` is set.
    public static let enterToSendDidChange = Notification.Name("LocalSettings.enterToSendDidChange")

    /// Settings › Appearance › Hardware Keyboard: Enter to Send: a hardware
    /// keyboard's Return sends, and Shift, ⌘ or Control with it makes a new
    /// line (the default), or Return is a newline and ⌘↩ sends. This
    /// device's own: the account's synced `agentInputEnterToSend`, which
    /// the web writes, no longer turns it off.
    public var enterToSend: Bool {
        get { storage.string(forKey: AddonKeys.enterToSendOff) != "true" }
        set {
            storage.set(newValue ? nil : "true", forKey: AddonKeys.enterToSendOff)
            NotificationCenter.default.post(name: Self.enterToSendDidChange, object: self)
        }
    }
}
