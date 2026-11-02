import Foundation
import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// After happy-app's sync/opencodeModes.test.ts, and what a computer that
/// reports OpenCode offers.
final class OpencodeHarnessTests: XCTestCase {
    private func modes(_ rows: (String, String)...) -> [ModeOption] {
        rows.map { ModeOption(key: $0.0, name: $0.1) }
    }

    private func machine(_ id: String, name: String? = nil, active: Bool = true, cli: [String: JSONValue]? = ["claude": .bool(true)]) -> MachineRecord {
        var values: [String: JSONValue] = ["displayName": .string(name ?? id), "homeDir": .string("/Users/steve")]
        if let cli { values["cliAvailability"] = .object(cli) }
        return MachineRecord(
            id: id, seq: 0, createdAt: 1, updatedAt: 1, active: active, activeAt: 1,
            metadataVersion: 1, metadataCipher: "c", metadata: .object(values),
            daemonStateVersion: 0, daemonStateCipher: nil, daemonState: nil, dataKeyCipher: "k", decryptable: true
        )
    }

    private func choice(_ machine: MachineRecord) throws -> MachineChoice {
        try XCTUnwrap(MachineChoice.collect([machine]).first)
    }

    // MARK: opencodeModes.test.ts

    func testSplitsAModeKeyIntoAgentAndPolicy() {
        XCTAssertEqual(OpencodeModes.split("build:ask").agent, "build")
        XCTAssertEqual(OpencodeModes.split("build:ask").policy, .ask)
        XCTAssertEqual(OpencodeModes.split("plan").agent, "plan")
        XCTAssertNil(OpencodeModes.split("plan").policy)
        XCTAssertEqual(OpencodeModes.split("ns:agent").agent, "ns:agent")
        XCTAssertNil(OpencodeModes.split("ns:agent").policy)
    }

    func testReadsTheLaunchPolicyFromATuiModeListAndDefaultsToAuto() {
        let tuiAsk = modes(("build", "Build-ask"), ("build:auto", "Build-auto"))
        let tuiAuto = modes(("build", "Build-auto"), ("build:ask", "Build-ask"))
        XCTAssertEqual(OpencodeModes.launchPolicy(tuiAsk, agent: "build"), .ask)
        XCTAssertEqual(OpencodeModes.launchPolicy(tuiAuto, agent: "build"), .auto)
        XCTAssertEqual(OpencodeModes.launchPolicy(modes(("build", "build")), agent: "build"), .auto)
        XCTAssertEqual(OpencodeModes.launchPolicy([], agent: "build"), .auto)
        XCTAssertEqual(OpencodeModes.normalize("build", modes: tuiAsk), "build:ask")
        XCTAssertEqual(OpencodeModes.normalize("plan"), "plan:auto")
        XCTAssertEqual(OpencodeModes.normalize("plan:ask"), "plan:ask")
        XCTAssertEqual(OpencodeModes.normalize("default"), "default")
        XCTAssertNil(OpencodeModes.normalize(nil))
    }

    func testDefaultsToBuildWithAutoPermissionsAndUpgradesBareSavedDefaults() {
        XCTAssertEqual(AgentDefaults.resolve([:], .opencode, cliVersion: nil).permissionMode, "build:auto")
        XCTAssertEqual(AgentDefaults.override(["opencode": .object(["permissionMode": .string("plan")])], .opencode, .permissionMode), "plan:auto")
        XCTAssertEqual(AgentDefaults.resolve(["opencode": .object(["permissionMode": .string("build:ask")])], .opencode, cliVersion: nil).permissionMode, "build:ask")
        // An old CLI loses the bare `auto` key, which this is not.
        XCTAssertEqual(AgentDefaults.codeDefaults(.opencode, cliVersion: "1.0.0").permissionMode, "build:auto")
        XCTAssertEqual(AgentDefaults.resolve([:], .opencode, cliVersion: nil).modelMode, "default")
        XCTAssertNil(AgentDefaults.resolve([:], .opencode, cliVersion: nil).effortLevel)
    }

