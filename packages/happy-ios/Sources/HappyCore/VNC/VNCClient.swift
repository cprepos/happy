import Foundation

/// The desktop as it is after an update, for drawing.
public struct VNCFrame: Sendable {
    public let width: Int
    public let height: Int
    /// `0xFFRRGGBB`, rows top down (`VNCFramebuffer`).
    public let pixels: [UInt32]
    /// What changed since the last frame; the whole desktop for the first.
    public let changed: [VNCRect]
}

/// What a connection tells its viewer.
public enum VNCEvent: Sendable {
    /// Through the handshake: the desktop's size and name.
    case connected(width: Int, height: Int, name: String)
    /// An update was drawn. The next is asked for once this returns, so a
    /// slow viewer slows the server, never queues frames.
    case frame(VNCFrame)
    /// The server's clipboard changed (ServerCutText), as text.
    case clipboard(String)
    case bell
}

/// One RFB connection over a byte stream (the live browser's VNC socket):
/// the handshake, then the server's updates read into a framebuffer while
/// the viewer's pointer, keys and clipboard go the other way, in order.
///
/// `run` lasts as long as the connection; cancelling it, or `close`, ends
/// it. Input sent before the handshake is through waits for it.
public final class VNCClient: Sendable {
    private let stream: any BrowserStream
    private let messages: AsyncStream<Data>
    private let outbox: AsyncStream<Data>.Continuation

    public init(stream: any BrowserStream) {
        self.stream = stream
        (messages, outbox) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    deinit { outbox.finish() }

    // MARK: Input

    public func send(_ message: Data) { outbox.yield(message) }

    public func pointer(_ events: [VNCPointerEvent]) {
        guard !events.isEmpty else { return }
        outbox.yield(events.reduce(into: Data()) { $0.append(RFBMessage.pointer($1)) })
    }

    public func key(_ keysym: UInt32, down: Bool) { outbox.yield(RFBMessage.key(keysym, down: down)) }

    /// Down and up, with `modifiers` held around it.
    public func tap(_ keysym: UInt32, modifiers: [UInt32] = []) {
        var data = Data()
        for modifier in modifiers { data.append(RFBMessage.key(modifier, down: true)) }
        data.append(RFBMessage.key(keysym, down: true))
        data.append(RFBMessage.key(keysym, down: false))
        for modifier in modifiers.reversed() { data.append(RFBMessage.key(modifier, down: false)) }
        outbox.yield(data)
    }

    /// `text` typed key by key.
    public func type(_ text: String) {
        var data = Data()
        for stroke in VNCKeys.strokes(for: text) { data.append(RFBMessage.key(stroke.keysym, down: stroke.down)) }
        if !data.isEmpty { outbox.yield(data) }
    }

    /// The viewer's clipboard becomes the server's (ClientCutText).
    public func clipboard(_ text: String) { outbox.yield(RFBMessage.cutText(text)) }

    public func close() async {
        outbox.finish()
        await stream.close()
    }

    // MARK: The connection

    public func run(password: String, events: @escaping @Sendable (VNCEvent) async -> Void) async throws {
        let stream = self.stream
        let reader = RFBReader(stream)
        do {
            let server = try await RFBHandshake.run(reader: reader, write: { try await stream.write($0) }, password: password)
            var framebuffer = VNCFramebuffer(width: server.width, height: server.height)
            try await stream.write(RFBMessage.setPixelFormat(.bgra)
                + RFBMessage.setEncodings(RFBEncoding.offered)
                + RFBMessage.framebufferUpdateRequest(incremental: false, width: server.width, height: server.height))
            await events(.connected(width: server.width, height: server.height, name: server.name))

            let messages = self.messages
            let writer = Task {
                for await message in messages {
                    do { try await stream.write(message) } catch { await stream.close(); return }
                }
            }
            defer { writer.cancel() }
            let decoder = VNCDecoder()
            var first = true
            while true {
                try Task.checkCancellation()
                let type = try await reader.u8()
                switch type {
                case 0:
                    _ = try await reader.u8()
                    let count = Int(try await reader.u16())
                    var changed: [VNCRect] = []
                    var resized = false
                    for _ in 0..<count {
                        let rect = VNCRect(x: Int(try await reader.u16()), y: Int(try await reader.u16()),
                                           width: Int(try await reader.u16()), height: Int(try await reader.u16()))
                        let encoding = try await reader.s32()
                        if encoding == RFBEncoding.lastRect { break }
                        if encoding == RFBEncoding.desktopSize {
                            guard rect.width > 0, rect.height > 0, rect.width <= 16384, rect.height <= 16384 else {
                                throw RFBError.protocolViolation("desktop size")
                            }
                            framebuffer.resize(width: rect.width, height: rect.height)
                            await events(.connected(width: rect.width, height: rect.height, name: server.name))
                            resized = true
                            continue
                        }
                        try await decoder.decode(encoding, rect: rect, from: reader, into: &framebuffer)
                        changed.append(rect)
                    }
                    if first || resized {
                        changed = [VNCRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)]
                    }
                    if !changed.isEmpty {
                        await events(.frame(VNCFrame(width: framebuffer.width, height: framebuffer.height, pixels: framebuffer.pixels, changed: changed)))
                    }
                    // Through the outbox, so it never goes in the middle of
                    // the viewer's own messages.
                    outbox.yield(RFBMessage.framebufferUpdateRequest(incremental: !resized, width: framebuffer.width, height: framebuffer.height))
                    first = first && changed.isEmpty
                case 1:
                    _ = try await reader.u8()
                    _ = try await reader.u16()
                    let count = Int(try await reader.u16())
                    try await reader.skip(count * 6)
                case 2:
                    await events(.bell)
                case 3:
                    try await reader.skip(3)
                    let length = Int(try await reader.u32())
                    guard length <= 8 << 20 else { throw RFBError.protocolViolation("cut text") }
                    let bytes = try await reader.bytes(length)
                    await events(.clipboard(String(bytes.map { Character(Unicode.Scalar($0)) })))
                default:
                    throw RFBError.protocolViolation("message \(type)")
                }
            }
        } catch {
            outbox.finish()
            await stream.close()
            throw error
        }
    }
}
