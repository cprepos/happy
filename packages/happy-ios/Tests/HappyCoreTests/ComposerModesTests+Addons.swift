import Foundation
import HappyCore
import HappyWire
import XCTest

// Ours: Codex starts on the account's own model (dd8b3bc33). The catalog
// lists a "default" row first, named "Default model" with no provider, and
// a Codex session with no pick sends no model. Kept out of
// ComposerModesTests.swift so upstream's model-list edits never conflict
// there: upstream's tests read the Codex list without this row, and the
// assertions that only hold because of it live here.

private typealias Options = ModelModeOptions

private func addonsJSON(_ text: String) -> JSONValue {
    // swiftlint:disable:next force_try
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

final class ComposerModesAddonsTests: XCTestCase {
    func testCodexListsTheDefaultModelFirst() {
        let models = Options.hardcodedModelModes(flavor: "codex")
        XCTAssertEqual(models.first, ModeOption(key: "default", name: "Default model"), "names no model and no provider")
        XCTAssertEqual(models.filter { $0.key == "default" }.count, 1)
        XCTAssertEqual(models.dropFirst().first?.name, "GPT-6 Astra")
    }

    func testTheDefaultOrAListedCodexModelAddsNoRow() {
        let models = Options.hardcodedModelModes(flavor: "codex")
        XCTAssertEqual(Options.includeConfiguredModel(flavor: "codex", models: models, configured: "default"), models)
        XCTAssertEqual(Options.includeConfiguredModel(flavor: "codex", models: models, configured: "gpt-6.1-sol"), models)
        let withCustom = Options.includeConfiguredModel(flavor: "codex", models: models, configured: "my-workspace-model")
        XCTAssertEqual(withCustom.first?.key, "default")
        XCTAssertEqual(withCustom.last?.key, "my-workspace-model")
    }

    func testCodexCodeDefaultIsTheAccountsOwnModel() {
        XCTAssertEqual(Options.defaultModelKey(flavor: "codex"), "default")
    }

    func testAnUnlistedCodexPickFallsThroughToTheDefaultModel() {
        let modes = ComposerModes(
            metadata: addonsJSON(#"{ "flavor": "codex", "version": "1.2.6" }"#),
            picks: ComposerPicks(permissionMode: "acceptEdits", effortLevel: "xhigh"),
            agentDefaultOverrides: [:]
        )
        XCTAssertEqual(modes.permissionMode?.key, "auto")
        XCTAssertEqual(modes.modelMode?.key, "default")
        XCTAssertEqual(modes.effortLevel?.key, "xhigh")
    }
}