    func testDisplayNamesDropDoublesAndPolicySuffixes() {
        XCTAssertEqual(OpencodeModes.displayName(agent: "build", option: nil), "Build")
        XCTAssertEqual(OpencodeModes.displayName(agent: "build", option: ModeOption(key: "build", name: "build, build")), "Build")
        XCTAssertEqual(OpencodeModes.displayName(agent: "plan", option: ModeOption(key: "plan", name: "plan/plan")), "Plan")
        XCTAssertEqual(OpencodeModes.displayName(agent: "build", option: ModeOption(key: "build", name: "Build-AUTO")), "Build")
    }

    // MARK: modelModeOptions.ts

    func testBeforeASessionExistsEachAgentIsOfferedOncePerPolicy() {
        let rows = ModelModeOptions.hardcodedPermissionModes(flavor: "opencode")
        XCTAssertEqual(rows.map(\.key), ["build:auto", "build:ask", "plan:auto", "plan:ask"])
        XCTAssertEqual(rows.map(\.name), ["Build-auto", "Build-ask", "Plan-auto", "Plan-ask"])
        XCTAssertEqual(rows[0].description, "opencode build agent · approves tool permissions automatically")
        XCTAssertEqual(rows[3].description, "plan first · asks before tools that need permission")
        XCTAssertEqual(ModelModeOptions.hardcodedModelModes(flavor: "opencode").map(\.key), ["default"])
        XCTAssertEqual(ModelModeOptions.effortLevelsForModel(flavor: "opencode", modelKey: "default"), [])
    }

    func testASessionListsItsReportedAgentsWithExplicitKeys() throws {
        let tuiList: JSONValue = .object(["flavor": .string("opencode"), "operatingModes": .array([
            .object(["code": .string("review"), "value": .string("Review-ask"), "description": .string("reads closely")]),
            .object(["code": .string("review:auto"), "value": .string("Review-auto")]),
            .object(["code": .string("default"), "value": .string("Default")]),
        ])])
        let rows = ModelModeOptions.availablePermissionModes(flavor: "opencode", metadata: tuiList)
        XCTAssertEqual(rows.map(\.key), ["review:auto", "review:ask"])
        XCTAssertEqual(rows.map(\.name), ["Review-auto", "Review-ask"])
        XCTAssertEqual(rows[1].description, "reads closely", "the plain row names the launch policy")
        XCTAssertEqual(rows[0].description, "approves tool permissions automatically")

        let nothingYet = ModelModeOptions.availablePermissionModes(flavor: "opencode", metadata: .object(["flavor": .string("opencode")]))
        XCTAssertEqual(nothingYet.first?.key, "build:auto")
    }

    func testTheChipReadsThePickThenTheSavedDefaultThenTheCli() {
        func chip(_ pick: String?, overrides: [String: JSONValue] = [:], reported: String? = nil) -> String? {
            var metadata: [String: JSONValue] = ["flavor": .string("opencode")]
            if let reported { metadata["currentOperatingModeCode"] = .string(reported) }
            return ComposerModes(metadata: .object(metadata), picks: ComposerPicks(permissionMode: pick), agentDefaultOverrides: overrides).permissionMode?.key
        }
        let saved: [String: JSONValue] = ["opencode": .object(["permissionMode": .string("plan")])]
        XCTAssertEqual(chip("build"), "build:auto", "an older saved pick is a bare agent")
        XCTAssertEqual(chip("build:ask", overrides: saved, reported: "plan:auto"), "build:ask")
        XCTAssertEqual(chip(nil, overrides: saved, reported: "build:ask"), "plan:auto")
        XCTAssertEqual(chip(nil, reported: "plan:ask"), "plan:ask")
        XCTAssertEqual(chip(nil), "build:auto")
    }

    func testAClaudeOverrideDoesNotReachOpenCode() {
        let overrides: [String: JSONValue] = ["claude": .object(["permissionMode": .string("plan"), "modelMode": .string("claude-opus-5")])]
        let modes = ComposerModes.newSession(agentType: "opencode", picks: ComposerPicks(), agentDefaultOverrides: overrides, cliVersion: "1.2.6")
        XCTAssertEqual(modes.permissionMode?.key, "build:auto")
        XCTAssertEqual(modes.modelMode?.key, "default")
        XCTAssertNil(modes.effortLevel)
    }

    // MARK: harnessCatalog.ts

