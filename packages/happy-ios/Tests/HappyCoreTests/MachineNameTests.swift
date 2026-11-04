import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// A relay machine's name everywhere the app shows one (`MachineName`): the
/// person's `displayName`, then the Happy Agent's node name happy-cli's
/// daemon publishes (`happyAgent.nodeName`), then the host, then the
/// session's own host.
final class MachineNameTests: XCTestCase {
    private typealias Fixture = LegacyHomeFixtures

    private func machine(_ fields: [String: JSONValue], id: String = "m1") -> MachineRecord {
        var machine = Fixture.machine(id, active: true, name: "")
        machine.metadata = .object(fields)
        return machine
    }

    private let node: JSONValue = .object(["nodeName": .string("prep-pro")])

    func testTheOrder() {
        XCTAssertEqual(MachineName.named(.object(["displayName": .string("Studio"), "happyAgent": node, "host": .string("mac.local")])), "Studio")
        XCTAssertEqual(MachineName.named(.object(["displayName": .string(""), "happyAgent": node, "host": .string("mac.local")])), "prep-pro")
        XCTAssertEqual(MachineName.named(.object(["happyAgent": .object(["nodeName": .string("  ")]), "host": .string("mac.local")])), "mac.local")
        XCTAssertEqual(MachineName.named(.object(["happyAgent": .object(["nodeName": .string(" prep-air ")])])), "prep-air")
        // An older daemon publishes no happyAgent.
        XCTAssertEqual(MachineName.named(.object(["host": .string("mac.local")])), "mac.local")
        XCTAssertEqual(MachineName.named(.object(["happyAgent": .string("prep-pro"), "host": .string("mac.local")])), "mac.local")
        XCTAssertNil(MachineName.named(nil))
        XCTAssertNil(MachineName.named(.object([:])))
    }

    func testHomeRowsUseIt() {
        let session = Fixture.session("s1", machine: "m1", path: "/work", metadata: ["host": .string("session-host")])
        let named = machine(["displayName": .string("Studio"), "happyAgent": node, "host": .string("mac.local")])
        XCTAssertEqual(SessionList.hostName(session, machines: ["m1": named]), "Studio")
        let agent = machine(["happyAgent": node, "host": .string("mac.local")])
        XCTAssertEqual(SessionList.hostName(session, machines: ["m1": agent]), "prep-pro")
        XCTAssertEqual(SessionList.hostName(session, machines: [:]), "session-host")
    }

    func testMachinePickerAndMachineScreenUseIt() {
        let agent = machine(["happyAgent": node, "host": .string("mac.local")])
        XCTAssertEqual(MachineChoice.machineName(agent), "prep-pro")
        XCTAssertEqual(MachineChoice.computerName(happy: nil, rig: agent), "prep-pro")
        XCTAssertEqual(MachineChoice.machineName(machine(["displayName": .string("Studio"), "happyAgent": node])), "Studio")
        XCTAssertEqual(MachineChoice.machineName(machine([:])), "Unknown machine")

        let model = MachineDetailsModel(machine: agent, sessions: [])
        XCTAssertEqual(model.name, "prep-pro")
        XCTAssertEqual(model.displayName, "")
        XCTAssertEqual(model.hostPlaceholder, "prep-pro")
        XCTAssertEqual(model.host, "mac.local")
        let renamed = MachineDetailsModel(machine: machine(["displayName": .string("Studio"), "happyAgent": node, "host": .string("mac.local")]), sessions: [])
        XCTAssertEqual(renamed.name, "Studio")
        XCTAssertEqual(renamed.displayName, "Studio")
    }

    func testTheLinkRouteReadsTheSameNode() {
        XCTAssertEqual(LegacyLinkRoute.agentNodeName(machine(["happyAgent": node])), "prep-pro")
        // The name a relay chat's links match by is the one home shows.
        let session = Fixture.session("s1", machine: "m1", path: "/work")
        XCTAssertEqual(LegacyLinkRoute.machineName(session: session, machine: machine(["happyAgent": node, "host": .string("mac.local")])), "prep-pro")
    }
}
