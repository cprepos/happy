import Foundation
import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// Claude Desktop as a harness (docs/plans/happyify-desktop-sync.md,
/// "Contract"): offered only where a computer reports it, named by
/// `metadata.harness` before the flavor, with no pickers and no resume.
final class ClaudeDesktopHarnessTests: XCTestCase {
    private func machine(_ id: String, active: Bool = true, cli: [String: JSONValue]? = ["claude": .bool(true)], extra: [String: JSONValue] = [:]) -> MachineRecord {
        var values: [String: JSONValue] = ["displayName": .string(id), "homeDir": .string("/Users/steve")]
        if let cli { values["cliAvailability"] = .object(cli) }
        values.merge(extra) { _, new in new }
        return MachineRecord(
            id: id, seq: 0, createdAt: 1, updatedAt: 1, active: active, activeAt: 1,
            metadataVersion: 1, metadataCipher: "c", metadata: .object(values),
            daemonStateVersion: 0, daemonStateCipher: nil, daemonState: nil, dataKeyCipher: "k", decryptable: true
        )
    }

    private func session(_ metadata: [String: JSONValue], active: Bool = false, thinking: Bool = false) -> SessionRecord {
        SessionRecord(
            id: "s", seq: 7, createdAt: 1, updatedAt: 1, active: active, activeAt: 1, projectId: nil,
            metadataVersion: 1, metadataCipher: "c", metadata: .object(metadata),
            agentStateVersion: 0, agentStateCipher: nil, agentState: nil, dataKeyCipher: "k", decryptable: true,
            thinking: thinking
        )
    }

    private func choice(_ machine: MachineRecord) throws -> MachineChoice {
        try XCTUnwrap(MachineChoice.collect([machine]).first)
    }

    /// What the plugin's mirror publishes.
    private let desktop: [String: JSONValue] = [
        "flavor": .string("claude"),
        "harness": .string("claude-desktop"),
        "machineId": .string("m1"),
        "claudeSessionId": .string("c1"),
        "version": .string("1.2.6"),
    ]

    // MARK: Catalog

    func testNameAndOrderSitStraightAfterClaudeCode() throws {
        XCTAssertEqual(HarnessCatalog.name("claude-desktop"), "Claude Desktop")
        XCTAssertEqual(MachineChoice.agentOrder, ["claude", "claude-desktop", "codex", "agy", "opencode", "rig"])
        XCTAssertEqual(ClaudeDesktopHarness.placed(in: ["codex", "rig"]), ["claude-desktop", "codex", "rig"])
        let everything = try choice(machine("m", cli: [
            "claude": .bool(true), "claude-desktop": .bool(true), "codex": .bool(true), "opencode": .bool(true),
        ]))
        XCTAssertEqual(everything.availableAgents, ["claude", "claude-desktop", "codex", "opencode"])
    }

    func testOfferedOnlyWhenTheMachineSaysTheAppIsRunning() throws {
        XCTAssertFalse(try choice(machine("silent", cli: nil)).agentAvailable("claude-desktop"))
        XCTAssertFalse(try choice(machine("older", cli: ["claude": .bool(true)])).agentAvailable("claude-desktop"))
        XCTAssertFalse(try choice(machine("closed", cli: ["claude-desktop": .bool(false)])).agentAvailable("claude-desktop"))
        XCTAssertTrue(try choice(machine("open", cli: ["claude-desktop": .bool(true)])).agentAvailable("claude-desktop"))
    }

    func testTheNewSessionComposerOffersItWithNoPickers() {
        let machines = [machine("m1", cli: ["claude": .bool(true), "claude-desktop": .bool(true)])]
        let draft = NewSessionDraft(selectedMachineId: "m1", agentType: .claudeDesktop, pickedAgentType: .claudeDesktop)
        let choices = NewSessionChoices(NewSessionChoices.Inputs(draft: draft, machines: machines, sessions: []))
        XCTAssertEqual(choices.agentOptions.map(\.key), ["claude", "claude-desktop"])
        XCTAssertEqual(choices.agentOptions.last?.name, "Claude Desktop")
        XCTAssertEqual(choices.resolvedAgent, .claudeDesktop)
        XCTAssertTrue(choices.permissionOptions.isEmpty)
        XCTAssertTrue(choices.modelOptions.isEmpty)
        XCTAssertTrue(choices.effortOptions.isEmpty)
        XCTAssertEqual(choices.modelChipLabel, "Claude Desktop")
        XCTAssertEqual(choices.promptPlaceholder, "Ask Claude Desktop")
        let chips = ComposerChipSet(choices: choices, titles: Self.titles)
        XCTAssertNil(chips.permission)
        XCTAssertNil(chips.model.sections)
        XCTAssertNil(chips.effort)
    }

