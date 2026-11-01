import Foundation
@testable import HappyCore
import HappyWire
import XCTest

final class VoiceSystemPromptTests: XCTestCase {
    private let morgan = VoicePersona(name: "Morgan", gender: .male)

    func testAnswersToTheVoiceNameAndToHappyWithTheVoiceGender() {
        let prompt = VoiceSystemPrompt.build(persona: morgan)
        XCTAssertTrue(prompt.contains("You are a friendly man"))
        XCTAssertTrue(prompt.contains(#"like "Morgan, ..." or "Happy, ...""#))
        XCTAssertEqual(VoiceSystemPrompt.firstMessage(persona: morgan), "Hi, Morgan here")
    }

    func testAnswersToHappyAloneWithoutAPersona() {
        let prompt = VoiceSystemPrompt.build()
        XCTAssertTrue(prompt.contains("You are a friendly woman"))
        XCTAssertTrue(prompt.contains(#"like "Happy, ...""#))
        XCTAssertEqual(VoiceSystemPrompt.firstMessage(), "Hi, Happy here")
    }

    func testKeepsAPersonaNamedHappyAsHappy() {
        let base = VoiceSystemPrompt.base(persona: VoicePersona(name: "Happy", gender: .male))
        XCTAssertTrue(base.contains(#"like "Happy, ...""#))
        XCTAssertFalse(base.contains(#""Happy, ..." or "Happy, ...""#))
    }

    func testKeepsTheOnboardingGreetingNamed() {
        XCTAssertEqual(
            VoiceSystemPrompt.firstMessage(hasPro: false, onboardingPromptLoadCount: 0, includePaidVoiceOnboarding: true, persona: morgan),
            "Hi, Morgan here, ask me what I can do"
        )
    }

    func testSectionsAndCountersAreLaidOutAsInExpo() {
        let prompt = VoiceSystemPrompt.build(initialContext: "  history  ", voiceMessageCount: 3)
        XCTAssertTrue(prompt.hasPrefix("You are a voice interface for Happy"))
        XCTAssertTrue(prompt.hasSuffix("# Runtime counters\n- onboarding_prompt_load_count: 0\n- voice_message_count: 3\n\n# Conversation history so far\nhistory"))
        XCTAssertFalse(VoiceSystemPrompt.build(initialContext: " \n").contains("Conversation history"))
    }
}

final class VoiceAgentConfigTests: XCTestCase {
    private func parsed(_ config: VoiceAgentConfig) throws -> JSONValue {
        try JSONValue.decode(JSONEncoder().encode(config))
    }

    func testDefaultsAreEmptyStringsAndNullLanguageWithoutVoiceOrSpeed() throws {
        XCTAssertEqual(try parsed(VoiceAgentConfig()), .object([
            "systemPrompt": .string(""), "firstMessage": .string(""), "initialContext": .string(""),
            "language": .null, "sessionId": .string(""),
        ]))
    }

    func testSpeedGoesOnlyWithAVoice() throws {
        XCTAssertEqual(try parsed(VoiceAgentConfig(voice: "am_onyx"))["voice"], .string("am_onyx"))
        XCTAssertNil(try parsed(VoiceAgentConfig(voice: "am_onyx"))["speed"])
        XCTAssertNil(try parsed(VoiceAgentConfig(speed: 0.9))["speed"])
        XCTAssertNil(try parsed(VoiceAgentConfig(voice: "", speed: 0.9))["voice"])
        XCTAssertNil(try parsed(VoiceAgentConfig(voice: "", speed: 0.9))["speed"])
    }

    func testAPresetCarriesItsVoiceSpeedAndPersona() throws {
        let preset = try XCTUnwrap(VoicePreset.find("deep"))
        let start = VoiceStart(sessionId: "s", context: "history", language: "pl", backend: .stream, voicePreset: preset)
        let value = try parsed(VoiceAgentConfig(start: start))
        XCTAssertEqual(value["voice"], .string("am_michael(2)+am_onyx(1)"))
        XCTAssertEqual(value["speed"], .number(0.85))
        XCTAssertEqual(value["language"], .string("pl"))
        XCTAssertEqual(value["sessionId"], .string("s"))
        XCTAssertEqual(value["initialContext"], .string("history"))
        XCTAssertEqual(value["firstMessage"]?.stringValue, VoiceSystemPrompt.firstMessage(persona: VoicePersona(voice: preset.voice)))
        XCTAssertTrue(value["systemPrompt"]?.stringValue?.hasSuffix("# Conversation history so far\nhistory") == true)
    }

    func testNoPresetLeavesTheServerDefaultVoice() throws {
        let value = try parsed(VoiceAgentConfig(start: VoiceStart(sessionId: "s", context: "", backend: .stream)))
        XCTAssertNil(value["voice"])
        XCTAssertNil(value["speed"])
        XCTAssertEqual(value["firstMessage"], .string("Hi, Happy here"))
    }

    func testAMaleVoiceSpeaksAsItself() throws {
        let start = VoiceStart(sessionId: "s", context: "", backend: .stream, voicePreset: VoicePreset.find("morgan"))
        let value = try parsed(VoiceAgentConfig(start: start))
        XCTAssertEqual(value["firstMessage"], .string("Hi, Morgan Freeman here"))
        XCTAssertTrue(value["systemPrompt"]?.stringValue?.contains("You are a friendly man") == true)
    }
}
