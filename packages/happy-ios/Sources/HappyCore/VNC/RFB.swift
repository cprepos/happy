import Foundation

/// Why an RFB (VNC) connection failed.
public enum RFBError: Error, Equatable, Sendable {
    /// The stream ended.
    case closed
    /// Bytes that aren't RFB, or an RFB the client never asked for.
    case protocolViolation(String)
    /// Not RFB 3.x.
    case unsupportedVersion(String)
    /// The server offers none of None and VNC Authentication.
    case noSupportedSecurity([UInt8])
    /// The server refused the connection before authentication, with why.
    case refused(String)
    /// The password was wrong (or the server said no after it).
    case authenticationFailed(String)
    /// A rectangle in an encoding the client never offered.
    case unsupportedEncoding(Int32)
}

/// Buffered big-endian reads over a byte stream: RFB's integers, and
/// exactly-n-bytes reads. One reader per connection, read from one task.
public final class RFBReader {
    private let stream: any BrowserStream
    private var buffer: [UInt8] = []
    private var offset = 0

    public init(_ stream: any BrowserStream) { self.stream = stream }

    /// Makes sure `count` bytes are buffered.
    private func need(_ count: Int) async throws {
        while buffer.count - offset < count {
            if offset > 0, offset >= buffer.count / 2 {
                buffer.removeFirst(offset)
                offset = 0
            }
            let more = try await stream.read(maximumBytes: max(65536, count - (buffer.count - offset)))
            if more.isEmpty { throw RFBError.closed }
            buffer.append(contentsOf: more)
        }
    }

    public func u8() async throws -> UInt8 {
        try await need(1)
        defer { offset += 1 }
        return buffer[offset]
    }

    public func u16() async throws -> UInt16 {
        try await need(2)
        defer { offset += 2 }
        return UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1])
    }

    public func u32() async throws -> UInt32 {
        try await need(4)
        defer { offset += 4 }
        return UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16 | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])
    }

    public func s32() async throws -> Int32 { Int32(bitPattern: try await u32()) }

    public func bytes(_ count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        try await need(count)
        defer { offset += count }
        return Array(buffer[offset..<offset + count])
    }

    public func skip(_ count: Int) async throws {
        var left = count
        while left > 0 {
            let chunk = min(left, 1 << 20)
            try await need(chunk)
            offset += chunk
            left -= chunk
        }
    }

    /// `count` little-endian 32-bit pixels, straight into `pixels`.
    func pixels(_ count: Int, into pixels: inout [UInt32], at start: Int) async throws {
        var done = 0
        while done < count {
            let chunk = min(count - done, 65536)
            try await need(chunk * 4)
            buffer.withUnsafeBufferPointer { source in
                pixels.withUnsafeMutableBufferPointer { target in
                    var at = offset
                    for index in 0..<chunk {
                        target[start + done + index] = RFBPixelFormat.pixel(source[at], source[at + 1], source[at + 2])
                        at += 4
                    }
                }
            }
            offset += chunk * 4
            done += chunk
        }
    }

    /// The bytes left buffered (tests).
    var buffered: Int { buffer.count - offset }
}

/// The one pixel format the viewer asks for: 32 bits, depth 24, little
/// endian, true colour, red at bit 16, green 8, blue 0. On the wire a pixel
/// is B, G, R, unused; in `VNCFramebuffer` it is `0xFFRRGGBB`, which is
/// BGRA in memory on every Apple device: a `CGImage` with
/// `byteOrder32Little | noneSkipFirst` takes it as it is.
public struct RFBPixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColour: Bool
    public var redMax: UInt16, greenMax: UInt16, blueMax: UInt16
    public var redShift: UInt8, greenShift: UInt8, blueShift: UInt8

    public static let bgra = RFBPixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColour: true,
                                            redMax: 255, greenMax: 255, blueMax: 255, redShift: 16, greenShift: 8, blueShift: 0)

    public init(bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool, trueColour: Bool, redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
                redShift: UInt8, greenShift: UInt8, blueShift: UInt8) {
        self.bitsPerPixel = bitsPerPixel; self.depth = depth; self.bigEndian = bigEndian; self.trueColour = trueColour
        self.redMax = redMax; self.greenMax = greenMax; self.blueMax = blueMax
        self.redShift = redShift; self.greenShift = greenShift; self.blueShift = blueShift
    }

    /// The 16 bytes of a PIXEL_FORMAT.
    public var encoded: [UInt8] {
        [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColour ? 1 : 0]
            + RFBMessage.u16(redMax) + RFBMessage.u16(greenMax) + RFBMessage.u16(blueMax)
            + [redShift, greenShift, blueShift, 0, 0, 0]
    }

    public static func decode(_ bytes: [UInt8]) -> RFBPixelFormat {
        RFBPixelFormat(bitsPerPixel: bytes[0], depth: bytes[1], bigEndian: bytes[2] != 0, trueColour: bytes[3] != 0,
                       redMax: UInt16(bytes[4]) << 8 | UInt16(bytes[5]), greenMax: UInt16(bytes[6]) << 8 | UInt16(bytes[7]),
                       blueMax: UInt16(bytes[8]) << 8 | UInt16(bytes[9]), redShift: bytes[10], greenShift: bytes[11], blueShift: bytes[12])
    }

    /// A framebuffer pixel from a wire pixel's first three bytes.
    @inline(__always) static func pixel(_ blue: UInt8, _ green: UInt8, _ red: UInt8) -> UInt32 {
        0xFF00_0000 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }
}

