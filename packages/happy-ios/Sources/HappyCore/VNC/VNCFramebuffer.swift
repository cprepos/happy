import CZlib
import Foundation

/// A rectangle of the remote desktop, in its pixels.
public struct VNCRect: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// The remote desktop's pixels, `0xFFRRGGBB` each, rows top down
/// (`RFBPixelFormat.bgra`).
public struct VNCFramebuffer: Equatable, Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    public var pixels: [UInt32]

    public init(width: Int, height: Int, fill: UInt32 = 0xFF00_0000) {
        self.width = width; self.height = height
        pixels = [UInt32](repeating: fill, count: width * height)
    }

    public subscript(x: Int, y: Int) -> UInt32 { pixels[y * width + x] }

    /// Whether `rect` lies inside the desktop: a server's rectangle that
    /// doesn't is a broken one, never drawn.
    public func contains(_ rect: VNCRect) -> Bool {
        rect.x >= 0 && rect.y >= 0 && rect.width >= 0 && rect.height >= 0 && rect.x + rect.width <= width && rect.y + rect.height <= height
    }

    public mutating func fill(_ rect: VNCRect, _ colour: UInt32) {
        pixels.withUnsafeMutableBufferPointer { buffer in
            for row in rect.y..<rect.y + rect.height {
                let start = row * width + rect.x
                for index in start..<start + rect.width { buffer[index] = colour }
            }
        }
    }

    /// CopyRect: `rect` takes what was at (`fromX`, `fromY`), overlapping or not.
    public mutating func copy(_ rect: VNCRect, fromX: Int, fromY: Int) {
        guard rect.width > 0, rect.height > 0 else { return }
        let width = self.width
        pixels.withUnsafeMutableBufferPointer { buffer in
            // Rows bottom up when moving down, so a row is read before it's
            // written over; within a row, memmove copes with the overlap.
            let rows = fromY < rect.y ? Array((0..<rect.height).reversed()) : Array(0..<rect.height)
            for row in rows {
                let source = buffer.baseAddress! + (fromY + row) * width + fromX
                let target = buffer.baseAddress! + (rect.y + row) * width + rect.x
                target.update(from: source, count: rect.width)
            }
        }
    }

    /// A new size, black: what DesktopSize asks for.
    public mutating func resize(width: Int, height: Int) {
        self.width = width; self.height = height
        pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
    }
}

/// Decodes rectangles into a framebuffer: one per connection, since ZRLE's
/// zlib stream runs across every rectangle of the connection.
public final class VNCDecoder {
    private let inflater = RFBInflater()

    public init() {}

    /// Reads one rectangle's data in `encoding` and draws it.
    public func decode(_ encoding: Int32, rect: VNCRect, from reader: RFBReader, into framebuffer: inout VNCFramebuffer) async throws {
        guard framebuffer.contains(rect) else { throw RFBError.protocolViolation("rectangle outside the desktop") }
        switch encoding {
        case RFBEncoding.raw: try await raw(rect, reader, &framebuffer)
        case RFBEncoding.copyRect:
            let fromX = Int(try await reader.u16()), fromY = Int(try await reader.u16())
            guard framebuffer.contains(VNCRect(x: fromX, y: fromY, width: rect.width, height: rect.height)) else {
                throw RFBError.protocolViolation("copy from outside the desktop")
            }
            framebuffer.copy(rect, fromX: fromX, fromY: fromY)
        case RFBEncoding.hextile: try await hextile(rect, reader, &framebuffer)
        case RFBEncoding.zrle:
            let length = Int(try await reader.u32())
            guard length <= 64 << 20 else { throw RFBError.protocolViolation("ZRLE length") }
            let compressed = try await reader.bytes(length)
            let data = try inflater.decompress(compressed)
            var cursor = ByteCursor(data)
            try VNCDecoder.zrle(rect, &cursor, &framebuffer)
        default: throw RFBError.unsupportedEncoding(encoding)
        }
    }

    private func raw(_ rect: VNCRect, _ reader: RFBReader, _ framebuffer: inout VNCFramebuffer) async throws {
        guard rect.width > 0 else { return }
        if rect.x == 0, rect.width == framebuffer.width {
            try await reader.pixels(rect.width * rect.height, into: &framebuffer.pixels, at: rect.y * framebuffer.width)
            return
        }
        for row in rect.y..<rect.y + rect.height {
            try await reader.pixels(rect.width, into: &framebuffer.pixels, at: row * framebuffer.width + rect.x)
        }
    }

