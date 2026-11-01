import Foundation
@testable import HappyCore
import HappyWire
import XCTest

final class VoiceConfigAPITests: XCTestCase {
    func testConfigIsAuthenticatedAndDecodesTheWireShape() async throws {
        let http = FakeHTTP()
        http.onRaw("GET /v1/voice/config", #"{"backends":["stream","elevenlabs"],"defaultBackend":"stream"}"#)
        let config = try await testAPI(http).voiceConfig()
        XCTAssertEqual(config, VoiceConfig(backends: [.stream, .elevenlabs], defaultBackend: .stream))
        XCTAssertEqual(http.requests("GET /v1/voice/config").first?.headers["Authorization"], "Bearer token-1")
    }

    func testOlderServerAnswering404IsElevenLabsOnly() async throws {
        let config = try await testAPI(FakeHTTP()).voiceConfig()
        XCTAssertEqual(config, .elevenLabsOnly)
        XCTAssertEqual(config.backends, [.elevenlabs])
        XCTAssertEqual(config.defaultBackend, .elevenlabs)
    }

    func testUnknownServerValuesAreDropped() async throws {
        let http = FakeHTTP()
        http.onRaw("GET /v1/voice/config", #"{"backends":["carrier-pigeon","stream"],"defaultBackend":"carrier-pigeon"}"#)
        let config = try await testAPI(http).voiceConfig()
        XCTAssertEqual(config, VoiceConfig(backends: [.stream], defaultBackend: nil))
    }

    func testServerOfferingNothing() async throws {
        let http = FakeHTTP()
        http.onRaw("GET /v1/voice/config", #"{"backends":[],"defaultBackend":null}"#)
        let config = try await testAPI(http).voiceConfig()
        XCTAssertEqual(config, VoiceConfig(backends: [], defaultBackend: nil))
    }

    func testOtherFailuresAreNotAnOlderServer() async throws {
        let http = FakeHTTP()
        http.onRaw("GET /v1/voice/config", "secret", status: 500)
        do { _ = try await testAPI(http).voiceConfig(); XCTFail("500 must throw") }
        catch let error as APIError { XCTAssertEqual(error, .http(status: 500, body: "Voice service unavailable")) }

        http.onRaw("GET /v1/voice/config", "", status: 401)
        do { _ = try await testAPI(http).voiceConfig(); XCTFail("401 must throw") }
        catch let error as APIError { XCTAssertEqual(error, .unauthorized) }

        http.onRaw("GET /v1/voice/config", "{}")
        do { _ = try await testAPI(http).voiceConfig(); XCTFail("malformed must throw") }
        catch let error as APIError { XCTAssertEqual(error, .decoding("Invalid voice response")) }
    }
}

final class VoiceBackendSelectionTests: XCTestCase {
    private let both = VoiceConfig(backends: [.stream, .elevenlabs], defaultBackend: .stream)
    private let streamOnly = VoiceConfig(backends: [.stream], defaultBackend: .stream)
    private let none = VoiceConfig(backends: [], defaultBackend: nil)

    private func expect(_ config: VoiceConfig, saved: VoiceBackend?, agent: String? = nil, _ backend: VoiceBackend?, unavailable: Bool = false, line: UInt = #line) {
        XCTAssertEqual(config.selection(saved: saved, customAgentId: agent), VoiceBackendSelection(backend: backend, savedUnavailable: unavailable), line: line)
    }

    func testNothingSavedFollowsTheServerDefault() {
        expect(both, saved: nil, .stream)
        expect(VoiceConfig(backends: [.stream, .elevenlabs], defaultBackend: .elevenlabs), saved: nil, .elevenlabs)
    }

    func testSavedChoiceWinsWhenOffered() {
        expect(both, saved: .elevenlabs, .elevenlabs)
        expect(both, saved: .stream, .stream)
    }

    func testNoDefaultTakesTheFirstOffered() {
        expect(VoiceConfig(backends: [.elevenlabs, .stream], defaultBackend: nil), saved: nil, .elevenlabs)
    }

    func testDefaultNotOfferedIsNotUsed() {
        expect(VoiceConfig(backends: [.stream], defaultBackend: .elevenlabs), saved: nil, .stream)
    }

    func testSavedStreamOnOlderServerFallsBackAndSaysSo() {
        expect(.elevenLabsOnly, saved: .stream, .elevenlabs, unavailable: true)
    }

    func testElevenLabsNotOfferedNeedsACustomAgent() {
        XCTAssertTrue(streamOnly.requiresCustomAgentId(.elevenlabs))
        XCTAssertFalse(both.requiresCustomAgentId(.elevenlabs))
        XCTAssertFalse(streamOnly.requiresCustomAgentId(.stream))
        expect(streamOnly, saved: .elevenlabs, .stream, unavailable: true)
        expect(streamOnly, saved: .elevenlabs, agent: "agent", .elevenlabs)
    }

    func testCustomAgentDoesNotOverrideTheDefaultUnlessChosen() {
        expect(streamOnly, saved: nil, agent: "agent", .stream)
    }

    func testServerOfferingNothing() {
        expect(none, saved: nil, nil)
        expect(none, saved: .stream, nil, unavailable: true)
        expect(none, saved: .elevenlabs, nil, unavailable: true)
        expect(none, saved: nil, agent: "agent", .elevenlabs)
        expect(none, saved: .stream, agent: "agent", .elevenlabs, unavailable: true)
    }
}

final class VoiceSettingsTests: XCTestCase {
    func testDefaultsAreNull() {
        let settings = AccountSettings()
        XCTAssertNil(settings.voiceBackend)
        XCTAssertNil(settings.voiceAssistantVoice)
        XCTAssertEqual(settings.voiceBySession, [:])
        XCTAssertEqual(AccountSettings.defaults["voiceBackend"], .null)
        XCTAssertEqual(AccountSettings.defaults["voiceAssistantVoice"], .null)
        XCTAssertEqual(AccountSettings.defaults["voiceBySession"], .object([:]))
    }

    func testStoredValuesRead() {
        let settings = AccountSettings([
            "voiceBackend": .string("stream"),
            "voiceAssistantVoice": .string("emma"),
            "voiceBySession": .object(["s1": .string("lewis"), "bad": .number(1)]),
        ])
        XCTAssertEqual(settings.voiceBackend, .stream)
        XCTAssertEqual(settings.voiceAssistantVoice, "emma")
        XCTAssertEqual(settings.voiceBySession, ["s1": "lewis"])
    }

    func testUnknownBackendReadsAsFollowingTheServerButSurvivesARoundTrip() {
        let settings = AccountSettings(["voiceBackend": .string("newer")])
        XCTAssertNil(settings.voiceBackend)
        XCTAssertEqual(settings["voiceBackend"], .string("newer"))
    }
}

final class VoicePresetTests: XCTestCase {
    func testTheCatalog() {
        XCTAssertEqual(VoicePreset.all.count, 13)
        XCTAssertEqual(Set(VoicePreset.all.map(\.id)).count, 13)
        XCTAssertEqual(Set(VoicePreset.all.map(\.label)).count, 13)
        XCTAssertEqual(VoicePreset.all.map(\.id), ["morgan", "heart", "bella", "nicole", "michael", "onyx", "deep", "fenrir", "puck", "emma", "george", "fable", "lewis"])
        XCTAssertEqual(VoicePreset.find("heart"), VoicePreset(id: "heart", label: "Heart", voice: "af_heart", speed: 1, accent: .us, tone: .warm))
        XCTAssertEqual(VoicePreset.find("deep"), VoicePreset(id: "deep", label: "Deep Blend", voice: "am_michael(2)+am_onyx(1)", speed: 0.85, accent: .us, tone: .deep))
        XCTAssertEqual(VoicePreset.find("lewis"), VoicePreset(id: "lewis", label: "Lewis", voice: "bm_lewis", speed: 1, accent: .uk, tone: .deep))
    }

    func testFind() {
        XCTAssertNil(VoicePreset.find(nil))
        XCTAssertNil(VoicePreset.find(""))
        XCTAssertNil(VoicePreset.find("nope"))
        XCTAssertEqual(VoicePreset.find("george")?.label, "George")
    }

    func testChatOverrideThenDefaultThenNone() {
        XCTAssertEqual(VoicePreset.resolve(sessionId: "s1", bySession: ["s1": "lewis"], defaultId: "bella")?.id, "lewis")
        XCTAssertEqual(VoicePreset.resolve(sessionId: "s2", bySession: ["s1": "lewis"], defaultId: "bella")?.id, "bella")
        XCTAssertNil(VoicePreset.resolve(sessionId: "s2", bySession: [:], defaultId: nil))
    }

    func testUnknownIdsFallThrough() {
        XCTAssertEqual(VoicePreset.resolve(sessionId: "s1", bySession: ["s1": "retired"], defaultId: "bella")?.id, "bella")
        XCTAssertNil(VoicePreset.resolve(sessionId: "s1", bySession: ["s1": "retired"], defaultId: "gone"))
    }

    func testSettingAnOverride() {
        let base = ["a": "heart"]
        let set = VoicePreset.settingOverride(base, sessionId: "b", presetId: "onyx")
        XCTAssertEqual(set, ["a": "heart", "b": "onyx"])
        XCTAssertEqual(VoicePreset.settingOverride(set, sessionId: "b", presetId: nil), ["a": "heart"])
        XCTAssertEqual(VoicePreset.settingOverride(set, sessionId: "b", presetId: "unknown"), ["a": "heart"])
    }

    func testPersonaFromVoiceId() {
        XCTAssertEqual(VoicePersona(voice: "am_morgan"), VoicePersona(name: "Morgan Freeman", gender: .male))
        XCTAssertEqual(VoicePersona(voice: "af_heart"), VoicePersona(name: "Heart", gender: .female))
        XCTAssertEqual(VoicePersona(voice: "bf_emma"), VoicePersona(name: "Emma", gender: .female))
        XCTAssertEqual(VoicePersona(voice: "bm_lewis"), VoicePersona(name: "Lewis", gender: .male))
        XCTAssertEqual(VoicePersona(voice: "am_michael(2)+am_onyx(1)"), VoicePersona(name: "Michael", gender: .male))
        XCTAssertNil(VoicePersona(voice: "zz"))
        XCTAssertNil(VoicePersona(voice: "am"))
        XCTAssertNil(VoicePersona(voice: ""))
    }

    func testSingleVoicePresetsAnswerToTheirLabel() throws {
        for preset in VoicePreset.all {
            let persona = try XCTUnwrap(VoicePersona(voice: preset.voice), preset.id)
            if !preset.voice.contains("+") { XCTAssertEqual(persona.name, preset.label, preset.id) }
        }
    }
}

final class VoiceStreamLanguageTests: XCTestCase {
    /// Every voiceCode in happy-app's constants/Languages.ts.
    func testStreamCodeMatchesHappyApp() {
        let table: [(String?, String?)] = [
            (nil, nil), ("en-US", "en"), ("en-GB", "en"), ("en-AU", "en"), ("en-CA", "en"),
            ("es-ES", "es"), ("es-MX", "es"), ("es-AR", "es"), ("fr-FR", "fr"), ("fr-CA", "fr"),
            ("de-DE", "de"), ("de-AT", "de"), ("it-IT", "it"), ("pt-BR", "pt-br"), ("pt-PT", "pt"),
            ("ru-RU", "ru"), ("zh-CN", "zh"), ("zh-TW", "zh"), ("ja-JP", "ja"), ("ko-KR", "ko"),
            ("ar-SA", "ar"), ("hi-IN", "hi"), ("nl-NL", "nl"), ("sv-SE", "sv"), ("no-NO", "no"),
            ("da-DK", "da"), ("fi-FI", "fi"), ("pl-PL", "pl"), ("tr-TR", "tr"), ("he-IL", nil),
            ("th-TH", nil), ("vi-VN", "vi"), ("id-ID", "id"), ("ms-MY", "ms"), ("uk-UA", "uk"),
            ("cs-CZ", "cs"), ("hu-HU", "hu"), ("ro-RO", "ro"), ("bg-BG", "bg"), ("el-GR", "el"),
            ("hr-HR", "hr"), ("sk-SK", "sk"), ("sl-SI", nil), ("et-EE", nil), ("lv-LV", nil),
            ("lt-LT", nil), ("unknown", nil),
        ]
        for (code, expected) in table {
            XCTAssertEqual(VoiceLanguage.streamCode(code), expected, code ?? "nil")
        }
    }

    func testElevenLabsMapIsUnchanged() {
        XCTAssertEqual(VoiceLanguage.selection("pt-BR").providerCode, "pt")
        XCTAssertNil(VoiceLanguage.selection("de-AT").providerCode)
    }
}
