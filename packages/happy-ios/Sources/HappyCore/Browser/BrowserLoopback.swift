import Foundation

/// The computer's own `localhost`, under a name the phone's WebKit sends
/// through its proxy.
///
/// On a device, WebKit connects loopback hosts (`localhost`, `127.0.0.1`,
/// `::1`) itself and never asks the configured proxy, so a link to an
/// agent's dev server or live browser reached the phone's own loopback and
/// failed before anything left it. The browser loads the alias instead; the
/// proxy tunnels it to the real loopback authority on the computer and puts
/// the real `Host`, `Origin` and `Referer` back, so the server sees exactly
/// what it would from a browser on the computer.
public enum BrowserLoopback {
    static let suffix = ".happy-loopback.invalid"

    /// `url` with its loopback host swapped for the alias; nil for any
    /// other URL. Only plain HTTP: a TLS name would not match the alias.
    public static func alias(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "ws"].contains(scheme),
              let host = url.host, let label = label(for: BrowserPolicy.normalize(host)),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = label + suffix
        return parts.url
    }

    /// The real address behind an alias URL; nil for any other URL.
    public static func real(_ url: URL) -> URL? {
        guard let host = url.host, let real = realHost(forAlias: host.lowercased()),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = real.contains(":") ? "[\(real)]" : real
        return parts.url
    }

    /// The real authority behind an alias authority; nil for any other.
    public static func real(_ authority: BrowserPolicy.Authority) -> BrowserPolicy.Authority? {
        guard let host = realHost(forAlias: authority.host),
              let url = URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(authority.port)") else { return nil }
        return BrowserPolicy.Authority(url: url)
    }

    /// One request's head bound for the real server: `Host`, `Origin` and
    /// `Referer` name the real authority, and the connection closes after
    /// the response (or upgrades), so every request is rewritten.
    public static func request(_ head: BrowserHTTPHead, alias: BrowserPolicy.Authority, real: BrowserPolicy.Authority) throws -> BrowserHTTPHead {
        let parts = head.line.split(separator: " ")
        guard parts.count == 3, parts[0] != "CONNECT", parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else { throw BrowserError.malformed }
        var result = head
        let dropped: Set<String> = ["connection", "proxy-connection", "proxy-authorization", "x-happy-proxy-route"]
        result.fields = head.fields.compactMap { name, value in
            let key = name.lowercased()
            if dropped.contains(key) { return nil }
            if key == "host" { return (name, hostField(real)) }
            if key == "origin" || key == "referer", let url = URL(string: value), BrowserPolicy.Authority(url: url) == alias,
               let unaliased = Self.real(url) {
                return (name, key == "origin" ? String(unaliased.absoluteString.trimmingSuffix("/")) : unaliased.absoluteString)
            }
            return (name, value)
        }
        if result.value("host") == nil { result.fields.insert(("Host", hostField(real)), at: 0) }
        result.fields.append(("Connection", head.value("upgrade") == nil ? "close" : "Upgrade"))
        return result
    }

    private static func hostField(_ authority: BrowserPolicy.Authority) -> String {
        let host = authority.host.contains(":") ? "[\(authority.host)]" : authority.host
        return authority.port == 80 ? host : "\(host):\(authority.port)"
    }

    private static func label(for host: String) -> String? {
        if host == "localhost" { return "localhost" }
        if host == "::1" { return "ip6-1" }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127", octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return octets.joined(separator: "-")
    }

    private static func realHost(forAlias host: String) -> String? {
        guard host.hasSuffix(suffix) else { return nil }
        let label = String(host.dropLast(suffix.count))
        if label == "localhost" { return "localhost" }
        if label == "ip6-1" { return "::1" }
        let octets = label.split(separator: "-", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127", octets.allSatisfy({ UInt8($0) != nil && !$0.isEmpty }) else { return nil }
        return octets.joined(separator: ".")
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> Substring { hasSuffix(suffix) ? dropLast(suffix.count) : Substring(self) }
}
