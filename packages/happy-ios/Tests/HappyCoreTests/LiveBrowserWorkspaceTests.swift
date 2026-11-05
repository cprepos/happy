import XCTest
@testable import HappyCore

final class LiveBrowserWorkspaceTests: XCTestCase {
    private func host(_ id: String, _ hostname: String? = nil, machine: String? = nil, status: String = "active", runner: String? = nil) -> BrowserHostWorkspaces.Workspace {
        .init(id: id, status: status, compute: .init(type: "host", runnerId: runner, machineId: machine, hostname: hostname))
    }

    func testOneHostWorkspaceIsTheOne() {
        let list = BrowserHostWorkspaces(workspaces: [host("w1"), host("r1", runner: "x"), host("old", status: "stopped")])
        XCTAssertEqual(list.pick(machine: nil), "w1")
        XCTAssertEqual(list.pick(machine: BrowserMachineHint(hosts: ["elsewhere"])), "w1")
    }

    func testNoHostWorkspaceIsNone() {
        let list = BrowserHostWorkspaces(workspaces: [host("r1", runner: "x"), .init(id: "c", status: "active", compute: .init(type: "cloud"))])
        XCTAssertNil(list.pick(machine: nil))
    }

    func testSeveralPickTheChatsMachine() {
        let list = BrowserHostWorkspaces(workspaces: [host("a", "prep-pro.local"), host("b", "Prep-Air"), host("c", machine: "m-9")])
        XCTAssertEqual(list.pick(machine: BrowserMachineHint(hosts: ["prep-air.lan"])), "b")
        XCTAssertEqual(list.pick(machine: BrowserMachineHint(hosts: ["PREP-PRO"])), "a")
        XCTAssertEqual(list.pick(machine: BrowserMachineHint(machineID: "m-9", hosts: [])), "c")
    }

    func testSeveralWithoutAnAnswerAreUnavailable() {
        let list = BrowserHostWorkspaces(workspaces: [host("a", "prep-pro"), host("b", "prep-pro"), host("c")])
        XCTAssertNil(list.pick(machine: BrowserMachineHint(hosts: ["prep-pro"])), "two match")
        XCTAssertNil(list.pick(machine: BrowserMachineHint(hosts: ["unknown"])), "none match")
        XCTAssertNil(list.pick(machine: BrowserMachineHint(hosts: [""])), "an empty name matches nothing")
        XCTAssertEqual(list.pick(machine: nil), "a", "no hint keeps the old first pick")
    }

    func testDecodesTheListing() throws {
        let json = #"{"workspaces":[{"id":"w","status":"active","compute":{"type":"host","hostname":"prep-pro"},"extra":1}]}"#
        let list = try JSONDecoder().decode(BrowserHostWorkspaces.self, from: Data(json.utf8))
        XCTAssertEqual(list.workspaces.first?.compute.hostname, "prep-pro")
    }

    private func text(_ id: String, _ at: Int64, _ body: String, thinking: Bool = false) -> ChatMessage {
        .agentText(AgentTextMessage(id: id, createdAt: at, text: body, isThinking: thinking))
    }

    func testTheChatsNewestLinkIsItsLiveBrowser() {
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32), c = String(repeating: "c", count: 32)
        let messages: [ChatMessage] = [
            text("1", 1, "Watch: http://localhost:6090/live/\(a)"),
            text("2", 5, "Now http://localhost:6090/live/\(b)"),
            text("3", 9, "thinking http://localhost:6090/live/\(c)", thinking: true),
            .userText(UserTextMessage(id: "u", createdAt: 10, text: "http://localhost:6090/live/\(c)")),
            text("4", 11, "no link here"),
        ]
        let facts = ChatSnapshotFacts(LegacyChatSnapshot(sessionId: "s", messages: messages, isLoaded: true))
        XCTAssertEqual(facts.liveBrowser?.id, b)
        XCTAssertNil(ChatSnapshotFacts(LegacyChatSnapshot(sessionId: "s", messages: [text("1", 1, "hi")])).liveBrowser)
    }
}
