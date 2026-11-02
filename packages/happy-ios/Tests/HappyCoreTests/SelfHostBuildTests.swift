import Foundation
import XCTest
@testable import HappyCore

/// The self-host build is opt-in: the normal project and plists know nothing
/// about it, and its own files come from them with only the expected changes.
final class SelfHostBuildTests: XCTestCase {
    private let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../..")
        .standardizedFileURL
    private let variants = ["Development", "Preview", "Production"]

    private func plist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: package.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheNormalBuildHasNoSelfHostKeys() throws {
        for variant in variants {
            let info = try plist(at: package.appendingPathComponent("App/Info-\(variant).plist"))
            XCTAssertNil(info[ServerConfig.bakedServerURLInfoKey], variant)
            XCTAssertNil(info[SelfHostBuild.pushDisabledInfoKey], variant)
            XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["remote-notification"], variant)
        }
    }

    func testTheNormalProjectNeverMentionsTheOverlay() throws {
        for path in ["project.yml", "xtool.yml"] {
            let spec = try text(path)
            XCTAssertFalse(spec.contains("selfhost"), path)
            XCTAssertFalse(spec.contains("SelfHost"), path)
            XCTAssertFalse(spec.contains("APPLE_TEAM_ID"), path)
            XCTAssertFalse(spec.contains("DEVELOPMENT_TEAM"), path)
        }
    }

    func testTheOverlayTakesItsIdentityFromTheEnvironmentAndCommitsNoTeam() throws {
        let overlay = try text("project.selfhost.yml")
        XCTAssertTrue(overlay.contains("DEVELOPMENT_TEAM: ${APPLE_TEAM_ID}"))
        XCTAssertTrue(overlay.contains("PRODUCT_BUNDLE_IDENTIFIER: ${APP_BUNDLE_ID_PREFIX}.dev"))
        XCTAssertTrue(overlay.contains("PRODUCT_BUNDLE_IDENTIFIER: ${APP_BUNDLE_ID_PREFIX}.preview"))
        XCTAssertTrue(overlay.contains("PRODUCT_BUNDLE_IDENTIFIER: ${APP_BUNDLE_ID_PREFIX}\n"))
        XCTAssertFalse(overlay.contains("com.slopus"))
        XCTAssertFalse(overlay.contains("com.ex3ndr"))
        XCTAssertFalse(overlay.contains("Happy.entitlements"))
        XCTAssertFalse(overlay.contains("Happy-Production.entitlements"))
    }

    func testSelfHostEntitlementsAreEmpty() throws {
        XCTAssertTrue(try plist(at: package.appendingPathComponent("App/Happy-SelfHost.entitlements")).isEmpty)
    }

    func testPushIsOnUnlessTheBuildSaysOtherwise() {
        XCTAssertFalse(SelfHostBuild.pushDisabled(bundle: .main))
        XCTAssertFalse(SelfHostBuild.pushDisabled(infoValue: nil))
        XCTAssertFalse(SelfHostBuild.pushDisabled(infoValue: "yes"))
        XCTAssertFalse(SelfHostBuild.pushDisabled(infoValue: false))
        XCTAssertTrue(SelfHostBuild.pushDisabled(infoValue: true))
    }

    // MARK: The generator

    #if os(Linux) || os(macOS)
    private struct Run {
        var status: Int32
        var stderr: String
        var output: URL
    }

    private func generate(_ overrides: [String: String?] = [:]) throws -> Run {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: output) }
        var environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        let defaults: [String: String?] = [
            "APPLE_TEAM_ID": "ABCDE12345",
            "APP_BUNDLE_ID_PREFIX": "com.example.happy",
            "SELFHOST_SERVER_URL": "https://happy.example.test/",
        ]
        for (key, value) in defaults.merging(overrides, uniquingKeysWith: { $1 }) {
            if let value { environment[key] = value }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", package.appendingPathComponent("scripts/selfhost-project.sh").path,
                             "--plists-only", "--output", output.path]
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stderr: String(decoding: data, as: UTF8.self), output: output)
    }

    private func assertRefused(_ overrides: [String: String?], mentioning word: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let run = try generate(overrides)
        XCTAssertNotEqual(run.status, 0, file: file, line: line)
        XCTAssertTrue(run.stderr.contains(word), run.stderr, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.output.path), "refused before writing", file: file, line: line)
    }

    func testOnlyTheExpectedKeysDifferFromTheNormalPlists() throws {
        let run = try generate(["APP_DISPLAY_NAME": "My Happy"])
        XCTAssertEqual(run.status, 0, run.stderr)
        for variant in variants {
            let normal = try plist(at: package.appendingPathComponent("App/Info-\(variant).plist"))
            let selfHost = try plist(at: run.output.appendingPathComponent("Info-\(variant).plist"))

            XCTAssertEqual(selfHost["CFBundleDisplayName"] as? String, "My Happy", variant)
            XCTAssertEqual(selfHost[SelfHostBuild.pushDisabledInfoKey] as? Bool, true, variant)
            XCTAssertNil(selfHost["UIBackgroundModes"], variant)
            for key in ["NSCameraUsageDescription", "NSLocalNetworkUsageDescription"] {
                let string = try XCTUnwrap(selfHost[key] as? String, variant)
                XCTAssertTrue(string.hasPrefix("Allow My Happy to "), string)
            }

            let changed: Set<String> = [
                "CFBundleDisplayName", "NSCameraUsageDescription", "NSLocalNetworkUsageDescription",
                "UIBackgroundModes", ServerConfig.bakedServerURLInfoKey, SelfHostBuild.pushDisabledInfoKey,
            ]
            XCTAssertEqual(Set(selfHost.keys).subtracting(changed), Set(normal.keys).subtracting(changed), variant)
            for key in Set(normal.keys).subtracting(changed) {
                XCTAssertEqual(
                    try PropertyListSerialization.data(fromPropertyList: try XCTUnwrap(normal[key]), format: .xml, options: 0),
                    try PropertyListSerialization.data(fromPropertyList: try XCTUnwrap(selfHost[key]), format: .xml, options: 0),
                    "\(variant) \(key), including App Transport Security"
                )
            }
        }
    }

    func testTheGeneratedServerResolvesThroughServerConfig() throws {
        let run = try generate()
        XCTAssertEqual(run.status, 0, run.stderr)
        for variant in variants {
            let info = try plist(at: run.output.appendingPathComponent("Info-\(variant).plist"))
            let baked = ServerConfig.bakedServerURL(infoValue: info[ServerConfig.bakedServerURLInfoKey])
            let config = ServerConfig(storage: InMemoryKeyValueStore(), bakedServerURL: baked)
            XCTAssertEqual(config.serverURL.absoluteString, "https://happy.example.test", variant)
        }
    }

    func testValuesAreEscapedForTheXML() throws {
        let run = try generate(["APP_DISPLAY_NAME": "Me & <My> Happy", "SELFHOST_SERVER_URL": "https://happy.example.test/a?x=1&y=2"])
        XCTAssertEqual(run.status, 0, run.stderr)
        let info = try plist(at: run.output.appendingPathComponent("Info-Preview.plist"))
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Me & <My> Happy")
        XCTAssertEqual(info[ServerConfig.bakedServerURLInfoKey] as? String, "https://happy.example.test/a?x=1&y=2")
    }

    func testBadIdentityIsRefused() throws {
        try assertRefused(["APPLE_TEAM_ID": nil], mentioning: "APPLE_TEAM_ID")
        try assertRefused(["APPLE_TEAM_ID": "short"], mentioning: "APPLE_TEAM_ID")
        try assertRefused(["APP_BUNDLE_ID_PREFIX": nil], mentioning: "APP_BUNDLE_ID_PREFIX")
        try assertRefused(["APP_BUNDLE_ID_PREFIX": "nodots"], mentioning: "APP_BUNDLE_ID_PREFIX")
        try assertRefused(["APP_BUNDLE_ID_PREFIX": "com.my-name.happy"], mentioning: "APP_BUNDLE_ID_PREFIX")
        try assertRefused(["APP_BUNDLE_ID_PREFIX": "com.slopus.happy"], mentioning: "upstream")
        try assertRefused(["APP_BUNDLE_ID_PREFIX": "com.ex3ndr"], mentioning: "upstream")
        try assertRefused(["APP_ENV": "staging"], mentioning: "APP_ENV")
    }

    func testBadServerIsRefused() throws {
        try assertRefused(["SELFHOST_SERVER_URL": nil], mentioning: "SELFHOST_SERVER_URL")
        try assertRefused(["SELFHOST_SERVER_URL": "ftp://happy.example.test"], mentioning: "SELFHOST_SERVER_URL")
        try assertRefused(["SELFHOST_SERVER_URL": "happy.example.test"], mentioning: "SELFHOST_SERVER_URL")
    }

    func testProductionRefusesARemotePlainHTTPServerThatATSWouldBlock() throws {
        for url in ["http://happy.example.test", "http://HAPPY.example.test:3005/", "http://user@happy.example.test"] {
            try assertRefused(["APP_ENV": "production", "SELFHOST_SERVER_URL": url], mentioning: "App Transport Security")
        }
    }

    func testProductionAllowsWhatATSAllows() throws {
        for url in ["https://happy.example.test", "http://192.168.1.20:3005", "http://mymac", "http://mymac.local:3005", "http://[fd00::1]:3005"] {
            let run = try generate(["APP_ENV": "production", "SELFHOST_SERVER_URL": url])
            XCTAssertEqual(run.status, 0, "\(url): \(run.stderr)")
        }
    }

    func testOtherVariantsMayUseRemotePlainHTTPBecauseTheirATSAllowsIt() throws {
        for variant in ["development", "preview"] {
            let run = try generate(["APP_ENV": variant, "SELFHOST_SERVER_URL": "http://happy.example.test"])
            XCTAssertEqual(run.status, 0, run.stderr)
        }
        let dev = try plist(at: package.appendingPathComponent("App/Info-Development.plist"))
        let preview = try plist(at: package.appendingPathComponent("App/Info-Preview.plist"))
        for info in [dev, preview] {
            let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any])
            XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        }
    }
    #endif
}
