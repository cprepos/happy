#if canImport(UIKit)
import HappyCore
import HappyLayout
import HappyStore
import HappyWire
import UIKit

/// Settings › Voice Assistant (app/(app)/settings/voice.tsx) in settings'
/// cards: which service carries a call, then the language the assistant
/// answers in. The rest follows the service: ElevenLabs has the last 30 days'
/// voice time and Upgrade Voice when the server offers it, and an agent of
/// one's own; Happy Server has its default voice. Every value is the Happy
/// account's synced setting, which `VoiceContext` reads when the microphone is
/// pressed; an agent connection has no voice, so the page is a Happy
/// account's alone.
final class VoiceSettingsViewController: SettingsPageViewController {
    private let context: AppContext
    private let session: AccountSession
    private var observation: StoreObservation?
    private var settings = AccountSettings()
    /// What the server offers; nil until it first answers.
    private var config: VoiceConfig?
    private var configTask: Task<Void, Never>?
    private var usage: VoiceUsage?
    private var loading = false
    private var usageTask: Task<Void, Never>?
    /// Tests stand in for the server.
    var loadsUsage = true
    var fetchConfig: @Sendable () async throws -> VoiceConfig

    init(context: AppContext, session: AccountSession) {
        self.context = context
        self.session = session
        let api = session.api
        fetchConfig = { try await api.voiceConfig() }
        super.init(title: Strings.Voice.title)
    }

    deinit {
        configTask?.cancel()
        usageTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = session.store.observeSettings { [weak self] snapshot in
            let settings = AccountSettings(snapshot)
            guard let self, settings != self.settings else { return }
            self.settings = settings
            followService()
        }
        loadConfig()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The language may have changed on the page pushed from here.
        reload()
    }

    /// Asks until the server answers, showing no error meanwhile: the page
    /// stands on the saved choice until then.
    private func loadConfig() {
        let fetch = fetchConfig
        configTask = Task { [weak self] in
            var wait = 1
            while !Task.isCancelled {
                if let config = try? await fetch() {
                    self?.config = config
                    self?.followService()
                    return
                }
                try? await Task.sleep(for: .seconds(wait))
                wait = min(wait * 2, 30)
            }
        }
    }

    /// The service the page's rows follow.
    private var shownBackend: VoiceBackend? {
        settings.activeVoiceBackend(config: config)
    }

    /// ElevenLabs with the server's allowance. On a server that doesn't offer
    /// it the call is the user's own agent, and the server's numbers aren't
    /// about it.
    private var showsAllowance: Bool {
        shownBackend == .elevenlabs && config?.backends.contains(.elevenlabs) == true
    }

    private func followService() {
        if showsAllowance, loadsUsage, usage == nil, !loading {
            loadUsage()
        } else {
            reload()
        }
    }

    private func loadUsage() {
        usageTask?.cancel()
        loading = true
        reload()
        let api = session.api
        usageTask = Task { [weak self] in
            let usage = try? await api.voiceUsage()
            guard !Task.isCancelled, let self else { return }
            self.usage = usage
            loading = false
            reload()
        }
    }

    override func makeRows() -> [[SettingsRow]] {
        typealias Row = SettingsRow
        typealias Text = Strings.Voice
        let language = VoiceLanguage.selection(settings.string("voiceAssistantLanguage"))
        let languageRow = [Row(id: "voice-language", title: Text.preferredLanguage, icon: ("language-outline", .blue), value: language.name, action: { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(VoiceLanguageViewController(session: session), animated: true)
        }, footer: Text.languageDescription)]
        var cards = [[serviceRow()]]
        if showsAllowance { cards += allowanceRows() }
        cards.append(languageRow)
        switch shownBackend {
        case .elevenlabs: cards.append(agentRows())
        case .stream: cards.append([voiceRow()])
        case nil: break
        }
        return cards
    }

    private func serviceRow() -> SettingsRow {
        typealias Text = Strings.Voice
        guard let config else {
            return SettingsRow(id: "voice-service", title: Text.service, icon: ("server-outline", .blue), value: Text.connecting, accessory: .none, dimmed: true)
        }
        let selection = config.selection(saved: settings.voiceBackend, customAgentId: settings.voiceCallAgentId)
        let footer: String?
        if let backend = selection.backend {
            footer = selection.savedUnavailable ? settings.voiceBackend.map { Text.savedNotOffered(saved: $0, current: backend) } : nil
        } else {
            footer = Text.noService
        }
        return SettingsRow(id: "voice-service", title: Text.service, icon: ("server-outline", .blue), value: selection.backend.map(Text.name(of:)), action: { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(VoiceServiceViewController(session: session, config: config), animated: true)
        }, footer: footer)
    }

