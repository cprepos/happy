import Foundation
import HappyWire
import Tailcat

extension TailcatHTTPTransport {
    static func safe(path: String, credential: String, headers: [String: String]) -> Bool {
        path.hasPrefix("/") && !path.contains("\r") && !path.contains("\n") && !path.contains(" ")
            && !credential.contains("\r") && !credential.contains("\n")
            && headers.allSatisfy { !$0.key.contains("\r") && !$0.key.contains("\n") && !$0.key.contains(":") && !$0.value.contains("\r") && !$0.value.contains("\n") }
    }

    /// How long `stream` may take to have its head: the client's lease, the
    /// flow, the request's write and the response head, all together.
    static let streamHeadDeadline: Duration = .seconds(35)

    /// Over the `.realtime` client. The head must arrive within
    /// `streamHeadDeadline`, counted from the call, so a client that never
    /// comes up or a flow that never opens gives up too; then the
    /// `.realtime` clients are let go, so the next try connects afresh.
    /// The body has no deadline and runs until the server ends it or the
    /// consumer stops iterating.
    public func stream(path: String, credential: String, headers: [String: String]) async throws -> HTTP1Stream {
        try await stream(path: path, credential: credential, headers: headers, within: Self.streamHeadDeadline)
    }

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
            Task { if let late = try? await opening.value { await late.stream.close() } }
            if !(error is CancellationError) { await reset(.realtime) }
            throw error
        }
        let stream = opened.stream, rest = opened.rest
        let chunked = opened.head.headers["transfer-encoding"]?.lowercased() == "chunked"
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let reader = Task {
                var decoder = HTTP1BodyDecoder(chunked: chunked)
                do {
                    var bytes = rest
                    while true {
                        let decoded = try decoder.append(bytes)
                        if !decoded.isEmpty { continuation.yield(decoded) }
                        if decoder.finished { break }
                        try Task.checkCancellation()
                        bytes = try await stream.read(maximumBytes: 65536)
                        if bytes.isEmpty { break }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
                await stream.close()
            }
            continuation.onTermination = { _ in reader.cancel(); Task { await stream.close() } }
        }
        return HTTP1Stream(status: opened.head.status, headers: opened.head.headers, body: body)
    }

    /// A stream past its response head: the head, the body bytes that came
    /// with it, and the flow the rest of the body comes on.
    struct OpenedStream: Sendable {
        let head: HTTP1Head
        let rest: Data
        let stream: any BrowserStream
    }

    /// Leases, opens the flow, writes the request and reads the head.
    /// Cancelling it closes the flow, so a read waiting on it ends.
    private func openStream(path: String, credential: String, headers: [String: String], until deadline: ContinuousClock.Instant) async throws -> OpenedStream {
        let lease = try await lease(.realtime, until: deadline)
        let stream: any BrowserStream
        do { stream = try await flow(lease, .realtime) } catch {
            lease?.release()
            if Self.lostTunnel(error) { await reset(lease) }
            throw error
        }
        do {
            return try await withTaskCancellationHandler {
                var head = "GET \(path) HTTP/1.1\r\nHost: \(authority)\r\nAuthorization: Bearer \(credential)\r\nConnection: close\r\nAccept: text/event-stream\r\n"
                for (name, value) in headers { head += "\(name): \(value)\r\n" }
                try await stream.write(Data((head + "\r\n").utf8))
                var buffer = Data()
                while true {
                    try Task.checkCancellation()
                    let bytes = try await stream.read(maximumBytes: 65536)
                    buffer.append(bytes)
                    if let parsed = try HTTP1Head.parse(buffer) {
                        return OpenedStream(head: parsed.0, rest: parsed.1, stream: stream)
                    }
                    if bytes.isEmpty { throw PairingError.unavailable }
                }
            } onCancel: { Task { await stream.close() } }
        } catch {
            await stream.close()
            // No answer on a stream the tunnel opened: the far side may
            // have restarted and forgotten it.
            if Self.lostTunnel(error) { await reset(lease) }
            throw error
        }
    }
}

/// A response's status line and headers, once all of them have arrived, and
/// the body bytes that came with them.
struct HTTP1Head: Sendable {
    let status: Int
    let headers: [String: String]

