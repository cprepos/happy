#if canImport(UIKit)
@testable import HappyCore
@testable import HappyUI
import UIKit
import WebKit
import XCTest

/// Our additions to `BrowserDaemon` and `HostedBrowserTests` (the live
/// browser, noVNC, workspaces and loopback checks), kept out of
/// HostedBrowserTests.swift so upstream merges don't conflict there.
extension BrowserDaemon {
    /// What our fake adds to the daemon: kept in one stored property so the
    /// actor's own list of them stays upstream's.
    struct ForkState {
        /// Each page request's `Host`, `Origin` and request line, as the server saw them.
        var pageHeads: [(line: String, host: String?, origin: String?)] = []
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
        /// `GET /v0/workspaces`, `/v0/config`'s node name, and the noVNC
        /// address `POST /take` answers with.
        var workspaces = #"{"workspaces":[{"id":"host1","status":"active","compute":{"type":"host","path":"/Users/me"}}]}"#
        var nodeName = "Studio Mac"
        var takeNoVNC = BrowserDaemon.chatNoVNC
        /// The approval `/state` says waits (its id); `/approve`, `/deny`
        /// and yolo turned on clear it.
        var liveApproval: String?
        /// The browser's yolo mode (`POST /auto`), and what it approved by
        /// itself, a JSON array, newest first.
        var liveAuto = false
        var liveAutoApproved = "[]"
    }

    var pageHeads: [(line: String, host: String?, origin: String?)] {
        get { forkState.pageHeads } set { forkState.pageHeads = newValue }
    }
    var liveStatus: String { get { forkState.liveStatus } set { forkState.liveStatus = newValue } }
    var livePod: String? { get { forkState.livePod } set { forkState.livePod = newValue } }
    var chatLink: String? { get { forkState.chatLink } set { forkState.chatLink = newValue } }
    var wakingTakes: Int { get { forkState.wakingTakes } set { forkState.wakingTakes = newValue } }
    var stalledFrames: Int { get { forkState.stalledFrames } set { forkState.stalledFrames = newValue } }
    var workspaces: String { get { forkState.workspaces } set { forkState.workspaces = newValue } }
    var nodeName: String { get { forkState.nodeName } set { forkState.nodeName = newValue } }
    var takeNoVNC: String { get { forkState.takeNoVNC } set { forkState.takeNoVNC = newValue } }
    func setLiveApproval(_ id: String?) { forkState.liveApproval = id }
    func setLiveAutoApproved(_ json: String) { forkState.liveAutoApproved = json }
    var liveAuto: Bool { forkState.liveAuto }

