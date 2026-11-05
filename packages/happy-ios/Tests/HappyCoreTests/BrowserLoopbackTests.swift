import Foundation
@testable import HappyCore
import XCTest

final class BrowserLoopbackTests: XCTestCase {
    func testLoopbackLinksLoadUnderAnAliasThatMapsBack() throws {
        let cases = [
            ("http://localhost:6090/live/d35b825e18ea32bebed6f63e89ce2047?x=1#f", "http://localhost.happy-loopback.invalid:6090/live/d35b825e18ea32bebed6f63e89ce2047?x=1#f"),
            ("http://127.0.0.1:5173/", "http://127-0-0-1.happy-loopback.invalid:5173/"),
            ("http://[::1]:8080/a", "http://ip6-1.happy-loopback.invalid:8080/a"),
            ("ws://localhost:6080/websockify", "ws://localhost.happy-loopback.invalid:6080/websockify"),
        ]
        for (real, alias) in cases {
            let aliased = try XCTUnwrap(BrowserLoopback.alias(XCTUnwrap(URL(string: real))), real)
            XCTAssertEqual(aliased.absoluteString, alias)
            XCTAssertEqual(BrowserLoopback.real(aliased)?.absoluteString, real)
        }
        for other in ["https://localhost:6090/", "http://example.com/", "http://10.0.0.2:3000/", "http://a.localhost/", "http://localhost.happy-loopback.invalid/"] {
            XCTAssertNil(BrowserLoopback.alias(URL(string: other)!), other)
        }
        XCTAssertNil(BrowserLoopback.real(URL(string: "http://localhost:6090/")!))
        XCTAssertNil(BrowserLoopback.real(URL(string: "http://a1.happy-artifact.invalid/")!))
        XCTAssertNil(BrowserLoopback.real(URL(string: "http://300-0-0-1.happy-loopback.invalid/")!))
    }

    func testTheAliasAuthorityTunnelsToTheRealOne() throws {
        let alias = try XCTUnwrap(BrowserPolicy.Authority(url: URL(string: "http://localhost.happy-loopback.invalid:6090")!))
        XCTAssertEqual(BrowserLoopback.real(alias)?.text, "localhost:6090")
        let six = try XCTUnwrap(BrowserPolicy.Authority(url: URL(string: "http://ip6-1.happy-loopback.invalid:80")!))
        XCTAssertEqual(BrowserLoopback.real(six)?.text, "[::1]:80")
        XCTAssertNil(BrowserLoopback.real(try XCTUnwrap(BrowserPolicy.Authority(url: URL(string: "http://localhost:6090")!))))
    }

    func testRequestsReachTheServerWithTheRealHostOriginAndReferer() throws {
        let alias = try XCTUnwrap(BrowserPolicy.Authority(url: URL(string: "http://localhost.happy-loopback.invalid:6080")!))
        let real = try XCTUnwrap(BrowserLoopback.real(alias))
        let head = BrowserHTTPHead(line: "GET /websockify HTTP/1.1", fields: [
            ("Host", "localhost.happy-loopback.invalid:6080"), ("Origin", "http://localhost.happy-loopback.invalid:6080"),
            ("Referer", "http://localhost.happy-loopback.invalid:6080/vnc.html?a=1"), ("Upgrade", "websocket"),
            ("Connection", "Upgrade"), ("Proxy-Connection", "keep-alive"), ("Sec-WebSocket-Key", "k"),
        ])
        let sent = try BrowserLoopback.request(head, alias: alias, real: real)
        XCTAssertEqual(sent.value("Host"), "localhost:6080")
        XCTAssertEqual(sent.value("Origin"), "http://localhost:6080")
        XCTAssertEqual(sent.value("Referer"), "http://localhost:6080/vnc.html?a=1")
        XCTAssertEqual(sent.value("Connection"), "Upgrade")
        XCTAssertNil(sent.value("Proxy-Connection"))
        XCTAssertEqual(sent.value("Sec-WebSocket-Key"), "k")

        let page = BrowserHTTPHead(line: "GET /live/x HTTP/1.1", fields: [("Host", "localhost.happy-loopback.invalid:6090"), ("Connection", "keep-alive"), ("Origin", "https://example.com")])
        let plain = try BrowserLoopback.request(page, alias: alias, real: real)
        XCTAssertEqual(plain.value("Host"), "localhost:6080")
        XCTAssertEqual(plain.value("Connection"), "close")
        XCTAssertEqual(plain.value("Origin"), "https://example.com", "another origin is left as the page sent it")
        XCTAssertThrowsError(try BrowserLoopback.request(BrowserHTTPHead(line: "CONNECT a:1 HTTP/1.1", fields: []), alias: alias, real: real))
    }
}
