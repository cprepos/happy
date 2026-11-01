import Foundation

/// One account's kept media: its `MediaStore` and the `MediaDownloads`
/// that fill it, made once per account and shared by every screen. Keys on
/// `DownloadBoard` are `namespace|id`, so two accounts never share a ring.
public final class MediaLibrary: Sendable {
    public let namespace: String
    public let store: MediaStore
    public let downloads: MediaDownloads

    private nonisolated(unsafe) static var libraries: [String: MediaLibrary] = [:]
    private static let lock = NSLock()

    public init(namespace: String, directory: URL, board: DownloadBoard = .shared) {
        self.namespace = namespace
        store = MediaStore(directory: directory)
        let prefix = namespace + "|"
        downloads = MediaDownloads(store: store, board: board, key: { prefix + $0 })
    }

    /// The board key of one of its files.
    public func key(_ id: String) -> String { "\(namespace)|\(id)" }

    /// The library under `namespace`, made at `directory` the first time.
    public static func library(namespace: String, directory: URL) -> MediaLibrary {
        lock.withLock {
            if let library = libraries[namespace] { return library }
            let library = MediaLibrary(namespace: namespace, directory: directory)
            libraries[namespace] = library
            return library
        }
    }

    /// A paired computer's, beside the rest it keeps offline.
    public static func agent(_ accountID: String) -> MediaLibrary? {
        guard let directory = OfflineFile.directory(for: accountID) else { return nil }
        return library(namespace: "agent/\(accountID)", directory: directory.appendingPathComponent("media", isDirectory: true))
    }

    /// A legacy account's, in its account folder beside `files/`.
    public static func legacy(accountID: String, filesDirectory: URL) -> MediaLibrary {
        library(namespace: "legacy/\(accountID)", directory: legacyDirectory(filesDirectory: filesDirectory))
    }

    public static func legacyDirectory(filesDirectory: URL) -> URL {
        filesDirectory.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
    }

    /// Every library made so far.
    public static var all: [MediaLibrary] { lock.withLock { Array(libraries.values) } }

    /// Stops an account's downloads as it goes; its folder goes with the account's.
    public static func forget(namespace: String) {
        let library = lock.withLock { libraries.removeValue(forKey: namespace) }
        guard let library else { return }
        Task { await library.downloads.stop() }
        DownloadBoard.shared.clear(prefix: namespace + "|")
    }

    /// Settings' Clear Media: every file of this account's, and every ring
    /// back to where nothing is here.
    public func clear() async {
        await downloads.removeAll()
        DownloadBoard.shared.clear(prefix: namespace + "|")
    }

    /// The bytes kept, read off the main thread.
    public func usage() -> Int64 { store.usage() }
}