    func testThePickDoesNotFollowToAComputerWithoutIt() {
        let machines = [machine("m1", cli: ["claude": .bool(true), "claude-desktop": .bool(false)])]
        let draft = NewSessionDraft(selectedMachineId: "m1", agentType: .claudeDesktop, pickedAgentType: .claudeDesktop)
        let choices = NewSessionChoices(NewSessionChoices.Inputs(draft: draft, machines: machines, sessions: []))
        XCTAssertEqual(choices.agentOptions.map(\.key), ["claude"])
        XCTAssertEqual(choices.resolvedAgent, .claude)
    }

    func testDefaultsAskForNothingAndSettingsDoNotListIt() {
        let config = AgentDefaults.resolve([:], .claudeDesktop, cliVersion: nil)
        XCTAssertEqual(config, AgentDefaults.Config(permissionMode: "default", modelMode: "default", effortLevel: nil))
        XCTAssertTrue(AgentDefaults.permissionModes(.claudeDesktop).isEmpty)
        XCTAssertTrue(AgentDefaults.modelModes(.claudeDesktop, configured: nil).isEmpty)
        XCTAssertFalse(AgentDefaults.Agent.configurable.contains(.claudeDesktop))
        XCTAssertEqual(NewSessionDraft.Agent.claudeDesktop.rawValue, "claude-desktop")
        XCTAssertEqual(NewSessionDraft.Agent.claudeDesktop.name, "Claude Desktop")
        XCTAssertEqual(NewSessionScreenModel.agentLabels["claude-desktop"], "claude desktop")
    }

    // MARK: A session

    func testTheHarnessFieldNamesItBeforeTheFlavor() {
        XCTAssertEqual(SessionAvatar.harness(flavor: "claude", clientId: nil, harness: "claude-desktop"), .claudeDesktop)
        XCTAssertEqual(SessionAvatar.harness(flavor: "claude", clientId: nil), .claude)
        XCTAssertEqual(SessionAvatar.harness(flavor: "claude", clientId: "rig", harness: "claude-desktop"), .rig)
        XCTAssertEqual(SessionDetails.harness(.object(desktop)), "Claude Desktop")
        XCTAssertEqual(SessionDetails.harness(.object(["flavor": .string("claude")])), "Claude Code")
        let settings = AccountSettings(["showHarnessIconInSessionHeader": .bool(true)])
        XCTAssertEqual(SessionInfoModel.avatar(session(desktop), settings: settings).harness, .claudeDesktop)
    }

    func testTheComposerOffersNoModelPermissionOrEffort() {
        let record = session(desktop, active: true)
        let modes = ComposerModes(metadata: record.metadata, picks: ComposerPicks(permissionMode: "plan"), agentDefaultOverrides: [:])
        XCTAssertTrue(modes.availableModes.isEmpty)
        XCTAssertTrue(modes.availableModels.isEmpty)
        XCTAssertTrue(modes.availableEffortLevels.isEmpty)
        let chips = ComposerChipSet(modes: modes, record: record, titles: Self.titles)
        XCTAssertNil(chips.permission)
        XCTAssertNil(chips.effort)
        XCTAssertNil(chips.model.sections, "the chip names the harness and does not open")
        XCTAssertEqual(chips.model.label, "Claude Desktop")
        XCTAssertFalse(chips.showsSettings)
        XCTAssertTrue(chips.settings.isEmpty)
    }

    func testNoStopButSendsAreNotBlocked() {
        // The CLI publishes no capabilities for these sessions: the harness
        // alone hides Stop.
        let thinking = session(desktop, active: true, thinking: true)
        XCTAssertFalse(SessionComposerRules.canAbortAgent(thinking.metadata))
        XCTAssertFalse(SessionComposerRules.showsAbortButton(thinking))
        XCTAssertFalse(SessionComposerRules.canAbort(thinking))
        XCTAssertFalse(SessionComposerRules.isSendBlocked(thinking))
        XCTAssertFalse(SessionComposerRules.canUseAttachments(thinking))
        XCTAssertFalse(SessionComposerRules.canUseAttachments(starting: .claudeDesktop))
        // A Claude Code session keeps its Stop.
        var claude = desktop
        claude.removeValue(forKey: "harness")
        XCTAssertTrue(SessionComposerRules.showsAbortButton(session(claude, active: true, thinking: true)))
    }

