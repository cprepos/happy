import Foundation
import HappyStore
import HappyWire
import XCTest
@testable import HappyCore

/// The daemon ignores spawn modes for OpenCode (spawnModeArgs.ts forwards them
/// for Claude and Codex only), so the first message's `meta.permissionMode` is
/// the only way a phone's pick reaches the agent.
final class OpencodeFirstMessageTests: XCTestCase {
    private func machine() -> MachineRecord {
        MachineRecord(
            id: "m1", seq: 0, createdAt: 1, updatedAt: 1, active: true, activeAt: 1,
            metadataVersion: 1, metadataCipher: "c",
            metadata: .object([
                "displayName": .string("prep-ml"),
                "homeDir": .string("/home/steve"),
                "happyCliVersion": .string("1.3.0"),
                "cliAvailability": .object(["claude": .bool(true), "opencode": .bool(true)]),
            ]),
            daemonStateVersion: 0, daemonStateCipher: nil, daemonState: nil, dataKeyCipher: "k", decryptable: true
        )
    }

    /// The launch a phone makes, its modes pinned as `SessionStarter` pins
    /// them, and the message `LegacySyncEngine.accept` encodes from the pin.
    private func firstMessageMeta(pick: String?, overrides: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        let draft = NewSessionDraft(
            selectedMachineId: "m1", selectedPath: "/home/steve/happy",
            agentType: .opencode, pickedAgentType: .opencode, permissionMode: pick
        )
        let launch = try NewSessionLaunch.resolve(
            draft: draft, pickedAgent: .opencode, machines: [machine()], sessions: [],
            agentDefaultOverrides: overrides, prompt: "hello", attachments: []
        ).get()
        XCTAssertEqual(launch.agent, .opencode)
        XCTAssertFalse(launch.isRig, "SessionStarter pins only Happy CLI sessions")

        let fixture = ServerFixture()
        let store = try LocalStore.inMemory()
        let sync = LegacySyncEngine(api: testAPI(FakeHTTP()), store: store, keys: fixture.keys, now: { 100 })
        await sync.setBackgrounded(true)
        var session = RecordDecoder(keyRing: KeyRing(keys: fixture.keys)).session(fixture.session("s", updatedAt: 1))
        session.metadata = .object(["flavor": .string("opencode"), "version": .string("1.3.0"), "machineId": .string("m1")])
        try store.upsertSessions([session], reconcileComposer: sync.modePushes.reconciliation)
        let files = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sender = OutboxSender(store: store, sync: sync, filesDirectory: files)

        try await sender.saveInitialModes(sessionId: "s", patch: SessionAgentModesPatch(
            permissionMode: .string(launch.permissionMode),
            modelMode: .string(launch.modelMode),
            effortLevel: launch.effortLevel.map(JSONValue.string) ?? .null
        ))
        let encoded = try UserMessageEncoder.encode(
            OutgoingMessage(text: launch.prompt, source: .newSession),
            session: session,
            composer: store.composerState(sessionId: "s").values,
            settings: .object(["agentDefaultOverrides": .object(overrides)])
        )
        await sync.stop()
        return try XCTUnwrap(encoded["meta"]?.objectValue)
    }

    func testAPhoneThatPicksAskSendsAsk() async throws {
        let meta = try await firstMessageMeta(pick: "build:ask")
        XCTAssertEqual(meta["permissionMode"], .string("build:ask"))
    }

    func testAPhoneThatPicksAutoSendsAuto() async throws {
        let meta = try await firstMessageMeta(pick: "build:auto")
        XCTAssertEqual(meta["permissionMode"], .string("build:auto"))
    }

    func testThePlanAgentTravelsWithItsPolicy() async throws {
        let meta = try await firstMessageMeta(pick: "plan:ask")
        XCTAssertEqual(meta["permissionMode"], .string("plan:ask"))
    }

    func testNoPickSendsTheHarnessDefault() async throws {
        let meta = try await firstMessageMeta(pick: nil)
        XCTAssertEqual(meta["permissionMode"], .string("build:auto"))
    }

    func testASavedOpencodeDefaultIsWhatTheFirstMessageCarries() async throws {
        let saved: [String: JSONValue] = ["opencode": .object(["permissionMode": .string("plan:ask")])]
        let meta = try await firstMessageMeta(pick: nil, overrides: saved)
        XCTAssertEqual(meta["permissionMode"], .string("plan:ask"))
    }

    func testAClaudeDefaultDoesNotReachIt() async throws {
        let saved: [String: JSONValue] = ["claude": .object(["permissionMode": .string("plan")])]
        let meta = try await firstMessageMeta(pick: nil, overrides: saved)
        XCTAssertEqual(meta["permissionMode"], .string("build:auto"))
    }

    /// OpenCode lists its models over ACP, so the phone asks for none.
    func testTheModelStaysTheAgents() async throws {
        let meta = try await firstMessageMeta(pick: "build:ask")
        XCTAssertEqual(meta["model"], .null)
        XCTAssertNil(meta["effort"])
    }
}
