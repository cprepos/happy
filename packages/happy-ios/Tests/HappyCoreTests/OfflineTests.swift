@testable import HappyCore
import HappyWire
import XCTest

/// What a computer last showed is kept, merged, read back, and forgotten.
final class OfflineTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("offline-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testChangesMergeAndAFreshReaderSeesThem() async {
        let file = OfflineFile(directory: directory)
        await file.update { $0.config = #"{"config":{}}"# }
        await file.update {
            $0.sidebar = OfflineSnapshot.Sidebar(
                artifactId: "a", version: 3, html: "<nav/>", spaces: [], agentIcons: [:], bots: [], tasks: [],
                surfaces: [AgentWire.Surface(id: "s", type: "todo", name: "Groceries")],
                capabilities: nil, prioritizing: true
            )
        }
        await file.flush()
        let kept = await OfflineFile(directory: directory).read()
        XCTAssertEqual(kept?.config, #"{"config":{}}"#)
        XCTAssertEqual(kept?.sidebar?.version, 3)
        XCTAssertEqual(kept?.sidebar?.surfaces?.first?.name, "Groceries")
        XCTAssertEqual(kept?.sidebar?.prioritizing, true)
    }

    /// A copy written while the home dock kept a pick for new work still
    /// loads, and the pick is never written again: new work starts where the
    /// Start On preference says (`Session.newWorkMode`), read from the config.
    func testAStoredDockPickLoadsButIsIgnored() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = OfflineFile(directory: directory)
        let config = #"{"config":{"defaults":{"providerId":"claude","modelId":"anthropic/opus-5-5"},"models":{"openai/sol":{"name":"Sol","efforts":["medium"],"defaultEffort":"medium"},"anthropic/opus-5-5":{"name":"Opus 5.5","efforts":["high"],"defaultEffort":"high"}},"providers":{"codex":{"type":"codex","enabled":true,"models":[{"id":"openai/sol","enabled":true}]},"claude":{"type":"claude","enabled":true,"models":[{"id":"anthropic/opus-5-5","enabled":true}]}}}}"#
        let old: JSONValue = .object([
            "format": .number(Double(OfflineSnapshot.format)),
            "config": .string(config),
            "dockMode": .object(["providerId": .string("codex"), "modelId": .string("openai/sol"), "effort": .string("medium"), "permissionMode": .string("auto")]),
        ])
        try JSONEncoder().encode(old).write(to: file.snapshotURL)
        let read = await file.read()
        let kept = try XCTUnwrap(read, "a copy with the dock's pick no longer loads")
        let catalog = try XCTUnwrap(kept.config.flatMap { ModelCatalog(response: Data($0.utf8)) })
        XCTAssertEqual(catalog.defaultMode().modelId, "anthropic/opus-5-5")
        XCTAssertEqual(catalog.defaultMode().providerId, "claude")

        await file.update { $0.config = config }
        await file.flush()
        let source = try String(contentsOf: Self.sources.appendingPathComponent("HappyUI/Agents/ModelPickers.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("dockMode"), "the dock's old pick is still read or written for new work")
    }

    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    func testACopyOfAnotherFormatIsNotRead() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = OfflineFile(directory: directory)
        try Data(#"{"format":0}"#.utf8).write(to: file.snapshotURL)
        let kept = await file.read()
        XCTAssertNil(kept)
    }

    func testPicturesAreKeptByPathAndHash() {
        let file = OfflineFile(directory: directory)
        file.keepPicture(Data([1, 2, 3]), path: "/v0/bots/b1/avatar", thumbhash: "KZcG/N+=")
        XCTAssertEqual(file.picture("/v0/bots/b1/avatar", thumbhash: "KZcG/N+="), Data([1, 2, 3]))
        // A new picture has a new hash: the old bytes are not it, and
        // keeping the new one drops the old.
        XCTAssertNil(file.picture("/v0/bots/b1/avatar", thumbhash: "other"))
        file.keepPicture(Data([4]), path: "/v0/bots/b1/avatar", thumbhash: "other")
        XCTAssertNil(file.picture("/v0/bots/b1/avatar", thumbhash: "KZcG/N+="))
        XCTAssertEqual(file.picture("/v0/bots/b1/avatar", thumbhash: "other"), Data([4]))
        let folder = file.pictureURL("/v0/bots/b1/avatar", thumbhash: "other").deletingLastPathComponent()
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        XCTAssertEqual(file.pictureURL("/v0/b", thumbhash: "x/").lastPathComponent.count, 32)
    }

    func testARemovedFolderStaysGoneWhateverWasOnItsWay() async {
        let file = OfflineFile(directory: directory)
        await file.update { $0.config = "a" }
        await file.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        OfflineFile.Gate.close(directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        // Late writes from the file that was open on it.
        await file.update { $0.config = "b" }
        await file.flush()
        file.keepPicture(Data([1]), path: "/p", thumbhash: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        // A computer paired again opens the folder afresh.
        let again = OfflineFile(directory: directory)
        await again.update { $0.config = "c" }
        await again.flush()
        let kept = await OfflineFile(directory: directory).read()
        XCTAssertEqual(kept?.config, "c")
    }
}
