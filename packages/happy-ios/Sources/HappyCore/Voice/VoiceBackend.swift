import Foundation

/// Who carries a voice call. The raw values are the wire's and the synced
/// `voiceBackend` setting's: `stream` is the Happy server's own voice stream,
/// `elevenlabs` the hosted provider.
public enum VoiceBackend: String, CaseIterable, Sendable {
    case stream
    case elevenlabs
}

/// `GET /v1/voice/config`: the backends this server offers and the one clients
/// use unless the user chose another.
public struct VoiceConfig: Decodable, Equatable, Sendable {
    /// What a server from before the config route is: it only knows ElevenLabs.
    public static let elevenLabsOnly = VoiceConfig(backends: [.elevenlabs], defaultBackend: .elevenlabs)

    public let backends: [VoiceBackend]
    public let defaultBackend: VoiceBackend?

    public init(backends: [VoiceBackend], defaultBackend: VoiceBackend?) {
        self.backends = backends
        self.defaultBackend = defaultBackend
    }

    private enum CodingKeys: String, CodingKey { case backends, defaultBackend }

    /// Backends this build doesn't know are dropped, so a newer server still
    /// offers the ones it does.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backends = try container.decode([String].self, forKey: .backends).compactMap(VoiceBackend.init(rawValue:))
        defaultBackend = try container.decodeIfPresent(String.self, forKey: .defaultBackend).flatMap(VoiceBackend.init(rawValue:))
    }

    /// ElevenLabs can always be picked, but where the server doesn't offer it
    /// the call has no grant and needs the user's own agent.
    public func requiresCustomAgentId(_ backend: VoiceBackend) -> Bool {
        backend == .elevenlabs && !backends.contains(.elevenlabs)
    }

    /// Whether a call can start on `backend` now.
    public func isAvailable(_ backend: VoiceBackend, customAgentId: String?) -> Bool {
        if backends.contains(backend) { return true }
        return requiresCustomAgentId(backend) && customAgentId != nil
    }

    /// The backend a call uses: the saved choice if it can run, else the
    /// server's default, else whatever else can. nil saved follows the server.
    public func selection(saved: VoiceBackend?, customAgentId: String?) -> VoiceBackendSelection {
        if let saved, isAvailable(saved, customAgentId: customAgentId) {
            return VoiceBackendSelection(backend: saved, savedUnavailable: false)
        }
        let fallback = ([defaultBackend].compactMap { $0 } + backends + [.elevenlabs])
            .first { isAvailable($0, customAgentId: customAgentId) }
        return VoiceBackendSelection(backend: fallback, savedUnavailable: saved != nil)
    }
}

public struct VoiceBackendSelection: Equatable, Sendable {
    /// nil when nothing can carry a call: the server offers none and there is
    /// no custom agent.
    public let backend: VoiceBackend?
    /// The user saved a backend that can't run now, so `backend` is another.
    public let savedUnavailable: Bool

    public init(backend: VoiceBackend?, savedUnavailable: Bool) {
        self.backend = backend
        self.savedUnavailable = savedUnavailable
    }
}

/// Nothing can carry a voice call: see `VoiceBackendSelection.backend`.
public struct VoiceBackendUnavailable: Error, Equatable, Sendable {
    public init() {}
}
