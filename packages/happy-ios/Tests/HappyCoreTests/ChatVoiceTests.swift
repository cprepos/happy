import Foundation
import XCTest
@testable import HappyCore
import HappyStore
import HappyWire

/// A chat's own voice: when its info screen has the row, what the row says,
/// what a choice writes, and which rows a change touches.
final class ChatVoiceTests: XCTestCase {
    typealias Fixture = LegacyHomeFixtures

    private static let stream = VoiceConfig(backends: [.stream], defaultBackend: .stream)
    private static let both = VoiceConfig(backends: [.stream, .elevenlabs], defaultBackend: .stream)

    // MARK: When the row shows

    private func row(_ values: [String: JSONValue] = [:], config: VoiceConfig?) -> ChatVoice? {
        ChatVoice(sessionId: "s1", settings: AccountSettings(values), config: config)
    }

    func testTheRowShowsWhileHappyServerCarriesTheCall() {
        XCTAssertNotNil(row(config: Self.stream))
        XCTAssertNotNil(row(config: Self.both))
        XCTAssertNotNil(row(["voiceBackend": .string("stream")], config: Self.both))
    }

    func testNoRowOnElevenLabs() {
        XCTAssertNil(row(config: .elevenLabsOnly))
        XCTAssertNil(row(["voiceBackend": .string("elevenlabs")], config: Self.both))
        // Saved, but the server no longer offers it: the call is ElevenLabs.
        XCTAssertNil(row(["voiceBackend": .string("stream")], config: .elevenLabsOnly))
    }

    func testNoRowWhenNothingCanCarryACall() {
        XCTAssertNil(row(config: VoiceConfig(backends: [], defaultBackend: nil)))
    }

    /// One's own agent on a server without ElevenLabs is a saved ElevenLabs
    /// call; without the agent the saved choice can't run and the stream does.
    func testASavedElevenLabsFollowsTheAgentOfOnesOwn() {
        let saved: [String: JSONValue] = ["voiceBackend": .string("elevenlabs")]
        XCTAssertNotNil(row(saved, config: Self.stream))
        XCTAssertNil(row(saved.merging(["voiceBypassToken": .bool(true), "voiceCustomAgentId": .string("agent_1")]) { $1 }, config: Self.stream))
        // Direct Connection off, or an empty ID, is no agent.
        XCTAssertNotNil(row(saved.merging(["voiceCustomAgentId": .string("agent_1")]) { $1 }, config: Self.stream))
        XCTAssertNotNil(row(saved.merging(["voiceBypassToken": .bool(true), "voiceCustomAgentId": .string("")]) { $1 }, config: Self.stream))
    }

    /// Until the server answers the saved service decides, so offline a chat
    /// whose account chose Happy Server still has the row.
    func testBeforeTheServerAnswersTheSavedServiceDecides() {
        XCTAssertNotNil(row(["voiceBackend": .string("stream")], config: nil))
        XCTAssertNil(row(["voiceBackend": .string("elevenlabs")], config: nil))
        XCTAssertNil(row(config: nil))
    }

    // MARK: What the row says

    func testTheRowSaysTheChatsOwnVoiceAndNeverTheDefault() {
        let settings: [String: JSONValue] = [
            "voiceAssistantVoice": .string("onyx"),
            "voiceBySession": .object(["s1": .string("deep"), "s2": .string("emma")]),
        ]
        XCTAssertEqual(ChatVoice(sessionId: "s1", settings: AccountSettings(settings), config: Self.stream)?.preset?.label, "Deep Blend")
        // Only the account's default: the row says Use default, as info.tsx.
        let other = ChatVoice(sessionId: "s3", settings: AccountSettings(settings), config: Self.stream)
        XCTAssertNotNil(other)
        XCTAssertNil(other?.preset)
    }

    /// The same reading as the call's: an unknown id is no override at all.
    func testAnUnknownOverrideReadsAsNone() {
        let settings = AccountSettings(["voiceAssistantVoice": .string("onyx"), "voiceBySession": .object(["s1": .string("removed")])])
        XCTAssertNil(settings.chatVoice(sessionId: "s1"))
        XCTAssertEqual(VoicePreset.resolve(sessionId: "s1", bySession: settings.voiceBySession, defaultId: settings.voiceAssistantVoice)?.id, "onyx")
    }

    // MARK: What a choice writes

    func testChoosingAVoiceKeepsTheOtherChats() {
        let settings = AccountSettings(["voiceBySession": .object(["s2": .string("emma")])])
        XCTAssertEqual(settings.chatVoiceDelta(sessionId: "s1", presetId: "deep"),
                       ["voiceBySession": .object(["s1": .string("deep"), "s2": .string("emma")])])
    }

    func testUseDefaultTakesTheOverrideAway() {
        let settings = AccountSettings(["voiceBySession": .object(["s1": .string("deep"), "s2": .string("emma")])])
        XCTAssertEqual(settings.chatVoiceDelta(sessionId: "s1", presetId: nil),
                       ["voiceBySession": .object(["s2": .string("emma")])])
        // The last override leaves the empty map, which is the setting's default.
        let alone = AccountSettings(["voiceBySession": .object(["s1": .string("deep")])])
        XCTAssertEqual(alone.chatVoiceDelta(sessionId: "s1", presetId: nil), ["voiceBySession": AccountSettings.defaults["voiceBySession"]])
    }

