import Foundation
import XCTest
@testable import HappyCore

/// A self-host build names its server in Info.plist. The user's choice still
/// wins, and nothing on such a build falls back to Happy's server unasked.
final class SelfHostServerResolutionTests: XCTestCase {
    private let baked = URL(string: "https://happy.example.test")!

    func testResolutionOrderIsCustomThenBakedThenHosted() throws {
        let storage = InMemoryKeyValueStore()
        let config = ServerConfig(storage: storage, bakedServerURL: baked)
        XCTAssertEqual(config.serverURL, baked)
        try config.setCustomServerURL("https://mine.test")
        XCTAssertEqual(config.serverURL.absoluteString, "https://mine.test")
        XCTAssertEqual(ServerConfig(storage: InMemoryKeyValueStore()).serverURL, ServerConfig.defaultServerURL)
    }

    func testAnUnusableStoredChoiceFallsThroughToTheBakedServer() {
        let storage = InMemoryKeyValueStore([ServerConfig.customServerKey: "ftp://broken.test"])
        XCTAssertEqual(ServerConfig(storage: storage, bakedServerURL: baked).serverURL, baked)
    }

    func testTheInfoValueIsNormalizedAndAnythingUnusableIsIgnored() {
        XCTAssertEqual(ServerConfig.bakedServerURL(infoValue: " https://happy.example.test/ "), baked)
        for value: Any? in [nil, "", "   ", "not a url", "ftp://happy.example.test", 42, true] {
            XCTAssertNil(ServerConfig.bakedServerURL(infoValue: value), "\(String(describing: value))")
        }
    }

    func testABuildWithoutTheKeyBakesNothing() {
        XCTAssertNil(ServerConfig.bakedServerURL(bundle: .main))
    }

    func testTheBakedServerIsNotACustomOneAndResetReturnsToIt() throws {
        let config = ServerConfig(storage: InMemoryKeyValueStore(), bakedServerURL: baked)
        XCTAssertFalse(config.isCustomServer)
        XCTAssertFalse(config.isHostedServer)
        XCTAssertEqual(config.displayHost, "happy.example.test")

        try config.setCustomServerURL("https://mine.test")
        XCTAssertTrue(config.isCustomServer)
        try config.setCustomServerURL(nil)
        XCTAssertEqual(config.serverURL, baked)
        XCTAssertFalse(config.isCustomServer)
    }

    func testHappysServerCanStillBePickedOnASelfHostBuildAndResetBack() throws {
        let config = ServerConfig(storage: InMemoryKeyValueStore(), bakedServerURL: baked)
        try config.setCustomServerURL(ServerConfig.defaultServerURL.absoluteString)
        XCTAssertEqual(config.serverURL, ServerConfig.defaultServerURL)
        XCTAssertTrue(config.isCustomServer)
        XCTAssertTrue(config.isHostedServer)
        try config.setCustomServerURL(nil)
        XCTAssertEqual(config.serverURL, baked)
    }

    func testANormalBuildBehavesAsItAlwaysDid() throws {
        let config = ServerConfig(storage: InMemoryKeyValueStore())
        XCTAssertEqual(config.fallbackServerURL, ServerConfig.defaultServerURL)
        XCTAssertFalse(config.isCustomServer)
        XCTAssertTrue(config.isHostedServer)
        try config.setCustomServerURL("https://mine.test")
        XCTAssertTrue(config.isCustomServer)
        XCTAssertFalse(config.isHostedServer)
    }
}

/// Installing over a self-host RN build: it signs with the same bundle id, so
/// its Keychain token is visible here, and it stored no server in MMKV because
/// its own was baked in too. That token must not go to Happy's server.
final class SelfHostAccountImportTests: XCTestCase {
    private let baked = URL(string: "https://happy.example.test")!
    private let item = SecureStoreCredentialStore.item.writeTarget

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    private func controller(_ keychain: AccountsKeychain, directory: URL, rn: URL,
                            http: FakeHTTP, connector: FakeConnector) -> AccountController {
        let baked = self.baked
        return AccountController(serverConfig: ServerConfig(storage: InMemoryKeyValueStore(), bakedServerURL: baked),
            clientID: "ios/test", credentialStore: SecureStoreCredentialStore(backend: keychain), storeDirectory: directory,
            accountCredentialStore: KeychainAccountCredentialStore(backend: keychain),
            rnServerImport: { RNServerConfigImporter.read(directory: rn, defaultServer: baked) },
            transport: http, connector: connector)
    }

    func testAMissingOrEmptyRNSettingImportsTheDefaultItIsGiven() throws {
        let base = try directory()
        XCTAssertEqual(RNServerConfigImporter.read(directory: base.appendingPathComponent("absent"), defaultServer: baked), .confirmed(baked))
        let rn = base.appendingPathComponent("mmkv")
        try MMKVFixtures.write(MMKVFixtures.file(MMKVFixtures.region([("custom-server-url", "")])), directory: rn)
        XCTAssertEqual(RNServerConfigImporter.read(directory: rn, defaultServer: baked), .confirmed(baked))
        XCTAssertEqual(RNServerConfigImporter.read(directory: rn), .confirmed(ServerConfig.defaultServerURL))
    }

    func testAStoredRNChoiceStillWinsAndATornOneStillAsks() throws {
        let base = try directory(), rn = base.appendingPathComponent("mmkv")
        try MMKVFixtures.write(MMKVFixtures.file(MMKVFixtures.region([("custom-server-url", "https://chosen.test")])), directory: rn)
        XCTAssertEqual(RNServerConfigImporter.read(directory: rn, defaultServer: baked), .confirmed(URL(string: "https://chosen.test")!))
        try Data("torn".utf8).write(to: rn.appendingPathComponent("server-config"))
        XCTAssertEqual(RNServerConfigImporter.read(directory: rn, defaultServer: baked), .needsConfirmation)
    }

    @MainActor
    func testAnRNTokenWithNoStoredServerNeverReachesHappysServer() async throws {
        let base = try directory(), rn = base.appendingPathComponent("mmkv")
        let keychain = AccountsKeychain(), http = FakeHTTP(), connector = FakeConnector()
        keychain.items.seed(item, Data(TokenStorageFixtures.typicalJSON.utf8))
        let account = controller(keychain, directory: base, rn: rn, http: http, connector: connector)
        await account.restore()
        XCTAssertEqual(account.session?.api.serverURL, baked)
        XCTAssertNil(account.pendingServerConfirmation)
        await eventually { !http.requests.isEmpty && connector.latest != nil }
        XCTAssertTrue(http.requests.allSatisfy { $0.url.host == "happy.example.test" })
        XCTAssertTrue(connector.urls.allSatisfy { $0.host == "happy.example.test" })
        await account.session?.stop()
    }

    @MainActor
    func testAnUnreadableRNSettingWaitsForConfirmationWithNoRequests() async throws {
        let base = try directory(), rn = base.appendingPathComponent("mmkv")
        try FileManager.default.createDirectory(at: rn, withIntermediateDirectories: true)
        try Data("torn".utf8).write(to: rn.appendingPathComponent("server-config"))
        let keychain = AccountsKeychain(), http = FakeHTTP(), connector = FakeConnector()
        keychain.items.seed(item, Data(TokenStorageFixtures.typicalJSON.utf8))
        let account = controller(keychain, directory: base, rn: rn, http: http, connector: connector)
        await account.restore()
        XCTAssertNil(account.session)
        XCTAssertEqual(account.pendingServerConfirmation?.serverURL, baked, "the placeholder isn't Happy's server either")
        XCTAssertTrue(http.requests.isEmpty)
    }
}
