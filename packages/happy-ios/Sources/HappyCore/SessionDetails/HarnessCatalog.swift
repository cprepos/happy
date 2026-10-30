import Foundation

/// utils/harnessCatalog.ts `HARNESS_NAMES`: the product name of each harness.
///
/// This is deliberately its own list rather than a property of
/// `AgentDefaults.Agent`, which is where the Swift side used to keep it. That
/// enum models the harnesses Settings > Agents can configure defaults for, so
/// it has no `opencode` or `rig` case -- and asking it for a name therefore
/// could not answer "which harness is this session?" for an OpenCode session
/// at all. happy-app keeps HARNESS_NAMES in utils/harnessCatalog.ts, separate
/// from sync/agentDefaults.ts, for the same reason.
public enum HarnessCatalog {
    public static let names: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex",
        "rig": "Happy",
        "agy": "Antigravity",
        "opencode": "OpenCode",
        "gemini": "Gemini",
        "openclaw": "OpenClaw",
    ]

    /// `getHarnessName`: the product name, or the key itself when it is one we
    /// do not ship a name for. An unknown flavor is shown as it arrived rather
    /// than guessed at, which is what happy-app does.
    public static func name(_ key: String) -> String {
        names[key] ?? key
    }
}
