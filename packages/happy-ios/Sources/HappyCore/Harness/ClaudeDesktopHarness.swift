import Foundation
import HappyWire

/// Claude Desktop as a harness: a Claude Code session running inside the
/// Claude desktop app, mirrored into Happy by the `happy@happy` plugin
/// (docs/plans/happyify-desktop-sync.md, "Contract"). Upstream's harness
/// lists each carry one line pointing here, so a pull that reshapes them
/// leaves this file alone.
///
/// Its sessions keep `metadata.flavor == "claude"`, so every Claude renderer
/// applies, and add `metadata.harness == "claude-desktop"`. The desktop app
/// owns the model, the permission mode, the effort and resuming, so this
/// harness offers no pickers and no resume command.
public enum ClaudeDesktopHarness {
    public static let key = "claude-desktop"
    /// utils/harnessCatalog.ts `HARNESS_NAMES`.
    public static let name = "Claude Desktop"
    /// new/index.tsx's `ALL_AGENTS` label.
    public static let label = "claude desktop"

    /// harnessCatalog.ts `HARNESS_ORDER`: straight after Claude Code, else
    /// first.
    public static func placed(in order: [String]) -> [String] {
        var order = order
        if let index = order.firstIndex(of: "claude") {
            order.insert(key, at: index + 1)
        } else {
            order.insert(key, at: 0)
        }
        return order
    }

    /// harnessCatalog.ts `EXPLICIT_REPORT_HARNESSES`: offered only while the
    /// machine says the desktop app is running with the plugin.
    public static func available(cliAvailability: JSONValue?) -> Bool {
        cliAvailability?[key]?.boolValue == true
    }

    /// A session the desktop app runs: `metadata.harness`, whatever its
    /// flavor says.
    public static func isSession(_ metadata: JSONValue?) -> Bool {
        metadata?["harness"]?.stringValue == key
    }

    /// agentDefaults.ts: nothing of its own. The desktop app picks the
    /// model, the permission mode and the effort.
    static let defaults = AgentDefaults.Config(
        permissionMode: "default",
        modelMode: "default",
        effortLevel: nil
    )
}
