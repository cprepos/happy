import Foundation
import HappyWire

enum AgentIdentity {
    /// How long one identity refresh (health, config, and the avatar when
    /// it is fetched inline) may take before it counts as a failure.
    static let deadline: Duration = .seconds(40)

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

    /// `refresh` without the picture, given up after `deadline` as
    /// `PairingError.unavailable` even when the transport ignores
    /// cancellation: the identity loop's step, so a request stuck on a dead
    /// tunnel turns into a retry instead of "connecting…" for good.
    static func refresh(_ account: AgentConnection, transport: any AgentTransport, token: String, within limit: Duration) async throws -> AgentConnection {
        do {
            return try await LiveBrowserFeed.within(limit) {
                try await refresh(account, transport: transport, token: token, avatar: false)
            }
        } catch BrowserError.timeout {
            throw PairingError.unavailable
        }
    }

    /// What `/v0/node/avatar` answered.
    enum Avatar: Equatable, Sendable {
        case image(Data, etag: String?)
        /// 304: the bytes held are current.
        case unchanged
        /// 404: the computer has no picture after all.
        case missing
    }

    /// The computer's picture, conditional on `etag`, over a `.file` client.
    static func avatar(etag: String?, transport: any AgentTransport, token: String) async throws -> Avatar {
        let image = try await transport.request("/v0/node/avatar", credential: token, headers: etag.map { ["If-None-Match": $0] } ?? [:], category: .file)
        if image.status == 401 || image.status == 403 { throw PairingError.revoked }
        switch image.status {
        case 200:
            guard image.body.count <= 8 * 1024 * 1024, image.headers["content-type"]?.lowercased().hasPrefix("image/") == true else { throw PairingError.invalidResponse }
            return .image(image.body, etag: image.headers["etag"])
        case 304: return .unchanged
        case 404: return .missing
        default: throw PairingError.unavailable
        }
    }

    static func apply(_ answer: Avatar, to account: inout AgentConnection) {
        switch answer {
        case .image(let data, let etag): account.avatar = data; account.avatarETag = etag
        case .unchanged: break
        case .missing: account.avatar = nil; account.avatarETag = nil
        }
    }

    /// Happy's `403` `profile_required`: the member has no profile yet.
    static func profileRequired(_ response: HTTP1Response) -> Bool {
        struct Failure: Decodable { let code: String? }
        return SignInRequired.isHappyError(contentType: response.headers["content-type"], body: response.body)
            && (try? JSONDecoder().decode(Failure.self, from: response.body))?.code == "profile_required"
    }
}
