import Foundation
#if canImport(Network)
import Network

/// Single resources (a document's pictures) fetched as the in-app browser
/// reaches the web: through the agent connection's workspace proxy, never
/// the phone's network, with no fallback. `https` goes through a loopback
/// `BrowserProxy` that URLSession uses as its CONNECT proxy, so TLS stays
/// end to end; plain `http` is one request over a CONNECT tunnel, which keeps
/// App Transport Security (that refuses plain HTTP before any proxy) out
/// of it. Nothing is sent with a request but the request. A live browser's
/// card (`LiveBrowserLink`) reads its frame and state, and ends a
/// takeover, the same way.
public actor BrowserFetcher {
    /// The largest body read; past it the fetch fails.
    public static let limit = BrowserExchange.limit
    static let redirects = 5

    private let client: AgentClient
    private let resolveWorkspace: @Sendable () async throws -> String
    private var workspace: Task<String, Error>?
    private var opening: Task<(URLSession, BrowserProxy), Error>?
    private var stopped = false

    /// `workspace` names the workspace whose network reaches the web,
    /// asked once, when the first resource is.
    public init(client: AgentClient, workspace: @escaping @Sendable () async throws -> String) {
        self.client = client
        resolveWorkspace = workspace
    }

    /// A picture, or anything else read whole: `send` as a GET.
    public func data(_ url: URL) async throws -> Data {
        try await send(method: "GET", url: url, accept: "image/*,*/*;q=0.8")
    }

    /// One request and its answer's body, which must be a success. Only a
    /// GET follows redirects; any other method sends its `body` (with its
    /// length, none for nothing) once and is never replayed.
    public func send(method: String, url: URL, body: Data? = nil, accept: String = "*/*") async throws -> Data {
        try await send(method: method, url: url, body: body, accept: accept, redirects: Self.redirects)
    }

    private func send(method: String, url: URL, body: Data?, accept: String, redirects: Int) async throws -> Data {
        guard !stopped else { throw CancellationError() }
        guard BrowserExchange.validMethod(method) else { throw BrowserError.malformed }
        switch url.scheme?.lowercased() {
        case "https": return try await secure(method: method, url: url, body: body, accept: accept)
        case "http": return try await plain(method: method, url: url, body: body, accept: accept, redirects: redirects)
        default: throw BrowserError.forbidden
        }
    }

    /// Lets go of the proxy and its connections.
    public func stop() async {
        stopped = true
        opening?.cancel()
        if let (session, proxy) = try? await opening?.value {
            session.invalidateAndCancel()
            await proxy.stop()
        }
        opening = nil
    }

    private func workspaceID() async throws -> String {
        if let workspace { return try await workspace.value }
        let task = Task { try await resolveWorkspace() }
        workspace = task
        do { return try await task.value } catch {
            // Asked again next time: the computer may come back.
            workspace = nil
            throw error
        }
    }

    // MARK: https

    private func secure(method: String, url: URL, body: Data?, accept: String) async throws -> Data {
        let (session, _) = try await proxied()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw BrowserError.upstream((response as? HTTPURLResponse)?.statusCode ?? 502) }
        guard data.count <= Self.limit else { throw BrowserError.tooLarge }
        return data
    }

    private func proxied() async throws -> (URLSession, BrowserProxy) {
        if let opening { return try await opening.value }
        let client = client
        let task = Task { [self] () throws -> (URLSession, BrowserProxy) in
            let proxy = BrowserProxy(client: client, scope: .workspace(id: try await workspaceID()))
            let port = try await proxy.start()
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { await proxy.stop(); throw BrowserError.unavailable }
            var settings = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: endpointPort))
            settings.allowFailover = false
            settings.applyCredential(username: proxy.username, password: proxy.password)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.proxyConfigurations = [settings]
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 35
            let delegate = ProxyCredential(user: proxy.username, password: proxy.password)
            return (URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil), proxy)
        }
        opening = task
        do { return try await task.value } catch {
            opening = nil
            throw error
        }
    }

    /// Answers the loopback proxy's challenge, should URLSession not send
    /// the configuration's credential unasked; never any other challenge.
    private final class ProxyCredential: NSObject, URLSessionTaskDelegate, Sendable {
        let user: String
        let password: String
        init(user: String, password: String) { self.user = user; self.password = password }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.isProxy(), challenge.protectionSpace.host == "127.0.0.1", challenge.previousFailureCount == 0 else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
        }
    }

    // MARK: http

    private func plain(method: String, url: URL, body: Data?, accept: String, redirects: Int) async throws -> Data {
        let response = try await BrowserExchange.send(client, workspaceID: try await workspaceID(), method: method, url: url, body: body, accept: accept)
        if [301, 302, 303, 307, 308].contains(response.status) {
            guard method == "GET", redirects > 0, let location = response.location, let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw BrowserError.upstream(response.status) }
            return try await send(method: method, url: next, body: nil, accept: accept, redirects: redirects - 1)
        }
        guard (200..<300).contains(response.status) else { throw BrowserError.upstream(response.status) }
        return response.body
    }
}
#endif