    func testAnyOtherSessionThatSaysItCannotAbortHasNoStop() {
        let metadata: JSONValue = .object(["flavor": .string("claude"), "capabilities": .object(["abort": .bool(false)])])
        XCTAssertFalse(SessionComposerRules.canAbortAgent(metadata))
        XCTAssertTrue(SessionComposerRules.canAbortAgent(.object(["flavor": .string("claude")])))
    }

    func testAMidTurnSendSaysItSendsAfterThisTurn() throws {
        let message = OutgoingMessage(text: "next", displayText: nil, source: .chat)
        let busy = try UserMessageEncoder.encode(message, session: session(desktop, active: true, thinking: true))
        XCTAssertEqual(busy["meta"]?["queuedWhileBusy"], .bool(true))
        let idle = try UserMessageEncoder.encode(message, session: session(desktop, active: true))
        XCTAssertEqual(idle["meta"]?["queuedWhileBusy"], .bool(false))
        let first = OutgoingMessage(text: "go", displayText: nil, source: .newSession)
        XCTAssertEqual(try UserMessageEncoder.encode(first, session: session(desktop, active: true, thinking: true))["meta"]?["queuedWhileBusy"], .bool(false))
        // Claude Code's sends are unchanged.
        var claude = desktop
        claude.removeValue(forKey: "harness")
        XCTAssertNil(try UserMessageEncoder.encode(message, session: session(claude, active: true, thinking: true))["meta"]?["queuedWhileBusy"])
        XCTAssertEqual(
            UserMessageStatus(pending: true, undelivered: false, queuedWhileBusy: true, createdAt: 0, failure: nil, now: 0).line,
            .sendsAfterThisTurn
        )
    }

    func testTheMirrorsPidIsNotShownAsTheAgents() {
        var withPid = desktop
        withPid["hostPid"] = .number(4242)
        let model = SessionInfoModel(session: session(withPid), machine: nil, settings: AccountSettings(), gitStatus: nil, permissionMode: nil)
        XCTAssertNil(model.metadata?.processId)
        var claude = withPid
        claude.removeValue(forKey: "harness")
        let claudeModel = SessionInfoModel(session: session(claude), machine: nil, settings: AccountSettings(), gitStatus: nil, permissionMode: nil)
        XCTAssertEqual(claudeModel.metadata?.processId, "4242")
    }

    /// An archived desktop chat resumes from the app: the daemon reopens it
    /// in Claude Desktop. There is still no terminal command to copy.
    func testResumesThroughTheDesktopButHasNoTerminalCommand() {
        let resumable = machine("m1", extra: ["resumeSupport": .object(["rpcAvailable": .bool(true)])])
        XCTAssertNil(SessionDetails.resumeCommand(.object(desktop)))
        XCTAssertEqual(SessionDetails.resumeAvailability(session(desktop), machine: resumable), .available)
        let resume = SessionQuickActions.Resume(session: session(desktop), machine: resumable)
        XCTAssertTrue(resume.canResume)
        XCTAssertTrue(resume.canShowResume)
        // The same session without the harness field resumes as Claude Code.
        var claude = desktop
        claude.removeValue(forKey: "harness")
        XCTAssertEqual(SessionDetails.resumeCommand(.object(claude)), "happy claude --resume c1")
    }

    func testTheMachineScreenRowFollowsTheReport() {
        let reported = MachineDetailsModel(machine: machine("m", cli: ["claude": .bool(true), "claude-desktop": .bool(true)]), sessions: [])
        XCTAssertEqual(reported.cliAvailability?.claudeDesktop, true)
        XCTAssertNil(MachineDetailsModel(machine: machine("m"), sessions: []).cliAvailability?.claudeDesktop)
    }

    private static let titles = ComposerChipSet.Titles(
        permission: "PERMISSION MODE", codexPermission: "CODEX PERMISSION MODE",
        geminiPermission: "GEMINI PERMISSION MODE", model: "MODEL", effort: "EFFORT"
    )
}
