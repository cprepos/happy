import Foundation

/// Where the native viewer drives a held live browser: what `POST /take`'s
/// noVNC page names, read for its parts. The page is
/// `<origin>/live/<id>/vnc/vnc.html?…#password=…`; its socket is
/// `<origin>/live/<id>/vnc/websockify`, upgraded through the workspace proxy
/// to the bridge, which pipes it to the browser's VNC server while the link
/// is held. The password only ever lives in the fragment and in memory.
public struct LiveBrowserVNCTarget: Equatable, Sendable {
    /// The bridge, as the workspace proxy connects to it.
    public let authority: BrowserPolicy.Authority
    /// `/live/<id>/vnc/websockify`.
    public let path: String
    public let password: String

    /// Nil for a page at an origin that isn't a bridge's
    /// (`LiveBrowserLink.origins`), a path that isn't a live link's noVNC
    /// page, or no password.
    public init?(novncURL url: URL) {
        guard let scheme = url.scheme, scheme == "http", let host = url.host, let port = url.port,
              LiveBrowserLink.origins.contains("\(scheme)://\(host):\(port)"),
              let authority = BrowserPolicy.Authority(url: url) else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        // "", "live", id, "vnc", "vnc.html"
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "live", LiveBrowserLink.validID(String(parts[2])),
              parts[3] == "vnc", parts[4] == "vnc.html" else { return nil }
        guard let password = Self.password(fragment: url.fragment(percentEncoded: true)), !password.isEmpty else { return nil }
        self.authority = authority
        self.path = "/live/\(parts[2])/vnc/websockify"
        self.password = password
    }

    /// `password=…` from a fragment of `&`-separated pairs, percent-decoded.
    static func password(fragment: String?) -> String? {
        guard let fragment else { return nil }
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "password" else { continue }
            // As noVNC reads it: decodeURIComponent, a "+" kept as itself.
            return String(parts[1]).removingPercentEncoding
        }
        return nil
    }
}

extension LiveBrowserVNCTarget: CustomStringConvertible {
    /// Never the password, and the link id cut short, for logs.
    public var description: String {
        let id = path.split(separator: "/").dropFirst().first.map { String($0.prefix(6)) } ?? "?"
        return "LiveBrowserVNCTarget(\(authority.text), \(id)…)"
    }
}

extension AgentClient {
    /// The VNC socket of a held live browser: a CONNECT tunnel through the
    /// workspace proxy to the bridge, upgraded to a WebSocket that carries
    /// RFB as binary messages. The bridge checks `Host` against its own
    /// listener's names, and the held link is the authorisation: no bearer
    /// goes to the bridge.
    public func liveBrowserVNC(_ target: LiveBrowserVNCTarget, workspaceID: String) async throws -> any BrowserStream {
        let stream = try await browserTunnel(workspaceID: workspaceID, target: target.authority)
        do {
            return try await WebSocketTunnel.open(stream, path: target.path, credential: nil, host: target.authority.text, protocols: ["binary"])
        } catch {
            await stream.close()
            throw error
        }
    }
}