    private static func pixel(_ reader: RFBReader) async throws -> UInt32 {
        let bytes = try await reader.bytes(4)
        return RFBPixelFormat.pixel(bytes[0], bytes[1], bytes[2])
    }

    /// Hextile: 16×16 tiles, left to right, top down. Background and
    /// foreground carry over from tile to tile within the rectangle.
    private func hextile(_ rect: VNCRect, _ reader: RFBReader, _ framebuffer: inout VNCFramebuffer) async throws {
        var background: UInt32 = 0xFF00_0000
        var foreground: UInt32 = 0xFFFF_FFFF
        var tileY = rect.y
        while tileY < rect.y + rect.height {
            let tileHeight = min(16, rect.y + rect.height - tileY)
            var tileX = rect.x
            while tileX < rect.x + rect.width {
                let tileWidth = min(16, rect.x + rect.width - tileX)
                let tile = VNCRect(x: tileX, y: tileY, width: tileWidth, height: tileHeight)
                let mask = try await reader.u8()
                if mask & 1 != 0 {
                    try await raw(tile, reader, &framebuffer)
                } else {
                    if mask & 2 != 0 { background = try await Self.pixel(reader) }
                    framebuffer.fill(tile, background)
                    if mask & 4 != 0 { foreground = try await Self.pixel(reader) }
                    if mask & 8 != 0 {
                        let count = Int(try await reader.u8())
                        let coloured = mask & 16 != 0
                        for _ in 0..<count {
                            let colour = coloured ? try await Self.pixel(reader) : foreground
                            let xy = try await reader.u8(), wh = try await reader.u8()
                            let sub = VNCRect(x: tileX + Int(xy >> 4), y: tileY + Int(xy & 0xF), width: Int(wh >> 4) + 1, height: Int(wh & 0xF) + 1)
                            guard sub.x + sub.width <= tileX + tileWidth, sub.y + sub.height <= tileY + tileHeight else {
                                throw RFBError.protocolViolation("hextile subrectangle")
                            }
                            framebuffer.fill(sub, colour)
                        }
                    }
                }
                tileX += 16
            }
            tileY += 16
        }
    }

    /// ZRLE's decompressed data: 64×64 tiles, each run-length or palette
    /// coded, pixels as CPIXELs of three bytes (B, G, R) for this format.
    static func zrle(_ rect: VNCRect, _ data: inout ByteCursor, _ framebuffer: inout VNCFramebuffer) throws {
        var tileY = rect.y
        var palette = [UInt32](repeating: 0, count: 128)
        while tileY < rect.y + rect.height {
            let tileHeight = min(64, rect.y + rect.height - tileY)
            var tileX = rect.x
            while tileX < rect.x + rect.width {
                let tileWidth = min(64, rect.x + rect.width - tileX)
                let tile = VNCRect(x: tileX, y: tileY, width: tileWidth, height: tileHeight)
                let sub = try data.u8()
                switch sub {
                case 0:
                    for row in 0..<tileHeight {
                        let start = (tileY + row) * framebuffer.width + tileX
                        for column in 0..<tileWidth { framebuffer.pixels[start + column] = try data.cpixel() }
                    }
                case 1:
                    framebuffer.fill(tile, try data.cpixel())
                case 2...16:
                    let size = Int(sub)
                    for index in 0..<size { palette[index] = try data.cpixel() }
                    let bits = size == 2 ? 1 : size <= 4 ? 2 : 4
                    let perByte = 8 / bits
                    let mask = UInt8((1 << bits) - 1)
                    for row in 0..<tileHeight {
                        let start = (tileY + row) * framebuffer.width + tileX
                        var byte: UInt8 = 0
                        for column in 0..<tileWidth {
                            if column % perByte == 0 { byte = try data.u8() }
                            let shift = 8 - bits * (column % perByte + 1)
                            let index = Int(byte >> UInt8(shift) & mask)
                            guard index < size else { throw RFBError.protocolViolation("ZRLE palette index") }
                            framebuffer.pixels[start + column] = palette[index]
                        }
                    }
                case 128:
                    var filled = 0
                    let total = tileWidth * tileHeight
                    while filled < total {
                        let colour = try data.cpixel()
                        let run = try data.runLength()
                        guard filled + run <= total else { throw RFBError.protocolViolation("ZRLE run") }
                        framebuffer.put(colour, run: run, from: filled, in: tile)
                        filled += run
                    }
                case 130...255:
                    let size = Int(sub) - 128
                    for index in 0..<size { palette[index] = try data.cpixel() }
                    var filled = 0
                    let total = tileWidth * tileHeight
                    while filled < total {
                        let byte = try data.u8()
                        let index = Int(byte & 0x7F)
                        guard index < size else { throw RFBError.protocolViolation("ZRLE palette index") }
                        let run = byte & 0x80 != 0 ? try data.runLength() : 1
                        guard filled + run <= total else { throw RFBError.protocolViolation("ZRLE run") }
                        framebuffer.put(palette[index], run: run, from: filled, in: tile)
                        filled += run
                    }
                default:
                    throw RFBError.protocolViolation("ZRLE subencoding \(sub)")
                }
                tileX += 64
            }
            tileY += 64
        }
    }
}

