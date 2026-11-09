import CZlib
import Foundation
@testable import HappyCore
import XCTest

/// The native live-browser viewer's protocol side: VNC Authentication's
/// DES, the RFB handshake, the client's messages, the decoders, the
/// connection end to end over a scripted stream, the pointer and keys, and
/// where the viewer connects.

// MARK: Fakes

/// A byte stream whose far side the test feeds as it goes: a read waits
/// for bytes, an `end` (or `close`) ends the stream.
private final class Wire: BrowserStream, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var waiting: CheckedContinuation<Data, Never>?
    private var ended = false
    private var written: [Data] = []

    init(_ chunks: [Data] = []) { self.chunks = chunks }

    func feed(_ data: Data) {
        let waiter: CheckedContinuation<Data, Never>? = lock.withLock {
            if let waiting { self.waiting = nil; return waiting }
            chunks.append(data)
            return nil
        }
        waiter?.resume(returning: data)
    }

    func feed(_ bytes: [UInt8]) { feed(Data(bytes)) }

    func end() {
        let waiter: CheckedContinuation<Data, Never>? = lock.withLock {
            ended = true
            defer { waiting = nil }
            return waiting
        }
        waiter?.resume(returning: Data())
    }

    func read(maximumBytes: Int) async throws -> Data {
        await withCheckedContinuation { continuation in
            let now: Data? = lock.withLock {
                if !chunks.isEmpty { return chunks.removeFirst() }
                if ended { return Data() }
                waiting = continuation
                return nil
            }
            if let now { continuation.resume(returning: now) }
        }
    }

    func write(_ data: Data) async throws { lock.withLock { written.append(data) } }
    func close() async { end() }
    var writes: [Data] { lock.withLock { written } }
    /// Everything written, as one byte string.
    var bytes: [UInt8] { writes.flatMap { [UInt8]($0) } }
}

/// Bytes ended: what a decoder or the handshake reads from.
private func ended(_ bytes: [UInt8]) -> Wire {
    let wire = Wire([Data(bytes)])
    wire.end()
    return wire
}

private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
private func unhex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

private func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func u32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func s32(_ value: Int32) -> [UInt8] { u32(Int(UInt32(bitPattern: value))) }

/// ServerInit for a desktop of `width` × `height` named `name`.
private func serverInit(_ width: Int, _ height: Int, name: String = "chromium") -> [UInt8] {
    u16(width) + u16(height) + RFBPixelFormat.bgra.encoded + u32(name.utf8.count) + Array(name.utf8)
}

/// A rectangle's header.
private func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ encoding: Int32) -> [UInt8] {
    u16(x) + u16(y) + u16(width) + u16(height) + s32(encoding)
}

/// A wire pixel (B, G, R, unused) and a ZRLE CPIXEL (B, G, R).
private func px(_ colour: UInt32) -> [UInt8] { [UInt8(colour & 0xFF), UInt8(colour >> 8 & 0xFF), UInt8(colour >> 16 & 0xFF), 0] }
private func cpixel(_ colour: UInt32) -> [UInt8] { Array(px(colour).prefix(3)) }

private let red: UInt32 = 0xFFFF_0000
private let green: UInt32 = 0xFF00_FF00
private let blue: UInt32 = 0xFF00_00FF
private let grey: UInt32 = 0xFF80_8080

/// One zlib stream across several messages, flushed after each, as a ZRLE
/// server keeps it.
private final class Deflater {
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)

    init() {
        stream.initialize(to: z_stream())
        precondition(czlib_deflate_init(stream, 6) == Z_OK)
    }

    deinit {
        deflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    func compress(_ input: [UInt8]) -> [UInt8] {
        var source = input
        var output = [UInt8](repeating: 0, count: input.count + 1024)
        let room = output.count
        source.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.pointee.next_in = source.baseAddress
                stream.pointee.avail_in = uInt(source.count)
                stream.pointee.next_out = target.baseAddress
                stream.pointee.avail_out = uInt(target.count)
                precondition(deflate(stream, Z_SYNC_FLUSH) == Z_OK)
            }
        }
        let produced = room - Int(stream.pointee.avail_out)
        return Array(output.prefix(produced))
    }
}