    func testAChoiceIsWhatTheCallResolves() {
        let settings = AccountSettings(["voiceAssistantVoice": .string("onyx")])
        let chosen = settings.applying(settings.chatVoiceDelta(sessionId: "s1", presetId: "fable"))
        XCTAssertEqual(VoicePreset.resolve(sessionId: "s1", bySession: chosen.voiceBySession, defaultId: chosen.voiceAssistantVoice)?.id, "fable")
        XCTAssertEqual(VoicePreset.resolve(sessionId: "s2", bySession: chosen.voiceBySession, defaultId: chosen.voiceAssistantVoice)?.id, "onyx")
        let back = chosen.applying(chosen.chatVoiceDelta(sessionId: "s1", presetId: nil))
        XCTAssertEqual(VoicePreset.resolve(sessionId: "s1", bySession: back.voiceBySession, defaultId: back.voiceAssistantVoice)?.id, "onyx")
    }

    // MARK: The words

    /// What the picker reads, in every language happy-app has them in.
    func testThePickersWordsAreInEveryCatalog() async {
        for language in AppLanguage.supported.map(\.code) {
            _ = await TranslationCatalog.load(language)
            let catalog = TranslationCatalog.catalog(for: language)
            for key in ["useDefault", "chatTitle", "chatFooter"] {
                let key = "settingsVoice.voicePicker.\(key)"
                XCTAssertNotEqual(catalog(key), key, "\(language) lacks \(key)")
            }
            XCTAssertTrue(catalog("settingsVoice.voicePicker.useDefaultSubtitle", ["name": "Heart"]).contains("Heart"), language)
        }
        let english = TranslationCatalog.catalog(for: "en")
        XCTAssertEqual(english("settingsVoice.voicePicker.useDefault"), "Use default")
        XCTAssertEqual(english("settingsVoice.voicePicker.useDefaultSubtitle", ["name": "Heart"]), "Default: Heart")
    }

    // MARK: Which rows a change touches

    private static let record = Fixture.session("s1", machine: "m1", path: "/work/happy", title: "Primary")

    private func derive(_ settings: [String: JSONValue] = [:], config: VoiceConfig? = ChatVoiceTests.stream, after applied: SessionInfoFrame? = nil) -> (output: SessionInfoUpdate, state: SessionInfoFrame)? {
        var input = SessionInfoInput()
        input.detail = SessionDetailSnapshot(
            session: Self.record, machine: Fixture.machine("m1", active: true, name: "Studio"),
            settings: SettingsSnapshot(pending: settings), dataReady: true, composer: .object([:])
        )
        input.voiceConfig = config
        return SessionInfoDerivation.derive(input, applied: applied)
    }

    func testChoosingAVoiceRebuildsOnlyTheQuickActions() throws {
        let first = try XCTUnwrap(derive())
        XCTAssertEqual(first.output.frame.voice, ChatVoice(sessionId: "s1", settings: AccountSettings(), config: Self.stream))
        let chosen = try XCTUnwrap(derive(["voiceBySession": .object(["s1": .string("deep")])], after: first.state))
        XCTAssertEqual(chosen.output.changes, SessionInfoChanges(rebuilt: [.quickActions]))
        XCTAssertEqual(chosen.output.frame.voice?.preset?.id, "deep")
    }

    /// Another chat's voice, or the default's, isn't drawn here.
    func testWhatTheRowDoesNotSayDerivesNothing() throws {
        let first = try XCTUnwrap(derive())
        XCTAssertNil(derive(["voiceBySession": .object(["s2": .string("deep")])], after: first.state))
        XCTAssertNil(derive(["voiceAssistantVoice": .string("onyx")], after: first.state))
    }

    func testTheServersAnswerTouchesTheQuickActionsOnlyWhenItBringsTheRow() throws {
        let waiting = try XCTUnwrap(derive(config: nil))
        XCTAssertNil(waiting.output.frame.voice)
        let answered = try XCTUnwrap(derive(config: Self.stream, after: waiting.state))
        XCTAssertEqual(answered.output.changes, SessionInfoChanges(rebuilt: [.quickActions]))
        XCTAssertNotNil(answered.output.frame.voice)
        XCTAssertNil(derive(config: .elevenLabsOnly, after: waiting.state))
    }

    func testChangingTheServiceTakesTheRowAway() throws {
        let first = try XCTUnwrap(derive(config: Self.both))
        let moved = try XCTUnwrap(derive(["voiceBackend": .string("elevenlabs")], config: Self.both, after: first.state))
        XCTAssertNil(moved.output.frame.voice)
        XCTAssertEqual(moved.output.changes, SessionInfoChanges(rebuilt: [.quickActions]))
    }

    func testADeletedChatHasNoRow() throws {
        var input = SessionInfoInput()
        input.detail = SessionDetailSnapshot(session: nil, machine: nil, settings: SettingsSnapshot(), dataReady: true, composer: .object([:]))
        input.voiceConfig = Self.stream
        XCTAssertNil(try XCTUnwrap(SessionInfoDerivation.derive(input, applied: nil)).output.frame.voice)
    }
}
