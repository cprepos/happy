import Foundation

/// Where one media file is on its way to this phone, in plaintext bytes,
/// as Telegram's ring and size badge show it.
public enum DownloadPhase: Equatable, Sendable {
    /// Nothing of it is here; `total` when its size is known.
    case remote(total: Int?)
    /// Being read: `done` of `total` bytes.
    case downloading(done: Int, total: Int?)
    /// Stopped by a tap, or by policy: what is here stays for a resume.
    case paused(done: Int, total: Int?)
    /// The last read failed; a tap tries again from where it stopped.
    case failed(done: Int, total: Int?)
    /// All of it is on this phone.
    case complete(total: Int)

    public var isComplete: Bool { if case .complete = self { true } else { false } }
    public var isDownloading: Bool { if case .downloading = self { true } else { false } }

    /// The share read, for the ring; nil while the size isn't known.
    public var share: Double? {
        switch self {
        case .remote: 0
        case .downloading(let done, let total), .paused(let done, let total), .failed(let done, let total):
            total.flatMap { $0 > 0 ? min(1, Double(done) / Double($0)) : nil }
        case .complete: 1
        }
    }

    public var total: Int? {
        switch self {
        case .remote(let total), .downloading(_, let total), .paused(_, let total), .failed(_, let total): total
        case .complete(let total): total
        }
    }
}

/// Every media file's download, by `MediaLibrary.key`, after
/// `UploadProgressBoard`: downloads write from any thread, the screen
/// drains what changed at most once a frame, so each ring and badge is
/// touched once a frame with its latest value.
public final class DownloadBoard: @unchecked Sendable {
    public static let shared = DownloadBoard()

    private let lock = NSLock()
    private var phases: [String: DownloadPhase] = [:]
    private var changed: Set<String> = []
    private var signalled = false
    private var wakes: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    /// Called once after the first change since the last `drain`, on the
    /// writer's thread. Keep the token; dropping it stops the calls.
    public func observe(_ wake: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { wakes[id] = wake }
        return id
    }

    public func stopObserving(_ id: UUID) {
        _ = lock.withLock { wakes.removeValue(forKey: id) }
    }

    public func phase(_ key: String) -> DownloadPhase? {
        lock.withLock { phases[key] }
    }

    public func set(_ key: String, _ phase: DownloadPhase) {
        let wakes: [@Sendable () -> Void] = lock.withLock {
            guard phases[key] != phase else { return [] }
            phases[key] = phase
            changed.insert(key)
            guard !signalled else { return [] }
            signalled = true
            return Array(self.wakes.values)
        }
        for wake in wakes { wake() }
    }

    /// Forgets every key under `prefix` (an account's media was cleared).
    public func clear(prefix: String) {
        let wakes: [@Sendable () -> Void] = lock.withLock {
            for key in phases.keys where key.hasPrefix(prefix) {
                phases[key] = nil
                changed.insert(key)
            }
            guard !signalled, !changed.isEmpty else { return [] }
            signalled = true
            return Array(self.wakes.values)
        }
        for wake in wakes { wake() }
    }

    /// What changed since the last drain, each once with its latest phase
    /// (nil: forgotten), in key order.
    public func drain() -> [(key: String, phase: DownloadPhase?)] {
        lock.withLock {
            let out = changed.sorted().map { ($0, phases[$0]) }
            changed = []
            signalled = false
            return out
        }
    }
}
