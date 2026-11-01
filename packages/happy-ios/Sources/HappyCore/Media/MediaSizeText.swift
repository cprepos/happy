import Foundation

/// What Telegram's media badge says (`dataSizeString`): a size in binary
/// units, "840 KB" or "8.4 MB", and a download's progress against it,
/// "1.2 / 8.4 MB", the unit said once where both share it.
public enum MediaSizeText {
    enum Unit: Int, Comparable {
        case bytes, kilobytes, megabytes, gigabytes
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        var name: String {
            switch self {
            case .bytes: "B"
            case .kilobytes: "KB"
            case .megabytes: "MB"
            case .gigabytes: "GB"
            }
        }

        static func of(_ bytes: Int) -> Unit {
            switch bytes {
            case ..<1024: .bytes
            case ..<(1024 * 1024): .kilobytes
            case ..<(1024 * 1024 * 1024): .megabytes
            default: .gigabytes
            }
        }
    }

    public static func size(_ bytes: Int) -> String {
        let unit = Unit.of(bytes)
        return "\(number(bytes, in: unit)) \(unit.name)"
    }

    public static func progress(_ done: Int, of total: Int) -> String {
        let unit = Unit.of(total)
        let doneUnit = Unit.of(done)
        // Under a megabyte of a bigger file reads as "0.4 / 8.4 MB".
        if doneUnit == unit || (unit >= .megabytes && doneUnit < unit) {
            return "\(number(done, in: unit)) / \(number(total, in: unit)) \(unit.name)"
        }
        return "\(size(done)) / \(size(total))"
    }

    /// A badge's text for `phase`: the size, or how far it is; nil while
    /// the size isn't known.
    public static func text(_ phase: DownloadPhase) -> String? {
        switch phase {
        case .remote(let total):
            return total.map(size)
        case .complete(let total):
            return size(total)
        case .downloading(let done, let total), .paused(let done, let total), .failed(let done, let total):
            guard let total else { return done > 0 ? size(done) : nil }
            // Nothing here yet and nothing coming: only the size.
            if done == 0, !phase.isDownloading { return size(total) }
            return progress(done, of: total)
        }
    }

    static func number(_ bytes: Int, in unit: Unit) -> String {
        switch unit {
        case .bytes: return "\(bytes)"
        case .kilobytes: return "\(Int((Double(bytes) / 1024).rounded()))"
        case .megabytes, .gigabytes:
            let value = Double(bytes) / pow(1024, Double(unit.rawValue))
            let tenths = (value * 10).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths))" : String(format: "%.1f", tenths)
        }
    }

    /// A recording's length as Telegram writes it: "0:12", "1:05:03".
    public static func duration(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
