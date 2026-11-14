import Foundation
import XCTest
import HappyWire
@testable import HappyCore

/// A conversation whose first read or start failed is read again when asked
/// (`retryLoad`), once however often it is asked; a cancellation from under
/// a read is never kept as a failure.
final class ChatLoadRetryTests: XCTestCase {
    /// Every snapshot a conversation published, newest last.
    private actor Seen {
        private(set) var all: [ChatSnapshot] = []
        func add(_ snapshot: ChatSnapshot) { all.append(snapshot) }
    }

    private struct Timeout: Error {}

    private func follow(_ conversation: Conversation) -> (Seen, Task<Void, Never>) {
        let seen = Seen()
        let task = Task { for await snapshot in conversation.updates { await seen.add(snapshot) } }
        return (seen, task)
    }

    /// The newest snapshot once it passes `check`, within five seconds.
    private func eventually(_ seen: Seen, _ what: String, _ check: (ChatSnapshot) -> Bool) async throws -> ChatSnapshot {
        for _ in 0..<500 {
            if let last = await seen.all.last, check(last) { return last }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("never \(what)")
        throw Timeout()
    }

    private func conversation(_ server: FlakyServer) -> Conversation {
        let client = AgentClient(transport: server, token: "t")
        let engine = SyncEngine(client: client, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return Conversation(client: client, store: engine.spaces, agentId: "flaky")
    }

    func testAFailedReadIsReadAgainOnceHoweverOftenItIsAsked() async throws {
        let server = FlakyServer(failures: [PairingError.unavailable])
        let conversation = conversation(server)
        let (seen, following) = follow(conversation)
        defer { following.cancel() }
        await conversation.start()
        let failed = try await eventually(seen, "failed") { $0.error != nil }
        XCTAssertTrue(failed.loaded)
        XCTAssertTrue(failed.items.isEmpty)
        let reads = await server.bootstraps
        XCTAssertEqual(reads, 1)
        // Asked at once from the screen opening, the phone's return and Retry: one read.
        async let a: Void = conversation.retryLoad()
        async let b: Void = conversation.retryLoad()
        async let c: Void = conversation.retryLoad()
        _ = await (a, b, c)
        let read = try await eventually(seen, "read") { $0.loaded && $0.error == nil && !$0.items.isEmpty }
        XCTAssertEqual(read.items.first?.text, "hello")
        let retried = await server.bootstraps
        XCTAssertEqual(retried, 2)
        // Read, it is not read again.
        await conversation.retryLoad()
        let after = await server.bootstraps
        XCTAssertEqual(after, 2)
        await conversation.stop()
    }

    func testAStartWhoseClaimFailedStartsAgain() async throws {
        let server = FlakyServer(failures: [])
        let conversation = conversation(server)
        let claims = Counter()
        await conversation.overrideClaim { _ in
            if claims.next() == 1 { throw PairingError.unavailable }
        }
        let (seen, following) = follow(conversation)
        defer { following.cancel() }
        await conversation.start()
        let failed = try await eventually(seen, "failed") { $0.error != nil }
        XCTAssertFalse(failed.loaded, "nothing was read")
        let inFlight = await conversation.loadInFlight
        XCTAssertFalse(inFlight)
        // A second start on its own changes nothing it shouldn't, and a retry starts it.
        async let a: Void = conversation.retryLoad()
        async let b: Void = conversation.retryLoad()
        _ = await (a, b)
        let read = try await eventually(seen, "read") { $0.loaded && $0.error == nil && !$0.items.isEmpty }
        XCTAssertEqual(read.items.first?.text, "hello")
        XCTAssertEqual(claims.count, 2)
        let reads = await server.bootstraps
        XCTAssertEqual(reads, 1)
        await conversation.stop()
    }

    func testACancellationFromUnderAReadIsNeverKeptAsAFailure() async throws {
        let server = FlakyServer(failures: [CancellationError()])
        let conversation = conversation(server)
        let (seen, following) = follow(conversation)
        defer { following.cancel() }
        await conversation.start()
        let read = try await eventually(seen, "read") { $0.loaded && !$0.items.isEmpty }
        XCTAssertNil(read.error)
        let shown = await seen.all
        XCTAssertFalse(shown.contains { $0.error != nil }, "no failure was shown on the way")
        let reads = await server.bootstraps
        XCTAssertEqual(reads, 2)
        await conversation.stop()
    }

    func testAStoppedConversationIsNotStartedAgain() async throws {
        let server = FlakyServer(failures: [])
        let conversation = conversation(server)
        await conversation.stop()
        await conversation.retryLoad()
        await conversation.start()
        let reads = await server.bootstraps
        XCTAssertEqual(reads, 0)
    }
}

/// A counter any thread may move.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// A daemon with one conversation of one run, whose bootstraps throw
/// `failures` in turn before answering.
private actor FlakyServer: AgentTransport {
    private var failures: [Error]
    private(set) var bootstraps = 0
    init(failures: [Error]) { self.failures = failures }

    func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) throws -> HTTP1Response {
        let value: JSONValue
        if path.contains("/messages?") {
            value = .object(["hasMore": .bool(false), "runs": .array([
                .object(["id": .string("r0"), "status": .string("completed"), "startedAt": .number(0), "messages": .array([
                    .object(["id": .string("u0"), "role": .string("user"), "createdAt": .number(0), "metadata": .object([:]),
                             "content": .array([.object(["type": .string("text"), "text": .string("hello")])])]),
                ])]),
            ])])
        } else if path.hasSuffix("/bootstrap") {
            bootstraps += 1
            if !failures.isEmpty { throw failures.removeFirst() }
            value = .object(["agent": .object(["id": .string("flaky"), "workspaceId": .string("w"), "status": .string("idle")]), "pending": .array([])])
        } else {
            value = .object([:])
        }
        return .init(status: 200, body: try JSONEncoder().encode(value))
    }

    func close() {}
}
