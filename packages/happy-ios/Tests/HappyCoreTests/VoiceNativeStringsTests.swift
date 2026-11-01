import XCTest
@testable import HappyCore

/// The voice service's words, in every language, around two names no
/// language translates.
final class VoiceNativeStringsTests: XCTestCase {
    private static let keys = [
        "native.voice.service",
        "native.voice.needsOwnAgent",
        "native.voice.savedNotOffered",
        "native.voice.noService",
    ]

    override func setUp() async throws {
        for language in AppLanguage.supported.map(\.code) { _ = await TranslationCatalog.load(language) }
    }

    func testEveryLanguageSaysTheWordsItsOwnWay() {
        let english = TranslationCatalog.nativeSources["en"] ?? [:]
        XCTAssertEqual(Set(english.keys.filter { $0.hasPrefix("native.voice.") }), Set(Self.keys))
        for language in AppLanguage.supported.map(\.code) {
            let catalog = TranslationCatalog.catalog(for: language)
            let words = TranslationCatalog.nativeSources[language] ?? [:]
            for key in Self.keys {
                XCTAssertNotEqual(catalog(key), key, "\(language) lacks \(key)")
                XCTAssertFalse((words[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language) \(key)")
                if language != "en" { XCTAssertNotEqual(words[key], english[key], "\(language) \(key) is English") }
            }
        }
    }

    func testTheNamesStayAsTheyAre() {
        for language in AppLanguage.supported.map(\.code) {
            let catalog = TranslationCatalog.catalog(for: language)
            let told = catalog("native.voice.savedNotOffered", ["saved": "ElevenLabs", "current": "Happy Server"])
            XCTAssertTrue(told.contains("ElevenLabs"), language)
            XCTAssertTrue(told.contains("Happy Server"), language)
            XCTAssertFalse(told.contains("${"), language)
            XCTAssertTrue(catalog("native.voice.noService").contains("ElevenLabs"), language)
        }
    }

    func testEnglishIsWhatTheScreenKeeps() {
        XCTAssertEqual(TranslationCatalog.english("native.voice.service"), "Voice service")
        XCTAssertEqual(TranslationCatalog.english("native.voice.savedNotOffered", ["saved": "ElevenLabs", "current": "Happy Server"]),
                       "ElevenLabs isn’t offered by this server, so voice uses the server’s default, Happy Server.")
    }
}
