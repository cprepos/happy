@testable import HappyCore
import HappyWire
import XCTest

/// Which accounts and models the pickers offer, ported case for case from
/// desktop's `happyAgentMenusStore.test.ts` ("hidden and unavailable
/// accounts in the pickers", "hidden models in the pickers"), over the
/// daemon's `/v0/config` as desktop's `happyAgentModelCatalogProject` reads it.
final class ModelFilterTests: XCTestCase {
    /// The fake daemon's test model under the accounts given, each written
    /// as `"id": {…}` in a `providers` object.
    private func catalog(_ providers: String, models extra: String = "") -> ModelCatalog {
        ModelCatalog(response: Data("""
        {"config": {
            "defaults": {"providerId": "main", "modelId": "test-model", "effort": "medium", "permissionMode": "auto"},
            "models": {
                "test-model": {"name": "Test Model", "efforts": ["low", "medium", "high"], "defaultEffort": "medium", "serviceTiers": [], "contextWindow": 200000}\(extra)
            },
            "providers": {\(providers)}
        }}
        """.utf8))!
    }

    private let base = #""type": "claude", "enabled": true, "models": [{"id": "test-model", "enabled": true}]"#

    private func on(_ providerId: String, _ modelId: String = "test-model") -> AgentWire.Mode {
        AgentWire.Mode(providerId: providerId, modelId: modelId, effort: "medium", serviceTier: nil, permissionMode: "auto")
    }

    private func offered(_ menus: ModelMenus) -> [String] {
        menus.services.flatMap(\.accounts).flatMap { account in account.models.map { "\(account.id)/\($0.id)" } }
    }

    // MARK: Hidden and unavailable accounts