/// One plain-HTTP request over a CONNECT tunnel through a workspace, and
/// the whole answer: `BrowserFetcher`'s `http`, apart so it runs (and is
/// tested) where Network isn't.
enum BrowserExchange {
    /// The largest body read; past it the request fails.
    static let limit = 32 * 1024 * 1024

    static func validMethod(_ method: String) -> Bool {
        !method.isEmpty && method.utf8.allSatisfy { (65...90).contains($0) }
    }

    static func send(_ client: AgentClient, workspaceID: String, method: String, url: URL, body: Data?, accept: String) async throws -> (status: Int, location: String?, body: Data) {
        guard validMethod(method), let authority = BrowserPolicy.Authority(url: url), let host = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw BrowserError.malformed }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?" + query }
        guard !target.utf8.contains(where: { $0 < 33 || $0 == 127 }), !accept.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw BrowserError.malformed }
        let hostField = (host.contains(":") ? "[\(host)]" : host) + (url.port.map { ":\($0)" } ?? "")
        // A GET says nothing of a body; anything else says how long it is.
        let length = body != nil || method != "GET" ? "Content-Length: \(body?.count ?? 0)\r\n" : ""
        var request = Data("\(method) \(target) HTTP/1.1\r\nHost: \(hostField)\r\nAccept: \(accept)\r\nAccept-Encoding: identity\r\n\(length)Connection: close\r\n\r\n".utf8)
        if let body { request.append(body) }
        let stream = try await client.browserTunnel(workspaceID: workspaceID, target: authority)
        do {
            try await stream.write(request)
            let response = try await read(stream)
            await stream.close()
            return response
        } catch {
            await stream.close()
            throw error
        }
    }

    /// One response, its body by its length, its chunks, or to the close.
    static func read(_ stream: any BrowserStream) async throws -> (status: Int, location: String?, body: Data) {
        let (head, rest) = try await BrowserRelay.head(stream)
        let parts = head.line.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else { throw BrowserError.malformed }
        let chunked = head.value("transfer-encoding")?.lowercased().contains("chunked") == true
        let length = chunked ? nil : head.value("content-length").flatMap { Int($0) }
        if let length, length > limit { throw BrowserError.tooLarge }
        var decoder = HTTP1BodyDecoder(chunked: chunked)
        var body = try decoder.append(rest)
        while !(chunked && decoder.finished), body.count < (length ?? .max) {
            try Task.checkCancellation()
            let bytes = try await stream.read(maximumBytes: 65536)
            if bytes.isEmpty {
                // Closed: the body is what came, unless more was promised.
                guard length == nil, !chunked else { throw BrowserError.malformed }
                break
            }
            body.append(try decoder.append(bytes))
            guard body.count <= limit else { throw BrowserError.tooLarge }
        }
        if let length { body = body.prefix(length) }
        return (status, head.value("location"), body)
    }
}
