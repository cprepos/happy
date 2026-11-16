import Foundation

// Our edge handling for `AgentHTTPTransport.classify`, kept out of
// ProxyTunnels.swift so upstream merges do not conflict there.
extension AgentHTTPTransport {
    /// `classify`'s last step, a refusal that is neither sign-in nor the
    /// daemon's own: a 5xx or an unreadable status is a passing failure,
    /// and only the edge's settled answer (`TunnelSupport.isDefinitive`)
    /// blocks the origin.
    static func classifyEdge(_ refusal: TunnelRefusal, origin: String, support: TunnelSupport = .shared) -> any Error {
        guard TunnelSupport.isDefinitive(status: refusal.status) else {
            return refusal.status >= 500 ? BrowserError.upstream(refusal.status) : BrowserError.unavailable
        }
        support.set(.blocked, for: origin)
        return BrowserError.tunnelsBlocked
    }

    /// `classify` with its own `TunnelSupport`, for a test.
    static func classify(_ refusal: TunnelRefusal, origin: String, support: TunnelSupport) -> any Error {
        if refusal.requiresSignIn || refusal.isHappyError { return classify(refusal, origin: origin) }
        return classifyEdge(refusal, origin: origin, support: support)
    }
}
