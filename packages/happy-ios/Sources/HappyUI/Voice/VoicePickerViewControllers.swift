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

/// Voice › Voice on Happy Server (settings/voice/voices.tsx): the server's
/// default voice, then every preset. The chosen one ticked; a choice goes
/// back. A saved id this build doesn't know reads as the server's default.
final class VoicePresetViewController: SettingsPageViewController {
    private let session: AccountSession
    private var observation: StoreObservation?
    private var selected: VoicePreset?

    init(session: AccountSession) {
        self.session = session
        super.init(title: Strings.Voice.voices)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = session.store.observeSettings { [weak self] snapshot in
            self?.selected = VoicePreset.find(AccountSettings(snapshot).voiceAssistantVoice)
            self?.reload()
        }
    }

    override func makeRows() -> [[SettingsRow]] {
        typealias Text = Strings.Voice
        let serverDefault = SettingsRow(id: "voice-preset:default", title: Text.serverDefault, icon: ("server-outline", .blue), value: selected == nil ? "✓" : nil, accessory: .none, subtitle: Text.serverDefaultSubtitle, action: { [weak self] in
            self?.choose(nil)
        })
        let presets = VoicePreset.all.map { preset in
            SettingsRow(id: "voice-preset:\(preset.id)", title: preset.label, icon: ("person-circle-outline", .blue), value: selected == preset ? "✓" : nil, accessory: .none, subtitle: Text.description(of: preset), action: { [weak self] in
                self?.choose(preset)
            })
        }
        return [([serverDefault] + presets).withFooter(Text.voicesFooter)]
    }

    private func choose(_ preset: VoicePreset?) {
        session.updateSettings(["voiceAssistantVoice": preset.map { .string($0.id) } ?? .null])
        navigationController?.popViewController(animated: true)
    }
}
#endif
