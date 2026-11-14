import Foundation

/// Our plugins' additions to `VoiceLanguage`: the code the server voice
/// stream takes, kept out of VoiceLanguage.swift so upstream merges do not
/// conflict there.
extension VoiceLanguage {
    /// The `language` the server voice stream takes for a setting value, as
    /// happy-app's Languages.ts `voiceCode`. It differs from `providerCode`
    /// only for Brazilian Portuguese; happy-app also offers Austrian German.
    /// nil lets the agent auto-detect, as for languages with no voice code.
    public static func streamCode(_ code: String?) -> String? {
        switch code {
        case "pt-BR": "pt-br"
        case "de-AT": "de"
        default: selection(code).providerCode
        }
    }
}
