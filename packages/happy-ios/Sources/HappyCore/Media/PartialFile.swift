import Foundation

/// A file read a range at a time, after Telegram's `MediaBoxPartialFile`:
/// the bytes so far at their own offsets in `<name>.part` (holes where
/// nothing came yet), and beside it `<name>.part.meta`, which ranges
/// those are and the file's whole length once an answer said it. Both
/// outlive the app, so a download picks up where it stopped after a
/// relaunch. Thread-safe; every call reads or writes the disk, so none
/// is made on the main thread.
public final class PartialFile: @unchecked Sendable {
    public let dataURL: URL
    public let metaURL: URL
    private let lock = NSLock()
    private var ranges = IndexSet()
    private var length: Int?
    private var handle: FileHandle?

    struct Meta: Codable, Equatable {
        static let format = 1
        var format = Self.format
        var total: Int?
        var ranges: [[Int]]
    }

    /// Opens what an earlier run kept; a missing or unreadable record
    /// starts empty, and the data it described goes with it.
    public init(dataURL: URL, metaURL: URL) {
        self.dataURL = dataURL
        self.metaURL = metaURL
        let manager = FileManager.default
        guard let data = try? Data(contentsOf: metaURL) else {
            try? manager.removeItem(at: dataURL)
            return
        }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: data), meta.format == Meta.format,
              let size = (try? manager.attributesOfItem(atPath: dataURL.path)[.size] as? NSNumber)?.intValue else {
            try? manager.removeItem(at: dataURL)
            try? manager.removeItem(at: metaURL)
            return
        }
        length = meta.total
        for pair in meta.ranges where pair.count == 2 && pair[0] >= 0 && pair[0] < pair[1] && pair[1] <= size {
            ranges.insert(integersIn: pair[0]..<pair[1])
        }
    }

    deinit { try? handle?.close() }

    /// The whole file's length, once known.
    public var total: Int? { lock.withLock { length } }

    /// How many of its bytes are here.
    public var downloaded: Int { lock.withLock { ranges.count } }

    /// Every byte is here.
    public var isComplete: Bool {
        lock.withLock { length.map { $0 == 0 || ranges.contains(integersIn: 0..<$0) } ?? false }
    }

    /// The ranges held, in order.
    public var held: [Range<Int>] { lock.withLock { ranges.rangeView.map { $0 } } }

    public func contains(_ range: Range<Int>) -> Bool {
        lock.withLock { range.isEmpty || ranges.contains(integersIn: range) }
    }

    /// The parts of `range` not here yet, in order.
    public func missing(in range: Range<Int>) -> [Range<Int>] {
        guard !range.isEmpty else { return [] }
        return lock.withLock { IndexSet(integersIn: range).subtracting(ranges).rangeView.map { $0 } }
    }

    /// The bytes that run on from `offset` without a hole, up to `limit`.
    public func contiguous(from offset: Int, limit: Int) -> Int {
        lock.withLock {
            guard let run = ranges.rangeView.first(where: { $0.contains(offset) }) else { return 0 }
            return min(limit, run.upperBound - offset)
        }
    }

    /// Records the whole length, as an answer's `Content-Range` gave it.
    /// A different length than before means the file changed under it:
    /// what was kept goes.
    public func setTotal(_ total: Int) throws {
        try lock.withLock {
            guard length != total else { return }
            if length != nil { try resetLocked() }
            length = total
            try saveLocked()
        }
    }

    /// Writes `data` at `offset` and records it, the bytes first, so the
    /// record never names bytes that aren't there.
    public func write(_ data: Data, at offset: Int) throws {
        guard !data.isEmpty else { return }
        try lock.withLock {
            let handle = try openLocked()
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            ranges.insert(integersIn: offset..<(offset + data.count))
            try saveLocked()
        }
    }

    /// The bytes of `range`, when all of them are here.
    public func read(_ range: Range<Int>) -> Data? {
        lock.withLock {
            guard range.isEmpty || ranges.contains(integersIn: range) else { return nil }
            guard !range.isEmpty else { return Data() }
            guard let handle = try? openLocked() else { return nil }
            try? handle.seek(toOffset: UInt64(range.lowerBound))
            guard let data = try? handle.read(upToCount: range.count), data.count == range.count else { return nil }
            return data
        }
    }

    /// Closes the file, which `MediaStore` then moves or removes.
    public func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }

    /// Forgets everything kept.
    public func remove() {
        lock.withLock { try? resetLocked() }
    }

    private func openLocked() throws -> FileHandle {
        if let handle { return handle }
        let manager = FileManager.default
        if !manager.fileExists(atPath: dataURL.path) {
            try manager.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: dataURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let opened = try FileHandle(forUpdating: dataURL)
        handle = opened
        return opened
    }

    private func resetLocked() throws {
        try? handle?.close()
        handle = nil
        ranges = IndexSet()
        length = nil
        try? FileManager.default.removeItem(at: dataURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    private func saveLocked() throws {
        let meta = Meta(total: length, ranges: ranges.rangeView.map { [$0.lowerBound, $0.upperBound] })
        try FileManager.default.createDirectory(at: metaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }
}
