import Foundation
import XCTest
import HappyCrypto
import HappyStore
import HappyWire
@testable import HappyCore

/// A computer that went away without a word (power, a crash, a reboot that
/// took its agents with it), from the phone's side: what it looks like, and
/// getting going again.
final class ComputerRestartPresenceTests: XCTestCase {
    private let tickStep: Int64 = 15_000

    private func machineRecord(active: Bool = true, activeAt: Int64) -> MachineRecord {
        MachineRecord(
            id: "m1", seq: 0, createdAt: 1, updatedAt: 1, active: active, activeAt: activeAt,
            metadataVersion: 1, metadataCipher: "c", metadata: ["resumeSupport": ["rpcAvailable": .bool(true)]],
            daemonStateVersion: 0, daemonStateCipher: nil, daemonState: nil, dataKeyCipher: "k", decryptable: true
        )
    }

    private func fixture(metadata: JSONValue? = nil, thinking: Bool = false) throws -> (LocalStore, LegacySyncEngineTests.Clock, SessionPresence) {
        let store = try LocalStore.inMemory()
        let clock = LegacySyncEngineTests.Clock()
        clock.now = 1_000_000
        var session = ChatRecords.storeSession(metadata: metadata)
        session.active = true
        session.activeAt = clock.now
        session.thinking = thinking
        try store.upsertSessions([session])
        try store.upsertMachine(machineRecord(activeAt: clock.now))
        return (store, clock, SessionPresence(store: store, now: { clock.now }))
    }

    /// Ticks as its timer does, so nothing reads as the process being suspended.
    private func pass(_ ms: Int64, _ clock: LegacySyncEngineTests.Clock, _ presence: SessionPresence) async {
        var left = ms
        while left > 0 {
            let step = min(left, tickStep)
            clock.now += step
            left -= step
            await presence.tick()
        }
    }

    func testASilentSessionStopsAfterTheLimitAndItsNextBeatBringsItBack() async throws {
        let (store, clock, presence) = try fixture(thinking: true)
        await presence.tick()
        await presence.setListening(true)
        await presence.activity(id: "s", active: true, activeAt: clock.now, thinking: true)

        await pass(75_000, clock, presence)
        XCTAssertEqual(try store.session(id: "s")?.active, true, "still inside the limit")

        await pass(15_000, clock, presence)
        let stopped = try XCTUnwrap(store.session(id: "s"))
        XCTAssertFalse(stopped.active)
        XCTAssertFalse(stopped.thinking, "a dead agent is not thinking")
        XCTAssertEqual(SessionState(stopped), .disconnected)

        await presence.activity(id: "s", active: true, activeAt: clock.now, thinking: false)
        XCTAssertEqual(try store.session(id: "s")?.active, true)
    }

    func testABeatingSessionNeverStops() async throws {
        let (store, clock, presence) = try fixture()
        await presence.tick()
        await presence.setListening(true)
        for _ in 0..<20 {
            await pass(tickStep, clock, presence)
            await presence.activity(id: "s", active: true, activeAt: clock.now, thinking: false)
            await presence.machineActivity(id: "m1", active: true, activeAt: clock.now)
        }
        XCTAssertEqual(try store.session(id: "s")?.active, true)
        XCTAssertEqual(try store.machine(id: "m1")?.active, true)
    }

    func testSilenceOnlyCountsWhileTheSocketIsUp() async throws {
        let (store, clock, presence) = try fixture()
        await pass(600_000, clock, presence)
        XCTAssertEqual(try store.session(id: "s")?.active, true, "never listening: the server's word stands")

        await presence.setListening(true)
        await pass(75_000, clock, presence)
        XCTAssertEqual(try store.session(id: "s")?.active, true, "the wait starts when listening does")

        await presence.setListening(false)
        await pass(600_000, clock, presence)
        XCTAssertEqual(try store.session(id: "s")?.active, true, "the socket is down")

        await presence.setListening(true)
        await pass(75_000, clock, presence)
        XCTAssertEqual(try store.session(id: "s")?.active, true, "and starts over when it returns")
        await pass(15_000, clock, presence)
        XCTAssertEqual(try store.session(id: "s")?.active, false)
    }

    func testAPhoneWakingFromSuspensionDoesNotCountWhatItMissed() async throws {
        let (store, clock, presence) = try fixture()
        await presence.setListening(true)
        await presence.tick()

        // The socket still reads as up; the timer simply didn't run.
        clock.now += 3_600_000
        await presence.tick()
        XCTAssertEqual(try store.session(id: "s")?.active, true)

        await pass(75_000, clock, presence)
        XCTAssertEqual(try store.session(id: "s")?.active, true)
        await pass(15_000, clock, presence)
        XCTAssertEqual(try store.session(id: "s")?.active, false)
    }