/// What a connection told its viewer, kept for the test.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [VNCEvent] = []
    func add(_ event: VNCEvent) { lock.withLock { all.append(event) } }
    var events: [VNCEvent] { lock.withLock { all } }
}

private func until(_ what: String, seconds: Double = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition(), "never: \(what)", file: file, line: line)
}

// MARK: VNC Authentication

final class VNCAuthTests: XCTestCase {
    func testDESMatchesTheTextbookVector() {
        // The worked example every DES text uses.
        let schedule = DES.schedule(key: unhex("133457799bbcdff1"))
        XCTAssertEqual(hex(DES.encrypt(unhex("0123456789abcdef"), schedule: schedule)), "85e813540f0ab405")
    }

    func testThePasswordKeyIsEightBytesEachReversed() {
        XCTAssertEqual(VNCAuth.reverseBits(0x01), 0x80)
        XCTAssertEqual(VNCAuth.reverseBits(0x73), 0xCE)
        XCTAssertEqual(hex(VNCAuth.key(password: "secret")), "cea6c64ea62e0000")
        // Past eight bytes the password is ignored, as every server does.
        XCTAssertEqual(VNCAuth.key(password: "abcdefghijk"), VNCAuth.key(password: "abcdefgh"))
    }

    func testTheResponseIsTheChallengeEncryptedUnderThatKey() {
        // Cross-checked with `openssl enc -des-ecb -K cea6c64ea62e0000`.
        let challenge = (0..<16).map { UInt8($0) }
        XCTAssertEqual(hex(VNCAuth.response(challenge: challenge, password: "secret")), "ee22539f33a5983ec12f9c2edbc995dd")
    }
}

// MARK: The handshake

final class RFBHandshakeTests: XCTestCase {
    private let challenge = (0..<16).map { UInt8($0) }
    private let response = unhex("ee22539f33a5983ec12f9c2edbc995dd")

    private func handshake(_ server: [UInt8], password: String = "secret") async throws -> (RFBServerInit, Wire) {
        let wire = ended(server)
        let reader = RFBReader(wire)
        let result = try await RFBHandshake.run(reader: reader, write: { try await wire.write($0) }, password: password)
        XCTAssertEqual(reader.buffered, 0, "ServerInit is the last of the handshake")
        return (result, wire)
    }

    func testVersion38WithVNCAuthentication() async throws {
        let server = Array("RFB 003.008\n".utf8) + [2, 1, 2] + challenge + u32(0) + serverInit(1920, 1200)
        let (result, wire) = try await handshake(server)
        XCTAssertEqual(result, RFBServerInit(width: 1920, height: 1200, pixelFormat: .bgra, name: "chromium"))
        XCTAssertEqual(wire.writes.map { [UInt8]($0) }, [Array("RFB 003.008\n".utf8), [2], response, [1]],
                       "the version, VNC Authentication over None, the response, shared")
    }

    func testVersion33TheServerChoosesAndAppleStyleVersionsSpeak38() async throws {
        let server = Array("RFB 003.003\n".utf8) + u32(2) + challenge + u32(0) + serverInit(800, 600, name: "")
        let (result, wire) = try await handshake(server)
        XCTAssertEqual(result.width, 800)
        XCTAssertEqual(wire.writes.map { [UInt8]($0) }, [Array("RFB 003.003\n".utf8), response, [1]])

        // 3.3 with None: no SecurityResult follows.
        let none = Array("RFB 003.003\n".utf8) + u32(1) + serverInit(2, 2)
        _ = try await handshake(none)

        let apple = Array("RFB 003.889\n".utf8) + [1, 2] + challenge + u32(0) + serverInit(10, 10)
        let (_, spoke) = try await handshake(apple)
        XCTAssertEqual([UInt8](spoke.writes[0]), Array("RFB 003.008\n".utf8))
    }

