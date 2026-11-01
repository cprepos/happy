import Foundation
import HappyCrypto

/// One account's media on this phone, kept for good: after Telegram's
/// resource store, a complete file under its name and a partial one
/// (`PartialFile`) beside it while it is read. A file's name is a hash of
/// its ID: the content's own, as the account's server names it (a legacy
/// attachment's ref, a tool call's media, an artifact version's file), so
/// it is read once and never again. Nothing is evicted on its own; only
/// `removeAll` (Settings' Clear Media) or removing the account empties it.
///
/// In Application Support, out of iCloud backup: it can always be read
/// again from where it came from.
public final class MediaStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var partials: [String: PartialFile] = [:]
    private var prepared = false

    public init(directory: URL) {
        self.directory = directory
    }

    /// The file name an ID is kept under.
    public static func name(_ id: String) -> String {
        Hashing.sha256(Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Where the complete file is, or goes.
    public func completeURL(_ id: String) -> URL {
        directory.appendingPathComponent(Self.name(id))
    }

    public func isComplete(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: completeURL(id).path)
    }

    /// The complete file's length.
    public func completeLength(_ id: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: completeURL(id).path)[.size] as? NSNumber)?.intValue
    }

    /// The file being read, opened once.
    public func partial(_ id: String) -> PartialFile {
        try? prepare()
        return lock.withLock {
            if let open = partials[id] { return open }
            let base = directory.appendingPathComponent(Self.name(id))
            let file = PartialFile(dataURL: base.appendingPathExtension("part"), metaURL: base.appendingPathExtension("part.meta"))
            partials[id] = file
            return file
        }
    }

    /// Whether anything of it is here yet, without creating a record.
    public func hasPartial(_ id: String) -> Bool {
        if lock.withLock({ partials[id] != nil }) { return true }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.name(id)).appendingPathExtension("part.meta").path)
    }

    /// The partial file is whole: it becomes the complete one. A sealed
    /// one is opened first, and kept only when its MAC checks; otherwise
    /// it is thrown away and `MediaError.notAuthentic` thrown.
    public func finish(_ id: String, seal: MediaSeal?) throws {
        let partial = partial(id)
        guard partial.isComplete, let total = partial.total else { throw MediaError.invalidResponse }
        try prepare()
        let target = completeURL(id)
        partial.close()
        if let seal {
            guard let sealed = partial.read(0..<total), let plain = seal.open(sealed) else {
                partial.remove()
                forget(id)
                throw MediaError.notAuthentic
            }
            try plain.write(to: target, options: .atomic)
            partial.remove()
        } else {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial.dataURL, to: target)
            try? FileManager.default.removeItem(at: partial.metaURL)
        }
        forget(id)
    }

    /// Keeps a file this phone already has, such as one the person sent:
    /// it is never read from the server.
    public func keep(_ id: String, file: URL) throws {
        try prepare()
        let target = completeURL(id)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let staging = directory.appendingPathComponent(UUID().uuidString + ".in")
        try FileManager.default.copyItem(at: file, to: staging)
        try moveIn(staging, to: target)
    }

    public func keep(_ id: String, data: Data) throws {
        try prepare()
        let target = completeURL(id)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try data.write(to: target, options: .atomic)
    }

    /// Plaintext bytes of `range`: from the complete file, else from what
    /// the partial one holds (decrypted on the way where it is sealed);
    /// nil while any of them is missing.
    public func read(_ id: String, _ range: Range<Int>, seal: MediaSeal?) -> Data? {
        let complete = completeURL(id)
        if let handle = try? FileHandle(forReadingFrom: complete) {
            defer { try? handle.close() }
            guard !range.isEmpty else { return Data() }
            try? handle.seek(toOffset: UInt64(range.lowerBound))
            guard let data = try? handle.read(upToCount: range.count), data.count == range.count else { return nil }
            return data
        }
        let partial = partial(id)
        guard let seal else { return partial.read(range) }
        let stored = seal.storedRanges(range)
        guard let nonce = partial.read(stored[0]), let sealed = partial.read(stored[1]) else { return nil }
        return seal.decrypt(sealed, nonce: nonce, plainOffset: range.lowerBound)
    }

    /// The bytes kept, partial files and all.
    public func usage() -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        return names.reduce(Int64(0)) { sum, url in
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return sum + Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
    }

    /// Forgets every file (Clear Media). What is being read starts over.
    public func removeAll() {
        lock.withLock {
            for file in partials.values { file.close() }
            partials.removeAll()
            prepared = false
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func forget(_ id: String) {
        lock.withLock { _ = partials.removeValue(forKey: id) }
    }

    private func moveIn(_ staging: URL, to target: URL) throws {
        do {
            try FileManager.default.moveItem(at: staging, to: target)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            // Another writer kept the same content first.
            if !FileManager.default.fileExists(atPath: target.path) { throw error }
        }
    }

    /// Makes the folder, out of backups.
    private func prepare() throws {
        if lock.withLock({ prepared }) { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
        #endif
        lock.withLock { prepared = true }
    }
}
