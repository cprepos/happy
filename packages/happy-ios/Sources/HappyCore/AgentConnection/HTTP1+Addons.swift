import Foundation

/// Our plugins' lease deadline for `AgentHTTPTransport`, kept out of
/// HTTP1.swift so upstream merges do not conflict there. `lease(_:until:)`
/// in HTTP1.swift hands its deadline to `TailcatClients.lease(_:until:)`.
extension AgentHTTPTransport {
    /// `perform`'s lease: the connect counts against the request's deadline
    /// too, so a request waiting on a client that never comes up gives up
    /// when its answer would have. Returns the lease and the time left of
    /// the deadline for the exchange.
    func leaseWithinDeadline(_ category: RequestCategory) async throws -> (TailcatClients<Tunnel>.Lease?, Duration) {
        let deadline = ContinuousClock.now + Self.deadline(category)
        let lease = try await lease(category, until: deadline)
        return (lease, max(.zero, deadline - ContinuousClock.now))
    }
}
