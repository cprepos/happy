import Foundation
#if canImport(Network)
import Network
#endif

// Ours, kept out of NetworkPath.swift so that file stays upstream's and
// merges do not conflict there.

/// Every change to the phone's way out, with its details: it coming or
/// going and a move to another interface (as `NetworkPath` tells them),
/// and also a change of interface, cost or Low Data Mode while it stays
/// up, which `NetworkPath` does not tell. Watchers hear on the main queue.
/// The same change may be told twice (once from each monitor); watchers
/// compare with what they last heard.
public final class NetworkPathChanges: @unchecked Sendable {
    public static let shared = NetworkPathChanges()

    #if canImport(Network)
    private let monitor = NWPathMonitor()
    #endif
    private let lock = NSLock()
    /// What this monitor last described; the system repeats an unchanged
    /// path at times, and that is not told.
    private var described: NetworkPathDetails?
    private var watchers: [UUID: @Sendable (NetworkPathDetails) -> Void] = [:]
    private var pathWatch: NetworkPathWatch?

    private init() {
        // Comes, goes, moves, and in tests `force` / `forceMove`.
        pathWatch = NetworkPath.shared.watch { [weak self] satisfied in
            var value = NetworkPath.shared.details
            value.satisfied = satisfied
            self?.tell(value)
        }
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(Self.describe(path))
        }
        monitor.start(queue: DispatchQueue(label: "engineering.happy.network-path-changes", qos: .utility))
        #endif
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

    /// From this monitor: told when it differs from what this monitor last
    /// described. Whether there is a way out is `NetworkPath`'s, so a path
    /// forced in tests stays forced.
    func update(_ value: NetworkPathDetails) {
        lock.lock()
        let changed = described != value
        described = value
        let watchers = Array(watchers.values)
        lock.unlock()
        guard changed else { return }
        var shown = value
        shown.satisfied = NetworkPath.shared.isSatisfied
        DispatchQueue.main.async { for watch in watchers { watch(shown) } }
    }

    /// Already on the main queue (`NetworkPath`'s watchers are).
    private func tell(_ value: NetworkPathDetails) {
        lock.lock()
        let watchers = Array(watchers.values)
        lock.unlock()
        for watch in watchers { watch(value) }
    }

    /// Calls `watch` on the main queue whenever the path changes: it coming
    /// or going, moving, or its interface, cost or Low Data Mode changing.
    /// Stops when the returned token is cancelled.
    public func watch(_ watch: @escaping @Sendable (NetworkPathDetails) -> Void) -> NetworkPathWatch {
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
}