    static func parse(_ data: Data) throws -> (HTTP1Head, Data)? {
        guard let divider = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 32768 else { throw PairingError.invalidResponse }
            return nil
        }
        guard divider.lowerBound - data.startIndex <= 32768,
              let head = String(data: data[..<divider.lowerBound], encoding: .utf8) else { throw PairingError.invalidResponse }
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = (lines.first ?? "").split(separator: " ")
        guard statusParts.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(String(statusParts[0])),
              let status = Int(statusParts[1]), (200...599).contains(status) else { throw PairingError.invalidResponse }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw PairingError.invalidResponse }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, headers[name] == nil else { throw PairingError.invalidResponse }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (HTTP1Head(status: status, headers: headers), Data(data[divider.upperBound...]))
    }
}

/// A streamed body decoded as it comes: chunked framing undone, or the bytes
/// as they are when the body is close-delimited.
struct HTTP1BodyDecoder {
    let chunked: Bool
    private var pending = Data()
    /// Bytes left in the current chunk; nil while a size line is awaited.
    private var remaining: Int?
    private(set) var finished = false

    init(chunked: Bool) { self.chunked = chunked }

    mutating func append(_ bytes: Data) throws -> Data {
        guard chunked else { return bytes }
        pending.append(bytes)
        var out = Data()
        while !finished {
            if let count = remaining {
                if count > 0 {
                    let take = min(count, pending.count)
                    guard take > 0 else { break }
                    out.append(pending.prefix(take))
                    pending = Data(pending.dropFirst(take))
                    remaining = count - take
                    continue
                }
                guard pending.count >= 2 else { break }
                guard pending.prefix(2) == Data("\r\n".utf8) else { throw PairingError.invalidResponse }
                pending = Data(pending.dropFirst(2))
                remaining = nil
                continue
            }
            guard let lineEnd = pending.range(of: Data("\r\n".utf8)) else {
                guard pending.count < 8192 else { throw PairingError.invalidResponse }
                break
            }
            guard let text = String(data: pending[pending.startIndex..<lineEnd.lowerBound], encoding: .utf8),
                  let countText = text.split(separator: ";", maxSplits: 1).first,
                  let count = Int(countText.trimmingCharacters(in: .whitespaces), radix: 16),
                  count >= 0, count <= 8 * 1024 * 1024 else { throw PairingError.invalidResponse }
            pending = Data(pending[lineEnd.upperBound...])
            if count == 0 { finished = true } else { remaining = count }
        }
        return out
    }
}

/// One Server-Sent Events frame.
public struct ServerSentEvent: Equatable, Sendable {
    public var id: String?
    public var event: String
    public var data: String
}

/// Splits a byte stream into SSE frames (WHATWG event-stream parsing): lines
/// end in LF, CR or CRLF; comments are skipped; `data` lines join with LF.
public struct ServerSentEventParser: Sendable {
    private var buffer = Data()
    private var sawCR = false
    private var id: String?
    private var event = ""
    private var data: [String] = []
    private var hasData = false

    public init() {}

    /// Lines are found by scanning the bytes and taken whole: appended to
    /// `Data` a byte at a time, the stream's every byte cost a call, about
    /// a twentieth of the phone's time while agents wrote.
    public mutating func append(_ bytes: Data) -> [ServerSentEvent] {
        var frames: [ServerSentEvent] = []
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let all = raw.bindMemory(to: UInt8.self)
            var index = 0
            // A CR that ended the last chunk: an LF starting this one is its pair.
            if sawCR, !all.isEmpty {
                sawCR = false
                if all[0] == 0x0A { index = 1 }
            }
            var start = index
            while index < all.count {
                let byte = all[index]
                guard byte == 0x0A || byte == 0x0D else { index += 1; continue }
                let piece = UnsafeBufferPointer(rebasing: all[start..<index])
                if buffer.isEmpty {
                    line(String(decoding: piece, as: UTF8.self), into: &frames)
                } else {
                    buffer.append(contentsOf: piece)
                    line(String(decoding: buffer, as: UTF8.self), into: &frames)
                    buffer.removeAll(keepingCapacity: true)
                }
                index += 1
                if byte == 0x0D {
                    if index == all.count { sawCR = true } else if all[index] == 0x0A { index += 1 }
                }
                start = index
            }
            if start < all.count { buffer.append(contentsOf: UnsafeBufferPointer(rebasing: all[start..<all.count])) }
        }
        return frames
    }

    private mutating func line(_ line: String, into frames: inout [ServerSentEvent]) {
        if line.isEmpty {
            if hasData {
                frames.append(ServerSentEvent(id: id, event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n")))
            }
            event = ""; data = []; hasData = false; id = nil
            return
        }
        if line.hasPrefix(":") { return }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line); value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value)); hasData = true
        case "id": if !value.contains("\0") { id = String(value) }
        default: break
        }
    }
}
