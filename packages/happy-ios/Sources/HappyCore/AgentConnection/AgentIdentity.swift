import Foundation
import HappyWire

enum AgentIdentity {
    /// A serialized config+image read. ETag, not ThumbHash, identifies bytes.
    /// With `avatar` false the picture is left to `avatar(etag:…)`, so a
    /// slow picture never holds the connection's status back.
    static func refresh(_ account: AgentConnection, transport: any AgentTransport, token: String, avatar fetchAvatar: Bool = true) async throws -> AgentConnection {
        func check(_ response: HTTP1Response) throws {
            if response.status == 401 || response.status == 403 { throw PairingError.revoked }
            guard response.status == 200 else { throw PairingError.unavailable }
        }
        let health = try await transport.request("/v0/health", credential: token)
        try check(health)
        struct Health: Decodable { struct Version: Decodable { let `protocol`: Int }; let ready: Bool; let version: Version; let instanceId: String? }
        let state = try JSONDecoder().decode(Health.self, from: health.body)
        guard state.version.protocol >= 27 else { throw PairingError.updateRequired }
        guard state.ready else { throw PairingError.unavailable }
        let response = try await transport.request("/v0/config", credential: token)
        var updated = account
        updated.instanceId = state.instanceId.flatMap { HappyLink.isInstanceID($0) ? $0 : nil }
        // A member with no profile yet is connected, and asked their name;
        // the server's own name and picture are read once they have one.
        if response.status == 403, Self.profileRequired(response) {
            updated.status = .connected
            return updated
        }
        try check(response)
        struct Configuration: Decodable {
            struct Config: Decodable {
                struct Node: Decodable { struct Avatar: Decodable { let thumbhash: String }; let name: String; let avatar: Avatar? }
                let node: Node?
            }
            let config: Config
        }
        let config = try JSONDecoder().decode(Configuration.self, from: response.body)
        if let node = config.config.node {
            guard !node.name.isEmpty, node.name.count <= 128, !node.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw PairingError.invalidResponse }
            updated.name = AgentName.friendly(node.name)
            updated.thumbhash = node.avatar?.thumbhash
            if node.avatar == nil { updated.avatar = nil; updated.avatarETag = nil }
            else if fetchAvatar {
                apply(try await avatar(etag: account.avatarETag, transport: transport, token: token), to: &updated)
            }
        }
        updated.status = .connected
        return updated
    }

    /// Happy's `403` `profile_required`: the member has no profile yet.
    static func profileRequired(_ response: HTTP1Response) -> Bool {
        struct Failure: Decodable { let code: String? }
        return SignInRequired.isHappyError(contentType: response.headers["content-type"], body: response.body)
            && (try? JSONDecoder().decode(Failure.self, from: response.body))?.code == "profile_required"
    }
}
