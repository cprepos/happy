import Foundation
@testable import HappyCore
import XCTest

final class BrowserTests: XCTestCase {
    func testClassification() throws {
        for host in ["localhost", "localhost.", "a.localhost", "127.0.0.1", "127.1", "0x7f000001", "2130706433", "0.0.0.0", "Mac.local", "intranet", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.2", "169.254.1.2", "100.64.0.1", "[::1]", "[fd00::1]", "[fe80::1]", "[::ffff:127.0.0.1]", "[::ffff:7f00:1]"] {
            XCTAssertEqual(BrowserPolicy.route(try XCTUnwrap(URL(string: "http://\(host):5173/"))), .web, host)
        }
        for host in ["example.com", "172.32.0.1", "192.169.1.2", "8.8.8.8", "[2606:4700::1111]"] {
            XCTAssertEqual(BrowserPolicy.route(try XCTUnwrap(URL(string: "https://\(host)/"))), .web, host)
        }
        XCTAssertEqual(BrowserPolicy.route(URL(string: "https://preview.example.com")!), .web)
        XCTAssertEqual(BrowserPolicy.route(URL(string: "mailto:steve@example.com")!), .system)
        XCTAssertEqual(BrowserPolicy.route(URL(string: "tel:1234")!), .system)
    }

    func testAuthority() {
        XCTAssertEqual(BrowserPolicy.Authority(url: URL(string: "https://EXAMPLE.com")!)?.text, "example.com:443")
        XCTAssertEqual(BrowserPolicy.Authority(url: URL(string: "http://[::1]:5173")!)?.text, "[::1]:5173")
        XCTAssertNil(BrowserPolicy.Authority(url: URL(string: "http://user:secret@localhost")!))
        if let malformed = URL(string: "http://:80") { XCTAssertNil(BrowserPolicy.Authority(url: malformed)) }
    }

