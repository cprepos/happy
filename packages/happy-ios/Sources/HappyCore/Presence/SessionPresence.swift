import Foundation
import HappyStore

/// Heartbeats stay here. Only rendered changes reach the shared snapshot
/// hubs; SQLite receives one coarse checkpoint of all dirty presence.
public actor SessionPresence {
    public struct Options: Sendable {
        public var persistenceIntervalMs: Int64 = 60_000
        public var timerInterval: Duration = .seconds(15)
        /// How long a live CLI can go unheard while this phone is listening.
        /// Sessions beat every 2s and daemons every 20s; the server only gives
        /// up on either after 10 minutes, which is how long a computer that
        /// lost power would otherwise look alive (and thinking).
        public var silenceLimitMs: Int64 = 90_000
        public init() { }
    }

    private struct State {
        var active: Bool
        var thinking: Bool
        var latestAt: Int64
        var persistedAt: Int64
        var displayedAt: Int64
        var thinkingAt: Int64
        var lastSeen: ComposerStatus.LastSeen?
        /// Whether its beats reach this account, so that silence means
        /// anything. Happy Agent's chats and tasks shared by others don't.
        var heartbeats = true
        var overlay: PresenceOverlayValue {
            PresenceOverlayValue(active: active, thinking: thinking, latestAt: latestAt,
                                 displayedAt: displayedAt, thinkingAt: thinkingAt)
        }
    }
    private let store: LocalStore
    private let now: @Sendable () -> Int64
    private let options: Options
    private var sessions: [String: State] = [:]
    private var machines: [String: State] = [:]
    private var dirtySessions: Set<String> = []
    private var dirtyMachines: Set<String> = []
    private var lastFlush: Int64
    private var timer: Task<Void, Never>?
    private var seeded = false
    private var stopped = false
    /// Since when the socket has been up; silence only counts from here.
    private var listeningSince: Int64?
    private var lastTick: Int64?

    public init(store: LocalStore, options: Options = Options(), now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store
        self.options = options
        self.now = now
        lastFlush = now()
    }

    deinit { timer?.cancel() }

    public func start() async {
        guard !stopped, timer == nil else { return }
        await tick()
        let interval = options.timerInterval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { break }
                guard let self else { break }
                await self.tick()
            }
        }
    }

    /// The socket came or went. Heartbeats missed while it was down say
    /// nothing about the computer.
    public func setListening(_ listening: Bool) {
        guard listening else {
            listeningSince = nil
            return
        }
        if listeningSince == nil { listeningSince = now() }
    }

    public func activity(id: String, active: Bool, activeAt: Int64, thinking: Bool) async {
        guard !stopped else { return }
        let time = now()
        if sessions[id] == nil, let row = try? store.session(id: id) { seed(row) }
        guard var state = sessions[id], activeAt >= state.latestAt else { return }
        let criticalTimestamp = activeAt - state.persistedAt > options.persistenceIntervalMs
        let flip = state.active != active || state.thinking != (active && thinking)
        let token = active ? nil : ComposerStatus.lastSeen(activeAt: activeAt, now: time)
        let textChanged = token != state.lastSeen
        state.active = active
        state.thinking = active && thinking
        state.latestAt = activeAt
        if flip || textChanged {
            state.displayedAt = activeAt
            state.thinkingAt = activeAt
            state.lastSeen = token
        }
        sessions[id] = state
        dirtySessions.insert(id)
        store.setSessionPresenceOverlay(id: id, value: state.overlay)
        if flip || textChanged { store.setPresenceDisplayClock(time) }
        if flip || criticalTimestamp || time - lastFlush >= options.persistenceIntervalMs { checkpoint() }
        // A flip already changed SQLite and wakes its observation. Reusing
        // the hub's older raw row here could expose pre-checkpoint unread.
        if textChanged && !flip { await store.refreshPresenceDisplay() }
    }

    public func machineActivity(id: String, active: Bool, activeAt: Int64) async {
        guard !stopped else { return }
        let time = now()
        if machines[id] == nil, let row = try? store.machine(id: id) { seed(row) }
        guard var state = machines[id], activeAt >= state.latestAt else { return }
        let criticalTimestamp = activeAt - state.persistedAt > options.persistenceIntervalMs
        let flip = state.active != active
        state.active = active
        state.latestAt = activeAt
        if flip { state.displayedAt = activeAt }
        machines[id] = state
        dirtyMachines.insert(id)
        store.setMachinePresenceOverlay(id: id, value: state.overlay)
        if flip { store.setPresenceDisplayClock(time) }
        if flip || criticalTimestamp || time - lastFlush >= options.persistenceIntervalMs { checkpoint() }
    }

    /// Seed incoming list scalars before their transaction so an older cached
    /// overlay cannot hide a same-stamp offline update. Thinking is local and
    /// retained unless the incoming row is inactive, as LocalStore.upsert does.
    func prepareSessions(_ rows: [SessionRecord], previous: [String: SessionRecord]) {
        for row in rows {
            if sessions[row.id] == nil, let old = previous[row.id] { seed(old) }
            if var state = sessions[row.id] {
                guard row.updatedAt >= (previous[row.id]?.updatedAt ?? 0), row.activeAt >= state.latestAt else { continue }
                let changed = row.active != state.active
                state.active = row.active
                state.thinking = state.thinking && row.active
                state.latestAt = row.activeAt
                if changed || !row.active { state.displayedAt = row.activeAt }
                state.lastSeen = row.active ? nil : ComposerStatus.lastSeen(activeAt: row.activeAt, now: now())
                state.heartbeats = Self.heartbeats(row)
                sessions[row.id] = state
                store.setSessionPresenceOverlay(id: row.id, value: state.overlay)
            } else { seed(row) }
        }
    }

    func prepareMachines(_ rows: [MachineRecord]) {
        for row in rows {
            if var state = machines[row.id] {
                guard row.activeAt >= state.latestAt else { continue }
                if row.active != state.active { state.displayedAt = row.activeAt }
                state.active = row.active
                state.latestAt = row.activeAt
                machines[row.id] = state
                store.setMachinePresenceOverlay(id: row.id, value: state.overlay)
            } else { seed(row) }
        }
    }

    var trackedCounts: (sessions: Int, machines: Int) { (sessions.count, machines.count) }

    func removeSession(_ id: String) {
        sessions.removeValue(forKey: id)
        dirtySessions.remove(id)
        store.clearSessionPresenceOverlay(id: id)
    }

    func removeMachine(_ id: String) {
        machines.removeValue(forKey: id)
        dirtyMachines.remove(id)
        store.clearMachinePresenceOverlay(id: id)
    }

    /// Row, overlay and actor state leave together without yielding to tick.
    public func deleteSession(_ id: String) throws {
        try store.deleteSession(id: id)
        removeSession(id)
    }

    public func deleteMachine(_ id: String) throws {
        try store.deleteMachine(id: id)
        removeMachine(id)
    }

    /// Full listings preserve rows newer than their cutoff. Read the actual
    /// retained ids on this actor so those late arrivals keep their presence.
    func reconcileStoredRows() {
        do {
            let ids = try store.storedPresenceIDs()
            sessions = sessions.filter { ids.sessions.contains($0.key) }
            machines = machines.filter { ids.machines.contains($0.key) }
            dirtySessions.formIntersection(ids.sessions)
            dirtyMachines.formIntersection(ids.machines)
        } catch { print("HappyStore presence pruning failed: \(error)") }
    }

    /// Also called directly by deterministic tests after advancing the clock.
    public func tick() async {
        guard !stopped else { return }
        if !seeded {
            for row in (try? store.sessions()) ?? [] where sessions[row.id] == nil { seed(row) }
            for row in (try? store.machines()) ?? [] where machines[row.id] == nil { seed(row) }
            seeded = true
        }
        let time = now()
        // A gap this long means the process was suspended and the socket may
        // not know yet that it is dead: what it missed is not silence.
        if let lastTick, time - lastTick >= options.silenceLimitMs / 2, listeningSince != nil { listeningSince = time }
        lastTick = time
        var changed = false
        for id in Array(machines.keys) {
            guard var state = machines[id], isSilent(state, at: time) else { continue }
            state.active = false
            state.displayedAt = state.latestAt
            machines[id] = state
            dirtyMachines.insert(id)
            store.setMachinePresenceOverlay(id: id, value: state.overlay)
            changed = true
        }
        for id in Array(sessions.keys) {
            guard var state = sessions[id] else { continue }
            if isSilent(state, at: time) {
                // As `activity(active: false)` would have; its next beat undoes it.
                state.active = false
                state.thinking = false
                state.displayedAt = state.latestAt
                state.thinkingAt = state.latestAt
                dirtySessions.insert(id)
                changed = true
            }
            let token = state.active ? nil : ComposerStatus.lastSeen(activeAt: state.latestAt, now: time)
            if token != state.lastSeen {
                state.lastSeen = token
                state.displayedAt = state.latestAt
                changed = true
            }
            sessions[id] = state
            store.setSessionPresenceOverlay(id: id, value: state.overlay)
        }
        if changed { store.setPresenceDisplayClock(time) }
        if changed || time - lastFlush >= options.persistenceIntervalMs { checkpoint() }
        if changed { await store.refreshPresenceDisplay() }
    }

    public func flush() throws {
        let sessionWrites = Dictionary(uniqueKeysWithValues: dirtySessions.compactMap { id in sessions[id].map { (id, $0.overlay) } })
        let machineWrites = Dictionary(uniqueKeysWithValues: dirtyMachines.compactMap { id in machines[id].map { (id, $0.overlay) } })
        try store.persistPresence(sessions: sessionWrites, machines: machineWrites)
        for id in dirtySessions {
            if var state = sessions[id] { state.persistedAt = state.latestAt; sessions[id] = state }
        }
        for id in dirtyMachines {
            if var state = machines[id] { state.persistedAt = state.latestAt; machines[id] = state }
        }
        dirtySessions.removeAll()
        dirtyMachines.removeAll()
        lastFlush = now()
    }

    public func stop() throws {
        stopped = true
        timer?.cancel()
        timer = nil
        try flush()
    }

    private func isSilent(_ state: State, at time: Int64) -> Bool {
        guard let listeningSince, state.active, state.heartbeats else { return false }
        return time - max(listeningSince, state.latestAt) >= options.silenceLimitMs
    }

    private static func heartbeats(_ row: SessionRecord) -> Bool { !row.isRig && !row.isTask }

    private func checkpoint() {
        do { try flush() }
        catch { print("HappyStore presence checkpoint failed: \(error)") }
    }

    private func seed(_ row: SessionRecord) {
        let state = State(active: row.active, thinking: row.thinking, latestAt: row.activeAt, persistedAt: row.activeAt,
                          displayedAt: row.activeAt, thinkingAt: row.thinkingAt,
                          lastSeen: row.active ? nil : ComposerStatus.lastSeen(activeAt: row.activeAt, now: now()),
                          heartbeats: Self.heartbeats(row))
        sessions[row.id] = state
        store.setSessionPresenceOverlay(id: row.id, value: state.overlay)
    }

    private func seed(_ row: MachineRecord) {
        let state = State(active: row.active, thinking: false, latestAt: row.activeAt, persistedAt: row.activeAt,
                          displayedAt: row.activeAt, thinkingAt: 0, lastSeen: nil)
        machines[row.id] = state
        store.setMachinePresenceOverlay(id: row.id, value: state.overlay)
    }
}