    func testRefusalsAndFailuresSayWhy() async throws {
        let refused = Array("RFB 003.008\n".utf8) + [0] + u32(8) + Array("too many".utf8)
        await XCTAssertThrowsAsync(try await handshake(refused)) { XCTAssertEqual($0 as? RFBError, .refused("too many")) }

        let wrong = Array("RFB 003.008\n".utf8) + [1, 2] + challenge + u32(1) + u32(3) + Array("bad".utf8)
        await XCTAssertThrowsAsync(try await handshake(wrong)) { XCTAssertEqual($0 as? RFBError, .authenticationFailed("bad")) }

        let wrong37 = Array("RFB 003.007\n".utf8) + [1, 2] + challenge + u32(1)
        await XCTAssertThrowsAsync(try await handshake(wrong37)) { XCTAssertEqual($0 as? RFBError, .authenticationFailed("")) }

        let tight = Array("RFB 003.008\n".utf8) + [1, 16]
        await XCTAssertThrowsAsync(try await handshake(tight)) { XCTAssertEqual($0 as? RFBError, .noSupportedSecurity([16])) }

        let four = Array("RFB 004.000\n".utf8)
        await XCTAssertThrowsAsync(try await handshake(four)) { XCTAssertEqual($0 as? RFBError, .unsupportedVersion("RFB 004.000")) }

        await XCTAssertThrowsAsync(try await handshake(Array("HTTP/1.1 400".utf8))) {
            XCTAssertEqual($0 as? RFBError, .protocolViolation("banner"))
        }
        // Cut short: the stream ended.
        await XCTAssertThrowsAsync(try await handshake(Array("RFB 003.008\n".utf8) + [1])) { XCTAssertEqual($0 as? RFBError, .closed) }

        let huge = Array("RFB 003.008\n".utf8) + [1, 1] + u32(0) + u16(20000) + u16(10) + RFBPixelFormat.bgra.encoded + u32(0)
        await XCTAssertThrowsAsync(try await handshake(huge)) { XCTAssertEqual($0 as? RFBError, .protocolViolation("size")) }
    }
}

// MARK: Messages

