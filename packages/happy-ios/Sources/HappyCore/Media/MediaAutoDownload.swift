import Foundation

/// Telegram's Data and Storage › Automatic Media Download, for this
/// phone: which kinds of media are read as soon as they show up in a
/// chat, so they are here offline, and up to what size. One setting for
/// every network (Telegram splits Wi-Fi and cellular; this doesn't yet).
public struct MediaAutoDownload: Codable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case photos, videos, files
    }

    public struct Rule: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// Bytes; a file larger than this waits for a tap.
        public var limit: Int

        public init(enabled: Bool, limit: Int) {
            self.enabled = enabled
            self.limit = limit
        }
    }

    public static let megabyte = 1024 * 1024
    /// The limits the setting offers.
    public static let limits = [1, 5, 10, 25, 50, 100].map { $0 * megabyte }

    public var photos = Rule(enabled: true, limit: 10 * megabyte)
    public var videos = Rule(enabled: false, limit: 10 * megabyte)
    public var files = Rule(enabled: true, limit: 1 * megabyte)

    public init() {}

    public subscript(kind: Kind) -> Rule {
        get {
            switch kind {
            case .photos: photos
            case .videos: videos
            case .files: files
            }
        }
        set {
            switch kind {
            case .photos: photos = newValue
            case .videos: videos = newValue
            case .files: files = newValue
            }
        }
    }

    /// Whether a file of `kind` and `size` is read without a tap. A photo
    /// of unknown size is (one is rarely large); anything else isn't.
    public func allows(_ kind: Kind, size: Int?) -> Bool {
        let rule = self[kind]
        guard rule.enabled else { return false }
        guard let size else { return kind == .photos }
        return size <= rule.limit
    }

    // MARK: Kept

    static let defaultsKey = "media.autoDownload"
    public static let didChange = Notification.Name("MediaAutoDownload.didChange")

    public static func load(_ defaults: UserDefaults = .standard) -> MediaAutoDownload {
        guard let data = defaults.data(forKey: defaultsKey), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    public func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
