import Foundation
import Tailcat

/// Backpressured bytes: each read/write finishes before the next is issued.
public protocol BrowserStream: Sendable {
    var authority: String { get }
    func read(maximumBytes: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

extension BrowserStream {
    public var authority: String { "server.tailcat" }
}

extension TailcatConnection: BrowserStream {}

extension AgentTransport {
    public func browserConnection() async throws -> any BrowserStream { throw BrowserError.unavailable }
}

extension TailcatHTTPTransport {
    /// Over a `.file` client: a page's bytes are a file's, and its many
    /// short flows never crowd the event stream's or the queries' stack.
    public func browserConnection() async throws -> any BrowserStream {
        let lease = try await lease(.file)
        do { return try await flow(lease, .file) } catch {
            lease?.release()
            throw error
        }
    }
}

extension AgentClient {
    /// The computer's recorder, when the client's transport counts.
    var metrics: ConnectionMetrics? { (transport as? MeteredAgentTransport)?.metrics ?? (transport as? AgentEndpointTransport)?.metrics }

    /// Authentication is injected here and never returned to the web process.
    public func browserTunnel(workspaceID: String, target: BrowserPolicy.Authority) async throws -> any BrowserStream {
        guard BrowserPolicy.validID(workspaceID) else { throw BrowserError.forbidden }
        let start = ConnectionMetrics.uptime()
        let stream: any BrowserStream
        do { stream = try await transport.proxyTunnel("/v0/workspaces/\(workspaceID)/proxy", credential: token) } catch {
            if !(error is CancellationError) {
                let status: Int? = if case BrowserError.upstream(let code) = error { code } else { nil }
                metrics?.request(.browser, status: status, duration: ConnectionMetrics.uptime() - start)
            }
            // No way to the computer at all is the link failing (502), as
            // a failure inside the tunnel is, not the proxy's own (500).
            if error is CancellationError || error is BrowserError || error is AgentClientError { throw error }
            throw BrowserProxyFailure.upstream(error)
        }
        do {
            try await Self.connect(stream, target: target.text, credential: nil)
            metrics?.request(.browser, status: 200, duration: ConnectionMetrics.uptime() - start)
            return stream
        } catch {
            if !(error is CancellationError) {
                let status: Int? = if case BrowserError.upstream(let code) = error { code } else { nil }
                metrics?.request(.browser, status: status, duration: ConnectionMetrics.uptime() - start)
            }
            await stream.close()
            if error is CancellationError { throw error }
            if case BrowserError.upstream = error { throw error }
            throw BrowserProxyFailure.upstream(error)
        }
    }

    public func artifactConnection(head: BrowserHTTPHead, artifactID: String, version: Int) async throws -> any BrowserStream {
        let stream = try await transport.browserConnection()
        do {
            let request = try head.artifactRequest(artifactID: artifactID, version: version, credential: try await transport.bearer(token), authority: stream.authority)
            try await stream.write(request.data); return stream
        }
        catch { await stream.close(); throw error }
    }

    static func connect(_ stream: any BrowserStream, target: String, credential: String?) async throws {
        var head = "CONNECT \(target) HTTP/1.1\r\nHost: \(credential == nil ? target : stream.authority)\r\n"
        if let credential { head += "Authorization: Bearer \(credential)\r\n" }
        try await stream.write(Data((head + "\r\n").utf8))
        let (response, rest) = try await BrowserRelay.head(stream)
        guard response.line.split(separator: " ").dropFirst().first == "200", rest.isEmpty else {
            throw BrowserError.upstream(Int(response.line.split(separator: " ").dropFirst().first ?? "") ?? 502)
        }
    }
}

public enum BrowserRelay {
    /// Buffer only bounded requests (the artifact API's 1 MiB contract). Convert
    /// chunked uploads to one exact length so no trailer or pipelined request can
    /// enter the authenticated daemon connection.
    public static func requestBody(_ head: BrowserHTTPHead, initial: Data, stream: any BrowserStream) async throws -> (BrowserHTTPHead, Data) {
        let lengths = head.fields.filter { $0.0.lowercased() == "content-length" }
        let transfers = head.fields.filter { $0.0.lowercased() == "transfer-encoding" }
        guard lengths.count <= 1, transfers.count <= 1, lengths.isEmpty || transfers.isEmpty else { throw BrowserError.malformed }
        var body = Data()
        if let transfer = transfers.first {
            guard transfer.1.lowercased() == "chunked" else { throw BrowserError.malformed }
            var decoder = HTTP1BodyDecoder(chunked: true)
            var bytes = initial
            var received = 0
            while true {
                received += bytes.count
                guard received <= 1_114_112 else { throw BrowserError.tooLarge }
                body.append(try decoder.append(bytes))
                guard body.count <= 1_048_576 else { throw BrowserError.tooLarge }
                if decoder.finished { break }
                bytes = try await stream.read(maximumBytes: 65536)
                guard !bytes.isEmpty else { throw BrowserError.malformed }
            }
        } else {
            let text = lengths.first?.1 ?? "0"
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(text), initial.count <= length else { throw BrowserError.malformed }
            guard length <= 1_048_576 else { throw BrowserError.tooLarge }
            body = initial
            while body.count < length {
                let bytes = try await stream.read(maximumBytes: min(65536, length - body.count))
                guard !bytes.isEmpty, bytes.count <= length - body.count else { throw BrowserError.malformed }
                body.append(bytes)
            }
        }
        var request = head
        request.fields.removeAll { ["content-length", "transfer-encoding", "trailer"].contains($0.0.lowercased()) }
        request.fields.append(("Content-Length", String(body.count)))
        return (request, body)
    }

    /// A head; with a `timeout`, a stream that sends none in time is closed.
    public static func head(_ stream: any BrowserStream, initial: Data = Data(), timeout: Duration? = .seconds(35)) async throws -> (BrowserHTTPHead, Data) {
        try await withThrowingTaskGroup(of: (BrowserHTTPHead, Data).self) { group in
            group.addTask {
                var buffer = initial
                while true {
                    try Task.checkCancellation()
                    if let head = try BrowserHTTPHead.parse(buffer) { return head }
                    let bytes = try await stream.read(maximumBytes: 65536)
                    guard !bytes.isEmpty else { throw BrowserError.unavailable }
                    buffer.append(bytes)
                }
            }
            if let timeout { group.addTask { try await Task.sleep(for: timeout); await stream.close(); throw BrowserError.timeout } }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    public static func pipe(_ source: any BrowserStream, to destination: any BrowserStream) async throws {
        while true {
            try Task.checkCancellation()
            let bytes = try await source.read(maximumBytes: 65536)
            if bytes.isEmpty { return }
            try await destination.write(bytes)
        }
    }

    /// How long an exchange waits for its response head: past any long poll
    /// a page makes (WebKit gives up on a request after 60 s), short of a
    /// tunnel that went quiet holding the page's connection for good.
    static let exchangeHeadDeadline: Duration = .seconds(120)

    /// The one exchange of a connection whose request head already went to
    /// `remote`: the rest of its body follows, and its response comes back
    /// saying `Connection: close`, after which both ends close. A server may
    /// close as asked and not say so (websockify answers HTTP/1.1 with only a
    /// length), and WebKit would then send its next request down the same
    /// tunnel, past the rewrite, to a server that is gone. An upgrade stays
    /// open both ways.
    public static func exchange(_ local: any BrowserStream, _ remote: any BrowserStream, method: String) async throws {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pipe(local, to: remote) }
                group.addTask {
                    // A long deadline: a long poll answers when it answers,
                    // a dead tunnel never does.
                    var (response, bytes) = try await head(remote, timeout: exchangeHeadDeadline)
                    var interim = 0
                    while let status = response.statusCode, (100..<200).contains(status), status != 101 {
                        interim += 1
                        guard interim <= 8 else { throw BrowserError.malformed }
                        try await local.write(response.data)
                        (response, bytes) = try await head(remote, initial: bytes, timeout: exchangeHeadDeadline)
                    }
                    if response.statusCode == 101 {
                        try await local.write(response.data)
                        if !bytes.isEmpty { try await local.write(bytes) }
                        try await pipe(remote, to: local)
                        return
                    }
                    var body = try BrowserResponseBody(head: response, method: method)
                    var closing = response
                    closing.fields.removeAll { ["connection", "keep-alive", "proxy-connection"].contains($0.0.lowercased()) }
                    closing.fields.append(("Connection", "close"))
                    try await local.write(closing.data)
                    try body.append(bytes)
                    if !bytes.isEmpty { try await local.write(bytes) }
                    while !body.finished {
                        let data = try await remote.read(maximumBytes: 65536)
                        if data.isEmpty { try body.end(); break }
                        try body.append(data)
                        try await local.write(data)
                    }
                }
                defer { group.cancelAll() }
                do { _ = try await group.next() }
                catch { await local.close(); await remote.close(); throw error }
                await local.close(); await remote.close()
            }
        } onCancel: { Task { await local.close(); await remote.close() } }
    }

    public static func duplex(_ first: any BrowserStream, _ second: any BrowserStream) async throws {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pipe(first, to: second) }
                group.addTask { try await pipe(second, to: first) }
                defer { group.cancelAll() }
                do { _ = try await group.next() }
                catch { await first.close(); await second.close(); throw error }
                await first.close(); await second.close()
            }
        } onCancel: { Task { await first.close(); await second.close() } }
    }
}

extension BrowserHTTPHead {
    /// A request's method.
    var method: String { line.split(separator: " ").first.map(String.init) ?? "" }
    fileprivate var statusCode: Int? { Int(line.split(separator: " ").dropFirst().first ?? "") }
}