    func testChatsWhoseBeatsDontReachThisAccountAreLeftToTheServer() async throws {
        for metadata: JSONValue in [["client": ["id": "rig"]], ["task": ["canArchive": .bool(false)]]] {
            let (store, clock, presence) = try fixture(metadata: metadata)
            await presence.tick()
            await presence.setListening(true)
            await pass(600_000, clock, presence)
            XCTAssertEqual(try store.session(id: "s")?.active, true, "\(metadata)")
        }
    }

    func testAMachineGoesOfflineAndTheHintFollowsItBothWaysLive() async throws {
        let claude: JSONValue = ["machineId": "m1", "claudeSessionId": "c-1", "path": "/Users/a/repo"]
        let (store, clock, presence) = try fixture(metadata: claude)
        var session = try XCTUnwrap(store.session(id: "s"))
        session.active = false
        session.updatedAt += 1
        try store.upsertSessions([session])
        await presence.tick()
        await presence.activity(id: "s", active: false, activeAt: clock.now, thinking: false)

        let home = HomeFeed(store: store).snapshots()
        let first = try await syncPerfNext(home)
        XCTAssertEqual(try XCTUnwrap(hint(first)).action, .resume)

        await presence.setListening(true)
        await pass(90_000, clock, presence)
        var offline = hint(try await syncPerfNext(home))
        while offline?.machineOffline != true { offline = hint(try await syncPerfNext(home)) }
        XCTAssertEqual(offline?.action, .command(lines: ["cd '/Users/a/repo'", "happy claude --resume c-1"]))

        await presence.machineActivity(id: "m1", active: true, activeAt: clock.now)
        var back = hint(try await syncPerfNext(home))
        while back?.machineOffline != false { back = hint(try await syncPerfNext(home)) }
        XCTAssertEqual(back?.action, .resume)
    }

    private func hint(_ snapshot: LegacyHomeSnapshot?) -> InactiveSessionHint? {
        guard let snapshot else { return nil }
        let state = ChatSessionState(snapshot, sessionId: "s", now: 1)
        return InactiveSessionHint(session: state.record, machine: state.machine)
    }
}

final class ComputerRestartHintTests: XCTestCase {
    private func session(metadata: JSONValue) -> SessionRecord {
        var record = ChatRecords.storeSession(metadata: metadata)
        record.active = false
        return record
    }

    private func machine(active: Bool) -> MachineRecord {
        MachineRecord(
            id: "m1", seq: 0, createdAt: 1, updatedAt: 1, active: active, activeAt: 1,
            metadataVersion: 1, metadataCipher: "c", metadata: ["resumeSupport": ["rpcAvailable": .bool(true)]],
            daemonStateVersion: 0, daemonStateCipher: nil, daemonState: nil, dataKeyCipher: "k", decryptable: true
        )
    }

    private let claude: JSONValue = ["machineId": "m1", "claudeSessionId": "c-1", "path": "/Users/a/repo"]

    func testOnlyAnOfflineMachineIsGivenAsTheReason() {
        XCTAssertEqual(InactiveSessionHint(session: session(metadata: claude), machine: machine(active: false))?.machineOffline, true)
        XCTAssertEqual(InactiveSessionHint(session: session(metadata: claude), machine: machine(active: true))?.machineOffline, false)
        XCTAssertEqual(InactiveSessionHint(session: session(metadata: claude), machine: nil)?.machineOffline, false, "a machine this phone hasn't heard of")
        XCTAssertEqual(InactiveSessionHint(session: session(metadata: ["machineId": "m1"]), machine: machine(active: false))?.machineOffline, false, "nothing to resume anyway")
    }
}

final class ResumeProgressTests: XCTestCase {
    func testItSpinsFromTheTapUntilTheAgentIsBack() {
        var progress = ResumeProgress()
        XCTAssertFalse(progress.isSpinning)
        XCTAssertTrue(progress.begin())
        XCTAssertFalse(progress.begin(), "one at a time")
        XCTAssertTrue(progress.isSpinning)
        progress.machineAnswered()
        XCTAssertTrue(progress.isSpinning, "the machine answers before the agent's first heartbeat")
        XCTAssertFalse(progress.begin())
        XCTAssertTrue(progress.agentCameBack())
        XCTAssertFalse(progress.isSpinning)
        XCTAssertTrue(progress.begin(), "and it can be resumed again another day")
    }

