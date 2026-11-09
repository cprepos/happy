import Foundation
#if canImport(Network)
import Network
#endif

/// Whether this phone has a way out at all, as the system says
/// (`NWPathMonitor`): with none, headers say "Waiting for network…" rather
/// than "Connecting…", as Telegram's do. One monitor for the app; watchers
/// hear on the main queue, whenever the way out changes: it coming or
/// going, and also a move between Wi-Fi and cellular, which leaves the old
/// socket dead while the phone still has a way out.
public final class NetworkPath: @unchecked Sendable {
    public static let shared = NetworkPath()

    #if canImport(Network)
    private let monitor = NWPathMonitor()
    #endif
    private let lock = NSLock()
    private var satisfied = true
    private var latest = NetworkPathDetails(satisfied: true)
    private var watchers: [UUID: @Sendable (NetworkPathDetails) -> Void] = [:]
    #if DEBUG
    /// Tests: what the path is said to be, whatever it is.
    private var forced: Bool?
    #endif

    private init() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(NetworkPath.describe(path))
        }
        monitor.start(queue: DispatchQueue(label: "engineering.happy.network-path", qos: .utility))
        #endif
    }

    /// Whether there is a way out; true until the system says otherwise.
    public var isSatisfied: Bool {
        lock.lock(); defer { lock.unlock() }
        #if DEBUG
        if let forced { return forced }
        #endif
        return satisfied
    }

    /// The way out as the system last described it: the interface, and
    /// whether it is expensive (cellular, a hotspot) or constrained (Low
    /// Data Mode).
    public var details: NetworkPathDetails {
        lock.lock(); defer { lock.unlock() }
        return shownLocked()
    }

    #if canImport(Network)
    private static func describe(_ path: NWPath) -> NetworkPathDetails {
        let interface: NetworkPathDetails.Interface = if path.status != .satisfied { .none }
            else if path.usesInterfaceType(.wifi) { .wifi }
            else if path.usesInterfaceType(.cellular) { .cellular }
            else if path.usesInterfaceType(.wiredEthernet) { .wired }
            else if path.usesInterfaceType(.loopback) { .loopback }
            else { .other }
        return NetworkPathDetails(satisfied: path.status == .satisfied, interface: interface, expensive: path.isExpensive, constrained: path.isConstrained)
    }
    #endif

    /// Any change to the path is told: its coming or going, and a change
    /// of interface, cost or Low Data Mode while it stays up. The system
    /// repeats an unchanged path at times; that is not told.
    func update(_ value: NetworkPathDetails) {
        lock.lock()
        let changed = latest != value
        latest = value
        satisfied = value.satisfied
        let shown = shownLocked()
        let watchers = Array(watchers.values)
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { for watch in watchers { watch(shown) } }
    }

    /// The details as watchers are told them; the lock is held.
    private func shownLocked() -> NetworkPathDetails {
        var value = latest
        #if DEBUG
        if let forced { value.satisfied = forced }
        #endif
        return value
    }

    /// Calls `watch` on the main queue whenever the path changes, with
    /// whether there is a way out; stops when the returned token is
    /// cancelled. A change of interface is told too, with `true` again.
    public func watch(_ watch: @escaping @Sendable (Bool) -> Void) -> NetworkPathWatch {
        watchDetails { watch($0.satisfied) }
    }

    /// Calls `watch` on the main queue whenever the path changes: it coming
    /// or going, or its interface, cost or Low Data Mode changing.
    public func watchDetails(_ watch: @escaping @Sendable (NetworkPathDetails) -> Void) -> NetworkPathWatch {
        let id = UUID()
        lock.lock()
        watchers[id] = watch
        lock.unlock()
        return NetworkPathWatch { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.watchers[id] = nil
            self.lock.unlock()
        }
    }

    #if DEBUG
    /// Tests: the path as given (nil: as the system says), told to watchers.
    public func force(_ value: Bool?) {
        lock.lock()
        forced = value
        let shown = shownLocked()
        let watchers = Array(watchers.values)
        lock.unlock()
        DispatchQueue.main.async { for watch in watchers { watch(shown) } }
    }
    #endif
}

public struct NetworkPathDetails: Equatable, Sendable {
    public enum Interface: String, Sendable {
        case wifi = "Wi-Fi", cellular = "Cellular", wired = "Ethernet", loopback = "Loopback", other = "Other", none = "None"
    }
    public var satisfied: Bool
    public var interface: Interface = .other
    public var expensive = false
    public var constrained = false

    public init(satisfied: Bool, interface: Interface = .other, expensive: Bool = false, constrained: Bool = false) {
        self.satisfied = satisfied; self.interface = interface; self.expensive = expensive; self.constrained = constrained
    }

    /// "Wi-Fi", "Cellular · expensive · Low Data Mode", "No network".
    public var text: String {
        guard satisfied else { return "No network" }
        var parts = [interface.rawValue]
        if expensive { parts.append("expensive") }
        if constrained { parts.append("Low Data Mode") }
        return parts.joined(separator: " · ")
    }
}

public final class NetworkPathWatch: @unchecked Sendable {
    private var cancel: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    public func invalidate() { cancel?(); cancel = nil }
    deinit { cancel?() }
}
