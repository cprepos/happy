import Foundation

/// X keysyms, the keys RFB's KeyEvent names.
public enum VNCKeys {
    public static let backSpace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let returnKey: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let delete: UInt32 = 0xFFFF
    public static let shift: UInt32 = 0xFFE1
    public static let control: UInt32 = 0xFFE3
    public static let alt: UInt32 = 0xFFE9
    /// Super (the Windows key). The remote browser runs on Linux, where
    /// ⌘'s shortcuts are Ctrl's: the viewer sends `control` for ⌘.
    public static let superKey: UInt32 = 0xFFEB
    public static let f1: UInt32 = 0xFFBE

    /// The keysym that types `scalar`: Latin-1 as itself, a line end as
    /// Return, a tab as Tab, anything else as a Unicode keysym.
    public static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x0A, 0x0D: returnKey
        case 0x09: tab
        case 0x08, 0x7F: backSpace
        case 0x1B: escape
        case 0x20...0x7E, 0xA0...0xFF: scalar.value
        default: 0x0100_0000 | scalar.value
        }
    }

    /// Down then up for every character of `text`: typed rather than
    /// pasted. `\r\n` is one Return.
    public static func strokes(for text: String) -> [(keysym: UInt32, down: Bool)] {
        text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.flatMap { scalar -> [(keysym: UInt32, down: Bool)] in
            // Controls with no key of their own are dropped.
            if scalar.value < 0x20, ![0x09, 0x0A, 0x0D, 0x08, 0x1B].contains(scalar.value) { return [] }
            let sym = Self.keysym(for: scalar)
            return [(sym, true), (sym, false)]
        }
    }
}

/// One RFB PointerEvent: buttons held (bit 0 left, 1 middle, 2 right,
/// 3/4 wheel up/down, 5/6 wheel left/right) and where, in desktop pixels.
public struct VNCPointerEvent: Equatable, Sendable {
    public var buttons: UInt8
    public var x: UInt16
    public var y: UInt16

    public init(buttons: UInt8, x: UInt16, y: UInt16) { self.buttons = buttons; self.x = x; self.y = y }
}

public enum VNCButton: UInt8, Sendable {
    case left = 1, middle = 2, right = 4
}

/// The pointer, from gestures to PointerEvents: where it is, which
/// buttons are down, and the scroll not yet a wheel notch. Points are in
/// desktop pixels; the view converts touches first (`VNCViewport`).
public struct VNCPointer: Equatable, Sendable {
    /// Desktop pixels of scroll per wheel notch: about what Chromium on X11
    /// moves a page for one, so a page follows the fingers.
    public static let notch: Double = 53

    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var x: Int
    public private(set) var y: Int
    public private(set) var buttons: UInt8 = 0
    /// Scroll owed, in desktop pixels; positive is down and right.
    public private(set) var pendingX: Double = 0
    public private(set) var pendingY: Double = 0

    public init(width: Int, height: Int) {
        self.width = max(1, width); self.height = max(1, height)
        x = self.width / 2; y = self.height / 2
    }

    public mutating func resize(width: Int, height: Int) {
        self.width = max(1, width); self.height = max(1, height)
        x = min(x, self.width - 1); y = min(y, self.height - 1)
    }

    private var event: VNCPointerEvent { VNCPointerEvent(buttons: buttons, x: UInt16(x), y: UInt16(y)) }

    private mutating func place(_ point: (x: Double, y: Double)) {
        x = Int(max(0, min(Double(width - 1), point.x.rounded(.down))))
        y = Int(max(0, min(Double(height - 1), point.y.rounded(.down))))
    }

    /// The pointer moves there, buttons as they are (a drag while one is down).
    public mutating func move(to point: (x: Double, y: Double)) -> [VNCPointerEvent] {
        place(point)
        return [event]
    }

    /// The trackpad: moves by a delta, kept on the desktop.
    public mutating func move(by delta: (x: Double, y: Double)) -> [VNCPointerEvent] {
        move(to: (Double(x) + delta.x, Double(y) + delta.y))
    }