    func testTheHintGoingBeforeTheMachineAnswersDoesNotEndTheAsk() {
        var progress = ResumeProgress()
        _ = progress.begin()
        XCTAssertFalse(progress.agentCameBack())
        XCTAssertTrue(progress.isSpinning)
    }

    func testFailingOrTheAgentNeverComingGivesResumeBack() {
        var progress = ResumeProgress()
        _ = progress.begin()
        progress.finished()
        XCTAssertFalse(progress.isSpinning)
        _ = progress.begin()
        progress.machineAnswered()
        progress.finished()
        XCTAssertFalse(progress.isSpinning)
        XCTAssertFalse(progress.agentCameBack())
    }

    func testAResumeThatFoundNoDaemonSaysTheMachineIsOffline() {
        for message in ["RPC method not available", "RPC target disconnected"] {
            XCTAssertEqual(ResumeProgress.failureText(message, machineOffline: "offline"), "offline")
        }
        let daemon = "The folder /tmp/x is no longer on this computer, so this session cannot be resumed there."
        XCTAssertEqual(ResumeProgress.failureText(daemon, machineOffline: "offline"), daemon)
    }
}

final class ComputerRestartResumeActionTests: XCTestCase {
    struct NoMetadata: MetadataUpdateTransport {
        func updateMetadata(event: String, payload: JSONValue) async throws -> JSONValue { .null }
    }

    func testResumingAMachineWithNoDaemonAlertsThatItIsOffline() async throws {
        let fixture = ServerFixture()
        let http = FakeHTTP()
        let store = try LocalStore.inMemory()
        let engine = LegacySyncEngine(api: testAPI(http), store: store, keys: fixture.keys)
        let rpc = FakeRPC()
        rpc.answer = { _ in RPCCallResult(ok: false, error: "RPC method not available") }
        let sessions = SessionActions(api: testAPI(http), store: store, sync: engine, rpc: rpc, now: { 500 })
        let machines = MachineActions(api: testAPI(http), store: store, sync: engine, rpc: rpc, metadataTransport: NoMetadata())
        let actions = SessionDetailActions(sessions: sessions, machines: machines, store: store, sync: engine, metadataTransport: NoMetadata())

        var record = RecordDecoder(keyRing: KeyRing(keys: fixture.keys)).session(fixture.session("s", updatedAt: 1))
        record.active = false
        record.metadata = ["machineId": "m", "claudeSessionId": "c-1", "path": "/repo"]
        try store.upsertSessions([record])
        // The stale row of a machine that just went away: still reads online.
        let machine = MachineRecord(
            id: "m", seq: 0, createdAt: 1, updatedAt: 1, active: true, activeAt: 1, metadataVersion: 1,
            metadataCipher: "", metadata: ["resumeSupport": ["rpcAvailable": .bool(true)]], daemonStateVersion: 0,
            daemonStateCipher: nil, daemonState: nil,
            dataKeyCipher: Base64.encode(try fixture.keys.wrapDataKey(Data(repeating: 21, count: 32))), decryptable: true
        )
        try store.upsertMachine(machine)
        let messages = SessionDetailActions.ResumeMessages(
            missingMachine: "no machine", missingBackendId: "no id", sameMachineOnly: "same", machineOffline: "offline", unexpectedDirectoryPrompt: "dir"
        )
        do {
            _ = try await actions.resume(try XCTUnwrap(store.session(id: "s")), machine: machine, settings: nil, composer: .object([:]), messages: messages)
            XCTFail("expected an error")
        } catch let failure as SessionDetailActions.Failure {
            XCTAssertEqual(failure.message, "offline")
        }
        await engine.stop()
    }
}

final class SessionResumeStringsTests: XCTestCase {
    private let key = "native.sessionResume.machineOffline"

    override func setUp() async throws {
        for language in AppLanguage.supported.map(\.code) { _ = await TranslationCatalog.load(language) }
    }

    func testEveryLanguageSaysItItsOwnWayAndKeepsTheProductsName() {
        let english = TranslationCatalog.nativeSources["en"]?[key]
        for language in AppLanguage.supported.map(\.code) {
            let text = TranslationCatalog.catalog(for: language)(key)
            XCTAssertNotEqual(text, key, language)
            XCTAssertTrue(text.contains("Happy CLI"), language)
            if language != "en" { XCTAssertNotEqual(text, english, language) }
        }
    }
}
