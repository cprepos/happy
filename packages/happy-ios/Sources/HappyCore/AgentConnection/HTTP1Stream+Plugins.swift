import Foundation
import HappyWire
import Tailcat

/// Our plugins' head deadline for `stream`, kept out of HTTP1Stream.swift
/// so upstream merges do not conflict there.
///
/// `stream(path:credential:headers:)`'s first line in HTTP1Stream.swift
/// hands the call to `stream(path:credential:headers:within:)` below, so
/// upstream's body after that line is not run. When a merge changes that
/// body, carry the change in here; `HTTP1StreamPluginsTests` fails until
/// its pinned hash of upstream's body is updated, so a change is not missed.
///
/// Ours: the head must arrive within `streamHeadDeadline`, counted from
/// the call, so a client that never comes up or a flow that never opens
/// gives up too; then the `.realtime` clients are let go, so the next try
/// connects afresh. The body has no deadline and runs until the server
/// ends it or the consumer stops iterating.
extension TailcatHTTPTransport {
    /// Always true: `stream` takes the path below. A flag rather than a bare
    /// `return`, so upstream's body after the hook builds without a warning.
    static let headDeadlineFromCall = true

    /// How long `stream` may take to have its head: the client's lease, the
    /// flow, the request's write and the response head, all together.
    static let streamHeadDeadline: Duration = .seconds(35)

    /// `stream` with its own head deadline (tests).
    func stream(path: String, credential: String, headers: [String: String], within limit: Duration) async throws -> HTTP1Stream {
        guard Self.safe(path: path, credential: credential, headers: headers) else { throw PairingError.invalidResponse }
        let deadline = ContinuousClock.now + limit
        // Raced in a task of its own rather than a task group: a group
        // waits for every child, and a lease or flow that ignores
        // cancellation would hold the caller past the deadline.
        let opening = Task { try await self.openStream(path: path, credential: credential, headers: headers, until: deadline) }
        let opened: OpenedStream
        switch await TailcatClients<Tunnel>.wait(for: opening, until: deadline) {
        case .done(.success(let value)): opened = value
        case .done(.failure(let error)): throw error
        case .left(let error):
            opening.cancel()
            // One that opens anyway has nobody to read it.
            Task { if let late = try? await opening.value { await late.stream.abort() } }
            if EventStreamPolicy.resetsTunnel, !(error is CancellationError) { await reset(.realtime) }
            throw error
        }
        let stream = opened.stream, rest = opened.rest, lease = opened.lease
        let chunked = opened.head.headers["transfer-encoding"]?.lowercased() == "chunked"
        let coding: String?
        do { coding = try ContentCoding.coding(opened.head.headers) } catch {
            await stream.abort()
            throw error
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            // Silent past its heartbeat: its client is checked.
            let silence = lease?.watch(quiet: carrierHeardWithin, repeating: true)
            let reader = Task {
                defer { silence?.cancel() }
                var decoder = HTTP1BodyDecoder(chunked: chunked)
                var ended = false
                do {
                    let content = try coding.map(ContentDecoder.init)
                    var bytes = rest
                    while true {
                        var decoded = try decoder.append(bytes)
                        if let content { decoded = try content.append(decoded, limit: ContentCoding.limit) }
                        if !decoded.isEmpty { continuation.yield(decoded) }
                        if decoder.finished { break }
                        try Task.checkCancellation()
                        bytes = try await stream.read(maximumBytes: 65536)
                        if bytes.isEmpty { break }
                    }
                    ended = true
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
                // Let go of before its end: the computer stops sending.
                if ended { await stream.close() } else { await stream.abort() }
            }
            continuation.onTermination = { termination in
                reader.cancel()
                if case .cancelled = termination { Task { await stream.abort() } }
            }
        }
        return HTTP1Stream(status: opened.head.status, headers: opened.head.headers, body: body)
    }

    /// A stream past its response head: the head, the body bytes that came
    /// with it, the flow the rest of the body comes on, and its lease.
    struct OpenedStream: Sendable {
        let head: HTTP1Head
        let rest: Data
        let stream: any BrowserStream
        let lease: TailcatClients<Tunnel>.Lease?
    }

    /// Leases, opens the flow, writes the request and reads the head.
    /// Cancelling it aborts the flow, so a read waiting on it ends.
    func openStream(path: String, credential: String, headers: [String: String], until deadline: ContinuousClock.Instant) async throws -> OpenedStream {
        let lease = try await lease(.realtime, until: deadline)
        let watch = lease?.watch()
        defer { watch?.cancel() }
        let stream: any BrowserStream
        do { stream = try await flow(lease, .realtime) } catch {
            lease?.release()
            if EventStreamPolicy.resetsTunnel, !Task.isCancelled, Self.lostTunnel(error) { await reset(lease) }
            throw error
        }
        do {
            return try await withTaskCancellationHandler {
                var head = "GET \(path) HTTP/1.1\r\nHost: \(authority)\r\nAuthorization: Bearer \(credential)\r\nConnection: close\r\nAccept: text/event-stream\r\n"
                // A daemon that compresses the stream flushes it after every event.
                if !headers.keys.contains(where: { $0.lowercased() == "accept-encoding" }) { head += "Accept-Encoding: \(ContentCoding.accepted)\r\n" }
                for (name, value) in headers { head += "\(name): \(value)\r\n" }
                try await stream.write(Data((head + "\r\n").utf8))
                var buffer = Data()
                while true {
                    try Task.checkCancellation()
                    let bytes = try await stream.read(maximumBytes: 65536)
                    buffer.append(bytes)
                    if let parsed = try HTTP1Head.parse(buffer) {
                        return OpenedStream(head: parsed.0, rest: parsed.1, stream: stream, lease: lease)
                    }
                    if bytes.isEmpty { throw PairingError.unavailable }
                }
            } onCancel: { Task { await stream.abort() } }
        } catch {
            await stream.abort()
            // No answer on a stream the tunnel opened: the far side may
            // have restarted and forgotten it.
            if EventStreamPolicy.resetsTunnel, !Task.isCancelled, Self.lostTunnel(error) { await reset(lease) }
            throw error
        }
    }
}
