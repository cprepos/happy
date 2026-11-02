#if canImport(UIKit)
import HappyCore
import HappyStore
import HappyWire
import UIKit

/// Voice › Voice service: following the server's default, Happy Server when
/// the server offers it, and ElevenLabs always, since one's own agent needs no
/// help from the server. The chosen one ticked; a choice goes back.
final class VoiceServiceViewController: SettingsPageViewController {
    private let session: AccountSession
    private let config: VoiceConfig
    private var observation: StoreObservation?
    private var settings = AccountSettings()

    init(session: AccountSession, config: VoiceConfig) {
        self.session = session
        self.config = config
        super.init(title: Strings.Voice.service)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = session.store.observeSettings { [weak self] snapshot in
            self?.settings = AccountSettings(snapshot)
            self?.reload()
        }
    }

    override func makeRows() -> [[SettingsRow]] {
        typealias Text = Strings.Voice
        let saved = settings.voiceBackend
        let followed = config.selection(saved: nil, customAgentId: nil).backend
        var rows = [SettingsRow(id: "voice-service:default", title: Text.serverDefault, value: saved == nil ? "✓" : nil, accessory: .none, subtitle: followed.map(Text.name(of:)), action: { [weak self] in
            self?.choose(nil)
        })]
        for backend in VoiceBackend.allCases where backend == .elevenlabs || config.backends.contains(backend) {
            rows.append(SettingsRow(id: "voice-service:\(backend.rawValue)", title: Text.name(of: backend), value: saved == backend ? "✓" : nil, accessory: .none,
                                    subtitle: config.requiresCustomAgentId(backend) ? Text.needsOwnAgent : nil, action: { [weak self] in
                self?.choose(backend)
            }))
        }
        return [rows]
    }

    private func choose(_ backend: VoiceBackend?) {
        guard let backend, config.requiresCustomAgentId(backend) else {
            finish(["voiceBackend": backend.map { .string($0.rawValue) } ?? .null])
            return
        }
        // The call needs the user's own agent: the saved one, or one asked for
        // now. Without one nothing changes.
        if VoiceSettingsViewController.agentID(in: settings) != nil {
            finish(["voiceBackend": .string(backend.rawValue), "voiceBypassToken": .bool(true)])
            return
        }
        Task { [weak self] in
            guard let self, let id = await VoiceSettingsViewController.askForAgentID(current: nil, on: self), !id.isEmpty else { return }
            finish(["voiceBackend": .string(backend.rawValue), "voiceCustomAgentId": .string(id), "voiceBypassToken": .bool(true)])
        }
    }

    private func finish(_ delta: [String: JSONValue]) {
        session.updateSettings(delta)
        navigationController?.popViewController(animated: true)
    }
}

/// The voice picker. Voice › Voice on Happy Server (settings/voice/voices.tsx)
/// picks the account's default: the server's default voice, then every preset.
/// A chat's info screen (session/[id]/voice.tsx) picks that chat's own: Use
/// default, which takes its override away, then every preset. The chosen one
/// ticked; a choice goes back. A saved id this build doesn't know reads as no
/// choice.
final class VoicePresetViewController: SettingsPageViewController {
    enum Scope: Equatable {
        case account
        case chat(sessionId: String)
    }

    private let session: AccountSession
    private let scope: Scope
    private var observation: StoreObservation?
    /// nil until the store is first read.
    private var settings: AccountSettings?

    init(session: AccountSession, scope: Scope = .account) {
        self.session = session
        self.scope = scope
        super.init(title: scope == .account ? Strings.Voice.voices : Strings.Voice.voice)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = session.store.observeSettings { [weak self] snapshot in
            self?.settings = AccountSettings(snapshot)
            self?.reload()
        }
    }

    override func makeRows() -> [[SettingsRow]] {
        typealias Text = Strings.Voice
        let first: SettingsRow
        let selected: VoicePreset?
        let footer: String
        switch scope {
        case .account:
            selected = VoicePreset.find(settings?.voiceAssistantVoice)
            first = SettingsRow(id: "voice-preset:default", title: Text.serverDefault, icon: ("server-outline", .blue), value: selected == nil ? "✓" : nil, accessory: .none, subtitle: Text.serverDefaultSubtitle, action: { [weak self] in
                self?.choose(nil)
            })
            footer = Text.voicesFooter
        case .chat(let sessionId):
            // A choice writes every chat's overrides, so there is nothing to
            // choose from until they have been read.
            guard let settings else { return [] }
            selected = settings.chatVoice(sessionId: sessionId)
            let fallback = VoicePreset.find(settings.voiceAssistantVoice)?.label ?? Text.serverDefault
            first = SettingsRow(id: "voice-preset:default", title: Text.useDefault, icon: ("settings-outline", .blue), value: selected == nil ? "✓" : nil, accessory: .none, subtitle: Text.useDefaultSubtitle(name: fallback), action: { [weak self] in
                self?.choose(nil)
            })
            // Settings' cards have no heading, so the group's title leads its
            // footer, as Voice's usage card has it.
            footer = "\(Text.chatVoiceTitle). \(Text.chatVoiceFooter) \(Text.voicesFooter)"
        }
        let presets = VoicePreset.all.map { preset in
            SettingsRow(id: "voice-preset:\(preset.id)", title: preset.label, icon: ("person-circle-outline", .blue), value: selected == preset ? "✓" : nil, accessory: .none, subtitle: Text.description(of: preset), action: { [weak self] in
                self?.choose(preset)
            })
        }
        return [([first] + presets).withFooter(footer)]
    }

    private func choose(_ preset: VoicePreset?) {
        switch scope {
        case .account:
            session.updateSettings(["voiceAssistantVoice": preset.map { .string($0.id) } ?? .null])
        case .chat(let sessionId):
            guard let settings else { return }
            session.updateSettings(settings.chatVoiceDelta(sessionId: sessionId, presetId: preset?.id))
        }
        navigationController?.popViewController(animated: true)
    }
}
#endif
