import Foundation
import HappyCrypto

/// Where a media file's bytes come from, as `MediaDownloads` reads them:
/// a range of what is stored on the server at a time. For a legacy
/// account that is the sealed blob (`seal`), whose plaintext is what the
/// app shows; for a paired computer it is the file itself.
public struct MediaSource: Sendable {
    /// One range of the stored bytes. The answer may hold less than asked,
    /// or the whole file from zero where a server ignores ranges.
    public typealias Fetch = @Sendable (Range<Int>) async throws -> MediaPiece

    public var fetch: Fetch
    /// The stored length, when it is known before the first answer.
    public var length: Int?
    public var seal: MediaSeal?

    public init(length: Int? = nil, seal: MediaSeal? = nil, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.length = length
        self.seal = seal
    }
}

/// An answer to one range: its bytes, where they start, and the file's
/// whole length when the server said.
public struct MediaPiece: Sendable, Equatable {
    public var offset: Int
    public var data: Data
    public var total: Int?

    public init(offset: Int, data: Data, total: Int?) {
        self.offset = offset
        self.data = data
        self.total = total
    }

    /// An HTTP answer to a `Range` request: a `206` with its
    /// `Content-Range`, or a `200` holding the whole file.
    public static func http(status: Int, headers: [String: String], body: Data) throws -> MediaPiece {
        if status == 200 { return MediaPiece(offset: 0, data: body, total: body.count) }
        guard status == 206 else { throw MediaError.status(status) }
        let header = headers.first { $0.key.lowercased() == "content-range" }?.value
        guard let range = header.flatMap(ContentRange.init) else { throw MediaError.invalidResponse }
        return MediaPiece(offset: range.start, data: body, total: range.total)
    }

    /// `Range` for a request: `bytes=a-b`, both ends included.
    public static func header(_ range: Range<Int>) -> String { "bytes=\(range.lowerBound)-\(range.upperBound - 1)" }
}

/// `Content-Range: bytes 0-1023/4096`.
public struct ContentRange: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var total: Int?

    public init?(_ header: String) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = trimmed.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), start <= end else { return nil }
        self.start = start
        self.end = end
        total = Int(parts[1])
    }
}

public enum MediaError: Error, Equatable, Sendable {
    case status(Int)
    case invalidResponse
    /// The sealed file's MAC didn't check: it was changed, or never was the file.
    case notAuthentic
    /// What was asked for lies past the file's end.
    case outOfRange
    case stopped
}

/// A legacy attachment's sealing (happy-app's encryptBlob): nonce(24),
/// MAC(16), then XSalsa20 ciphertext of exactly the plaintext's length.
/// A stream cipher, so any plaintext range is the same range of
/// ciphertext 40 bytes on, readable before the rest arrives. The MAC
/// covers the whole ciphertext, so it is checked once all of it is here,
/// before the plaintext is kept for good.
public struct MediaSeal: Sendable, Equatable {
    public let key: Data
    public static let header = BlobCipher.headerLength

    public init(key: Data) { self.key = key }

    public func plainLength(stored: Int) -> Int { max(0, stored - Self.header) }
    public func storedLength(plain: Int) -> Int { plain + Self.header }

    /// The stored bytes a plaintext range needs, the nonce among them.
    public func storedRanges(_ plain: Range<Int>) -> [Range<Int>] {
        [0..<SecretBox.nonceLength, (plain.lowerBound + Self.header)..<(plain.upperBound + Self.header)]
    }

    public func decrypt(_ ciphertext: Data, nonce: Data, plainOffset: Int) -> Data? {
        BlobCipher.decrypt(range: ciphertext, nonce: nonce, key: key, offset: plainOffset)
    }

    public func open(_ sealed: Data) -> Data? { BlobCipher.open(sealed, key: key) }
}
