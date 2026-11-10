#if canImport(UIKit)
import CryptoKit
@testable import HappyCore
@testable import HappyUI
import HappyLayout
import UIKit
import WebKit
import XCTest

/// A byte-level fake daemon, behind the same CONNECT and artifact translation
/// used in production. WebKit still speaks real HTTP to our loopback listener.
actor BrowserDaemon: AgentTransport {
    var requests: [String] = []
    var bodies: [Data] = []
    var credentials: [String] = []
    var targetCredentials: [String] = []
    /// Each page request's `Host`, `Origin` and request line, as the server saw them.
    var pageHeads: [(line: String, host: String?, origin: String?)] = []
    let artifactHTML: String?
    let keepAlive: Bool
    var connections = 0
    /// What the live browser (`/live/<id>/state`) says it is; `/done` makes it watching.
    var liveStatus = "takeover"
    /// The browser's pod, as a bridge with one per chat says it (nil: no pods).
    /// Asleep, its frame is 503.
    var livePod: String?
    /// The link `/live/chat/<key>` answers with; nil is 404 `no_link`.
    var chatLink: String?
    /// `/take`s answered 202 (waking) before the 200.
    var wakingTakes = 0
    /// `frame.jpg` reads that are never answered, as a stalled tunnel's.
    var stalledFrames = 0
    /// Requests WebKit sent on a connection after its server had closed it:
    /// none ever reached a server, so none was answered.
    var afterClose: [String] = []
    /// `GET /v0/workspaces`, `/v0/config`'s node name, and the noVNC
    /// address `POST /take` answers with.
    var workspaces = #"{"workspaces":[{"id":"host1","status":"active","compute":{"type":"host","path":"/Users/me"}}]}"#
    var nodeName = "Studio Mac"
    var takeNoVNC = BrowserDaemon.chatNoVNC
    init(artifactHTML: String? = nil, keepAlive: Bool = false) { self.artifactHTML = artifactHTML; self.keepAlive = keepAlive }

    func browserConnection() async throws -> any BrowserStream { connections += 1; return Socket(self) }
    func close() async {}
    func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) async throws -> HTTP1Response {
        let text: String
        if path == "/v0/config" { text = #"{"config":{"node":{"name":"\#(nodeName)"}}}"# }
        else if path == "/v0/workspaces" { text = workspaces }
        else if path.hasPrefix("/v0/agents/") { text = #"{"agent":{"id":"agent1","workspaceId":"work1","status":"idle"}}"# }
        else if path.hasPrefix("/v0/artifacts/") { text = #"{"artifact":{"updatedSource":{"kind":"workspace","workspaceId":"work1"}}}"# }
        else { text = "{}" }
        return HTTP1Response(status: 200, body: Data(text.utf8))
    }

    func answer(_ head: BrowserHTTPHead, body: Data) -> (Data, Bool) {
        requests.append(head.line); bodies.append(body)
        if let credential = head.value("Authorization") { credentials.append(credential) }
        if head.line.hasPrefix("CONNECT ") { return (Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), true) }
        targetCredentials.append(head.value("Authorization") ?? "none")
        pageHeads.append((head.line, head.value("Host"), head.value("Origin")))
        if let key = head.value("Sec-WebSocket-Key") {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            var bytes = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
            bytes.append(contentsOf: [0x81, 7]); bytes.append(Data("ws-live".utf8))
            return (bytes, true)
        }
        if head.line.contains("/frame.jpg "), stalledFrames > 0 {
            stalledFrames -= 1
            return (Data(), true)
        }
        if let live = liveAnswer(head) { return (live, false) }
        if let novnc = novncAnswer(head) { return (novnc, false) }
        if head.line.contains("/api/v1/kv/events") {
            let event = "data: shared-update\n\n"
            return (Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\n\r\n\(String(event.utf8.count, radix: 16))\r\n\(event)\r\n".utf8), true)
        }
        let content: String
        let type: String
        if head.line.contains("/api/v1/kv/entry") { content = #"{"value":"saved"}"#; type = "application/json" }
        else if head.line.contains("/api/v1/style.css") { content = ":root{}"; type = "text/css" }
        else if head.line.contains("/public.js") { content = "window.publicResourceLoaded=true;"; type = "text/javascript" }
        else if head.line.contains("/app.js") {
            content = "document.querySelector('#js').textContent='JavaScript loaded'; const ws=new WebSocket('ws://'+location.host+'/socket'); ws.onmessage=e=>document.querySelector('#result').textContent=e.data;"
            type = "text/javascript"
        } else if head.line.contains("/versions/") {
            content = artifactHTML ?? Self.html; type = "text/html"
        } else {
            content = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><title>Remote preview</title></head><body style='font:20px -apple-system;padding:24px;background:#f3f6fc;color:#14233a'><h1>Remote preview</h1><p id='js'>Loading script…</p><p id='result'>Connecting…</p><script src='/app.js'></script><script src='http://assets.example.invalid/public.js'></script></body></html>"
            type = "text/html"
        }
        let reuse = keepAlive && head.value("Connection") == "keep-alive"
        return (Data("HTTP/1.1 200 OK\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(content.utf8.count)\r\nConnection: \(reuse ? "keep-alive" : "close")\r\n\r\n\(content)".utf8), reuse)
    }

    /// The live browser's frame, state and hand-back; a page under it is
    /// the ordinary preview.
    private func liveAnswer(_ head: BrowserHTTPHead) -> Data? {
        guard head.line.contains(" /live/") else { return nil }
        func reply(_ status: String, _ type: String, _ body: Data) -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        }
        let pod = livePod.map { #","pod":"\#($0)""# } ?? ""
        if head.line.contains(" /live/chat/") {
            guard let chatLink else { return reply("404 Not Found", "application/json", Data(#"{"error":"no_link"}"#.utf8)) }
            let live = liveStatus != "done" && (livePod == nil || livePod == "running" || livePod == "starting")
            return reply("200 OK", "application/json", Data(#"{"id":"\#(chatLink)","live":\#(live),"status":"\#(liveStatus)","url":"https://example.com/login","title":"Log in to Example"\#(pod)}"#.utf8))
        }
        if head.line.contains("/live/0e0e0e0e") { return reply("410 Gone", "application/json", Data(#"{"error":"expired"}"#.utf8)) }
        if head.line.hasPrefix("POST ") && head.line.contains("/take ") && wakingTakes > 0 {
            wakingTakes -= 1
            livePod = "starting"
            return reply("202 Accepted", "application/json", Data(#"{"status":"\#(liveStatus)","url":"https://example.com/login","title":"Log in to Example","pod":"starting"}"#.utf8))
        }
        if head.line.hasPrefix("POST ") && head.line.contains("/take ") {
            liveStatus = "user"
            if livePod != nil { livePod = "running" }
            // A container per chat: its noVNC is wherever the bridge says.
            return reply("200 OK", "application/json", Data(#"{"status":"user","reason":"Sign in","url":"https://example.com/login","title":"Log in to Example","novnc_url":"\#(takeNoVNC)"}"#.utf8))
        }
        if head.line.hasPrefix("POST ") && head.line.contains("/release ") {
            liveStatus = "watching"
            return reply("200 OK", "application/json", Data(#"{"status":"watching","url":"https://example.com/login","title":"Log in to Example"}"#.utf8))
        }
        if head.line.hasPrefix("POST ") && head.line.contains("/end ") {
            liveStatus = "done"
            return reply("200 OK", "application/json", Data(#"{"status":"done","reason":"user_ended","url":"https://example.com/login","title":"Log in to Example"}"#.utf8))
        }
        if head.line.hasPrefix("POST ") && head.line.contains("/done ") {
            liveStatus = "watching"
            return reply("200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
        }
        if head.line.contains("/state ") {
            return reply("200 OK", "application/json", Data(#"{"status":"\#(liveStatus)","reason":"Sign in","url":"https://example.com/login","title":"Log in to Example","viewers":1\#(pod)}"#.utf8))
        }
        if head.line.contains("/frame.jpg ") && livePod == "asleep" { return reply("503 Service Unavailable", "application/json", Data(#"{"error":"asleep"}"#.utf8)) }
        if head.line.contains("/frame.jpg ") { return reply("200 OK", "image/png", Self.frame) }
        return nil
    }

    /// The live page's Take control link, and noVNC behind it as websockify
    /// serves it: HTTP/1.1 with a length and no `Connection` field, then the
    /// socket closes because the request asked it to. Its page is an ES
    /// module graph of `novncModules` files.
    private func novncAnswer(_ head: BrowserHTTPHead) -> Data? {
        func reply(_ type: String, _ body: String, close: Bool) -> Data {
            Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n\(close ? "Connection: close\r\n" : "")\r\n\(body)".utf8)
        }
        let path = head.line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        if path == "/takeover" {
            return reply("text/html", "<!doctype html><meta name='viewport' content='width=device-width'><p id='result'>ready</p><a id='take' href='\(Self.takeover)'>Take control</a>", close: true)
        }
        if path.hasPrefix("/vnc.html") {
            return reply("text/html", "<!doctype html><meta name='viewport' content='width=device-width'><title>noVNC</title><p id='result'>Loading modules</p><script type='module' src='/app/ui.js'></script>", close: false)
        }
        if path == "/app/ui.js" {
            let imports = (0..<Self.novncModules).map { "import { v\($0) } from './m\($0).js';" }.joined(separator: "\n")
            let sum = (0..<Self.novncModules).map { "v\($0)" }.joined(separator: "+")
            let script = imports + """

            const count = \(sum);
            const ws = new WebSocket('ws://' + location.host + '/websockify');
            ws.onmessage = e => { document.querySelector('#result').textContent = 'modules ' + count + ' ' + location.hash + ' ' + e.data; };
            ws.onerror = () => { document.querySelector('#result').textContent = 'socket failed'; };
            """
            return reply("text/javascript", script, close: false)
        }
        if path.hasPrefix("/app/m"), let n = Int(path.dropFirst(6).dropLast(3)) {
            return reply("text/javascript", "export const v\(n) = 1;", close: false)
        }
        return nil
    }

    nonisolated static let novncModules = 48
    nonisolated static let takeover = "http://localhost:6080/vnc.html?autoconnect=true&resize=remote#password=s3cr%2Bt"
    /// One chat's container's noVNC, as `POST /take` answers it.
    nonisolated static let chatNoVNC = "http://localhost:6123/vnc.html?autoconnect=true&resize=remote"
    func setLiveStatus(_ status: String) { liveStatus = status }
    func setWorkspaces(_ json: String) { workspaces = json }
    func setNodeName(_ name: String) { nodeName = name }
    func setTakeNoVNC(_ url: String) { takeNoVNC = url }
    /// Every workspace the computer was asked to tunnel through.
    var tunnelledWorkspaces: Set<String> {
        Set(requests.compactMap { line in
            guard line.hasPrefix("CONNECT /v0/workspaces/") else { return nil }
            return line.dropFirst("CONNECT /v0/workspaces/".count).split(separator: "/").first.map(String.init)
        })
    }
    func setLivePod(_ pod: String?) { livePod = pod }
    func setChatLink(_ id: String?) { chatLink = id }
    func setWakingTakes(_ count: Int) { wakingTakes = count }
    func setStalledFrames(_ count: Int) { stalledFrames = count }
    var frameReads: Int { requests.filter { $0.contains("/frame.jpg ") }.count }

    /// The bridge serves `frame.jpg` as a PNG; the card reads it by its bytes.
    nonisolated static let frame: Data = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 40)).image { context in
        UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
    }.pngData() ?? Data()

    nonisolated static let html = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Shared counter</title></head>
    <body style="font:20px -apple-system;padding:24px;background:#edf4ee;color:#183c27"><h1>Shared counter</h1><p id="result">Saving…</p>
    <script>fetch('/api/v1/kv/entry?key=count',{method:'PUT',headers:{'Content-Type':'application/json','If-Match':'version1'},body:JSON.stringify({value:42})}).then(r=>r.json()).then(()=>{let events=new EventSource('/api/v1/kv/events');events.onmessage=e=>document.querySelector('#result').textContent=e.data;}).catch(e=>document.querySelector('#result').textContent='error:'+e);</script></body></html>
    """

    func closed(_ head: BrowserHTTPHead) { afterClose.append("\(head.line) Host: \(head.value("Host") ?? "-")") }

    private actor Socket: BrowserStream {
        let daemon: BrowserDaemon
        var buffer = Data()
        var pending = Data()
        var reader: CheckedContinuation<Data, Error>?
        var ended = false
        /// The server closed its end; the close reaches the phone a moment
        /// later, as it does across the network.
        var serverClosed = false
        var websocket = false
        init(_ daemon: BrowserDaemon) { self.daemon = daemon }
        func read(maximumBytes: Int) async throws -> Data {
            if !pending.isEmpty { let data = Data(pending.prefix(maximumBytes)); pending.removeFirst(data.count); return data }
            if ended { return Data() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { reader = $0 }
            } onCancel: { Task { await self.close() } }
        }
        func write(_ data: Data) async throws {
            if websocket { return }
            buffer.append(data)
            guard let (head, body) = try BrowserHTTPHead.parse(buffer), body.count >= (Int(head.value("Content-Length") ?? "0") ?? 0) else { return }
            buffer = Data()
            if serverClosed { await daemon.closed(head); return }
            let (response, staysOpen) = await daemon.answer(head, body: body)
            websocket = head.value("upgrade") != nil
            pending.append(response)
            if !staysOpen {
                serverClosed = true
                Task { try? await Task.sleep(for: .milliseconds(150)); self.end() }
            }
            if let reader { self.reader = nil; let bytes = pending; pending = Data(); reader.resume(returning: bytes) }
        }
        private func end() {
            ended = true
            if let reader, pending.isEmpty { self.reader = nil; reader.resume(returning: Data()) }
        }
        func close() async { ended = true; reader?.resume(returning: Data()); reader = nil }
    }
}

@MainActor
final class HostedBrowserTests: XCTestCase {
    func testArtifactAPIReusesUpstreamWhileSSEStaysOpen() async throws {
        let daemon = BrowserDaemon(artifactHTML: """
        <!doctype html><p id="result">Starting</p><script>
        const events = new EventSource('/api/v1/kv/events');
        events.onmessage = async () => {
          try {
            for (let i = 0; i < 100; i++) {
              const r = await fetch('/api/v1/kv/entry?key='+i, {method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({value:i})});
              if (r.status !== 200 || (await r.json()).value !== 'saved') throw Error('bad response');
            }
            document.querySelector('#result').textContent='100 reused writes and SSE';
          } catch(e) {document.querySelector('#result').textContent=String(e);}
        };
        </script>
        """, keepAlive: true)
        let client = AgentClient(transport: daemon, token: "native-secret")
        let page = try await BrowserPage.artifact(client: client, id: "art1", version: 1, entry: "index.html")
        let browser = BrowserViewController(url: page.url, artifactID: "art1", page: page)
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: UINavigationController(rootViewController: browser))
        defer { window.isHidden = true }
        let web = try await waitForWeb(browser)
        try await waitForText("100 reused writes and SSE", web: web)
        let connections = await daemon.connections
        let writes = await daemon.requests.filter { $0.hasPrefix("PUT ") }
        XCTAssertEqual(writes.count, 100)
        XCTAssertLessThan(connections, 8, "Sequential API requests must reuse upstream sockets alongside SSE")
    }

    func testArtifactWriteAndLiveUpdate() async throws {
        let daemon = BrowserDaemon()
        let client = AgentClient(transport: daemon, token: "native-secret")
        let page = try await BrowserPage.artifact(client: client, id: "art1", version: 2, entry: "index.html")
        let browser = BrowserViewController(url: page.url, artifactID: "art1", page: page)
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: UINavigationController(rootViewController: browser))
        defer { window.isHidden = true }
        let web = try await waitForWeb(browser)
        try await waitForText("shared-update", web: web)
        let requests = await daemon.requests
        XCTAssertTrue(requests.contains("PUT /v0/artifacts/art1/api/v1/kv/entry?key=count HTTP/1.1"), "\(requests)")
        XCTAssertTrue(requests.contains("GET /v0/artifacts/art1/api/v1/kv/events HTTP/1.1"))
        let bodies = await daemon.bodies
        XCTAssertTrue(bodies.contains(Data(#"{"value":42}"#.utf8)))
        let credentials = await daemon.credentials
        XCTAssertTrue(credentials.allSatisfy { $0 == "Bearer native-secret" })
        let content = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
        XCTAssertFalse(content?.contains("native-secret") == true)
        try screenshot(window, name: "browser-artifact")
    }

    func testLocalhostPageLoadsScriptAndWebSocketThroughWorkspace() async throws {
        let daemon = BrowserDaemon()
        let page = try await BrowserPage.workspace(client: AgentClient(transport: daemon, token: "native-secret"), url: URL(string: "http://localhost:5173")!, workspaceID: "runner1")
        let browser = BrowserViewController(url: page.url, page: page)
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: UINavigationController(rootViewController: browser))
        defer { window.isHidden = true }
        let web = try await waitForWeb(browser)
        try await waitForText("ws-live", web: web)
        let js = try await web.evaluateJavaScript("document.querySelector('#js').textContent") as? String
        XCTAssertEqual(js, "JavaScript loaded")
        let requests = await daemon.requests
        XCTAssertTrue(requests.contains { $0.hasPrefix("CONNECT /v0/workspaces/runner1/proxy") }, "\(requests)")
        XCTAssertTrue(requests.contains { $0.hasPrefix("CONNECT localhost:5173") })
        XCTAssertTrue(requests.contains { $0.hasPrefix("GET /app.js") })
        XCTAssertTrue(requests.contains { $0.hasPrefix("GET /socket") })
        window.overrideUserInterfaceStyle = .light
        try screenshot(window, name: "browser-localhost-light")
        window.overrideUserInterfaceStyle = .dark
        try await Task.sleep(for: .milliseconds(150))
        try screenshot(window, name: "browser-localhost-dark")
    }

    func testPublicPageAndPublicResourcesUseProxyWithoutDirectFallback() async throws {
        let daemon = BrowserDaemon()
        let page = try await BrowserPage.workspace(client: AgentClient(transport: daemon, token: "native-secret"), url: URL(string: "http://public.example.invalid")!, workspaceID: "work1")
        let settings = try XCTUnwrap(page.configuration.websiteDataStore.proxyConfigurations.first)
        XCTAssertFalse(settings.allowFailover)
        XCTAssertTrue(settings.matchDomains.isEmpty)
        XCTAssertTrue(settings.excludedDomains.isEmpty)
        let browser = BrowserViewController(url: page.url, page: page)
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: UINavigationController(rootViewController: browser))
        defer { window.isHidden = true }
        let web = try await waitForWeb(browser)
        try await waitForText("ws-live", web: web)
        let requests = await daemon.requests
        // Neither domain can resolve on the phone. Every load must reach the
        // fake daemon, including the cross-origin script and WebSocket.
        XCTAssertTrue(requests.contains { $0.hasPrefix("CONNECT public.example.invalid:80") }, "\(requests)")
        XCTAssertTrue(requests.contains { $0.hasPrefix("CONNECT assets.example.invalid:80") }, "\(requests)")
        let publicResource = try await web.evaluateJavaScript("window.publicResourceLoaded") as? Bool
        XCTAssertEqual(publicResource, true)
        let targetCredentials = await daemon.targetCredentials
        XCTAssertTrue(targetCredentials.allSatisfy { $0 == "none" })
        XCTAssertTrue(requests.contains { $0.hasPrefix("GET /socket") })
        XCTAssertEqual(BrowserPolicy.route(page.url), .web)
        XCTAssertEqual(BrowserPolicy.route(URL(string: "mailto:hello@example.com")!), .system)
    }

    func testNoConnectionNeverCreatesADirectWebView() async throws {
        let browser = BrowserViewController(url: URL(string: "http://public.example.invalid")!)
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: UINavigationController(rootViewController: browser))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(browser.view.subviews.compactMap { $0 as? WKWebView }.isEmpty)
        XCTAssertEqual(browser.problem, .unavailable)
        XCTAssertFalse(browser.failureView.isHidden)
    }

    func testChatLocalhostLinkUsesItsWorkspace() async throws {
        let daemon = BrowserDaemon()
        let account = AccountController(serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "browser-test", credentialStore: InMemoryCredentialStore(), storeDirectory: nil, agentTransport: { _ in daemon })
        await account.agentConnections.setForeground(false)
        let connection = try await account.agentConnections.add(JSONDecoder().decode(AgentConnectionCredentials.self,
            from: Data(#"{"address":"browser-test","port":1,"deviceID":"\#(UUID().uuidString)","deviceToken":"native-secret"}"#.utf8)), name: "Studio Mac")
        let context = AppContext(account: account, variant: .preview, version: "test")
        let session = try XCTUnwrap(Session.session(for: connection.id, context: context))
        let chat = ChatViewController(session: session, agentId: "agent1", title: "Preview", spaceId: nil, intro: nil, previewing: true)
        let navigation = UINavigationController(rootViewController: chat)
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: navigation)
        defer {
            window.isHidden = true; Session.forget(connection.id)
            Task { try? await account.agentConnections.remove(connection.id) }
        }
        chat.transcriptOpened("http://localhost:5173")
        let browser = try XCTUnwrap(navigation.topViewController as? BrowserViewController)
        let web = try await waitForWeb(browser)
        try await waitForText("ws-live", web: web)
        XCTAssertNil(browser.view.subviews.first { $0.accessibilityIdentifier == "browser-route" }, "No “via <computer>” line")
        let requests = await daemon.requests
        XCTAssertTrue(requests.contains { $0.hasPrefix("CONNECT /v0/workspaces/work1/proxy") })
        // A device's WebKit never proxies loopback: the page loads under the
        // alias, and the computer's server still sees its own localhost.
        XCTAssertEqual(web.url?.host, "name.happy-loopback.invalid")
        XCTAssertEqual(browser.navigationItem.title.map { $0 == "localhost" || $0 == "Remote preview" }, true)
        XCTAssertTrue(requests.contains { $0.hasPrefix("CONNECT localhost:5173 ") })
        XCTAssertFalse(requests.contains { $0.contains("happy-loopback") })
        let heads = await daemon.pageHeads.filter { $0.host?.hasPrefix("assets.") != true }
        XCTAssertTrue(heads.contains { $0.line.hasPrefix("GET / ") })
        XCTAssertTrue(heads.contains { $0.line.hasPrefix("GET /socket ") && $0.origin == "http://localhost:5173" }, "the WebSocket's Origin is the real one")
        XCTAssertEqual(Set(heads.compactMap(\.host)), ["localhost:5173"])
        window.overrideUserInterfaceStyle = .light
        try screenshot(window, name: "browser-chat-light")
        window.overrideUserInterfaceStyle = .dark
        try await Task.sleep(for: .milliseconds(150))
        try screenshot(window, name: "browser-chat-dark")
    }

    /// Take control on the live page, first time, no refresh: the link to
    /// another loopback port keeps its query and fragment under the alias,
    /// every module of noVNC's graph loads although websockify never says
    /// it closes, and the socket opens with noVNC's real Origin and Host.
    func testTakeControlLoadsNoVNCOnTheFirstNavigation() async throws {
        let daemon = BrowserDaemon()
        let page = try await BrowserPage.workspace(client: AgentClient(transport: daemon, token: "native-secret"), url: URL(string: "http://localhost:6090/takeover")!, workspaceID: "work1")
        let browser = BrowserViewController(url: page.url, page: page)
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: UINavigationController(rootViewController: browser))
        defer { window.isHidden = true }
        let web = try await waitForWeb(browser)
        try await waitForText("ready", web: web)
        _ = try await web.evaluateJavaScript("document.querySelector('#take').click(); void 0")
        do { try await waitForText("modules \(BrowserDaemon.novncModules) #password=s3cr%2Bt ws-live", web: web) } catch {
            let dropped = await daemon.afterClose
            let seen = await daemon.requests.filter { !$0.hasPrefix("CONNECT /v0/") }
            XCTFail("\(dropped.count) requests went to a closed server: \(dropped.prefix(5)); the servers saw \(seen)")
            throw error
        }

        XCTAssertEqual(web.url?.host, "name.happy-loopback.invalid")
        XCTAssertEqual(web.url?.port, 6080)
        XCTAssertEqual(web.url?.query, "autoconnect=true&resize=remote")
        XCTAssertEqual(web.url?.fragment, "password=s3cr%2Bt")
        let afterClose = await daemon.afterClose
        XCTAssertEqual(afterClose, [], "a request went down a connection its server had closed")
        let heads = await daemon.pageHeads
        XCTAssertEqual(Set(heads.compactMap(\.host)), ["localhost:6090", "localhost:6080"])
        for n in 0..<BrowserDaemon.novncModules {
            XCTAssertEqual(heads.filter { $0.line.hasPrefix("GET /app/m\(n).js ") }.count, 1, "module \(n)")
        }
        let socket = heads.filter { $0.line.hasPrefix("GET /websockify ") }
        XCTAssertEqual(socket.count, 1)
        XCTAssertEqual(socket.first?.origin, "http://localhost:6080")
        XCTAssertEqual(socket.first?.host, "localhost:6080")
        // One request per tunnel (WebKit may open one more it never uses).
        let requests = await daemon.requests
        XCTAssertGreaterThanOrEqual(requests.filter { $0.hasPrefix("CONNECT localhost:6080 ") }.count,
                                    heads.filter { $0.host == "localhost:6080" }.count)
    }

    private func until(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out", file: file, line: line)
        throw BrowserError.timeout
    }

    func testLiveArtifactOpensThroughItsOwnProxyWithNoAPIBridge() async throws {
        let daemon = BrowserDaemon()
        let page = try await BrowserPage.live(client: AgentClient(transport: daemon, token: "native-secret"), url: URL(string: "http://localhost:5173")!, artifactID: "art1")
        let browser = BrowserViewController(url: page.url, artifactID: "art1", page: page)
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: UINavigationController(rootViewController: browser))
        defer { window.isHidden = true }
        let web = try await waitForWeb(browser)
        try await waitForText("ws-live", web: web)
        _ = try await web.evaluateJavaScript("fetch('/api/v1/kv/entry?key=count',{method:'PUT',headers:{'Content-Type':'application/json'},body:'{\"value\":42}'}).then(r=>r.json()).then(j=>document.querySelector('#result').textContent=j.value);void 0;")
        try await waitForText("saved", web: web)
        let requests = await daemon.requests
        let targets = await daemon.targetCredentials
        // Every tunnel, the page's and its public script's, is the artifact's own.
        XCTAssertTrue(requests.contains("CONNECT /v0/artifacts/art1/proxy HTTP/1.1"))
        XCTAssertTrue(requests.contains("CONNECT localhost:5173 HTTP/1.1"))
        XCTAssertTrue(requests.contains("CONNECT assets.example.invalid:80 HTTP/1.1"))
        XCTAssertFalse(requests.contains { $0.contains("/v0/workspaces/") }, "No workspace is guessed for a live artifact")
        // Its /api is the site's own, sent to the site without the daemon's credential.
        XCTAssertTrue(requests.contains("PUT /api/v1/kv/entry?key=count HTTP/1.1"))
        XCTAssertFalse(requests.contains { $0.contains("/v0/artifacts/art1/api") || $0.contains("/versions/") })
        XCTAssertTrue(targets.allSatisfy { $0 == "none" })
    }

    private func waitForWeb(_ browser: BrowserViewController) async throws -> WKWebView {
        for _ in 0..<150 {
            if let web = browser.view.subviews.compactMap({ $0 as? WKWebView }).first { return web }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BrowserError.unavailable
    }
    private func waitForText(_ text: String, web: WKWebView) async throws {
        for _ in 0..<200 {
            if let result = try? await web.evaluateJavaScript("document.querySelector('#result')?.textContent"), result as? String == text { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = try? await web.evaluateJavaScript("document.documentElement.outerHTML")
        XCTFail("Page did not reach \(text): \(String(describing: result))")
        throw BrowserError.unavailable
    }
    private func screenshot(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["HAPPY_PREVIEW_DIR"] {
            try image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
#endif