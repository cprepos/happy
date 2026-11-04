import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// Which paired computer a Happy CLI chat's links open through
/// (docs/browser-proxy.md, Routing): the browser's workspace selection for
/// chats that have no workspace of their own.
final class LegacyLinkRouteTests: XCTestCase {
    private typealias Fixture = LegacyHomeFixtures

    private let pro = LegacyLinkComputer(id: "direct-pro", name: AgentName.friendly("prep-pro"))
    private let air = LegacyLinkComputer(id: "direct-air", name: AgentName.friendly("prep-air"))
    private let ml = LegacyLinkComputer(id: "direct-ml", name: AgentName.friendly("prep-ml"))

    private func settings() -> LocalSettings { LocalSettings(storage: InMemoryKeyValueStore()) }

    func testTheMachineIsNamedAsHomeNamesIt() {
        var machine = Fixture.machine("m1", active: true, name: "prep-pro")
        let session = Fixture.session("s1", machine: "m1", path: "/work", metadata: ["host": .string("session-host")])
        XCTAssertEqual(LegacyLinkRoute.machineName(session: session, machine: machine), "prep-pro")
        machine.metadata = .object(["displayName": .string(""), "host": .string("prep-air.local")])
        XCTAssertEqual(LegacyLinkRoute.machineName(session: session, machine: machine), "prep-air.local")
        XCTAssertEqual(LegacyLinkRoute.machineName(session: session, machine: nil), "session-host")
        XCTAssertNil(LegacyLinkRoute.machineName(session: Fixture.session("s2", machine: nil, path: nil), machine: nil))
    }

