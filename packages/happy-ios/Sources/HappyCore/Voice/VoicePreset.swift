import Foundation

/// A curated voice for the server voice stream, from happy-app's
/// voiceCatalog.ts: a Kokoro voice or blend and a speaking rate. Settings store
/// only the id; the agent gets `voice` and `speed` through `happy.getConfig`.
public struct VoicePreset: Equatable, Sendable {
    public enum Accent: String, Sendable { case us, uk }
    public enum Tone: String, Sendable { case warm, bright, soft, calm, deep, lively }

    /// Stable id stored in settings. Never reuse an id for a different voice.
    public let id: String
    public let label: String
    public let voice: String
    public let speed: Double
    public let accent: Accent
    public let tone: Tone

    public static let all: [VoicePreset] = [
        .init(id: "morgan", label: "Morgan Freeman", voice: "am_morgan", speed: 1.0, accent: .us, tone: .deep),
        .init(id: "heart", label: "Heart", voice: "af_heart", speed: 1.0, accent: .us, tone: .warm),
        .init(id: "bella", label: "Bella", voice: "af_bella", speed: 1.0, accent: .us, tone: .bright),
        .init(id: "nicole", label: "Nicole", voice: "af_nicole", speed: 1.0, accent: .us, tone: .soft),
        .init(id: "michael", label: "Michael", voice: "am_michael", speed: 1.0, accent: .us, tone: .calm),
        .init(id: "onyx", label: "Onyx", voice: "am_onyx", speed: 1.0, accent: .us, tone: .deep),
        .init(id: "deep", label: "Deep Blend", voice: "am_michael(2)+am_onyx(1)", speed: 0.85, accent: .us, tone: .deep),
        .init(id: "fenrir", label: "Fenrir", voice: "am_fenrir", speed: 1.0, accent: .us, tone: .lively),
        .init(id: "puck", label: "Puck", voice: "am_puck", speed: 1.0, accent: .us, tone: .bright),
        .init(id: "emma", label: "Emma", voice: "bf_emma", speed: 1.0, accent: .uk, tone: .warm),
        .init(id: "george", label: "George", voice: "bm_george", speed: 1.0, accent: .uk, tone: .calm),
        .init(id: "fable", label: "Fable", voice: "bm_fable", speed: 1.0, accent: .uk, tone: .lively),
        .init(id: "lewis", label: "Lewis", voice: "bm_lewis", speed: 1.0, accent: .uk, tone: .deep),
    ]

    public static func find(_ id: String?) -> VoicePreset? {
        guard let id, !id.isEmpty else { return nil }
        return all.first { $0.id == id }
    }

    /// The chat's override, else the account's default, else nil (the server's
    /// default voice). An unknown id falls through, so a preset removed in a
    /// later version lands on the next level.
    public static func resolve(sessionId: String, bySession: [String: String], defaultId: String?) -> VoicePreset? {
        find(bySession[sessionId]) ?? find(defaultId)
    }

    /// `voiceBySession` with this chat's override set, or removed for nil or an
    /// unknown id.
    public static func settingOverride(_ bySession: [String: String], sessionId: String, presetId: String?) -> [String: String] {
        var next = bySession
        next[sessionId] = find(presetId)?.id
        return next
    }
}

/// Who a voice answers to in the prompt and greeting.
public struct VoicePersona: Equatable, Sendable {
    public enum Gender: Equatable, Sendable { case male, female }

    public let name: String
    public let gender: Gender

    public init(name: String, gender: Gender) {
        self.name = name
        self.gender = gender
    }

    /// Names that differ from the id derivation. Keep in sync with OVERRIDES in
    /// packages/happy-voice-agent/happy_voice/names.py.
    private static let overrides = ["am_morgan": "Morgan Freeman"]

    /// The name encoded in a Kokoro voice id and its gender from the prefix
    /// (am_michael is Michael, male). A blend answers to its first voice. nil
    /// when the id has no resolvable name.
    public init?(voice: String) {
        var first = String(voice.split(separator: "+", omittingEmptySubsequences: false).first ?? "")
        if first.hasSuffix(")"), let open = first.lastIndex(of: "("),
           first[first.index(after: open)...].dropLast().allSatisfy(\.isASCIINumber),
           first.index(after: open) < first.index(before: first.endIndex) {
            first = String(first[..<open])
        }
        first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = first.firstIndex(of: "_"), separator != first.startIndex else { return nil }
        let prefix = first[..<separator]
        let tail = first[first.index(after: separator)...]
        guard prefix.count <= 2, prefix.allSatisfy({ $0.isASCII && $0.isLowercase }), !tail.isEmpty else { return nil }
        let derived = tail.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let name = Self.overrides[first] ?? derived
        guard !name.isEmpty else { return nil }
        // Two-letter prefixes (a/b + f/m) and single-letter ones (m male, n/e/o female).
        self.init(name: name, gender: prefix.last == "m" ? .male : .female)
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
}