    public mutating func press(_ button: VNCButton, at point: (x: Double, y: Double)? = nil) -> [VNCPointerEvent] {
        if let point { place(point) }
        buttons |= button.rawValue
        return [event]
    }

    public mutating func release(_ button: VNCButton) -> [VNCPointerEvent] {
        buttons &= ~button.rawValue
        return [event]
    }

    /// Releases whatever is down: a gesture cancelled mid-drag never
    /// leaves a button held.
    public mutating func releaseAll() -> [VNCPointerEvent] {
        guard buttons != 0 else { return [] }
        buttons = 0
        return [event]
    }

    /// A click: there first, then down and up.
    public mutating func click(_ button: VNCButton = .left, at point: (x: Double, y: Double)? = nil) -> [VNCPointerEvent] {
        var events: [VNCPointerEvent] = []
        if let point { events += move(to: point) }
        events += press(button)
        events += release(button)
        return events
    }

    /// Scrolls by `delta` desktop pixels (positive: down, right, as the
    /// page moves up and left under the fingers), at the pointer. Whole
    /// notches go as wheel buttons pressed and released; the rest waits for
    /// the next call. The wheel turns in the direction the delta goes.
    public mutating func scroll(by delta: (x: Double, y: Double), at point: (x: Double, y: Double)? = nil) -> [VNCPointerEvent] {
        var events: [VNCPointerEvent] = []
        if let point {
            let before = (x, y)
            place(point)
            if (x, y) != before { events.append(event) }
        }
        pendingX += delta.x
        pendingY += delta.y
        events += notches(&pendingY, negative: 8, positive: 16)
        events += notches(&pendingX, negative: 32, positive: 64)
        return events
    }

    /// Drops scroll owed (a new gesture starts its own count).
    public mutating func resetScroll() { pendingX = 0; pendingY = 0 }

    private func notches(_ pending: inout Double, negative: UInt8, positive: UInt8) -> [VNCPointerEvent] {
        var events: [VNCPointerEvent] = []
        // At most a screenful of notches at once: a fling never floods.
        var count = 0
        while abs(pending) >= Self.notch, count < 40 {
            let bit = pending > 0 ? positive : negative
            events.append(VNCPointerEvent(buttons: buttons | bit, x: UInt16(x), y: UInt16(y)))
            events.append(VNCPointerEvent(buttons: buttons, x: UInt16(x), y: UInt16(y)))
            pending -= pending > 0 ? Self.notch : -Self.notch
            count += 1
        }
        return events
    }
}

/// A two-finger fling's glide after the fingers lift: velocity decays as
/// a scroll view's does, and the glide ends once it is slow.
public struct VNCScrollMomentum: Equatable, Sendable {
    /// Of the velocity, what remains after each millisecond
    /// (`UIScrollView.DecelerationRate.normal`).
    public static let decay = 0.998
    /// Below this many desktop pixels a second it stops.
    public static let stopSpeed = 20.0

    public private(set) var velocityX: Double
    public private(set) var velocityY: Double

    /// Nil when it is too slow to glide at all.
    public init?(velocity: (x: Double, y: Double)) {
        velocityX = velocity.x; velocityY = velocity.y
        guard speed >= Self.stopSpeed else { return nil }
    }

    public var speed: Double { (velocityX * velocityX + velocityY * velocityY).squareRoot() }

    /// The distance glided over the next `seconds`, or nil once it has stopped.
    public mutating func step(_ seconds: Double) -> (x: Double, y: Double)? {
        guard speed >= Self.stopSpeed, seconds > 0 else { return nil }
        // The exact integral of v·decay^(1000t) over the step.
        let k = 1000 * log(Self.decay)
        let factor = pow(Self.decay, 1000 * seconds)
        let distance = (factor - 1) / k
        let moved = (velocityX * distance, velocityY * distance)
        velocityX *= factor; velocityY *= factor
        return moved
    }
}