    func testWorkspaceSelectionUsesArtifactThenChatThenLocalHost() async throws {
        let client = AgentClient(transport: RoutingTransport(responses: [
            "/v0/artifacts/art1": #"{"artifact":{"updatedSource":{"workspaceId":"artifactworkspace"}}}"#,
            "/v0/agents/chat1": #"{"agent":{"id":"chat1","workspaceId":"chatworkspace","status":"idle"}}"#,
            "/v0/workspaces": #"{"workspaces":[{"id":"runnerworkspace","status":"active","compute":{"type":"host","runnerId":"runner1"}},{"id":"hostworkspace","status":"active","compute":{"type":"host","path":"/Users/me"}}]}"#,
        ]), token: "test")
        let artifact = try await client.browserWorkspace(agentID: "chat1", artifactID: "art1")
        let chat = try await client.browserWorkspace(agentID: "chat1")
        let host = try await client.browserWorkspace()
        XCTAssertEqual(artifact, "artifactworkspace")
        XCTAssertEqual(chat, "chatworkspace")
        XCTAssertEqual(host, "hostworkspace")
        let runnerOnly = AgentClient(transport: RoutingTransport(responses: ["/v0/workspaces": #"{"workspaces":[{"id":"runnerworkspace","status":"active","compute":{"type":"host","runnerId":"runner1"}}]}"#]), token: "test")
        do { _ = try await runnerOnly.browserWorkspace(); XCTFail("must not silently use a runner as the host fallback") }
        catch { XCTAssertEqual(error as? BrowserError, .unavailable) }
    }

    func testArtifactBoundaryAndQueryArePreserved() throws {
        XCTAssertEqual(try BrowserPolicy.artifactPath(target: "/api/v1/kv/entry?key=a%2Fb", artifactID: "art1", version: 2), "/v0/artifacts/art1/api/v1/kv/entry?key=a%2Fb")
        XCTAssertEqual(try BrowserPolicy.artifactPath(target: "/nested/app.js", artifactID: "art1", version: 2), "/v0/artifacts/art1/versions/2/files/nested/app.js")
        for target in ["//other/api/v1", "/api/../agents", "/api/%2e%2e/agents", "/api/%252e%252e/agents", "/api/a%2fb", "/api/a%5cb", "/api/a%00", "/api/a\r\nX:yes", "http://other/"] {
            XCTAssertThrowsError(try BrowserPolicy.artifactPath(target: target, artifactID: "art1", version: 2), target)
        }
    }

    func testRequestTranslationPreservesMethodsAndConditionsButReplacesCredentials() throws {
        let raw = Data("PUT /api/v1/kv/entry?key=a HTTP/1.1\r\nHost: page\r\nAuthorization: attacker\r\nProxy-Authorization: local\r\nX-Happy-Proxy-Route: attacker\r\nIf-Match: version1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let (head, rest) = try XCTUnwrap(BrowserHTTPHead.parse(raw))
        let translated = try head.artifactRequest(artifactID: "art1", version: 3, credential: "native-token")
        XCTAssertEqual(translated.line, "PUT /v0/artifacts/art1/api/v1/kv/entry?key=a HTTP/1.1")
        XCTAssertEqual(translated.value("Authorization"), "Bearer native-token")
        XCTAssertEqual(translated.value("If-Match"), "version1")
        XCTAssertNil(translated.value("Proxy-Authorization"))
        XCTAssertNil(translated.value("X-Happy-Proxy-Route"))
        XCTAssertEqual(rest, Data("{}".utf8))
    }

    func testResponsePreservesErrorStatusAndDuplicateCookies() throws {
        let raw = Data("HTTP/1.1 409 Conflict\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nETag: x\r\nRetry-After: 3\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n".utf8)
        let (head, rest) = try XCTUnwrap(BrowserHTTPHead.parse(raw))
        let result = head.artifactResponse()
        XCTAssertEqual(result.line, "HTTP/1.1 409 Conflict")
        XCTAssertEqual(result.fields.filter { $0.0 == "Set-Cookie" }.count, 2)
        XCTAssertEqual(result.value("Retry-After"), "3")
        XCTAssertEqual(result.value("Transfer-Encoding"), "chunked")
        XCTAssertEqual(rest, Data("2\r\n{}\r\n0\r\n\r\n".utf8))
    }

    func testStreamingForwardsEachChunkBeforeReadingAnother() async throws {
        let source = Bytes([Data("data: first\n\n".utf8), Data("data: update\n\n".utf8)])
        let destination = Bytes([])
        try await BrowserRelay.pipe(source, to: destination)
        let writes = await destination.writes
        XCTAssertEqual(writes, [Data("data: first\n\n".utf8), Data("data: update\n\n".utf8)])
    }

    func testConnectAuthenticatesOnlyOuterTunnelAndKeepsWorkspace() async throws {
        let bytes = Bytes([Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 200 OK\r\n\r\n".utf8)])
        let client = AgentClient(transport: Transport(bytes), token: "native-token")
        let stream = try await client.browserTunnel(workspaceID: "runnerworkspace", target: BrowserPolicy.Authority(url: URL(string: "http://localhost:5173")!)!)
        await stream.close()
        let written = await bytes.writes.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(written[0].hasPrefix("CONNECT /v0/workspaces/runnerworkspace/proxy"))
        XCTAssertTrue(written[0].contains("Authorization: Bearer native-token"))
        XCTAssertTrue(written[1].hasPrefix("CONNECT localhost:5173"))
        XCTAssertFalse(written[1].contains("native-token"))
    }

    func testConnectErrorClosesStream() async throws {
        let bytes = Bytes([Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8)])
        let client = AgentClient(transport: Transport(bytes), token: "token")
        do { _ = try await client.browserTunnel(workspaceID: "work1", target: BrowserPolicy.Authority(url: URL(string: "http://localhost")!)!); XCTFail() }
        catch { XCTAssertEqual(error as? BrowserError, .upstream(403)) }
        let closed = await bytes.closed
        XCTAssertTrue(closed)
    }

    func testLiveArtifactTunnelsThroughItsOwnProxyForHTTPAndHTTPS() async throws {
        for (url, target) in [("http://127.0.0.1:4191/", "127.0.0.1:4191"), ("https://preview.example.com/app", "preview.example.com:443")] {
            let bytes = Bytes([Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 200 OK\r\n\r\n".utf8)])
            let client = AgentClient(transport: Transport(bytes), token: "native-token")
            let stream = try await client.browserTunnel(.artifact("art1"), target: XCTUnwrap(BrowserPolicy.Authority(url: XCTUnwrap(URL(string: url)))))
            await stream.close()
            let written = await bytes.writes.map { String(decoding: $0, as: UTF8.self) }
            XCTAssertTrue(written[0].hasPrefix("CONNECT /v0/artifacts/art1/proxy HTTP/1.1\r\n"), url)
            XCTAssertTrue(written[0].contains("Authorization: Bearer native-token"))
            XCTAssertTrue(written[1].hasPrefix("CONNECT \(target) HTTP/1.1\r\n"), url)
            XCTAssertFalse(written[1].contains("native-token"))
            XCTAssertFalse(written.contains { $0.contains("/v0/workspaces/") || $0.contains("/api/") })
        }
        XCTAssertNil(BrowserNetwork.artifact("../agents").path)
    }

    func testTheLoopbackOpensOnAnAliasForTheComputersOwnLoopback() throws {
        let link = try XCTUnwrap(URL(string: "http://localhost:5173/app?x=1"))
        let alias = try XCTUnwrap(BrowserPolicy.Loopback.alias(link))
        XCTAssertEqual(alias.absoluteString, "http://name.happy-loopback.invalid:5173/app?x=1")
        XCTAssertEqual(BrowserPolicy.Loopback.shown(alias), link)
        for (url, target) in [("http://127.0.0.1:4191/", "127.0.0.1:4191"), ("http://127.1:4191/", "127.0.0.1:4191"), ("ws://[::1]:24678/", "[::1]:24678"), ("https://LOCALHOST.:8443/", "localhost:8443")] {
            let alias = try XCTUnwrap(BrowserPolicy.Loopback.alias(XCTUnwrap(URL(string: url))), url)
            XCTAssertTrue(alias.host?.hasSuffix(".happy-loopback.invalid") == true, url)
            XCTAssertEqual(BrowserPolicy.Loopback.target(try XCTUnwrap(BrowserPolicy.Authority(url: alias)))?.text, target, url)
        }
        XCTAssertEqual(BrowserPolicy.Loopback.shown(try XCTUnwrap(URL(string: "http://ipv6.happy-loopback.invalid:4191/"))).absoluteString, "http://[::1]:4191/")
        for url in ["http://127.0.0.2/", "http://example.com/", "http://a.localhost/", "http://name.happy-loopback.invalid/", "mailto:a@b.c"] {
            XCTAssertNil(BrowserPolicy.Loopback.alias(try XCTUnwrap(URL(string: url))), url)
        }
        XCTAssertNil(BrowserPolicy.Loopback.target(try XCTUnwrap(BrowserPolicy.Authority(url: XCTUnwrap(URL(string: "http://localhost:80"))))))
    }

    func testALoopbackAliasNamesTheLoopbackInEachRequestAndPassesTheRest() async throws {
        let alias = "name.happy-loopback.invalid"
        let local = Bytes([
            Data("POST /api HTTP/1.1\r\nHost: \(alias):5173\r\nOrigin: http://\(alias):5173\r\nContent-Length: 5\r\n\r\nhel".utf8),
            Data("loGET /next HTTP/1.1\r\nHost: \(alias):5173\r\nReferer: http://\(alias):5173/app\r\n\r\n".utf8),
            Data("GET /hmr HTTP/1.1\r\nHost: \(alias):5173\r\nOrigin: http://\(alias).example.com\r\nUpgrade: websocket\r\n\r\nframe ".utf8),
            Data("Host: \(alias):5173".utf8),
        ])
        let remote = Bytes([], holds: true)
        try await BrowserRelay.loopback(local, remote, initial: Data(), alias: alias, host: "localhost")
        let sent = String(decoding: await remote.writes.reduce(Data(), +), as: UTF8.self)
        XCTAssertEqual(sent, "POST /api HTTP/1.1\r\nHost: localhost:5173\r\nOrigin: http://localhost:5173\r\nContent-Length: 5\r\n\r\nhello"
            + "GET /next HTTP/1.1\r\nHost: localhost:5173\r\nReferer: http://localhost:5173/app\r\n\r\n"
            // Another site's Origin stays; after the upgrade nothing is read as HTTP.
            + "GET /hmr HTTP/1.1\r\nHost: localhost:5173\r\nOrigin: http://\(alias).example.com\r\nUpgrade: websocket\r\n\r\nframe Host: \(alias):5173")

        // TLS carries its own name: its bytes pass as they are.
        let hello = Data([0x16, 0x03, 0x01]) + Data(alias.utf8)
        let secure = Bytes([], holds: true)
        try await BrowserRelay.loopback(Bytes([]), secure, initial: hello, alias: alias, host: "localhost")
        let passed = await secure.writes.reduce(Data(), +)
        XCTAssertEqual(passed, hello)
    }

    func testLiveArtifactProxyRefusalsMeanItsComputerIsUnavailable() async throws {
        let target = try XCTUnwrap(BrowserPolicy.Authority(url: XCTUnwrap(URL(string: "http://localhost:4191"))))
        for status in [404, 501, 503] {
            let client = AgentClient(transport: Transport(Bytes([Data("HTTP/1.1 \(status) Refused\r\n\r\n".utf8)])), token: "token")
            do { _ = try await client.browserTunnel(.artifact("gone1"), target: target); XCTFail() }
            catch { XCTAssertEqual(error as? BrowserError, .liveUnavailable, "\(status)") }
        }
        // The same refusal from a workspace's proxy says only its status.
        let workspace = AgentClient(transport: Transport(Bytes([Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8)])), token: "token")
        do { _ = try await workspace.browserTunnel(.workspace("work1"), target: target); XCTFail() }
        catch { XCTAssertEqual(error as? BrowserError, .upstream(404)) }
        // A destination the daemon's policy refuses, or a dev server that isn't
        // running, is answered inside the open tunnel: not the computer's absence.
        let inner = AgentClient(transport: Transport(Bytes([Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8)])), token: "token")
        do { _ = try await inner.browserTunnel(.artifact("art1"), target: target); XCTFail() }
        catch { XCTAssertEqual(error as? BrowserError, .upstream(403)) }
        let failure = BrowserFailure(BrowserError.liveUnavailable)
        XCTAssertEqual(failure.code, "browser_proxy_live_unavailable")
        XCTAssertEqual(BrowserProxyRefusal(status: failure.status, code: failure.code).problem, .liveUnavailable)
    }

    func testPublicAuthoritySurvivesMeteringForConnectAndArtifactUpgrade() async throws {
        let bytes = Bytes([Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 200 OK\r\n\r\n".utf8)], authority: "agent.example.com:8443")
        let metered = MeteredStream(bytes, metrics: ConnectionMetrics(), channel: .browser)
        XCTAssertEqual(metered.authority, "agent.example.com:8443")
        let client = AgentClient(transport: Transport(bytes), token: "native-token")
        let stream = try await client.browserTunnel(workspaceID: "workspace", target: BrowserPolicy.Authority(url: URL(string: "https://example.com")!)!)
        await stream.close()
        let written = await bytes.writes.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(written[0].contains("Host: agent.example.com:8443\r\n"))
        XCTAssertFalse(written[1].contains("native-token"))
        let (head, _) = try XCTUnwrap(BrowserHTTPHead.parse(Data("GET /api/v1/events HTTP/1.1\r\nHost: artifact.invalid\r\nAuthorization: attacker\r\nUpgrade: websocket\r\n\r\n".utf8)))
        let request = try head.artifactRequest(artifactID: "art1", version: 1, credential: "native-token", authority: bytes.authority)
        XCTAssertEqual(request.value("Host"), "agent.example.com:8443")
        XCTAssertEqual(request.value("Authorization"), "Bearer native-token")
        XCTAssertEqual(request.value("Connection"), "Upgrade")
    }

    func testChunkedRequestIsBoundedAndCannotSmuggleAnotherRequest() async throws {
        let (head, _) = try XCTUnwrap(BrowserHTTPHead.parse(Data("PUT /api/v1/kv/entry HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
        let stream = Bytes([Data("2\r\n{}\r\n0\r\n\r\nGET /v0/config HTTP/1.1\r\n\r\n".utf8)])
        let (request, body) = try await BrowserRelay.requestBody(head, initial: Data(), stream: stream)
        XCTAssertEqual(body, Data("{}".utf8))
        XCTAssertEqual(request.value("Content-Length"), "2")
        XCTAssertNil(request.value("Transfer-Encoding"))
        let (bad, _) = try XCTUnwrap(BrowserHTTPHead.parse(Data("PUT /api/v1/kv/entry HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
        do { _ = try await BrowserRelay.requestBody(bad, initial: Data(), stream: stream); XCTFail() }
        catch { XCTAssertEqual(error as? BrowserError, .malformed) }
    }

    func testThirdPartyFramesCannotBorrowArtifactAPI() throws {
        let authority = try XCTUnwrap(BrowserPolicy.Authority(url: URL(string: "http://artifact.invalid")!))
        for origin in ["https://attacker.example", "null", "http://artifact.invalid:1234"] {
            let (head, _) = try XCTUnwrap(BrowserHTTPHead.parse(Data("POST /api/v1/debug/log HTTP/1.1\r\nOrigin: \(origin)\r\n\r\n".utf8)))
            XCTAssertThrowsError(try BrowserPolicy.checkArtifactOrigin(head, authority: authority))
        }
        let (head, _) = try XCTUnwrap(BrowserHTTPHead.parse(Data("POST /api/v1/debug/log HTTP/1.1\r\nOrigin: http://artifact.invalid\r\nSec-Fetch-Site: same-origin\r\n\r\n".utf8)))
        XCTAssertNoThrow(try BrowserPolicy.checkArtifactOrigin(head, authority: authority))
    }

    func testArtifactSandboxAdjustmentPreservesOtherServerPolicies() throws {
        let (head, _) = try XCTUnwrap(BrowserHTTPHead.parse(Data("HTTP/1.1 200 OK\r\nContent-Security-Policy: sandbox allow-scripts; default-src 'self'\r\n\r\n".utf8)))
        XCTAssertEqual(head.artifactResponse().value("Content-Security-Policy"), "sandbox allow-scripts allow-same-origin; default-src 'self'")
    }

    func testAPostSendsItsLengthOnceThroughTheWorkspace() async throws {
        let answer = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let bytes = Bytes([Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 200 OK\r\n\r\n".utf8), answer])
        let client = AgentClient(transport: Transport(bytes), token: "native-token")
        let url = URL(string: "http://localhost:6090/live/3f9a1c0e5b7d42e8a6c1f09b2d4e7a35/done")!
        let response = try await BrowserExchange.send(client, workspaceID: "work1", method: "POST", url: url, body: nil, accept: "*/*")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("{}".utf8))
        let written = await bytes.writes.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(written.count, 3)
        XCTAssertTrue(written[0].hasPrefix("CONNECT /v0/workspaces/work1/proxy"))
        XCTAssertTrue(written[1].hasPrefix("CONNECT localhost:6090"))
        XCTAssertEqual(written[2], "POST /live/3f9a1c0e5b7d42e8a6c1f09b2d4e7a35/done HTTP/1.1\r\nHost: localhost:6090\r\nAccept: */*\r\nAccept-Encoding: identity\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        do { _ = try await BrowserExchange.send(client, workspaceID: "work1", method: "post", url: url, body: nil, accept: "*/*"); XCTFail() }
        catch { XCTAssertEqual(error as? BrowserError, .malformed) }
    }

    func testAGetSaysNothingOfABody() async throws {
        let bytes = Bytes([Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 410 Gone\r\nContent-Length: 0\r\n\r\n".utf8)])
        let client = AgentClient(transport: Transport(bytes), token: "native-token")
        let response = try await BrowserExchange.send(client, workspaceID: "work1", method: "GET", url: URL(string: "http://localhost:6090/live/3f9a1c0e5b7d42e8a6c1f09b2d4e7a35/state")!, body: nil, accept: "application/json")
        XCTAssertEqual(response.status, 410)
        let written = await bytes.writes.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(written[2], "GET /live/3f9a1c0e5b7d42e8a6c1f09b2d4e7a35/state HTTP/1.1\r\nHost: localhost:6090\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n")
    }

    func testATargetThatHangsUpBeforeAHeadClosedBeforeResponse() async throws {
        let url = URL(string: "http://192.168.1.20:6090/live/3f9a1c0e5b7d42e8a6c1f09b2d4e7a35/state")!
        let bytes = Bytes([Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 200 OK\r\n\r\n".utf8)])
        let client = AgentClient(transport: Transport(bytes), token: "native-token")
        do { _ = try await BrowserExchange.send(client, workspaceID: "work1", method: "GET", url: url, body: nil, accept: "application/json"); XCTFail() }
        catch { XCTAssertEqual(error as? BrowserError, .closedBeforeResponse) }
        // An end at the outer CONNECT is still no route.
        let none = AgentClient(transport: Transport(Bytes([])), token: "native-token")
        do { _ = try await BrowserExchange.send(none, workspaceID: "work1", method: "GET", url: url, body: nil, accept: "application/json"); XCTFail() }
        catch { XCTAssertEqual(error as? BrowserError, .unavailable) }
    }

    #if canImport(Network)
    func testTheFetcherPostsAndRefusesAFailure() async throws {
        let bytes = Bytes([Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)])
        let client = AgentClient(transport: Transport(bytes), token: "native-token")
        let fetcher = BrowserFetcher(client: client) { "work1" }
        let url = URL(string: "http://localhost:6090/live/3f9a1c0e5b7d42e8a6c1f09b2d4e7a35/done")!
        let body = try await fetcher.send(method: "POST", url: url, body: Data("{}".utf8), accept: "application/json")
        XCTAssertEqual(body, Data())
        let written = await bytes.writes.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertTrue(written[2].hasPrefix("POST /live/3f9a1c0e5b7d42e8a6c1f09b2d4e7a35/done HTTP/1.1\r\n"))
        XCTAssertTrue(written[2].contains("\r\nContent-Length: 2\r\n"))
        XCTAssertTrue(written[2].hasSuffix("\r\n\r\n{}"))
        await fetcher.stop()

        let gone = Bytes([Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 200 OK\r\n\r\n".utf8), Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)])
        let refused = BrowserFetcher(client: AgentClient(transport: Transport(gone), token: "native-token")) { "work1" }
        do { _ = try await refused.send(method: "POST", url: url); XCTFail() }
        catch { XCTAssertEqual(error as? BrowserError, .upstream(404)) }
        await refused.stop()
    }
    #endif

    /// A server that closes as asked but never says so, as websockify does:
    /// WebKit is told, the exchange ends at the body's length without
    /// waiting for the server's close, and a 101 passes through unchanged.
    func testAnExchangeTellsWebKitTheConnectionCloses() async throws {
        let local = Held([])
        let remote = Held([Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nKeep-Alive: timeout=5\r\nConnection: keep-alive\r\n\r\nhel".utf8), Data("lo".utf8)])
        try await BrowserRelay.exchange(local, remote, method: "GET")
        let sent = await local.writes.reduce(Data(), +)
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
        let closed = await (local.closed, remote.closed)
        XCTAssertTrue(closed.0 && closed.1)

        let head = Held([Data("HTTP/1.1 304 Not Modified\r\nETag: x\r\n\r\n".utf8)])
        let client = Held([])
        try await BrowserRelay.exchange(client, head, method: "GET")
        let notModified = await client.writes.reduce(Data(), +)
        XCTAssertEqual(String(decoding: notModified, as: UTF8.self), "HTTP/1.1 304 Not Modified\r\nETag: x\r\nConnection: close\r\n\r\n")

        let upgrade = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        let socket = Held([Data((upgrade).utf8) + Data([0x81, 2, 0x68, 0x69])], ends: true)
        let page = Held([])
        try await BrowserRelay.exchange(page, socket, method: "GET")
        let frames = await page.writes.reduce(Data(), +)
        XCTAssertEqual(frames, Data(upgrade.utf8) + Data([0x81, 2, 0x68, 0x69]))
    }

    /// Reads its chunks, then waits (or, with `ends`, ends) until closed.
    private actor Held: BrowserStream {
        var pending: [Data]
        var writes: [Data] = []
        var closed = false
        let ends: Bool
        var waiter: CheckedContinuation<Data, Never>?
        init(_ pending: [Data], ends: Bool = false) { self.pending = pending; self.ends = ends }
        func read(maximumBytes: Int) async throws -> Data {
            if !pending.isEmpty { return pending.removeFirst() }
            if closed || ends { return Data() }
            return await withCheckedContinuation { waiter = $0 }
        }
        func write(_ data: Data) async throws { writes.append(data) }
        func close() async { closed = true; waiter?.resume(returning: Data()); waiter = nil }
    }

    private actor Bytes: BrowserStream {
        nonisolated let authority: String
        var pending: [Data]
        var writes: [Data] = []
        var closed = false
        /// Once its bytes are read, waits like a server with nothing to say.
        let holds: Bool
        init(_ pending: [Data], authority: String = "server.tailcat", holds: Bool = false) { self.pending = pending; self.authority = authority; self.holds = holds }
        func read(maximumBytes: Int) async throws -> Data {
            if pending.isEmpty, holds { try await Task.sleep(for: .seconds(60)) }
            return pending.isEmpty ? Data() : pending.removeFirst()
        }
        func write(_ data: Data) async throws { writes.append(data) }
        func close() async { closed = true }
    }
    private struct Transport: AgentTransport {
        let bytes: Bytes
        init(_ bytes: Bytes) { self.bytes = bytes }
        func browserConnection() async throws -> any BrowserStream { bytes }
        func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) async throws -> HTTP1Response { throw BrowserError.unavailable }
        func close() async {}
    }
    private struct RoutingTransport: AgentTransport {
        let responses: [String: String]
        func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) async throws -> HTTP1Response {
            HTTP1Response(status: responses[path] == nil ? 404 : 200, body: Data((responses[path] ?? "{}").utf8))
        }
        func close() async {}
    }
}