    func testAMissingHiddenFlagIsFalseAndEveryVisibleAccountIsListed() {
        let catalog = catalog(#""main": {\#(base)}, "extra": {\#(base), "hidden": false}"#)
        XCTAssertEqual(catalog.providers.map(\.hidden), [false, false])
        let menus = ModelMenus(catalog: catalog, selection: on("main"))
        XCTAssertEqual(offered(menus), ["main/test-model", "extra/test-model"])
        XCTAssertNil(menus.notice)
        XCTAssertEqual(menus.current?.label, "Test Model")
    }

    func testHiddenAccountsAreLeftOutOfTheChoices() {
        let menus = ModelMenus(catalog: catalog(#""main": {\#(base)}, "pooled": {\#(base), "hidden": true}"#), selection: on("main"))
        XCTAssertEqual(offered(menus), ["main/test-model"])
        XCTAssertNil(menus.notice)
    }

    func testASelectionOnAHiddenAccountIsNamedButNotOffered() {
        let menus = ModelMenus(catalog: catalog(#""main": {\#(base)}, "pooled": {\#(base), "hidden": true}"#), selection: on("pooled"))
        XCTAssertEqual(menus.selection.providerId, "pooled")
        XCTAssertEqual(menus.notice, .hidden)
        XCTAssertFalse(menus.services.flatMap(\.accounts).contains { $0.id == "pooled" })
        XCTAssertEqual(menus.current?.label, "Test Model")
        XCTAssertEqual(menus.current?.disabled, false)
        // Its efforts stay choosable.
        XCTAssertEqual(menus.current?.efforts, ["low", "medium", "high"])
    }

    func testASelectionOnASwitchedOffAccountIsDisabled() {
        let menus = ModelMenus(catalog: catalog(#""main": {\#(base)}, "off": {"type": "claude", "enabled": false, "hidden": true, "models": [{"id": "test-model", "enabled": true}]}"#), selection: on("off"))
        XCTAssertEqual(menus.notice, .off("off"))
        XCTAssertEqual(menus.current?.disabled, true)
        // Hidden as well, it is not listed.
        XCTAssertEqual(offered(menus), ["main/test-model"])
    }

    func testASelectionOnARemovedAccountIsMissingAndStillNamesItsModel() {
        let menus = ModelMenus(catalog: catalog(#""main": {\#(base)}"#), selection: on("gone"))
        XCTAssertEqual(menus.notice, .removed("gone"))
        XCTAssertEqual(menus.current?.label, "Test Model")
        XCTAssertEqual(menus.current?.disabled, true)
    }

    /// Desktop lists a switched-off account that is not hidden, its models
    /// greyed; only hiding it keeps it out.
    func testASwitchedOffAccountThatIsNotHiddenIsListedGreyed() {
        let menus = ModelMenus(catalog: catalog(#""main": {\#(base)}, "off": {"type": "codex", "enabled": false, "models": [{"id": "test-model", "enabled": true}]}"#), selection: on("main"))
        XCTAssertEqual(offered(menus), ["main/test-model", "off/test-model"])
        XCTAssertEqual(menus.services.last?.shown?.models.map(\.disabled), [true])
    }

    /// An account switched on with nothing switched on is no row, and its
    /// selection carries no notice (desktop's "available").
    func testAnAccountOfferingNothingIsNotListed() {
        let menus = ModelMenus(catalog: catalog(#""main": {\#(base)}, "empty": {"type": "codex", "enabled": true, "models": [{"id": "test-model", "enabled": false}]}"#), selection: on("empty"))
        XCTAssertEqual(menus.services.map(\.id), ["claude"])
        XCTAssertNil(menus.notice)
    }

    // MARK: Hidden models

    /// One account offering the test model and a second, `sol`, marked as `hidden`.
    private func withSol(_ hidden: Bool?) -> ModelCatalog {
        let flag = hidden.map { #", "hidden": \#($0)"# } ?? ""
        return catalog(
            #""main": {"type": "claude", "enabled": true, "models": [{"id": "test-model", "enabled": true}, {"id": "sol", "enabled": true\#(flag)}]}"#,
            models: #", "sol": {"name": "Sol", "efforts": ["low", "medium", "high"], "defaultEffort": "medium", "serviceTiers": []}"#
        )
    }

    func testAModelTheDaemonDoesNotMarkHiddenIsOffered() {
        for hidden in [nil, false] {
            XCTAssertEqual(offered(ModelMenus(catalog: withSol(hidden), selection: on("main"))), ["main/test-model", "main/sol"])
        }
    }

    func testAHiddenModelIsLeftOutOfTheChoices() {
        let catalog = withSol(true)
        XCTAssertEqual(catalog.providers[0].hiddenModels, ["sol"])
        XCTAssertEqual(offered(ModelMenus(catalog: catalog, selection: on("main"))), ["main/test-model"])
        // Nor is it where a switch of account would land.
        let account = ModelMenus(catalog: catalog, selection: on("main")).services[0].accounts[0]
        XCTAssertEqual(account.models.map(\.id), ["test-model"])
    }

    func testAHiddenModelStaysOfferedWhileItIsTheSelection() {
        let menus = ModelMenus(catalog: withSol(true), selection: on("main", "sol"))
        XCTAssertEqual(offered(menus), ["main/test-model", "main/sol"])
        XCTAssertEqual(menus.current?.label, "Sol")
        XCTAssertNil(menus.notice)
        XCTAssertEqual(menus.current?.efforts, ["low", "medium", "high"])
    }

    /// A hidden model on a disabled reference is no model at all.
    func testOnlySwitchedOnReferencesCountAsHidden() {
        let catalog = catalog(
            #""main": {"type": "claude", "enabled": true, "models": [{"id": "test-model", "enabled": true}, {"id": "sol", "enabled": false, "hidden": true}]}"#,
            models: #", "sol": {"name": "Sol", "efforts": [], "defaultEffort": "medium", "serviceTiers": []}"#
        )
        XCTAssertEqual(catalog.providers[0].hiddenModels, [])
    }

    // MARK: Windows

    func testTheCatalogReadsTheModelsWindowAndCompactionPoint() {
        let catalog = catalog(
            #""main": {"type": "claude", "enabled": true, "models": [{"id": "test-model", "enabled": true}, {"id": "big", "enabled": true, "name": "Big (Work)"}]}"#,
            models: #", "big": {"name": "Big", "efforts": [], "defaultEffort": "medium", "serviceTiers": [], "contextWindow": 1000000, "autoCompactWindow": 800000}, "custom": {"name": "Custom", "efforts": [], "defaultEffort": "medium", "serviceTiers": [], "contextWindow": null, "autoCompactWindow": null}"#
        )
        let models = catalog.providers[0].models
        XCTAssertEqual(models.map(\.contextWindow), [200_000, 1_000_000])
        XCTAssertEqual(models.map(\.autoCompactWindow), [nil, 800_000])
        XCTAssertNil(catalog.models.first { $0.id == "custom" }?.contextWindow)
    }
}
