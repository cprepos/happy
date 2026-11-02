import Foundation

/// Drops a context update identical to one sent moments ago (happy-app's
/// contextRepeat.ts, with the voice agent's own window and size). A tool call
/// renders to the same text when it arrives and when its result lands, because
/// the rendering carries no state. Beyond the window a repeat is taken at face
/// value: the same file really can be read twice.
public struct VoiceContextRepeatFilter: Sendable {
    private let window: TimeInterval
    private let keep: Int
    private var seen: [(at: TimeInterval, text: String)] = []

    public init(window: TimeInterval = 2, keep: Int = 8) {
        self.window = window
        self.keep = keep
    }

    public mutating func isRepeat(_ text: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        seen.removeAll { now - $0.at > window }
        if seen.contains(where: { $0.text == text }) { return true }
        seen.append((now, text))
        if seen.count > keep { seen.removeFirst(seen.count - keep) }
        return false
    }
}
