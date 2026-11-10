import Foundation

// Our avatar fetch for `AgentConnections`, kept out of
// AgentConnections.swift so upstream merges do not conflict there.
extension AgentConnections {
    /// The avatar fetch's answer, kept if the computer still shows the
    /// picture it was asked for.
    func applyAvatar(_ answer: AgentIdentity.Avatar, id: String, thumbhash: String, generation: UInt64) async {
        guard !Task.isCancelled, self.generation == generation,
              let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].thumbhash == thumbhash else { return }
        var updated = accounts[index]
        AgentIdentity.apply(answer, to: &updated)
        guard updated != accounts[index] else { return }
        accounts[index] = updated
        onChange?()
        try? await storage.update(updated)
    }

    func avatarETag(_ id: String) -> String? { accounts.first { $0.id == id }?.avatarETag }
}

/// One fire-and-forget read of a computer's picture, after its identity
/// loop has said `.connected`. It runs over a transport of its own (the
/// loop's is closed after each check), on a `.file` client, so a picture
/// that is slow to come (its slot has a 15 minute deadline) never holds the
/// status back; the transport is closed when the read ends or is
/// cancelled, and the loop starts another only once this one is over.
final class AvatarFetch: @unchecked Sendable {
    /// How long one read may take before the next refresh may try again.
    static let limit: Duration = .seconds(120)

    private let lock = NSLock()
    private var isRunning = true
    private var task: Task<Void, Never>?

    var running: Bool { lock.withLock { isRunning } }

    init(id: String, thumbhash: String, transport: AgentEndpointTransport, token: String, generation: UInt64, owner: AgentConnections) {
        let task = Task { [weak self, weak owner] in
            await Self.read(id: id, thumbhash: thumbhash, transport: transport, token: token, generation: generation, owner: owner)
            // Its own transport: no tunnel of it idles on the radio after.
            await transport.close()
            self?.finish()
        }
        lock.withLock { self.task = task }
    }

    private static func read(id: String, thumbhash: String, transport: AgentEndpointTransport, token: String, generation: UInt64, owner: AgentConnections?) async {
        guard !Task.isCancelled, let owner else { return }
        let etag = await owner.avatarETag(id)
        guard !Task.isCancelled,
              let answer = try? await LiveBrowserFeed.within(AvatarFetch.limit, { try await AgentIdentity.avatar(etag: etag, transport: transport, token: token) }),
              !Task.isCancelled else { return }
        await owner.applyAvatar(answer, id: id, thumbhash: thumbhash, generation: generation)
    }

    private func finish() { lock.withLock { isRunning = false } }

    func cancel() { lock.withLock { task }?.cancel() }
}
