#if canImport(UIKit)
import HappyCore
import HappyStore
import UIKit
#if canImport(OSLog)
import OSLog
#endif

/// The computer a chat's live browser is asked through.
@MainActor
enum LiveBrowserComputer {
    /// The computer whose screen the chat is (a Happy Agent chat). `happy`
    /// is the signed-in Happy account, whose sessions an agent's mirror is
    /// looked for in.
    case client(AgentClient, happy: AccountSession?)
    /// The paired computer a Happy session's machine is
    /// (`LegacyBrowserRoute`), among this app's.
    case machine(AccountSession, context: AppContext)
}

extension LiveBrowserDock {
    /// Decides the chat's computer, workspace and keys from `identity`
    /// alone, once for each chat and machine, then asks the bridge by
    /// those keys, the Happy session's first. Called again (its record
    /// read, its link changed), it decides nothing new. Nil stops asking.
    func route(_ identity: LiveBrowserChatIdentity?, through computer: LiveBrowserComputer) {
        guard let identity else {
            routing?.cancel()
            routing = nil
            routedFor = nil
            routedConnection = nil
            routedKeys = []
            lookUp(keys: [])
            return
        }
        let routeKey = Self.routeKey(identity)
        if routeKey == routedFor {
            if routing == nil { chatWatch?.reconsider() }
            return
        }
        routedFor = routeKey
        routing?.cancel()
        routing = Task { @MainActor [weak self] in
            let client = await Self.client(for: identity, through: computer, ask: self?.askComputer)
            guard let self, !Task.isCancelled, self.routedFor == routeKey else { return }
            // A chat whose computer isn't certain reads nothing: it says
            // unavailable rather than look through another computer.
            guard let client else {
                self.routedConnection = nil
                self.routedKeys = []
                self.routing = nil
                self.lookUp(keys: [])
                return
            }
            let workspace = identity.workspace
            self.routedConnection = LiveBrowserConnection(client: client) { try await workspace.find(client) }
            let keys = await Self.keys(for: identity, client: client, computer: computer, within: Self.keysTimeout)
            guard !Task.isCancelled, self.routedFor == routeKey else { return }
            self.routedKeys = keys
            self.routing = nil
            Self.log(identity, keys: keys)
            self.lookUp(keys: keys)
        }
    }

    /// How long finding an agent's mirrored Happy session may take before
    /// the chat is asked for by the keys it has without it. A call to the
    /// computer that never answered held the lookup back for good: no
    /// `/live/chat` was ever asked, and the chat showed no browser.
    static let keysTimeout: Duration = .seconds(6)

    /// `keys(for:client:computer:)`, or `identity.keys()` once `limit` passes.
    private static func keys(for identity: LiveBrowserChatIdentity, client: AgentClient, computer: LiveBrowserComputer, within limit: Duration) async -> [String] {
        let fallback = identity.keys()
        do {
            let keys = try await LiveBrowserFeed.within(limit) { @MainActor in await Self.keys(for: identity, client: client, computer: computer) }
            return keys.isEmpty ? fallback : keys
        } catch {
            if Task.isCancelled { return fallback }
            LiveBrowserLog.info("live browser: finding the chat's keys took over \(limit); asking by \(fallback.count) key(s)")
            return fallback
        }
    }

    private static func routeKey(_ identity: LiveBrowserChatIdentity) -> String {
        switch identity {
        case .cliSession(let record): "cli|\(record.id)|\(record.metadata?["machineId"]?.stringValue ?? "")"
        case .botSession(let record): "bot|\(record.id)|\(record.metadata?["machineId"]?.stringValue ?? "")"
        case .agent(let id, let happySession): "agent|\(id)|\(happySession ?? "")"
        }
    }

    /// The chat's computer: its own for an agent chat; for a Happy session,
    /// the paired computer its machine is, or the one the person picks.
    private static func client(for identity: LiveBrowserChatIdentity, through computer: LiveBrowserComputer, ask: ((_ choices: [LegacyLinkComputer], _ record: SessionRecord, _ picked: @escaping @MainActor (String?) -> Void) -> Void)?) async -> AgentClient? {
        switch computer {
        case .client(let client, _):
            return client
        case .machine(let account, let context):
            guard let record = identity.record else { return nil }
            let machineId = LegacyBrowserRoute.machineId(record)
            let store = account.store
            let (machine, machines) = await Task.detached(priority: .userInitiated) {
                (machineId.flatMap { try? store.machine(id: $0) }, (try? store.machines()) ?? [])
            }.value
            let route = LegacyBrowserRoute.resolve(
                session: record, machine: machine, machines: machines,
                computers: UIViewController.legacyLinkComputers(context.account), settings: account.localSettings
            )
            let id: String?
            switch route {
            case .computer(let computer, _): id = computer
            case .unavailable: id = nil
            case .ask(let choices, _):
                guard let ask else { return nil }
                id = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
                    ask(choices, record) { done.resume(returning: $0) }
                }
            }
            return id.flatMap { Session.session(for: $0, context: context)?.client }
        }
    }

    /// The keys for `identity`: an agent's mirrored Happy session's first
    /// when it can be told (by its bot, exactly), and a bot session's agent
    /// after its own.
    private static func keys(for identity: LiveBrowserChatIdentity, client: AgentClient, computer: LiveBrowserComputer) async -> [String] {
        switch identity {
        case .cliSession:
            return identity.keys()
        case .botSession:
            guard let bot = identity.botID else { return identity.keys() }
            let agent = try? await client.liveBrowserBot(bot).agentID
            return identity.keys(agent: agent)
        case .agent(let id, let happySession):
            if happySession != nil { return identity.keys() }
            guard case .client(_, let happy?) = computer,
                  let bot = (try? await client.liveBrowserBotID(agent: id)) ?? nil else { return identity.keys() }
            let store = happy.store
            let sessions = await Task.detached(priority: .userInitiated) { (try? store.sessions()) ?? [] }.value
            let mirror = LiveBrowserMirror.happySession(bot: bot, among: sessions)
            return LiveBrowserChatIdentity.agent(id: id, happySession: mirror).keys()
        }
    }

    private static func log(_ identity: LiveBrowserChatIdentity, keys: [String]) {
#if canImport(OSLog)
        let kind: String = switch identity {
        case .cliSession: "cli session"
        case .botSession: "bot session"
        case .agent(_, let happySession): happySession == nil ? "agent" : "agent with its Happy session"
        }
        Logger(subsystem: "org.girthbass.native", category: "live-browser")
            .info("live browser: \(kind, privacy: .public) asks by \(keys.count, privacy: .public) key(s)")
#endif
    }
}
#endif