    private func allowanceRows() -> [[SettingsRow]] {
        typealias Row = SettingsRow
        typealias Text = Strings.Voice
        let usageRows: [Row]
        if let usage {
            usageRows = [
                Row(id: "voice-time", title: Text.usage, icon: ("time-outline", .orange), value: "\(Self.time(usage.usedSeconds)) / \(Self.time(usage.limitSeconds))", accessory: .none),
                Row(id: "voice-conversations", title: Text.conversations, icon: ("chatbubbles-outline", .orange), value: "\(usage.conversationCount) / \(usage.conversationLimit)", accessory: .none),
            ]
        } else {
            // Tapped, it asks again.
            usageRows = [Row(id: "voice-usage-retry", title: loading ? Text.connecting : Text.unavailable, icon: ("time-outline", .orange), value: loading ? nil : Text.retry, accessory: .none, action: loading ? nil : { [weak self] in self?.loadUsage() }, dimmed: loading)]
        }
        return [
            usageRows.withFooter("\(Text.usageTitle). \(Text.usageFooter)"),
            [Row(id: "voice-upgrade", title: Text.upgrade, icon: ("heart-outline", .red), action: { [weak self] in
                self?.navigationController?.pushViewController(SupportUsViewController(), animated: true)
            }, footer: Text.upgradeSubtitle)],
        ]
    }

    /// An agent of one's own. Where the server doesn't offer ElevenLabs it is
    /// the only way there, so there is no connection to choose.
    private func agentRows() -> [SettingsRow] {
        typealias Row = SettingsRow
        typealias Text = Strings.Voice
        var rows = [Row(id: "voice-agent-id", title: Text.agentID, icon: ("key-outline", .orange), value: settings.string("voiceCustomAgentId") ?? Text.notConfigured, accessory: .none, action: { [weak self] in self?.editAgent() })]
        guard config?.requiresCustomAgentId(.elevenlabs) != true else {
            return rows.withFooter("\(Text.byo): \(Text.byoDescription)")
        }
        rows.append(Row(id: "voice-direct", title: Text.direct, icon: ("flash-outline", .red), accessory: .toggle, isOn: settings.bool("voiceBypassToken"), toggled: { [weak self] on in
            self?.set(["voiceBypassToken": .bool(on)])
        }))
        return rows.withFooter("\(Text.directSubtitle).\n\n\(Text.byo): \(Text.byoDescription)")
    }

    private func voiceRow() -> SettingsRow {
        typealias Text = Strings.Voice
        return SettingsRow(id: "voice-preset", title: Text.voice, icon: ("mic-outline", .blue), value: VoicePreset.find(settings.voiceAssistantVoice)?.label ?? Text.serverDefault, action: { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(VoicePresetViewController(session: session), animated: true)
        }, footer: Text.voiceSubtitle)
    }

    /// Shown at once; the store echoes the same value back.
    private func set(_ delta: [String: JSONValue]) {
        settings = settings.applying(delta)
        session.updateSettings(delta)
        followService()
    }

    /// An ID turns the direct connection on, none turns it off, as voice.tsx.
    private func editAgent() {
        Task { [weak self] in
            guard let self, let id = await Self.askForAgentID(current: settings.string("voiceCustomAgentId"), on: self) else { return }
            set(["voiceCustomAgentId": id.isEmpty ? .null : .string(id), "voiceBypassToken": .bool(!id.isEmpty)])
        }
    }

    /// The trimmed ID, empty for none; nil when the prompt was cancelled.
    static func askForAgentID(current: String?, on controller: UIViewController) async -> String? {
        let value = await Alerts.prompt(Strings.Voice.agentID, Strings.Voice.agentDescription,
                                        placeholder: current ?? "agent_…", confirmTitle: Strings.Common.save, on: controller)
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The saved agent ID, an empty one being none, as `VoiceContext` reads it.
    static func agentID(in settings: AccountSettings) -> String? {
        settings.string("voiceCustomAgentId").flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func time(_ seconds: Int) -> String { "\(max(0, seconds) / 60)m \(max(0, seconds) % 60)s" }
}

/// Voice › Preferred Language: every language the assistant speaks, the
/// chosen one ticked, narrowed by the bar's search; a choice goes back.
final class VoiceLanguageViewController: SettingsPageViewController, UISearchResultsUpdating {
    private let session: AccountSession
    private var observation: StoreObservation?
    private var preferred: String?
    private var query = ""
    private let search = UISearchController(searchResultsController: nil)

    init(session: AccountSession) {
        self.session = session
        super.init(title: Strings.Voice.languageTitle)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = Strings.Voice.search
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        observation = session.store.observeSettings { [weak self] snapshot in
            self?.preferred = AccountSettings(snapshot).string("voiceAssistantLanguage")
            self?.reload()
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        reload()
    }

    override func makeRows() -> [[SettingsRow]] {
        let languages = VoiceLanguage.all.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.code?.localizedCaseInsensitiveContains(query) ?? false) }
        return [languages.map { language in
            SettingsRow(id: "voice-language:\(language.code ?? "auto")", title: language.name, value: language.code == preferred ? "✓" : language.code, accessory: .none, action: { [weak self] in
                self?.choose(language)
            })
        }]
    }

    private func choose(_ language: VoiceLanguage) {
        preferred = language.code
        session.updateSettings(["voiceAssistantLanguage": language.code.map(JSONValue.string) ?? .null])
        search.isActive = false
        navigationController?.popViewController(animated: true)
    }
}
#endif
