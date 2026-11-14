import Foundation
import XCTest
@testable import HappyCore
import HappyWire

// Ours: SyncEngine's pause, start and resync as this fork has them, kept out
// of SyncEngineTests.swift so upstream merges do not conflict there. The
// fixture is upstream's `SyncFixture`.

extension SyncFixture {
    func resetCount(_ category: RequestCategory) -> Int { resets.filter { $0 == category }.count }
}

/// Home that has revoked this device: every request answers 401.
private actor RevokedTransport: AgentTransport {
    var requests = 0
    func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) async throws -> HTTP1Response {
        requests += 1
        return HTTP1Response(status: 401)
    }
    func stream(path: String, credential: String, headers: [String: String]) -> HTTP1Stream {
        requests += 1
        return .init(status: 401, body: AsyncThrowingStream { $0.finish() })
    }
    func count() -> Int { requests }
    func close() {}
}

final class SyncEnginePluginsTests: XCTestCase {
    private struct Timeout: Error {}
    private func wait(_ engine: SyncEngine, _ predicate: @escaping @Sendable (HomeSnapshot) -> Bool) async throws -> HomeSnapshot {
        try await withThrowingTaskGroup(of: HomeSnapshot.self) { group in
            group.addTask {
                for await snapshot in await engine.snapshots() where predicate(snapshot) { return snapshot }
                throw Timeout()
            }
            group.addTask { try await Task.sleep(for: .seconds(4)); throw Timeout() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<80 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("not in time")
    }

    /// A run that home ended by revoking this device stays ended when the
    /// network comes back: its "pair again" stays up and nothing is asked
    /// of home again. Only a run whose setup failed starts over.
    func testAReconnectLeavesARevokedRunEnded() async throws {
        let transport = RevokedTransport()
        let engine = SyncEngine(client: AgentClient(transport: transport, token: "test"), directory: nil)
        await engine.start()
        let ended = try await wait(engine) { $0.error != nil && !$0.reconnecting }
        let message = try XCTUnwrap(ended.error)
        try await eventually { await !engine.running }
        let asked = await transport.count()
        await engine.reconnect()
        try await Task.sleep(for: .milliseconds(300))
        let after = await transport.count()
        XCTAssertEqual(after, asked)
        let error = await engine.snapshot.error
        XCTAssertEqual(error, message)
        let running = await engine.running
        XCTAssertFalse(running)
        await engine.stop()
    }

    /// A start that comes while a pause is still waiting on its tasks
    /// begins a new run; it used to find the old runner set and do nothing,
    /// leaving the engine paused until the app was relaunched.
    func testAStartDuringAPauseLeavesTheEngineRunning() async throws {
        let transport = SyncFixture()
        let engine = SyncEngine(client: AgentClient(transport: transport, token: "test"), directory: nil)
        await engine.start()
        _ = try await wait(engine) { $0.live && !$0.syncing }
        try await eventually { await engine.deliveryAllowed }
        let opened = await transport.streamsOpened()
        let pausing = Task { await engine.pause() }
        // The pause has begun once delivery is no longer allowed.
        while await engine.deliveryAllowed { await Task.yield() }
        await engine.start()
        await pausing.value
        try await eventually { await transport.streamsOpened() > opened }
        try await eventually { await engine.deliveryAllowed }
        await engine.stop()
    }

    /// Pull to refresh on a live engine: the realtime and query clients are
    /// let go (never the file client), home is read whole again although
    /// the stream could have resumed, and it answers once caught up.
    func testAResyncOnALiveEngineResetsRealtimeAndQueryAndReadsHomeAgain() async throws {
        let transport = SyncFixture()
        await transport.setDaemon("d1")
        let engine = SyncEngine(client: AgentClient(transport: transport, token: "test"), directory: nil)
        await engine.start()
        _ = try await wait(engine) { $0.live && !$0.syncing }
        let reads = await transport.bootstrapReads()
        let caughtUp = await engine.resync(timeout: .seconds(4))
        XCTAssertTrue(caughtUp)
        let realtime = await transport.resetCount(.realtime)
        let query = await transport.resetCount(.query)
        let file = await transport.resetCount(.file)
        XCTAssertEqual(realtime, 1)
        XCTAssertEqual(query, 1)
        XCTAssertEqual(file, 0)
        let after = await transport.bootstrapReads()
        XCTAssertGreaterThan(after, reads, "a refresh reads home whole, not resuming")
        await engine.stop()
    }

    /// A paused engine is left paused: nothing is reset or started.
    func testAResyncLeavesAPausedEngineAlone() async throws {
        let transport = SyncFixture()
        let engine = SyncEngine(client: AgentClient(transport: transport, token: "test"), directory: nil)
        let caughtUp = await engine.resync(timeout: .seconds(1))
        XCTAssertFalse(caughtUp)
        let resets = await transport.resets
        XCTAssertEqual(resets, [])
        let opened = await transport.streamsOpened()
        XCTAssertEqual(opened, 0)
        await engine.stop()
    }
}
