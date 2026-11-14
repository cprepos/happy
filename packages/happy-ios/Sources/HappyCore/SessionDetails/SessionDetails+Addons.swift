import Foundation
import HappyWire

/// Our plugins' additions to `SessionDetails`: info.tsx's Harness row,
/// kept out of SessionDetails.swift so upstream merges do not conflict there.
extension SessionDetails {
    /// info.tsx's Harness row: which harness is running this session, by
    /// product name. Nil for Happy Agent, where the harness is Happy whatever
    /// the provider is, so `aiProvider` is the useful row.
    ///
    /// This replaced a switch that returned "Claude" for a Claude session --
    /// the model's name, not the harness's -- and fell through to the bare
    /// flavor for anything it did not list, so `agy` read "agy" and an
    /// OpenCode session read "opencode", lowercase. HarnessCatalog is the one
    /// list of names, so there is no switch to drift.
    public static func harness(_ metadata: JSONValue?) -> String? {
        if RigIdentity(metadata) != nil { return nil }
        // `metadata.harness` first: a Claude Desktop session's flavor is
        // `claude`.
        if let harness = truthy(metadata?["harness"]) { return HarnessCatalog.name(harness) }
        let flavor = truthy(metadata?["flavor"]) ?? "claude"
        // `gpt` and `openai` are older spellings of the Codex flavor that the
        // replaced switch mapped, and sessions carrying them still exist.
        if flavor == "gpt" || flavor == "openai" { return HarnessCatalog.name("codex") }
        return HarnessCatalog.name(flavor)
    }
}