final class RFBMessageTests: XCTestCase {
    func testThePixelFormatIsThirtyTwoBitLittleEndianRedAtSixteen() {
        XCTAssertEqual([UInt8](RFBMessage.setPixelFormat(.bgra)),
                       [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        XCTAssertEqual(RFBPixelFormat.decode(RFBPixelFormat.bgra.encoded), .bgra)
    }

    func testEncodingsAreSignedAndZRLEComesFirst() {
        XCTAssertEqual([UInt8](RFBMessage.setEncodings([16, -223])), [2, 0, 0, 2, 0, 0, 0, 16, 0xFF, 0xFF, 0xFF, 0x21])
        XCTAssertEqual(RFBEncoding.offered.first, RFBEncoding.zrle)
        XCTAssertTrue(RFBEncoding.offered.contains(RFBEncoding.desktopSize))
    }

    func testUpdateRequestKeyAndPointer() {
        XCTAssertEqual([UInt8](RFBMessage.framebufferUpdateRequest(incremental: true, x: 1, y: 2, width: 300, height: 4)),
                       [3, 1, 0, 1, 0, 2, 1, 44, 0, 4])
        XCTAssertEqual([UInt8](RFBMessage.framebufferUpdateRequest(incremental: false, width: 70000, height: -1)),
                       [3, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0], "clamped to 16 bits")
        XCTAssertEqual([UInt8](RFBMessage.key(VNCKeys.escape, down: true)), [4, 1, 0, 0, 0, 0, 0xFF, 0x1B])
        XCTAssertEqual([UInt8](RFBMessage.key(0x61, down: false)), [4, 0, 0, 0, 0, 0, 0, 0x61])
        XCTAssertEqual([UInt8](RFBMessage.pointer(VNCPointerEvent(buttons: 4, x: 258, y: 3))), [5, 4, 1, 2, 0, 3])
    }

    func testCutTextIsLatin1() {
        XCTAssertEqual([UInt8](RFBMessage.cutText("hé")), [6, 0, 0, 0, 0, 0, 0, 2, 0x68, 0xE9])
        XCTAssertEqual([UInt8](RFBMessage.cutText("a€")), [6, 0, 0, 0, 0, 0, 0, 2, 0x61, 0x3F])
        XCTAssertNil(RFBMessage.latin1("€"))
        XCTAssertEqual(RFBMessage.latin1("a\r\nb"), [0x61, 0x0A, 0x62])
    }
}

// MARK: Decoding

final class VNCDecoderTests: XCTestCase {
    private func decode(_ rects: [(VNCRect, Int32)], _ bytes: [UInt8], into framebuffer: inout VNCFramebuffer) async throws {
        let reader = RFBReader(ended(bytes))
        let decoder = VNCDecoder()
        for (rect, encoding) in rects { try await decoder.decode(encoding, rect: rect, from: reader, into: &framebuffer) }
        XCTAssertEqual(reader.buffered, 0, "every byte read")
    }

    func testRawLandsWhereItsRectangleSays() async throws {
        var framebuffer = VNCFramebuffer(width: 3, height: 2)
        let pixels = [red, green, blue, grey]
        try await decode([(VNCRect(x: 1, y: 0, width: 2, height: 2), RFBEncoding.raw)], pixels.flatMap(px), into: &framebuffer)
        XCTAssertEqual(framebuffer.pixels, [0xFF00_0000, red, green, 0xFF00_0000, blue, grey])

        // A full-width rectangle goes in one read.
        var wide = VNCFramebuffer(width: 2, height: 2)
        try await decode([(VNCRect(x: 0, y: 1, width: 2, height: 1), RFBEncoding.raw)], [red, blue].flatMap(px), into: &wide)
        XCTAssertEqual(wide.pixels, [0xFF00_0000, 0xFF00_0000, red, blue])
    }

    func testCopyRectCopesWithOverlapEitherWay() async throws {
        var framebuffer = VNCFramebuffer(width: 4, height: 1)
        framebuffer.pixels = [red, green, blue, grey]
        try await decode([(VNCRect(x: 1, y: 0, width: 3, height: 1), RFBEncoding.copyRect)], u16(0) + u16(0), into: &framebuffer)
        XCTAssertEqual(framebuffer.pixels, [red, red, green, blue])

        var column = VNCFramebuffer(width: 1, height: 4)
        column.pixels = [red, green, blue, grey]
        column.copy(VNCRect(x: 0, y: 1, width: 1, height: 3), fromX: 0, fromY: 0)
        XCTAssertEqual(column.pixels, [red, red, green, blue], "moving down: bottom row first")
        column.pixels = [red, green, blue, grey]
        column.copy(VNCRect(x: 0, y: 0, width: 1, height: 3), fromX: 0, fromY: 1)
        XCTAssertEqual(column.pixels, [green, blue, grey, grey], "moving up: top row first")
    }

    func testHextileTilesCarryTheirBackgroundOn() async throws {
        var framebuffer = VNCFramebuffer(width: 18, height: 2)
        // Tile one (16 × 2): background blue, foreground red, one 1×1
        // subrectangle at (1, 0). Tile two (2 × 2): nothing new, so blue.
        let bytes: [UInt8] = [2 | 4 | 8] + px(blue) + px(red) + [1, 0x10, 0x00] + [0]
        try await decode([(VNCRect(x: 0, y: 0, width: 18, height: 2), RFBEncoding.hextile)], bytes, into: &framebuffer)
        XCTAssertEqual(framebuffer[0, 0], blue)
        XCTAssertEqual(framebuffer[1, 0], red)
        XCTAssertEqual(framebuffer[2, 0], blue)
        XCTAssertEqual(framebuffer[1, 1], blue)
        XCTAssertEqual(framebuffer[17, 1], blue)

        // A raw tile, then coloured subrectangles.
        var raw = VNCFramebuffer(width: 2, height: 1)
        try await decode([(VNCRect(x: 0, y: 0, width: 2, height: 1), RFBEncoding.hextile)], [1] + px(green) + px(grey), into: &raw)
        XCTAssertEqual(raw.pixels, [green, grey])
        var coloured = VNCFramebuffer(width: 4, height: 1)
        let subs: [UInt8] = [2 | 8 | 16] + px(grey) + [2] + px(red) + [0x00, 0x00] + px(green) + [0x20, 0x10]
        try await decode([(VNCRect(x: 0, y: 0, width: 4, height: 1), RFBEncoding.hextile)], subs, into: &coloured)
        XCTAssertEqual(coloured.pixels, [red, grey, green, green])

        // A subrectangle past its tile is a broken server.
        var broken = VNCFramebuffer(width: 2, height: 2)
        let past: [UInt8] = [2 | 8] + px(grey) + [1, 0x11, 0x11]
        await XCTAssertThrowsAsync(try await decode([(VNCRect(x: 0, y: 0, width: 2, height: 2), RFBEncoding.hextile)], past, into: &broken)) {
            XCTAssertEqual($0 as? RFBError, .protocolViolation("hextile subrectangle"))
        }
    }

    func testZRLEOneStreamAcrossRectanglesEverySubencoding() async throws {
        var framebuffer = VNCFramebuffer(width: 4, height: 5)
        let deflater = Deflater()
        var bytes: [UInt8] = []
        func zrle(_ data: [UInt8]) {
            let compressed = deflater.compress(data)
            bytes += u32(compressed.count) + compressed
        }
        // Solid (1): rows 0–1 grey.
        zrle([1] + cpixel(grey))
        // Packed palette (2 colours, 1 bit): rows 2–3 alternate.
        zrle([2] + cpixel(red) + cpixel(blue) + [0b1010_0000, 0b0101_0000])
        // Plain RLE (128): row 4's first two red, run 1 + 1.
        zrle([128] + cpixel(red) + [1])
        // Palette RLE (130): row 4's last two, green run 1 then blue once.
        zrle([130] + cpixel(blue) + cpixel(green) + [0x81, 0x00, 0x00])
        // Raw (0): one pixel, at the end.
        zrle([0] + cpixel(green))
        try await decode([
            (VNCRect(x: 0, y: 0, width: 4, height: 2), RFBEncoding.zrle),
            (VNCRect(x: 0, y: 2, width: 4, height: 2), RFBEncoding.zrle),
            (VNCRect(x: 0, y: 4, width: 2, height: 1), RFBEncoding.zrle),
            (VNCRect(x: 2, y: 4, width: 2, height: 1), RFBEncoding.zrle),
            (VNCRect(x: 0, y: 0, width: 1, height: 1), RFBEncoding.zrle),
        ], bytes, into: &framebuffer)
        XCTAssertEqual(framebuffer.pixels, [
            green, grey, grey, grey,
            grey, grey, grey, grey,
            blue, red, blue, red,
            red, blue, red, blue,
            red, red, green, blue,
        ])
    }

    func testZRLEOverrunsAndOutsideRectanglesAreRefused() async throws {
        var framebuffer = VNCFramebuffer(width: 2, height: 1)
        let deflater = Deflater()
        let run = deflater.compress([128] + cpixel(red) + [5])
        await XCTAssertThrowsAsync(try await decode([(VNCRect(x: 0, y: 0, width: 2, height: 1), RFBEncoding.zrle)], u32(run.count) + run, into: &framebuffer)) {
            XCTAssertEqual($0 as? RFBError, .protocolViolation("ZRLE run"))
        }
        await XCTAssertThrowsAsync(try await decode([(VNCRect(x: 1, y: 0, width: 2, height: 1), RFBEncoding.raw)], [], into: &framebuffer)) {
            XCTAssertEqual($0 as? RFBError, .protocolViolation("rectangle outside the desktop"))
        }
        await XCTAssertThrowsAsync(try await decode([(VNCRect(x: 0, y: 0, width: 1, height: 1), 7)], [], into: &framebuffer)) {
            XCTAssertEqual($0 as? RFBError, .unsupportedEncoding(7))
        }
    }
}

// MARK: The connection

final class VNCClientTests: XCTestCase {
    func testFramesClipboardAndInputInOrder() async throws {
        let wire = Wire()
        let client = VNCClient(stream: wire)
        let seen = Events()
        let run = Task { try await client.run(password: "secret") { seen.add($0) } }

        wire.feed(Array("RFB 003.008\n".utf8) + [1, 1] + u32(0) + serverInit(2, 1, name: "desk"))
        try await until("connected") { seen.events.contains { if case .connected(2, 1, "desk") = $0 { true } else { false } } }
        // Set up after the handshake: format, encodings, the whole desktop.
        try await until("asked for the desktop") { wire.writes.count >= 4 }
        XCTAssertEqual(wire.writes[3], RFBMessage.setPixelFormat(.bgra) + RFBMessage.setEncodings(RFBEncoding.offered)
            + RFBMessage.framebufferUpdateRequest(incremental: false, width: 2, height: 1))

        wire.feed([0, 0] + u16(1) + rect(0, 0, 2, 1, RFBEncoding.raw) + px(red) + px(blue))
        try await until("a frame") { seen.events.contains { if case .frame = $0 { true } else { false } } }
        guard case .frame(let frame)? = seen.events.first(where: { if case .frame = $0 { true } else { false } }) else { return XCTFail() }
        XCTAssertEqual(frame.pixels, [red, blue])
        XCTAssertEqual(frame.changed, [VNCRect(x: 0, y: 0, width: 2, height: 1)])
        let incremental = RFBMessage.framebufferUpdateRequest(incremental: true, width: 2, height: 1)
        try await until("the next update asked for") { wire.writes.contains(incremental) }

        wire.feed([3, 0, 0, 0] + u32(3) + [0x68, 0x69, 0xE9])
        try await until("the clipboard") { seen.events.contains { if case .clipboard("hié") = $0 { true } else { false } } }

        client.pointer([VNCPointerEvent(buttons: 1, x: 1, y: 0), VNCPointerEvent(buttons: 0, x: 1, y: 0)])
        client.tap(0x76, modifiers: [VNCKeys.control])
        let input = RFBMessage.pointer(VNCPointerEvent(buttons: 1, x: 1, y: 0)) + RFBMessage.pointer(VNCPointerEvent(buttons: 0, x: 1, y: 0))
        let paste = RFBMessage.key(VNCKeys.control, down: true) + RFBMessage.key(0x76, down: true)
            + RFBMessage.key(0x76, down: false) + RFBMessage.key(VNCKeys.control, down: false)
        try await until("the input") { wire.writes.suffix(2) == [input, paste] }

        // A DesktopSize rectangle resizes, and asks for all of it again.
        wire.feed([0, 0] + u16(2) + rect(0, 0, 3, 2, RFBEncoding.desktopSize) + rect(0, 0, 0, 0, RFBEncoding.lastRect))
        try await until("resized") { seen.events.contains { if case .connected(3, 2, _) = $0 { true } else { false } } }
        try await until("the whole new desktop asked for") {
            wire.writes.contains(RFBMessage.framebufferUpdateRequest(incremental: false, width: 3, height: 2))
        }

        wire.end()
        do { try await run.value; XCTFail("ran past the end") } catch { XCTAssertEqual(error as? RFBError, .closed) }
    }

    func testTypingSendsKeyStrokes() async throws {
        let wire = Wire()
        let client = VNCClient(stream: wire)
        let run = Task { try await client.run(password: "") { _ in } }
        wire.feed(Array("RFB 003.008\n".utf8) + [1, 1] + u32(0) + serverInit(2, 1))
        try await until("set up") { wire.writes.count >= 4 }
        client.type("a\n")
        let typed = RFBMessage.key(0x61, down: true) + RFBMessage.key(0x61, down: false)
            + RFBMessage.key(VNCKeys.returnKey, down: true) + RFBMessage.key(VNCKeys.returnKey, down: false)
        try await until("typed") { wire.writes.last == typed }
        await client.close()
        do { try await run.value; XCTFail("ran past close") } catch {}
    }
}

// MARK: Pointer and keys

final class VNCPointerTests: XCTestCase {
    private func e(_ buttons: UInt8, _ x: UInt16, _ y: UInt16) -> VNCPointerEvent { VNCPointerEvent(buttons: buttons, x: x, y: y) }

    func testClicksMoveThenPressAndRelease() {
        var pointer = VNCPointer(width: 100, height: 50)
        XCTAssertEqual(pointer.click(.left, at: (10.7, 20.2)), [e(0, 10, 20), e(1, 10, 20), e(0, 10, 20)])
        XCTAssertEqual(pointer.click(.right), [e(4, 10, 20), e(0, 10, 20)], "right click where the pointer is")
    }

    func testPointsAreKeptOnTheDesktop() {
        var pointer = VNCPointer(width: 100, height: 50)
        XCTAssertEqual(pointer.move(to: (-5, 999)), [e(0, 0, 49)])
        XCTAssertEqual(pointer.move(by: (500, -500)), [e(0, 99, 0)])
        pointer.resize(width: 40, height: 40)
        XCTAssertEqual(pointer.move(by: (0, 0)), [e(0, 39, 0)])
    }

    func testADragHoldsItsButtonAndReleaseAllLetsGo() {
        var pointer = VNCPointer(width: 100, height: 100)
        XCTAssertEqual(pointer.press(.left, at: (5, 5)), [e(1, 5, 5)])
        XCTAssertEqual(pointer.move(to: (30, 40)), [e(1, 30, 40)])
        XCTAssertEqual(pointer.releaseAll(), [e(0, 30, 40)])
        XCTAssertEqual(pointer.releaseAll(), [])
    }

    func testScrollGoesInWholeNotchesAndKeepsTheRest() {
        var pointer = VNCPointer(width: 200, height: 200)
        _ = pointer.move(to: (10, 20))
        XCTAssertEqual(pointer.scroll(by: (0, 120), at: (10, 20)), [e(16, 10, 20), e(0, 10, 20), e(16, 10, 20), e(0, 10, 20)])
        XCTAssertEqual(pointer.pendingY, 120 - 2 * VNCPointer.notch, accuracy: 1e-9)
        XCTAssertEqual(pointer.scroll(by: (0, -70)), [e(8, 10, 20), e(0, 10, 20)])
        XCTAssertEqual(pointer.pendingY, 14 - 70 + VNCPointer.notch, accuracy: 1e-9)
        XCTAssertEqual(pointer.scroll(by: (60, -60)).map(\.buttons), [8, 0, 64, 0], "vertical then horizontal")
        pointer.resetScroll()
        XCTAssertEqual(pointer.pendingX, 0)
        // Somewhere else: the pointer goes there first.
        XCTAssertEqual(pointer.scroll(by: (0, 0), at: (50, 60)), [e(0, 50, 60)])
        // A fling never floods: forty notches at most a call.
        XCTAssertEqual(pointer.scroll(by: (0, 100 * VNCPointer.notch)).count, 80)
        XCTAssertEqual(pointer.pendingY, 60 * VNCPointer.notch, accuracy: 1e-6)
    }

    func testMomentumDecaysLikeAScrollViewAndStops() {
        XCTAssertNil(VNCScrollMomentum(velocity: (0, 10)), "too slow to glide")
        var momentum = VNCScrollMomentum(velocity: (0, 1000))!
        let first = momentum.step(1.0 / 60)!
        XCTAssertEqual(first.x, 0)
        XCTAssertGreaterThan(first.y, 16)
        XCTAssertLessThan(first.y, 1000.0 / 60)
        var total = first.y
        var frames = 1
        while let moved = momentum.step(1.0 / 60) { total += moved.y; frames += 1 }
        // All of v / ln(1/decay) but the tail below the stop speed.
        XCTAssertEqual(total, 1000 / (-1000 * log(VNCScrollMomentum.decay)) - 20 / (-1000 * log(VNCScrollMomentum.decay)), accuracy: 2)
        XCTAssertLessThan(frames, 200)
        XCTAssertNil(momentum.step(1.0 / 60))
    }

    func testKeysymsAndStrokes() {
        XCTAssertEqual(VNCKeys.keysym(for: "a"), 0x61)
        XCTAssertEqual(VNCKeys.keysym(for: "\n"), VNCKeys.returnKey)
        XCTAssertEqual(VNCKeys.keysym(for: "é"), 0xE9)
        XCTAssertEqual(VNCKeys.keysym(for: "€"), 0x0100_20AC)
        let strokes = VNCKeys.strokes(for: "a\r\nb\u{1}")
        XCTAssertEqual(strokes.map(\.keysym), [0x61, 0x61, VNCKeys.returnKey, VNCKeys.returnKey, 0x62, 0x62])
        XCTAssertEqual(strokes.map(\.down), [true, false, true, false, true, false])
    }
}

// MARK: Where it connects

final class LiveBrowserVNCTargetTests: XCTestCase {
    private let id = "3f9a1c0e5b7d42e8a6c1f09b2d4e7a35"

    private func target(_ text: String) -> LiveBrowserVNCTarget? { URL(string: text).flatMap(LiveBrowserVNCTarget.init(novncURL:)) }

    func testTakesTheBridgesNoVNCPageApart() throws {
        let page = "http://192.168.2.72:6090/live/\(id)/vnc/vnc.html?autoconnect=1&resize=scale&path=live/\(id)/vnc/websockify#password=s3cr%2Bt"
        let target = try XCTUnwrap(target(page))
        XCTAssertEqual(target.authority.text, "192.168.2.72:6090")
        XCTAssertEqual(target.path, "/live/\(id)/vnc/websockify")
        XCTAssertEqual(target.password, "s3cr+t")
        XCTAssertEqual(self.target("http://localhost:6090/live/\(id)/vnc/vnc.html#a=b&password=p+q")?.password, "p+q", "as noVNC decodes it")
        XCTAssertFalse(target.description.contains("s3cr"))
        XCTAssertFalse(target.description.contains(id))
    }

    func testAnythingElseIsNoTarget() {
        let path = "/live/\(id)/vnc/vnc.html#password=p"
        XCTAssertNil(target("http://evil.example:6090\(path)"), "not a bridge")
        XCTAssertNil(target("https://192.168.2.72:6090\(path)"))
        XCTAssertNil(target("http://192.168.2.72:6091\(path)"))
        XCTAssertNil(target("http://192.168.2.72:6090/live/\(id)/vnc/vnc.html"), "no password")
        XCTAssertNil(target("http://192.168.2.72:6090/live/\(id)/vnc/vnc.html#password="))
        XCTAssertNil(target("http://192.168.2.72:6090/live/\(id)/vnc/other.html#password=p"))
        XCTAssertNil(target("http://192.168.2.72:6090/live/NOTANID/vnc/vnc.html#password=p"))
        XCTAssertNil(target("http://192.168.2.72:6090/live/\(id)/vnc/vnc.html/x#password=p"))
    }
}
