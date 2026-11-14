import Foundation
import XCTest
@testable import HappyCore
import HappyWire

// Our AgentConnections tests, kept out of AgentConnectionsTests.swift so
// upstream merges do not conflict there.
@MainActor
final class AgentConnectionsPluginsTests: XCTestCase {
    /// Pull to refresh on a computer waiting out its retry backoff asks
    /// again at once, showing connecting, not when the backoff ends; a
    /// revoked computer and a backgrounded app are left alone.
    func testRestartingARetryingConnectionSkipsTheBackoff() async throws {
        let transport = IdentityTransport()
        let manager = AgentConnections(credentials: InMemoryAgentConnectionCredentialStore(), directory: nil, makeTransport: { _ in transport })
        await manager.setForeground(false)
        // `add` reads the identity once itself and shrugs off a failure:
        // the first failure is that read's, the second the loop's first
        // check, which leaves it retrying a second later.
        await transport.failNext(2)
        let account = try await manager.add(value("retrying"), name: "Mac")
        await manager.setForeground(true)
        for _ in 0..<100 where manager.accounts.first?.status != .retrying { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(manager.accounts.first?.status, .retrying)
        var seen: [ConnectionStatus] = []
        manager.onChange = { [weak manager] in
            if let status = manager?.accounts.first?.status { seen.append(status) }
        }
        let asked = Date()
        await manager.restartConnection(account.id)
        // The first retry waits a second; this is well inside it.
        for _ in 0..<60 where manager.accounts.first?.status != .connected { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(manager.accounts.first?.status, .connected)
        XCTAssertLessThan(Date().timeIntervalSince(asked), 0.9)
        XCTAssertEqual(seen.first, .connecting)
        manager.onChange = nil
        // The picture is fetched after connecting; let it land first.
        for _ in 0..<100 {
            if await transport.paths().contains("/v0/node/avatar") { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        await manager.setForeground(false)
        let background = await transport.paths().count
        await manager.restartConnection(account.id)
        try await Task.sleep(for: .milliseconds(30))
        let afterBackground = await transport.paths().count
        XCTAssertEqual(afterBackground, background)
        XCTAssertEqual(manager.accounts.first?.status, .paused)

        await transport.configure(revoked: true)
        await manager.setForeground(true)
        for _ in 0..<100 where manager.accounts.first?.status != .revoked { try await Task.sleep(for: .milliseconds(5)) }
        let revoked = await transport.paths().count
        await manager.restartConnection(account.id)
        try await Task.sleep(for: .milliseconds(30))
        let afterRevoked = await transport.paths().count
        XCTAssertEqual(afterRevoked, revoked)
        XCTAssertEqual(manager.accounts.first?.status, .revoked)
        try await manager.remove(account.id)
    }

    private func value(_ id: String = "device") -> AgentConnectionCredentials {
        AgentConnectionCredentials(address: "tcAddress", port: 24781, deviceID: id, deviceToken: CanonicalBase64URL.encode(Data(repeating: 7, count: 32)))
    }
}