    /// `/v0/config` and `/v0/workspaces` as our fake answers them.
    func forkRequest(_ path: String) -> String? {
        if path == "/v0/config" { return #"{"config":{"node":{"name":"\#(nodeName)"}}}"# }
        if path == "/v0/workspaces" { return workspaces }
        return nil
    }

    /// A stalled frame, the live browser or noVNC; nil for anything else.
    func forkAnswer(_ head: BrowserHTTPHead) -> (Data, Bool)? {
        if head.line.contains("/frame.jpg "), stalledFrames > 0 {
            stalledFrames -= 1
            return (Data(), true)
        }
        if let live = liveAnswer(head) { return (live, false) }
        if let novnc = novncAnswer(head) { return (novnc, false) }
        return nil
    }

    /// The live browser's frame, state and hand-back; a page under it is
    /// the ordinary preview.
    private func liveAnswer(_ head: BrowserHTTPHead) -> Data? {
        guard head.line.contains(" /live/") else { return nil }
        func reply(_ status: String, _ type: String, _ body: Data) -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        }
        let pod = livePod.map { #","pod":"\#($0)""# } ?? ""
        func approvalAndYolo() -> String {
            let approval = forkState.liveApproval.map {
                #","approval":{"id":"\#($0)","kind":"submit","summary":"Submit the order form","details":["Total: $42.00"],"asked_at":1}"#
            } ?? ""
            return #"\#(approval),"auto_approve":\#(forkState.liveAuto),"auto_approved":\#(forkState.liveAutoApproved)"#
        }
        if head.line.hasPrefix("POST ") && head.line.contains("/auto ") {
            let body = (try? JSONSerialization.jsonObject(with: bodies.last ?? Data())) as? [String: Any]
            guard let on = body?["on"] as? Bool else { return reply("400 Bad Request", "application/json", Data(#"{"error":"bad_body"}"#.utf8)) }
            forkState.liveAuto = on
            if on { forkState.liveApproval = nil }
            return reply("200 OK", "application/json", Data(#"{"auto_approve":\#(on)}"#.utf8))
        }
        if head.line.hasPrefix("POST ") && (head.line.contains("/approve ") || head.line.contains("/deny ")) {
            forkState.liveApproval = nil
            return reply("200 OK", "application/json", Data(#"{"status":"\#(liveStatus)","url":"https://example.com/login","title":"Log in to Example"\#(approvalAndYolo())}"#.utf8))
        }
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
            return reply("200 OK", "application/json", Data(#"{"status":"\#(liveStatus)","reason":"Sign in","url":"https://example.com/login","title":"Log in to Example","viewers":1\#(pod)\#(approvalAndYolo())}"#.utf8))
        }
        if head.line.contains("/frame.jpg ") && livePod == "asleep" { return reply("503 Service Unavailable", "application/json", Data(#"{"error":"asleep"}"#.utf8)) }
        if head.line.contains("/frame.jpg ") { return reply("200 OK", "image/png", Self.frame) }
        return nil
    }

    /// noVNC as websockify serves it: HTTP/1.1 with a length and no
    /// `Connection` field, then the socket closes because the request asked
    /// it to. Its page is an ES module graph of `novncModules` files.
    private func novncAnswer(_ head: BrowserHTTPHead) -> Data? {
        func reply(_ type: String, _ body: String, close: Bool) -> Data {
            Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\n\(close ? "Connection: close\r\n" : "")\r\n\(body)".utf8)
        }
        let path = head.line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
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
}

extension BrowserDaemon.Socket {
    /// The server closed its end; the close reaches the phone a moment later.
    func closeSoon() {
        serverClosed = true
        Task { try? await Task.sleep(for: .milliseconds(150)); self.end() }
    }

    private func end() {
        ended = true
        if let reader, pending.isEmpty { self.reader = nil; reader.resume(returning: Data()) }
    }
}

extension HostedBrowserTests {
    /// A device's WebKit never proxies loopback: the page loads under the
    /// alias, and the computer's server still sees its own localhost.
    func assertLoopbackAlias(_ browser: BrowserViewController, web: WKWebView, daemon: BrowserDaemon, requests: [String], file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(web.url?.host, "name.happy-loopback.invalid", file: file, line: line)
        XCTAssertEqual(browser.navigationItem.title.map { $0 == "localhost" || $0 == "Remote preview" }, true, file: file, line: line)
        XCTAssertTrue(requests.contains { $0.hasPrefix("CONNECT localhost:5173 ") }, file: file, line: line)
        XCTAssertFalse(requests.contains { $0.contains("happy-loopback") }, file: file, line: line)
        let heads = await daemon.pageHeads.filter { $0.host?.hasPrefix("assets.") != true }
        XCTAssertTrue(heads.contains { $0.line.hasPrefix("GET / ") }, file: file, line: line)
        XCTAssertTrue(heads.contains { $0.line.hasPrefix("GET /socket ") && $0.origin == "http://localhost:5173" }, "the WebSocket's Origin is the real one", file: file, line: line)
        XCTAssertEqual(Set(heads.compactMap(\.host)), ["localhost:5173"], file: file, line: line)
    }

    private func until(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out", file: file, line: line)
        throw BrowserError.timeout
    }
}
#endif
