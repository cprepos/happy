import Foundation

/// How much of the model's context window a conversation has spent, as the
/// composer's meter shows it: desktop's `contextGaugeDerive` for the numbers
/// and `ContextMeter` for the fill, the compaction mark and the colour.
public struct AgentContextGauge: Equatable, Sendable {
    /// Tokens already spent in the window, never past it.
    public var usedTokens: Int
    /// The whole context window.
    public var totalTokens: Int
    /// Where the daemon compacts on its own, below the window; nil when the
    /// model publishes no threshold.
    public var compactTokens: Int?
    /// The count is estimated rather than reported.
    public var approximate: Bool
    /// False while the window is known but the provider hasn't measured
    /// the conversation yet.
    public var measured: Bool

    public init(usedTokens: Int, totalTokens: Int, compactTokens: Int? = nil, approximate: Bool = false, measured: Bool = true) {
        self.usedTokens = usedTokens
        self.totalTokens = totalTokens
        self.compactTokens = compactTokens
        self.approximate = approximate
        self.measured = measured
    }

    /// The meter for a conversation: its last measurement against its
    /// model's window, or before the first one, the window its selection
    /// declares with nothing spent. Nil when no window is known.
    public static func derive(catalog: ModelCatalog?, context: AgentWire.ContextUsage?, selection: AgentWire.Mode?) -> AgentContextGauge? {
        func model(_ providerId: String, _ modelId: String) -> ModelCatalog.Model? {
            catalog?.provider(providerId)?.models.first { $0.id == modelId }
        }
        // The daemon compacts at the model's published threshold; a limit at
        // or past the window is no threshold at all.
        func compact(_ model: ModelCatalog.Model?, _ total: Int) -> Int? {
            guard let limit = model?.autoCompactWindow, limit > 0, limit < total else { return nil }
            return limit
        }
        guard let context else {
            guard let selection, let model = model(selection.providerId, selection.modelId),
                  let total = model.contextWindow, total > 0 else { return nil }
            return AgentContextGauge(usedTokens: 0, totalTokens: total, compactTokens: compact(model, total), measured: false)
        }
        let measuredModel = context.modelId.flatMap { model(context.providerId, $0) }
        guard let total = context.contextWindow.map({ Int($0) }) ?? measuredModel?.contextWindow, total > 0 else { return nil }
        let used = max(0, min(Int(context.contextTokens.rounded()), total))
        return AgentContextGauge(usedTokens: used, totalTokens: total, compactTokens: compact(measuredModel, total), approximate: context.approximate)
    }

    /// Where compaction is marked when the model publishes no threshold.
    public static let defaultCompactFraction = 0.75
    /// The warning colour comes once the fill is within this share of the
    /// compaction point, and the error colour at the point itself.
    public static let warningMargin = 0.2

    /// The share of the window spent, 0–1; none before a measurement.
    public var fraction: Double {
        guard totalTokens > 0, measured else { return 0 }
        return Double(max(0, min(usedTokens, totalTokens))) / Double(totalTokens)
    }

    public var percent: Int { Int((fraction * 100).rounded()) }

    /// Where the notch sits, as a share of the track.
    public var compactFraction: Double {
        guard let compactTokens, compactTokens > 0, compactTokens < totalTokens else { return Self.defaultCompactFraction }
        return Double(compactTokens) / Double(totalTokens)
    }

    /// Quiet with room to spare; coloured only once compacting is next.
    public enum Tone: Equatable, Sendable { case ample, compact, critical }

    public var tone: Tone {
        if fraction >= compactFraction { return .critical }
        return fraction >= compactFraction * (1 - Self.warningMargin) ? .compact : .ample
    }

    /// `tokensFormat`: 950, 1.2k, 84k, 128k, 1M.
    public static func tokens(_ count: Int) -> String {
        if count < 1000 { return String(max(0, count)) }
        let thousands = Double(count) / 1000
        if thousands < 1000 {
            return thousands < 100 ? trimmed(thousands) + "k" : String(Int(thousands.rounded())) + "k"
        }
        return trimmed(thousands / 1000) + "M"
    }

    /// One decimal, without a trailing ".0", a half rounded up as
    /// `toFixed(1)` rounds 1.25.
    private static func trimmed(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return tenths % 10 == 0 ? String(tenths / 10) : "\(tenths / 10).\(tenths % 10)"
    }
}