    func testAMachineMustReportOpenCodeToOfferIt() throws {
        XCTAssertFalse(try choice(machine("silent", cli: nil)).agentAvailable("opencode"))
        XCTAssertFalse(try choice(machine("older", cli: ["claude": .bool(true)])).agentAvailable("opencode"))
        XCTAssertFalse(try choice(machine("missing", cli: ["opencode": .bool(false)])).agentAvailable("opencode"))
        XCTAssertTrue(try choice(machine("has", cli: ["opencode": .bool(true)])).agentAvailable("opencode"))
    }

    func testOpenCodeSitsAfterAgyBeforeHappy() throws {
        XCTAssertEqual(MachineChoice.agentOrder, ["claude", "codex", "agy", "opencode", "rig"])
        XCTAssertEqual(OpencodeHarness.placed(in: ["claude", "rig"]), ["claude", "opencode", "rig"])
        XCTAssertEqual(OpencodeHarness.placed(in: ["claude"]), ["claude", "opencode"])
        let everything = try choice(machine("m", cli: ["claude": .bool(true), "codex": .bool(true), "agy": .bool(true), "opencode": .bool(true)]))
        XCTAssertEqual(everything.availableAgents, ["claude", "codex", "agy", "opencode"])
    }

    func testTheComposerOffersItOnTheComputerThatReportsIt() {
        let machines = [machine("m1", cli: ["claude": .bool(true), "opencode": .bool(true)])]
        let draft = NewSessionDraft(selectedMachineId: "m1", agentType: .opencode, pickedAgentType: .opencode)
        let choices = NewSessionChoices(NewSessionChoices.Inputs(draft: draft, machines: machines, sessions: []))
        XCTAssertEqual(choices.agentOptions.map(\.key), ["claude", "opencode"])
        XCTAssertEqual(choices.agentOptions.last?.name, "OpenCode")
        XCTAssertEqual(choices.resolvedAgent, .opencode)
        XCTAssertEqual(choices.currentPermission?.key, "build:auto")
        XCTAssertEqual(choices.permissionLabel, "Build-auto")
        XCTAssertEqual(choices.permissionOptions.count, 4)
    }

    func testThePickDoesNotFollowToAComputerWithoutIt() {
        let machines = [machine("m1", cli: ["claude": .bool(true)])]
        let draft = NewSessionDraft(selectedMachineId: "m1", agentType: .opencode, pickedAgentType: .opencode)
        let choices = NewSessionChoices(NewSessionChoices.Inputs(draft: draft, machines: machines, sessions: []))
        XCTAssertEqual(choices.agentOptions.map(\.key), ["claude"])
        XCTAssertEqual(choices.resolvedAgent, .claude)
    }

    func testThreeComputersStayChoosableWithSomeOffline() {
        let machines = [
            machine("a", name: "prep-ml", cli: ["opencode": .bool(true)]),
            machine("b", name: "prep-air", active: false),
            machine("c", name: "prep-pro", active: false),
        ]
        let draft = NewSessionDraft(selectedMachineId: "a")
        let choices = NewSessionChoices(NewSessionChoices.Inputs(draft: draft, machines: machines, sessions: []))
        XCTAssertEqual(choices.machineOptions.map(\.key).sorted(), ["a", "b", "c"])
        XCTAssertEqual(choices.machineOptions.first?.key, "a", "online first")
    }

    func testTheMachineScreenRowFollowsTheReport() {
        let reported = MachineDetailsModel(machine: machine("m", cli: ["claude": .bool(true), "opencode": .bool(false)]), sessions: [])
        XCTAssertEqual(reported.cliAvailability?.opencode, false)
        XCTAssertNil(MachineDetailsModel(machine: machine("m"), sessions: []).cliAvailability?.opencode)
    }

    func testAttachmentsAndAvatarAndName() {
        XCTAssertFalse(SessionComposerRules.canUseAttachments(starting: .opencode))
        XCTAssertEqual(SessionAvatar.harness(flavor: "opencode", clientId: nil), .opencode)
        XCTAssertEqual(NewSessionDraft.Agent.opencode.name, "OpenCode")
        XCTAssertEqual(NewSessionScreenModel.agentLabels["opencode"], "opencode")
    }
}
