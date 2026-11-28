import Foundation
#if canImport(ElevenLabs)
import ElevenLabs
#endif

/// Our addition to the call: points upstream's unchanged ElevenLabs call
/// (`ElevenLabsCallConnection`) at our own ElevenLabs-compatible server
/// instead of ElevenLabs, kept out of the call's own files so upstream
/// merges do not conflict there. The server's two addresses come from the
/// build's Info.plist (scripts/call-server-plist.sh writes them). A build
/// without both keys changes nothing: the SDK keeps ElevenLabs.
public enum CallServer {
    /// Info.plist key of the token route the SDK asks before each call
    /// (`GET <url>?agent_id=…`, answering `{"token": …}`).
    public static let tokenURLInfoKey = "HappyCallTokenURL"
    /// Info.plist key of the LiveKit address the call's media goes to.
    public static let liveKitURLInfoKey = "HappyCallLiveKitURL"

    /// Where the SDK's calls go, once read from the build.
    struct Endpoints: Equatable {
        let tokenURL: URL
        let liveKitURL: String
    }

    /// Hands the build's server to the SDK. Once at launch is enough: the
    /// SDK reads its global configuration as each conversation starts.
    @MainActor
    public static func start() {
        #if canImport(ElevenLabs)
        let info = Bundle.main
        guard let endpoints = endpoints(tokenURL: info.object(forInfoDictionaryKey: tokenURLInfoKey),
                                        liveKitURL: info.object(forInfoDictionaryKey: liveKitURLInfoKey)) else { return }
        ElevenLabs.configure(ElevenLabs.Configuration(apiEndpoint: endpoints.tokenURL, websocketUrl: endpoints.liveKitURL))
        #endif
    }

    /// Both addresses, or nil unless both are usable: an http(s) token URL
    /// and a ws(s) LiveKit URL, each with a host. An absent, empty or
    /// unexpanded (`$(…)`) value is nil, so the SDK keeps its defaults.
    static func endpoints(tokenURL: Any?, liveKitURL: Any?) -> Endpoints? {
        guard let token = url(tokenURL, schemes: ["https", "http"]),
              let liveKit = url(liveKitURL, schemes: ["wss", "ws"]) else { return nil }
        return Endpoints(tokenURL: token, liveKitURL: liveKit.absoluteString)
    }

    private static func url(_ value: Any?, schemes: Set<String>) -> URL? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
