#if canImport(UIKit)
import Foundation
@testable import HappyCore
import HappyLayout
import HappyStore
@testable import HappyUI
import HappyWire
import UIKit
import XCTest

/// The stopped-session hint while its computer is offline: why, then the
/// commands, with the longer words pushing them down rather than under.
@MainActor
final class ComputerRestartHintTests: XCTestCase {
    private func session() -> SessionRecord {
        SessionRecord(
            id: "s", seq: 1, createdAt: 1, updatedAt: 1, active: false, activeAt: 1, projectId: nil,
            metadataVersion: 1, metadataCipher: "c", metadata: .object(["machineId": .string("m1"), "claudeSessionId": .string("c-1"), "path": .string("/Users/a/repo")]),
            agentStateVersion: 1, agentStateCipher: nil, agentState: nil, dataKeyCipher: "k", decryptable: true
        )
    }

    private func machine(active: Bool) -> MachineRecord {
        MachineRecord(
            id: "m1", seq: 0, createdAt: 1, updatedAt: 1, active: active, activeAt: 1,
            metadataVersion: 1, metadataCipher: "c", metadata: .object(["resumeSupport": .object(["rpcAvailable": .bool(true)])]),
            daemonStateVersion: 0, daemonStateCipher: nil, daemonState: nil, dataKeyCipher: "k", decryptable: true
        )
    }

    func testTheNoticeSaysTheComputerIsOfflineOnlyWhenItIs() throws {
        let offline = try XCTUnwrap(InactiveSessionHint(session: session(), machine: machine(active: false)))
        XCTAssertEqual(ChatInactiveHintView.notice(offline), Strings.SessionResume.machineOffline)
        let online = try XCTUnwrap(InactiveSessionHint(session: session(), machine: machine(active: true)))
        XCTAssertEqual(ChatInactiveHintView.notice(online), Strings.Chat.inactiveArchived)
    }

    func testTheLongerNoticePushesTheCommandsDown() async throws {
        let environment = UITraitCollection(preferredContentSizeCategory: .large).measuredTextEnvironment
        func plan(_ notice: String) async -> ChatInactiveHintPlan {
            await Task.detached {
                ChatDockBarMeasure.inactiveHint(ChatDockBarInput(
                    model: ChatInactiveHintModel(notice: notice, terminalNotice: Strings.Chat.resumeFromTerminal, action: .command("happy claude --resume c-1")),
                    width: 361, text: environment
                ))
            }.value
        }
        let short = await plan(Strings.Chat.inactiveArchived)
        let long = await plan(Strings.SessionResume.machineOffline)
        XCTAssertGreaterThan(long.layout.notice.height, short.layout.notice.height, "it wraps")
        let terminal = try XCTUnwrap(long.layout.terminalNotice)
        XCTAssertGreaterThanOrEqual(terminal.minY, long.layout.notice.maxY)
        XCTAssertGreaterThan(long.layout.size.height, short.layout.size.height)
    }
}
#endif
