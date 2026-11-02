import Foundation
import HappyWire

/// OpenCode as a harness: everything about it that is not its mode picker
/// (`OpencodeModes`). Upstream's harness lists each carry one line pointing
/// here, so a pull that reshapes them leaves this file alone.
public enum OpencodeHarness {
    public static let key = "opencode"
    /// utils/harnessCatalog.ts `HARNESS_NAMES`.
    public static let name = "OpenCode"
    /// new/index.tsx's `ALL_AGENTS` label.
    public static let label = "opencode"
    /// The session metadata field `happy opencode --resume` takes.
    public static let resumeIdField = "opencodeSessionId"

    /// harnessCatalog.ts `HARNESS_ORDER`: straight after agy, else before
    /// Happy Agent, else last.
    public static func placed(in order: [String]) -> [String] {
        var order = order
        if let index = order.firstIndex(of: "agy") {
            order.insert(key, at: index + 1)
        } else if let index = order.firstIndex(of: "rig") {
            order.insert(key, at: index)
        } else {
            order.append(key)
        }
        return order
    }

    /// harnessCatalog.ts `EXPLICIT_REPORT_HARNESSES`: a daemon that says
    /// nothing about OpenCode is not offering it.
    public static func available(cliAvailability: JSONValue?) -> Bool {
        cliAvailability?[key]?.boolValue == true
    }

    /// agentDefaults.ts: OpenCode's own default agent, approving tool
    /// permissions automatically, on whatever model the machine's config
    /// selects.
    static let defaults = AgentDefaults.Config(
        permissionMode: OpencodeModes.defaultPermissionMode,
        modelMode: "default",
        effortLevel: nil
    )
}