    func testANameMatchRoutesThroughThatComputer() {
        let settings = settings()
        // The computers are shown as "Prep Pro" and so on; the machine's own
        // spelling, case, spaces and a host suffix all still match.
        for name in ["prep-pro", "PREP-PRO", "  Prep Pro ", "prep-pro.local"] {
            XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: name, computers: [air, pro, ml], settings: settings), .computer("direct-pro"), name)
        }
        // A match is not a pick: nothing is kept.
        XCTAssertEqual(settings.legacyLinkComputers, [:])
    }

    /// happy-cli's daemon names the Happy Agent sharing its computer
    /// (`happyAgent.nodeName`); that beats the machine's own name and a pick.
    func testTheAgentNodeTheMachineNamesComesFirst() throws {
        var machine = Fixture.machine("m1", active: true, name: "prep-air")
        machine.metadata = .object(["displayName": .string("prep-air"), "happyAgent": .object(["nodeName": .string("prep-pro")])])
        XCTAssertEqual(LegacyLinkRoute.agentNodeName(machine), "prep-pro")
        XCTAssertNil(LegacyLinkRoute.agentNodeName(Fixture.machine("m2", active: true, name: "prep-air")))
        XCTAssertNil(LegacyLinkRoute.agentNodeName(nil))
        let session = Fixture.session("s1", machine: "m1", path: "/work")
        let name = LegacyLinkRoute.machineName(session: session, machine: machine)
        XCTAssertEqual(name, "prep-air")
        let settings = settings()
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: name, agentNodeName: LegacyLinkRoute.agentNodeName(machine), computers: [air, pro, ml], settings: settings), .computer("direct-pro"))
        // In any case, trimmed.
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: name, agentNodeName: " PREP-PRO ", computers: [air, pro, ml], settings: settings), .computer("direct-pro"))
        LegacyLinkRoute.remember("direct-ml", for: "m1", settings: settings)
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: name, agentNodeName: "prep-pro", computers: [air, pro, ml], settings: settings), .computer("direct-pro"))
        // A node that isn't paired here leaves the rest to decide.
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: name, agentNodeName: "studio", computers: [air, pro, ml], settings: settings), .computer("direct-ml"))
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m2", machineName: name, agentNodeName: "studio", computers: [air, pro, ml], settings: settings), .computer("direct-air"))
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m2", machineName: name, agentNodeName: "prep-pro", computers: [], settings: settings), .unavailable)
    }

    /// A Happy Agent's own relay machine (its bots' Happy CLI page copies)
    /// names no node; the happy-cli machine on the same host does.
    func testAMachineWithoutANodeTakesItsHostsNode() {
        var agent = Fixture.machine("agent", active: true, name: "Christopher’s MacBook Pro")
        agent.metadata = .object(["displayName": .string("Christopher’s MacBook Pro"), "host": .string("Mac")])
        var cli = Fixture.machine("cli", active: true, name: "Mac")
        cli.metadata = .object(["host": .string(" mac "), "happyAgent": .object(["nodeName": .string("prep-pro")])])
        var air = Fixture.machine("air", active: true, name: "MacBookAir")
        air.metadata = .object(["host": .string("MacBookAir"), "happyAgent": .object(["nodeName": .string("prep-air")])])
        let machines = [agent, cli, air]

        XCTAssertEqual(LegacyLinkRoute.agentNodeName(agent, among: machines), "prep-pro")
        // Its own node, when it names one, is never looked past.
        XCTAssertEqual(LegacyLinkRoute.agentNodeName(air, among: machines), "prep-air")
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "agent", machineName: "Christopher’s MacBook Pro", agentNodeName: LegacyLinkRoute.agentNodeName(agent, among: machines), computers: [self.air, pro, ml], settings: settings()), .computer("direct-pro"))

        // Two nodes on one host name neither; no host names none.
        var other = Fixture.machine("other", active: true, name: "Mac")
        other.metadata = .object(["host": .string("Mac"), "happyAgent": .object(["nodeName": .string("studio")])])
        XCTAssertNil(LegacyLinkRoute.agentNodeName(agent, among: machines + [other]))
        var hostless = agent
        hostless.metadata = .object(["displayName": .string("Bot box")])
        XCTAssertNil(LegacyLinkRoute.agentNodeName(hostless, among: machines))
        XCTAssertNil(LegacyLinkRoute.agentNodeName(nil, among: machines))
    }

    func testNoMatchAsksAmongEveryComputer() {
        let settings = settings()
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: "studio", computers: [pro, air], settings: settings), .ask([pro, air]))
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: nil, computers: [pro], settings: settings), .ask([pro]))
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: nil, machineName: "   ", computers: [pro], settings: settings), .ask([pro]))
    }

    func testSeveralMatchesAsk() {
        let twin = LegacyLinkComputer(id: "direct-pro-2", name: "prep-pro")
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: "prep-pro", computers: [pro, twin, air], settings: settings()), .ask([pro, twin, air]))
    }

    func testAPickIsUsedForTheMachinesLaterLinks() {
        let settings = settings()
        LegacyLinkRoute.remember("direct-air", for: "m1", settings: settings)
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: "studio", computers: [pro, air], settings: settings), .computer("direct-air"))
        // Over a name match too: the person chose.
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: "prep-pro", computers: [pro, air], settings: settings), .computer("direct-air"))
        XCTAssertEqual(LegacyLinkRoute.remembered(for: "m1", computers: [pro, air], settings: settings), air)
        // Another machine still asks.
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m2", machineName: "studio", computers: [pro, air], settings: settings), .ask([pro, air]))
        // It survives a new settings instance on the same storage.
        let storage = InMemoryKeyValueStore()
        LegacyLinkRoute.remember("direct-pro", for: "m3", settings: LocalSettings(storage: storage))
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m3", machineName: nil, computers: [pro, air], settings: LocalSettings(storage: storage)), .computer("direct-pro"))
    }

    func testAPickWhoseComputerIsGoneIsDropped() {
        let settings = settings()
        LegacyLinkRoute.remember("direct-gone", for: "m1", settings: settings)
        LegacyLinkRoute.remember("direct-air", for: "m2", settings: settings)
        XCTAssertNil(LegacyLinkRoute.remembered(for: "m1", computers: [pro, air], settings: settings))
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: "studio", computers: [pro, air], settings: settings), .ask([pro, air]))
        XCTAssertEqual(settings.legacyLinkComputers, ["m2": "direct-air"])
        // Dropped, the name decides again.
        LegacyLinkRoute.remember("direct-gone", for: "m1", settings: settings)
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: "prep-pro", computers: [pro, air], settings: settings), .computer("direct-pro"))
        XCTAssertEqual(settings.legacyLinkComputers, ["m2": "direct-air"])
    }

    func testNoPairedComputerIsUnavailable() {
        let settings = settings()
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: "prep-pro", computers: [], settings: settings), .unavailable)
        // A kept pick doesn't stand in for a computer that isn't paired.
        LegacyLinkRoute.remember("direct-pro", for: "m1", settings: settings)
        XCTAssertEqual(LegacyLinkRoute.resolve(machineId: "m1", machineName: "prep-pro", computers: [], settings: settings), .unavailable)
        XCTAssertEqual(settings.legacyLinkComputers, [:])
    }

    func testSignOutForgetsThePicks() {
        let settings = settings()
        LegacyLinkRoute.remember("direct-pro", for: "m1", settings: settings)
        settings.clear()
        XCTAssertEqual(settings.legacyLinkComputers, [:])
    }

    /// Every language has every word, with the same parameters, and only
    /// English is English.
    func testEveryLanguageHasTheWords() async {
        for language in AppLanguage.supported.map(\.code) { _ = await TranslationCatalog.load(language) }
        let english = TranslationCatalog.browserSources["en"] ?? [:]
        XCTAssertEqual(Set(TranslationCatalog.browserSources.keys), Set(AppLanguage.supported.map(\.code)))
        XCTAssertEqual(english.count, 5)
        for language in AppLanguage.supported.map(\.code) {
            let words = TranslationCatalog.browserSources[language] ?? [:]
            let catalog = TranslationCatalog.catalog(for: language)
            XCTAssertEqual(Set(words.keys), Set(english.keys), language)
            for (key, text) in words {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language) \(key)")
                for parameter in ["${machine}", "${name}"] {
                    XCTAssertEqual(text.contains(parameter), (english[key] ?? "").contains(parameter), "\(language) \(key) \(parameter)")
                }
                if language != "en" { XCTAssertNotEqual(text, english[key], "\(language) \(key) is English") }
            }
            XCTAssertTrue(catalog("native.browser.relayPickerTitle", ["machine": "prep-ml"]).contains("prep-ml"), language)
            XCTAssertTrue(catalog("native.browser.linksOpenThrough", ["name": "Prep Pro"]).contains("Prep Pro"), language)
        }
    }
}
