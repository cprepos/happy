import HappyWire
import XCTest
@testable import HappyCore

/// A flavor this app doesn't know shows what its session reports under its
/// own name. It never borrows Claude's lists or the user's Claude defaults.
final class UnknownHarnessTests: XCTestCase {
    private typealias Options = ModelModeOptions

    private let claudeOverrides: [String: JSONValue] = [
        "claude": .object([
            "permissionMode": .string("plan"),
            "modelMode": .string("claude-sonnet-5"),
            "effortLevel": .string("high"),
        ]),
    ]

    private func metadata(_ fields: [String: JSONValue] = [:]) -> JSONValue {
        .object(["flavor": .string("newcomer")].merging(fields) { _, new in new })
    }

    private var reported: [String: JSONValue] {
        [
            "operatingModes": .array([.object(["code": .string("fast"), "value": .string("Fast")])]),
            "models": .array([.object(["code": .string("own-model"), "value": .string("Own Model")])]),
        ]
    }

    func testItHasNoHardcodedCatalog() {
        XCTAssertEqual(Options.hardcodedPermissionModes(flavor: "newcomer"), [])
        XCTAssertEqual(Options.hardcodedModelModes(flavor: "newcomer"), [])
        XCTAssertEqual(Options.availablePermissionModes(flavor: "newcomer", metadata: metadata()), [])
        XCTAssertEqual(Options.availableModels(flavor: "newcomer", metadata: metadata()), [])
    }

    func testItShowsWhatItsSessionReports() {
        let modes = ComposerModes(metadata: metadata(reported), picks: ComposerPicks(), agentDefaultOverrides: claudeOverrides)
        XCTAssertEqual(modes.availableModes.map(\.key), ["fast"])
        XCTAssertEqual(modes.availableModels.map(\.key), ["own-model"])
        XCTAssertEqual(modes.availableEffortLevels, [])
    }

    func testClaudesDefaultsPickNothingForIt() {
        let modes = ComposerModes(metadata: metadata(), picks: ComposerPicks(), agentDefaultOverrides: claudeOverrides)
        XCTAssertNil(modes.permissionMode)
        XCTAssertNil(modes.modelMode)
        XCTAssertNil(modes.effortLevel)
    }

    func testASavedClaudeModelIsNotKeptAsARow() {
        XCTAssertEqual(Options.includeConfiguredModel(flavor: "newcomer", models: [], configured: "claude-sonnet-5"), [])
        XCTAssertEqual(AgentDefaults.retireModelMode("claude-opus-5-5[1m]", flavor: "newcomer"), "claude-opus-5-5[1m]")
    }

    func testItsDefaultKeysAreNotClaudes() {
        XCTAssertEqual(Options.defaultModelKey(flavor: "newcomer"), "default")
        XCTAssertEqual(Options.defaultPermissionModeKey(flavor: "newcomer"), "default")
        XCTAssertNil(Options.defaultEffortKey(flavor: "newcomer"))
    }

    func testItsMessagesCarryNoClaudeDefaults() throws {
        let settings: JSONValue = .object(["agentDefaultOverrides": .object(claudeOverrides)])
        let none = try UserMessageEncoder.modeMeta(metadata: metadata(), composer: .object([:]), settings: settings)
        XCTAssertEqual(none, [:])
    }

    func testItsMessagesCarryItsOwnPicks() throws {
        let picks: JSONValue = .object(["permissionMode": .string("fast"), "modelMode": .string("own-model")])
        let meta = try UserMessageEncoder.modeMeta(metadata: metadata(reported), composer: picks, settings: nil)
        XCTAssertEqual(meta["permissionMode"], .string("fast"))
        XCTAssertEqual(meta["model"], .string("own-model"))
    }

    func testItKeepsItsRawName() {
        XCTAssertEqual(HarnessCatalog.name("newcomer"), "newcomer")
    }

    /// Old sessions wrote no flavor; those are Claude's and stay so.
    func testNoFlavorStaysClaude() throws {
        XCTAssertEqual(Options.hardcodedPermissionModes(flavor: nil).map(\.key), Options.hardcodedPermissionModes(flavor: "claude").map(\.key))
        let settings: JSONValue = .object(["agentDefaultOverrides": .object(claudeOverrides)])
        let meta = try UserMessageEncoder.modeMeta(metadata: .object([:]), composer: .object([:]), settings: settings)
        XCTAssertEqual(meta["permissionMode"], .string("plan"))
        XCTAssertEqual(meta["effort"], .string("high"))
    }

    func testAKnownHarnessKeepsItsOwnDefaults() {
        let modes = ComposerModes(metadata: .object(["flavor": .string("codex")]), picks: ComposerPicks(), agentDefaultOverrides: claudeOverrides)
        XCTAssertEqual(modes.modelMode?.key, AgentDefaults.codeDefaults(.codex, cliVersion: nil).modelMode)
    }
}