extension VNCFramebuffer {
    /// `run` pixels of `colour` from the `from`-th of `tile`, row by row.
    mutating func put(_ colour: UInt32, run: Int, from: Int, in tile: VNCRect) {
        var left = run, at = from
        while left > 0 {
            let row = at / tile.width, column = at % tile.width
            let count = min(left, tile.width - column)
            let start = (tile.y + row) * width + tile.x + column
            pixels.withUnsafeMutableBufferPointer { buffer in
                for index in start..<start + count { buffer[index] = colour }
            }
            left -= count; at += count
        }
    }
}

/// Reads over decompressed ZRLE data.
struct ByteCursor {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw RFBError.protocolViolation("ZRLE data ended") }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// A CPIXEL: B, G, R.
    mutating func cpixel() throws -> UInt32 {
        guard offset + 3 <= bytes.count else { throw RFBError.protocolViolation("ZRLE data ended") }
        defer { offset += 3 }
        return RFBPixelFormat.pixel(bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    /// One plus the sum of bytes up to and including the first that isn't 255.
    mutating func runLength() throws -> Int {
        var length = 1
        while true {
            let byte = try u8()
            length += Int(byte)
            if byte != 255 { return length }
            guard length < 1 << 24 else { throw RFBError.protocolViolation("ZRLE run") }
        }
    }
}

/// One zlib stream for the life of a connection, as ZRLE uses it: each
/// rectangle's bytes continue it, flushed so each inflates whole.
final class RFBInflater {
    private let stream: UnsafeMutablePointer<z_stream>
    private var ready = false

    init() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
    }

    deinit {
        if ready { inflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    func decompress(_ input: [UInt8]) throws -> [UInt8] {
        if !ready {
            guard czlib_inflate_init(stream) == Z_OK else { throw RFBError.protocolViolation("zlib init") }
            ready = true
        }
        guard !input.isEmpty else { return [] }
        var output: [UInt8] = []
        var source = input
        var chunk = [UInt8](repeating: 0, count: 65536)
        try source.withUnsafeMutableBufferPointer { sourceBuffer in
            stream.pointee.next_in = sourceBuffer.baseAddress
            stream.pointee.avail_in = uInt(sourceBuffer.count)
            defer { stream.pointee.next_in = nil; stream.pointee.avail_in = 0 }
            while true {
                let produced: Int = try chunk.withUnsafeMutableBufferPointer { chunkBuffer in
                    stream.pointee.next_out = chunkBuffer.baseAddress
                    stream.pointee.avail_out = uInt(chunkBuffer.count)
                    let status = inflate(stream, Z_SYNC_FLUSH)
                    let produced = chunkBuffer.count - Int(stream.pointee.avail_out)
                    stream.pointee.next_out = nil
                    switch status {
                    case Z_OK, Z_STREAM_END: return produced
                    case Z_BUF_ERROR: return produced
                    default: throw RFBError.protocolViolation("zlib \(status)")
                    }
                }
                output.append(contentsOf: chunk[0..<produced])
                guard output.count <= 64 << 20 else { throw RFBError.protocolViolation("ZRLE too large") }
                // Done once the input is used up and the last call had
                // room to spare; no progress at all is done too.
                if stream.pointee.avail_in == 0 && produced < chunk.count { break }
                if produced == 0 && stream.pointee.avail_in > 0 { throw RFBError.protocolViolation("zlib stalled") }
            }
        }
        return output
    }
}
