import Foundation
import XCTest
@testable import HappyCore

/// Reads happy-app's harness catalog, so a pull that adds a harness says so
/// instead of leaving it missing from this app without a word.
final class HarnessCatalogDriftTests: XCTestCase {
    /// In happy-app's catalog and left out here on purpose. Both are retired
    /// on this path: an existing session still shows its name, and neither
    /// can be started.
    private let excluded: Set<String> = ["gemini", "openclaw"]

    private func catalog() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.deletingLastPathComponent().appendingPathComponent("happy-app/sources/utils/harnessCatalog.ts")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw XCTSkip("happy-app's sources are not beside this package")
        }
        return text
    }

    /// The text between `name` and the bracket that closes its literal.
    private func body(of name: String, in text: String, closing: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: name), "\(name) moved out of harnessCatalog.ts: read it again here")
        let end = try XCTUnwrap(text.range(of: closing, range: start.upperBound..<text.endIndex))
        return text[start.upperBound..<end.lowerBound]
    }

    private func matches(_ pattern: String, in body: Substring) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let text = String(body)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private func names() throws -> [String] {
        try matches(#"^\s*([a-z_]+):\s*'"#, in: body(of: "HARNESS_NAMES", in: catalog(), closing: "\n};"))
    }

    private func order() throws -> [String] {
        try matches(#"^\s*'([a-z_]+)',"#, in: body(of: "HARNESS_ORDER", in: catalog(), closing: "\n];"))
    }

    func testTheCatalogStillParses() throws {
        XCTAssertTrue(try names().contains("claude"))
        XCTAssertTrue(try order().contains("claude"))
    }

    func testEveryHarnessHappyAppNamesIsOfferedOrExcluded() throws {
        for key in try names() where !excluded.contains(key) {
            XCTAssertTrue(
                MachineChoice.agentOrder.contains(key),
                "happy-app lists a harness this app doesn't offer: \(key). Add it (AGENTS.md, Adding a harness) or say why not in `excluded`."
            )
        }
    }

    func testEveryHarnessHappyAppOrdersIsOfferedOrExcluded() throws {
        for key in try order() where !excluded.contains(key) {
            XCTAssertTrue(
                MachineChoice.agentOrder.contains(key),
                "happy-app orders a harness this app doesn't offer: \(key). Add it (AGENTS.md, Adding a harness) or say why not in `excluded`."
            )
        }
    }

    func testTheOfferedHarnessesKeepHappyAppsOrder() throws {
        XCTAssertEqual(MachineChoice.agentOrder, try order().filter { !excluded.contains($0) })
    }

    func testEveryHarnessHappyAppNamesHasItsNameHere() throws {
        for key in try names() {
            XCTAssertNotNil(HarnessCatalog.names[key], "\(key) has no product name in HarnessCatalog")
        }
    }

    /// An exclusion happy-app has dropped is one nobody needs any more.
    func testEveryExclusionIsStillInTheCatalog() throws {
        let names = try names()
        for key in excluded {
            XCTAssertTrue(names.contains(key), "\(key) left happy-app's catalog: drop it from `excluded`")
        }
    }

    func testAnExcludedHarnessIsNotOffered() {
        for key in excluded {
            XCTAssertFalse(MachineChoice.agentOrder.contains(key), "\(key) is offered and excluded at once")
        }
    }
}
