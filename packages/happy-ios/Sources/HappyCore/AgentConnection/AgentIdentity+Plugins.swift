import Foundation
import HappyWire

/// Our plugins' additions to `AgentIdentity`: the picture fetched on its
/// own and a deadline on each refresh, kept out of AgentIdentity.swift so
/// upstream merges do not conflict there.
extension AgentIdentity {
    /// How long one identity refresh (health, config, and the avatar when
    /// it is fetched inline) may take before it counts as a failure.
    static let deadline: Duration = .seconds(40)

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
}
