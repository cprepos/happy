import XCTest
@testable import HappyCore

/// Our plugins' words sit beside upstream's `nativeSources`, joined in
/// `nativeSourcesWithPlugins`. Upstream's AccountKindNamingTests checks every
/// language has every word of `nativeSources`; this checks the same for the
/// joined words, so a plugin word missing from a language is caught.
final class NativeTranslationsPluginsTests: XCTestCase {
    func testEveryLanguageHasEveryPluginWord() {
        let languages = AppLanguage.supported.map(\.code)
        XCTAssertEqual(Set(TranslationCatalog.nativeSourcesWithPlugins.keys), Set(languages))
        let english = TranslationCatalog.nativeSourcesWithPlugins["en"] ?? [:]
        for language in languages {
            let words = TranslationCatalog.nativeSourcesWithPlugins[language] ?? [:]
            XCTAssertEqual(Set(words.keys), Set(english.keys), language)
        }
    }

    func testUpstreamWordsAreKeptAsTheyAre() {
        for (language, upstream) in TranslationCatalog.nativeSources {
            let joined = TranslationCatalog.nativeSourcesWithPlugins[language] ?? [:]
            for (key, text) in upstream { XCTAssertEqual(joined[key], text, "\(language) \(key)") }
        }
    }
}
