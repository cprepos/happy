import Foundation
import HappyCore

// Media kept on this phone: the ring's and badge's spoken states, and
// Settings' Data and Storage page. Telegram's wording, as happy-app has
// none of its own for these.

extension Strings {
    public enum Download {
        public static func size(_ text: String) -> String { "not downloaded, \(text), double-tap to download" }
        public static let notDownloaded = "not downloaded, double-tap to download"
        public static func downloading(_ percent: Int) -> String { "downloading, \(percent)%" }
        public static let waiting = "downloading"
        public static func paused(_ percent: Int) -> String { "paused at \(percent)%, double-tap to resume" }
        public static let failed = "download failed, double-tap to retry"
        public static let pause = "Pause download"
        public static let resume = "Download"
    }

    public enum DataStorage {
        public static let title = "Data and Storage"
        public static let subtitle = "Storage used, automatic media download"
        public static let storage = "Storage"
        public static let storageUsage = "Storage Usage"
        public static let calculating = "Calculating…"
        public static let clearMedia = "Clear Media"
        public static let clearMediaFooter = "Photos, videos and files are kept on this iPhone for good, so they open without the network. Clearing them frees the space; anything cleared is downloaded again when it is opened."
        public static func clearConfirm(_ size: String) -> String { "Clear \(size) of media from this iPhone? It is downloaded again when opened." }
        public static let clear = "Clear"
        public static let autoDownload = "Automatic Media Download"
        public static let autoDownloadFooter = "Media up to the size limit downloads by itself as it appears in a chat, so it is here offline. The same on Wi-Fi and cellular."
        public static let photos = "Photos"
        public static let videos = "Videos"
        public static let files = "Files"
        public static let limit = "Up To"
        public static func limitValue(_ bytes: Int) -> String { MediaSizeText.size(bytes) }
        public static let off = "Off"
    }
}
