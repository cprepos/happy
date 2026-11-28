#if canImport(UIKit)
@testable import HappyUI
import XCTest

/// The call's own server (CallServer+Addons.swift) is used only when the
/// build names both addresses, each one usable; anything else keeps the SDK
/// on ElevenLabs.
final class CallServerAddonsTests: XCTestCase {
    private let token = "https://happy.example.test/elevenlabs/v1/convai/conversation/token"
    private let liveKit = "wss://happy.example.test/elevenlabs"

    func testBothAddressesAreUsed() throws {
        let endpoints = try XCTUnwrap(CallServer.endpoints(tokenURL: token, liveKitURL: liveKit))
        XCTAssertEqual(endpoints.tokenURL.absoluteString, token)
        XCTAssertEqual(endpoints.liveKitURL, liveKit)
    }

    func testLocalPlainAddressesAreUsed() throws {
        let endpoints = try XCTUnwrap(CallServer.endpoints(tokenURL: " http://192.168.2.10:8080/token\n", liveKitURL: "ws://192.168.2.56:7880"))
        XCTAssertEqual(endpoints.tokenURL.absoluteString, "http://192.168.2.10:8080/token")
        XCTAssertEqual(endpoints.liveKitURL, "ws://192.168.2.56:7880")
    }

    func testEitherMissingKeepsElevenLabs() {
        XCTAssertNil(CallServer.endpoints(tokenURL: nil, liveKitURL: nil))
        XCTAssertNil(CallServer.endpoints(tokenURL: token, liveKitURL: nil))
        XCTAssertNil(CallServer.endpoints(tokenURL: nil, liveKitURL: liveKit))
        XCTAssertNil(CallServer.endpoints(tokenURL: "", liveKitURL: liveKit))
        XCTAssertNil(CallServer.endpoints(tokenURL: token, liveKitURL: "  "))
    }

    func testUnusableValuesKeepElevenLabs() {
        // An unexpanded build setting, a value of the wrong type, no host, the wrong scheme.
        XCTAssertNil(CallServer.endpoints(tokenURL: "$(HAPPY_CALL_TOKEN_URL)", liveKitURL: liveKit))
        XCTAssertNil(CallServer.endpoints(tokenURL: token, liveKitURL: "$(HAPPY_CALL_LIVEKIT_URL)"))
        XCTAssertNil(CallServer.endpoints(tokenURL: 42, liveKitURL: liveKit))
        XCTAssertNil(CallServer.endpoints(tokenURL: "https:///token", liveKitURL: liveKit))
        XCTAssertNil(CallServer.endpoints(tokenURL: "happy.example.test/token", liveKitURL: liveKit))
        XCTAssertNil(CallServer.endpoints(tokenURL: "wss://happy.example.test/token", liveKitURL: liveKit))
        XCTAssertNil(CallServer.endpoints(tokenURL: token, liveKitURL: "https://happy.example.test/elevenlabs"))
    }

    func testTheKeysAreTheOnesTheBuildScriptWrites() {
        XCTAssertEqual(CallServer.tokenURLInfoKey, "HappyCallTokenURL")
        XCTAssertEqual(CallServer.liveKitURLInfoKey, "HappyCallLiveKitURL")
    }
}
#endif