/// The encodings the viewer offers, best first.
public enum RFBEncoding {
    public static let raw: Int32 = 0
    public static let copyRect: Int32 = 1
    public static let hextile: Int32 = 5
    public static let zrle: Int32 = 16
    /// Pseudo: the desktop changed size.
    public static let desktopSize: Int32 = -223
    /// Pseudo: no more rectangles in this update.
    public static let lastRect: Int32 = -224

    public static let offered: [Int32] = [zrle, hextile, copyRect, raw, desktopSize, lastRect]
}

/// What the server said about itself once the handshake was through.
public struct RFBServerInit: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelFormat: RFBPixelFormat
    public var name: String
}

/// Client-to-server messages, as bytes.
public enum RFBMessage {
    static func u16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    static func u32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    static func clamp16(_ value: Int) -> UInt16 { UInt16(max(0, min(Int(UInt16.max), value))) }

    public static func setPixelFormat(_ format: RFBPixelFormat) -> Data {
        Data([0, 0, 0, 0] + format.encoded)
    }

    public static func setEncodings(_ encodings: [Int32]) -> Data {
        Data([2, 0] + u16(UInt16(encodings.count)) + encodings.flatMap { u32(UInt32(bitPattern: $0)) })
    }

    public static func framebufferUpdateRequest(incremental: Bool, x: Int = 0, y: Int = 0, width: Int, height: Int) -> Data {
        Data([3, incremental ? 1 : 0] + u16(clamp16(x)) + u16(clamp16(y)) + u16(clamp16(width)) + u16(clamp16(height)))
    }

    public static func key(_ keysym: UInt32, down: Bool) -> Data {
        Data([4, down ? 1 : 0, 0, 0] + u32(keysym))
    }

    public static func pointer(_ event: VNCPointerEvent) -> Data {
        Data([5, event.buttons] + u16(event.x) + u16(event.y))
    }

    /// ClientCutText: Latin-1 by the protocol; what Latin-1 can't hold is
    /// sent as `?` (the viewer types such text as keys instead).
    public static func cutText(_ text: String) -> Data {
        let bytes = latin1(text) ?? text.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : 0x3F }
        return Data([6, 0, 0, 0] + u32(UInt32(bytes.count)) + bytes)
    }

    /// `text` in Latin-1, nil when it holds a character Latin-1 doesn't.
    /// Line ends go as `\n`.
    public static func latin1(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            guard scalar.value < 256 else { return nil }
            bytes.append(UInt8(scalar.value))
        }
        return bytes
    }
}

/// The RFB handshake, as a client: version, security, ClientInit,
/// ServerInit. Speaks 3.8, and 3.7 or 3.3 to a server that only knows
/// those. VNC Authentication is preferred; None is accepted only from a
/// server that offers nothing else.
public enum RFBHandshake {
    public static func run(reader: RFBReader, write: (Data) async throws -> Void, password: String) async throws -> RFBServerInit {
        let banner = try await reader.bytes(12)
        guard let text = String(bytes: banner, encoding: .ascii), text.hasPrefix("RFB "), text.hasSuffix("\n"),
              let major = Int(text.dropFirst(4).prefix(3)), let minor = Int(text.dropFirst(8).prefix(3)) else {
            throw RFBError.protocolViolation("banner")
        }
        guard major == 3, minor >= 3 else { throw RFBError.unsupportedVersion(String(text.dropLast())) }
        let version = minor >= 8 ? 8 : minor == 7 ? 7 : 3
        try await write(Data("RFB 003.00\(version)\n".utf8))

        let security: UInt8
        if version == 3 {
            let chosen = try await reader.u32()
            if chosen == 0 { throw RFBError.refused(try await reason(reader)) }
            guard chosen == 1 || chosen == 2 else { throw RFBError.noSupportedSecurity([UInt8(truncatingIfNeeded: chosen)]) }
            security = UInt8(chosen)
        } else {
            let count = try await reader.u8()
            if count == 0 { throw RFBError.refused(try await reason(reader)) }
            let offered = try await reader.bytes(Int(count))
            if offered.contains(2) { security = 2 }
            else if offered.contains(1) { security = 1 }
            else { throw RFBError.noSupportedSecurity(offered) }
            try await write(Data([security]))
        }

        if security == 2 {
            let challenge = try await reader.bytes(16)
            try await write(Data(VNCAuth.response(challenge: challenge, password: password)))
        }
        // 3.8 sends a result for every type; 3.3 and 3.7 only after VNC
        // Authentication.
        if security == 2 || version == 8 {
            let result = try await reader.u32()
            if result != 0 {
                throw RFBError.authenticationFailed(version == 8 ? try await reason(reader) : "")
            }
        }

        // Shared: the agent's own viewer, or another phone, stays connected.
        try await write(Data([1]))
        let width = Int(try await reader.u16())
        let height = Int(try await reader.u16())
        let format = RFBPixelFormat.decode(try await reader.bytes(16))
        let nameLength = Int(try await reader.u32())
        guard nameLength <= 4096 else { throw RFBError.protocolViolation("name") }
        let name = String(decoding: try await reader.bytes(nameLength), as: UTF8.self)
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw RFBError.protocolViolation("size") }
        return RFBServerInit(width: width, height: height, pixelFormat: format, name: name)
    }

    private static func reason(_ reader: RFBReader) async throws -> String {
        let length = Int(try await reader.u32())
        guard length <= 4096 else { throw RFBError.protocolViolation("reason") }
        return String(decoding: try await reader.bytes(length), as: UTF8.self)
    }
}
