import Foundation
import HappyCore

// The composer's context meter and the model chip's usage warning, spelled as
// happy-desktop spells them: ContextMeter.tsx (readout, label and title) and
// ComposerModelControl.tsx (`usageWarning`).
extension Strings {
    enum ContextMeter {
        /// `~42%`, or a dash before the first measurement.
        static func percent(_ gauge: AgentContextGauge) -> String {
            gauge.measured ? "\(gauge.approximate ? "~" : "")\(gauge.percent)%" : "—"
        }

        /// `84k/200k`.
        static func tokens(_ gauge: AgentContextGauge) -> String {
            "\(gauge.measured ? AgentContextGauge.tokens(gauge.usedTokens) : "—")/\(AgentContextGauge.tokens(gauge.totalTokens))"
        }

        private static func compactNote(_ gauge: AgentContextGauge) -> String {
            gauge.compactTokens.map { " \u{00b7} compacts at \(AgentContextGauge.tokens($0))" } ?? ""
        }

        /// The `aria-label`, read aloud.
        static func label(_ gauge: AgentContextGauge) -> String {
            let used = AgentContextGauge.tokens(gauge.usedTokens), total = AgentContextGauge.tokens(gauge.totalTokens)
            return gauge.measured
                ? "\(used) of \(total) context tokens used\(gauge.approximate ? ", approximate" : "")\(compactNote(gauge))"
                : "Context measurement pending for a \(total) token window\(compactNote(gauge))"
        }

        /// The `title`: the label, and what the colour asks for.
        static func title(_ gauge: AgentContextGauge) -> String {
            let used = AgentContextGauge.tokens(gauge.usedTokens), total = AgentContextGauge.tokens(gauge.totalTokens)
            guard gauge.measured else {
                return "Waiting for the first context measurement (\(total) token window\(compactNote(gauge)))"
            }
            let advice = switch gauge.tone {
            case .critical: " — the next turn compacts the conversation"
            case .compact: " — compaction is close; compact now to choose the moment"
            case .ample: ""
            }
            return "\(used) of \(total) context tokens used\(gauge.approximate ? " (approximate)" : "")\(compactNote(gauge))\(advice)"
        }
    }

    /// `usageWarning`'s label: "Weekly limit · 12% left · resets Fri 4:10 PM",
    /// or "Session limit reached · resets 3:05 PM" for a window holding a
    /// spent account back.
    static func usageWarning(_ warning: AccountUsage.Warning, now: Date) -> String {
        let name = "\(warning.window.kind == .week ? "Weekly" : "Session") limit"
        let resets = warning.window.resetsAt.map { " · \(Strings.resets(Strings.dayTime($0, now: now)))" } ?? ""
        return warning.window.blocking ? "\(name) reached\(resets)" : "\(name) · \(warning.left)% left\(resets)"
    }

    /// An account whose sign-in is missing or refused, at its row's end.
    static let signedOut = "Signed out"
}
