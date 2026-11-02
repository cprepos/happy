import HappyStore
import HappyWire
import XCTest
@testable import HappyCore

/// resumeCommand.ts and useSessionQuickActions.ts for the harnesses that keep
/// their conversation under their own key: OpenCode and Antigravity.
final class HarnessResumeTests: XCTestCase {
    private let resumable: [String: JSONValue] = ["resumeSupport": .object(["rpcAvailable": .bool(true)])]

    private func session(_ metadata: [String: JSONValue], active: Bool = false) -> SessionRecord {
        SessionRecord(
            id: "s", seq: 7, createdAt: 1, updatedAt: 1, active: active, activeAt: 1, projectId: nil,
            metadataVersion: 1, metadataCipher: "c", metadata: .object(metadata),
            agentStateVersion: 0, agentStateCipher: nil, agentState: nil, dataKeyCipher: "k", decryptable: true
        )
    }

    private func machine(active: Bool = true) -> MachineRecord {
        MachineRecord(
            id: "m1", seq: 0, createdAt: 1, updatedAt: 1, active: active, activeAt: 5,
            metadataVersion: 3, metadataCipher: "c", metadata: .object(resumable),
            daemonStateVersion: 2, daemonStateCipher: nil, daemonState: nil, dataKeyCipher: "k", decryptable: true
        )
    }

    private let opencode: [String: JSONValue] = ["flavor": .string("opencode"), "machineId": .string("m1"), "opencodeSessionId": .string("ses_1")]
    private let agy: [String: JSONValue] = ["flavor": .string("agy"), "machineId": .string("m1"), "agyConversationId": .string("conv_1")]

    func testOpenCodesCommand() {
        XCTAssertEqual(SessionDetails.resumeCommand(.object(opencode)), "happy opencode --resume ses_1")
        XCTAssertEqual(
            SessionDetails.resumeCommand(.object(opencode.merging(["path": .string("/w")]) { _, new in new })),
            "cd '/w' && happy opencode --resume ses_1"
        )
    }

    func testAntigravitysCommand() {
        XCTAssertEqual(SessionDetails.resumeCommand(.object(agy)), "happy agy --resume conv_1")
    }

    func testAnIdOnlyCountsForItsOwnFlavor() {
        XCTAssertNil(SessionDetails.resumeCommand(.object(["flavor": .string("codex"), "opencodeSessionId": .string("ses_1")])))
        XCTAssertNil(SessionDetails.resumeCommand(.object(["flavor": .string("claude"), "agyConversationId": .string("conv_1")])))
        XCTAssertNil(SessionDetails.resumeCommand(.object(["flavor": .string("opencode")])))
    }

    func testTheHarnessesOwnIdWinsOverAClaudeOne() {
        let both = opencode.merging(["claudeSessionId": .string("c1")]) { _, new in new }
        XCTAssertEqual(SessionDetails.resumeCommand(.object(both)), "happy opencode --resume ses_1")
    }

    func testAnEmptyIdIsNoId() {
        XCTAssertNil(SessionDetails.resumeCommand(.object(["flavor": .string("opencode"), "opencodeSessionId": .string("")])))
    }

    func testResumeIsOfferedOnAnOnlineComputer() {
        for metadata in [opencode, agy] {
            XCTAssertEqual(SessionDetails.resumeAvailability(session(metadata), machine: machine()), .available)
            XCTAssertEqual(SessionDetails.resumeAvailability(session(metadata), machine: machine(active: false)), .machineOffline)
            XCTAssertEqual(SessionDetails.resumeAvailability(session(metadata, active: true), machine: machine()), .hidden)
        }
    }

    func testResumeWithoutTheIdSaysSo() {
        let noId: [String: JSONValue] = ["flavor": .string("opencode"), "machineId": .string("m1")]
        XCTAssertEqual(SessionDetails.resumeAvailability(session(noId), machine: machine()), .missingBackendId)
    }

    func testTheQuickActionsAgree() {
        for metadata in [opencode, agy] {
            let resume = SessionQuickActions.Resume(session: session(metadata), machine: machine())
            XCTAssertTrue(resume.canResume)
            XCTAssertNil(resume.blocker)
        }
        let noId: [String: JSONValue] = ["flavor": .string("opencode"), "machineId": .string("m1")]
        XCTAssertEqual(SessionQuickActions.Resume(session: session(noId), machine: machine()).blocker, .missingBackendId)
    }

    /// Fork is Claude's and Codex's; OpenCode has no fork source.
    func testAnOpencodeSessionHasNoForkSource() {
        var metadata = opencode
        metadata["path"] = .string("/w")
        XCTAssertNil(SessionDetails.forkSource(session(metadata)))
    }
}
