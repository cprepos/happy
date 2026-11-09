#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// A drawn desktop, made off the main thread.
struct VNCImage: @unchecked Sendable {
    let image: CGImage

    /// The frame's pixels as an image: `0xFFRRGGBB` words are BGRA bytes,
    /// little-endian 32-bit with the top byte skipped.
    static func make(_ frame: VNCFrame) -> VNCImage? {
        guard frame.width > 0, frame.height > 0, frame.pixels.count == frame.width * frame.height else { return nil }
        let data = frame.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return VNCImage(image: image)
    }
}

/// The remote desktop, drawn and driven by touch:
///
/// - one finger taps a left click, where it taps (or, as a trackpad, where
///   the pointer is);
/// - a long press or a two-finger tap is a right click;
/// - two fingers dragging scroll the page under them, and a fling glides on;
/// - pinching zooms, and one finger pans the zoomed desktop (unzoomed, it
///   drags with the left button down: selecting text, moving a slider);
/// - as a trackpad, one finger moves the pointer instead, and the view
///   follows it.
///
/// It is the keyboard's first responder too (`UIKeyInput`): what's typed
/// goes as keys, and the accessory row has the keys a phone lacks.
@MainActor
final class LiveBrowserVNCView: UIView, UIGestureRecognizerDelegate {
    /// Where input goes: the connection, while there is one.
    var send: (([VNCPointerEvent]) -> Void)?
    /// A key down and up, with modifiers held around it.
    var sendKey: ((_ keysym: UInt32, _ modifiers: [UInt32]) -> Void)?
    var sendText: ((String) -> Void)?
    /// ⌘V on a hardware keyboard: the controller's Paste.
    var onPaste: (() -> Void)?

    private(set) var viewport = VNCViewport(bounds: .zero, content: CGSize(width: 1920, height: 1200))
    private(set) var pointer = VNCPointer(width: 1920, height: 1200)
    private(set) var trackpad = false
    private let imageLayer = CALayer()
    private let cursorLayer = CALayer()

    private let tap = UITapGestureRecognizer()
    private let secondaryTap = UITapGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let longPress = UILongPressGestureRecognizer()
    private let onePan = UIPanGestureRecognizer()
    private let twoPan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let hover = UIHoverGestureRecognizer()

    private enum TwoFingers { case undecided, scroll, zoom }
    private var twoFingers = TwoFingers.undecided
    private var lastPinch: (scale: CGFloat, centre: CGPoint)?
    private var lastTwoPan = CGPoint.zero
    private var lastOnePan = CGPoint.zero
    private var dragging = false
    private var momentum: VNCScrollMomentum?
    private var glide: CADisplayLink?
    private var glideTime: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "live-browser-vnc-screen"
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(imageLayer)
        cursorLayer.contents = Self.cursorImage?.cgImage
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: 18, height: 24)
        cursorLayer.anchorPoint = CGPoint(x: 0.12, y: 0.06)
        cursorLayer.isHidden = true
        layer.addSublayer(cursorLayer)

        tap.addTarget(self, action: #selector(tapped))
        secondaryTap.addTarget(self, action: #selector(rightTapped))
        secondaryTap.buttonMaskRequired = .secondary
        twoFingerTap.addTarget(self, action: #selector(rightTapped))
        twoFingerTap.numberOfTouchesRequired = 2
        longPress.addTarget(self, action: #selector(pressed))
        longPress.minimumPressDuration = 0.5
        onePan.addTarget(self, action: #selector(panned))
        onePan.maximumNumberOfTouches = 1
        twoPan.addTarget(self, action: #selector(twoFingerPanned))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        // A Magic Keyboard's trackpad and a mouse's wheel scroll as two fingers do.
        twoPan.allowedScrollTypesMask = .all
        pinch.addTarget(self, action: #selector(pinched))
        hover.addTarget(self, action: #selector(hovered))
        for gesture in [tap, secondaryTap, twoFingerTap, longPress, onePan, twoPan, pinch, hover] as [UIGestureRecognizer] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static let cursorImage: UIImage? = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        return UIImage(systemName: "cursorarrow", withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal)
    }()

    // MARK: Drawing

    /// The desktop changed size (connected, or resized by the server).
    func desktop(width: Int, height: Int) {
        pointer.resize(width: width, height: height)
        viewport.resize(bounds: bounds.size, content: CGSize(width: width, height: height))
        place()
    }

    func show(_ image: VNCImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image.image
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        viewport.resize(bounds: bounds.size, content: viewport.content)
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = viewport.imageFrame
        // Nearest once a desktop pixel is two points or more: crisp text.
        imageLayer.magnificationFilter = viewport.scale >= 2 ? .nearest : .linear
        cursorLayer.isHidden = !trackpad
        cursorLayer.position = viewport.toView(CGPoint(x: pointer.x, y: pointer.y))
        CATransaction.commit()
    }

    func setTrackpad(_ on: Bool) {
        trackpad = on
        if on { viewport.reveal(CGPoint(x: pointer.x, y: pointer.y)) }
        place()
    }

    func fit() {
        viewport.reset()
        place()
    }

    // MARK: Pointer

    private func emit(_ events: [VNCPointerEvent]) {
        guard !events.isEmpty else { return }
        send?(events)
        if trackpad { place() }
    }

    private func desktopPoint(_ location: CGPoint) -> (x: Double, y: Double) {
        let pixel = viewport.toDesktop(location)
        return (Double(pixel.x), Double(pixel.y))
    }

    /// Where a touch at `location` clicks: there, or at the trackpad's pointer.
    private func target(_ location: CGPoint) -> (x: Double, y: Double)? {
        trackpad ? nil : desktopPoint(location)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        stopGlide()
        emit(pointer.click(.left, at: target(gesture.location(in: self))))
    }

    @objc private func rightTapped(_ gesture: UITapGestureRecognizer) {
        stopGlide()
        emit(pointer.click(.right, at: target(gesture.location(in: self))))
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        stopGlide()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        emit(pointer.click(.right, at: target(gesture.location(in: self))))
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard !trackpad, gesture.state == .began || gesture.state == .changed else { return }
        emit(pointer.move(to: desktopPoint(gesture.location(in: self))))
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            stopGlide()
            lastOnePan = translation
            // Unzoomed, by touch: a drag with the left button down, from
            // where the finger first went down.
            dragging = !trackpad && !viewport.isZoomed
            if dragging {
                let start = CGPoint(x: gesture.location(in: self).x - translation.x, y: gesture.location(in: self).y - translation.y)
                emit(pointer.press(.left, at: desktopPoint(start)))
                emit(pointer.move(to: desktopPoint(gesture.location(in: self))))
            }
        case .changed:
            let delta = CGPoint(x: translation.x - lastOnePan.x, y: translation.y - lastOnePan.y)
            lastOnePan = translation
            if dragging {
                emit(pointer.move(to: desktopPoint(gesture.location(in: self))))
            } else if trackpad {
                let moved = viewport.desktopDistance(delta)
                emit(pointer.move(by: (Double(moved.x), Double(moved.y))))
                viewport.reveal(CGPoint(x: pointer.x, y: pointer.y))
                place()
            } else {
                viewport.pan(by: delta)
                place()
            }
        default:
            if dragging { emit(pointer.release(.left)) }
            dragging = false
        }
    }

    @objc private func twoFingerPanned(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            stopGlide()
            lastTwoPan = translation
            pointer.resetScroll()
        case .changed:
            let delta = CGPoint(x: translation.x - lastTwoPan.x, y: translation.y - lastTwoPan.y)
            lastTwoPan = translation
            if twoFingers == .undecided {
                // A trackpad's or a wheel's scroll has no fingers on the
                // glass, and is a scroll from the start; two fingers are
                // one once they've moved and haven't pinched.
                let indirect = gesture.numberOfTouches == 0
                let moved = hypot(translation.x, translation.y) > 10 && abs((lastPinch?.scale ?? 1) - 1) < 0.08
                if indirect || moved { twoFingers = .scroll }
            }
            guard twoFingers == .scroll else { return }
            // The page follows the fingers: up is a scroll down.
            let moved = viewport.desktopDistance(delta)
            emit(pointer.scroll(by: (-Double(moved.x), -Double(moved.y)), at: target(gesture.location(in: self))))
        case .ended:
            if twoFingers == .scroll {
                let velocity = viewport.desktopDistance(gesture.velocity(in: self))
                startGlide(VNCScrollMomentum(velocity: (-Double(velocity.x), -Double(velocity.y))))
            }
            twoFingersEnded()
        default:
            twoFingersEnded()
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.numberOfTouches >= 2 || gesture.state != .changed else { return }
        let centre = gesture.location(in: self)
        switch gesture.state {
        case .began:
            stopGlide()
            lastPinch = (gesture.scale, centre)
        case .changed:
            guard let last = lastPinch else { lastPinch = (gesture.scale, centre); return }
            if twoFingers == .undecided, abs(gesture.scale - 1) > 0.08 { twoFingers = .zoom }
            guard twoFingers == .zoom else { lastPinch = (last.scale, centre); return }
            viewport.zoom(by: gesture.scale / last.scale, around: centre)
            viewport.pan(by: CGPoint(x: centre.x - last.centre.x, y: centre.y - last.centre.y))
            lastPinch = (gesture.scale, centre)
            place()
        default:
            twoFingersEnded()
        }
    }

    private func twoFingersEnded() {
        guard twoPan.state != .changed, pinch.state != .changed else { return }
        twoFingers = .undecided
        lastPinch = nil
    }

    // MARK: Glide

    private func startGlide(_ momentum: VNCScrollMomentum?) {
        stopGlide()
        guard let momentum else { return }
        self.momentum = momentum
        let link = CADisplayLink(target: GlideTarget(self), selector: #selector(GlideTarget.tick))
        glideTime = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        glide = link
    }

    func stopGlide() {
        glide?.invalidate()
        glide = nil
        momentum = nil
    }

    fileprivate func glideTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let seconds = max(0, now - glideTime)
        glideTime = now
        guard var momentum, let moved = momentum.step(seconds) else { return stopGlide() }
        self.momentum = momentum
        emit(pointer.scroll(by: moved))
    }

    /// The display link keeps its target: this keeps the view weakly.
    /// It runs on the main run loop, so it is the main actor's.
    @MainActor private final class GlideTarget: NSObject {
        weak var view: LiveBrowserVNCView?
        init(_ view: LiveBrowserVNCView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) { view?.glideTick(link) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A finger down stops a glide, as on any scroll view.
        stopGlide()
        super.touchesBegan(touches, with: event)
    }

    // MARK: Gesture rules

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair: Set<ObjectIdentifier> = [ObjectIdentifier(gesture), ObjectIdentifier(other)]
        return pair == [ObjectIdentifier(twoPan), ObjectIdentifier(pinch)] || gesture === hover || other === hover
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The secondary tap is a mouse's; a finger's taps are the others'.
        if gesture === secondaryTap { return touch.type == .indirectPointer }
        return true
    }

    // MARK: Keyboard

    /// Ctrl, Alt or ⌘ tapped on the key row: held for the next key.
    private(set) var armed: [UInt32] = []
    var onArmedChange: (() -> Void)?
    var showsKeyboard = false {
        didSet { if !showsKeyboard, isFirstResponder { resignFirstResponder() } }
    }

    func arm(_ modifier: UInt32) {
        if let index = armed.firstIndex(of: modifier) { armed.remove(at: index) } else { armed.append(modifier) }
        onArmedChange?()
    }

    /// A key from the row or the keyboard, with what's armed held around it.
    func press(_ keysym: UInt32) {
        let modifiers = armed
        if !armed.isEmpty { armed = []; onArmedChange?() }
        sendKey?(keysym, modifiers)
    }

    override var canBecomeFirstResponder: Bool { showsKeyboard }

    /// The key row over the keyboard (`LiveBrowserVNCKeyRow`).
    var keyRow: UIView?
    override var inputAccessoryView: UIView? { keyRow }

    private var hardwareHeld: [UIKeyboardHIDUsage: (keysym: UInt32, modifiers: [UInt32])] = [:]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let mapped = Self.keysym(key) else { unhandled.insert(press); continue }
            if key.modifierFlags.contains(.command), key.charactersIgnoringModifiers.lowercased() == "v" { onPaste?(); continue }
            let modifiers = Self.modifiers(key.modifierFlags, printable: mapped.printable)
            sendKey?(mapped.keysym, modifiers)
            hardwareHeld[key.keyCode] = (mapped.keysym, modifiers)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, Self.keysym(key) != nil else { unhandled.insert(press); continue }
            hardwareHeld[key.keyCode] = nil
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { hardwareHeld[key.keyCode] = nil } }
        super.pressesCancelled(presses, with: event)
    }

    /// A hardware key's keysym: the keys with names by their HID usage,
    /// else the character it types. Modifiers alone go with the next key.
    static func keysym(_ key: UIKey) -> (keysym: UInt32, printable: Bool)? {
        let named: [UIKeyboardHIDUsage: UInt32] = [
            .keyboardEscape: VNCKeys.escape, .keyboardTab: VNCKeys.tab, .keyboardReturnOrEnter: VNCKeys.returnKey,
            .keypadEnter: VNCKeys.returnKey, .keyboardDeleteOrBackspace: VNCKeys.backSpace, .keyboardDeleteForward: VNCKeys.delete,
            .keyboardLeftArrow: VNCKeys.left, .keyboardRightArrow: VNCKeys.right, .keyboardUpArrow: VNCKeys.up, .keyboardDownArrow: VNCKeys.down,
            .keyboardHome: VNCKeys.home, .keyboardEnd: VNCKeys.end, .keyboardPageUp: VNCKeys.pageUp, .keyboardPageDown: VNCKeys.pageDown,
        ]
        if let keysym = named[key.keyCode] { return (keysym, false) }
        let f1 = UIKeyboardHIDUsage.keyboardF1.rawValue
        if (f1...f1 + 11).contains(key.keyCode.rawValue) { return (VNCKeys.f1 + UInt32(key.keyCode.rawValue - f1), false) }
        let flags = key.modifierFlags
        let text = flags.contains(.control) || flags.contains(.command) || flags.contains(.alternate) ? key.charactersIgnoringModifiers : key.characters
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        // Ctrl-letter goes as the letter, lower case, with Ctrl held.
        let shown = flags.contains(.control) || flags.contains(.command) ? (Unicode.Scalar(String(scalar).lowercased()) ?? scalar) : scalar
        return (VNCKeys.keysym(for: shown), true)
    }

    /// The modifiers a hardware key holds: ⌘ as Ctrl, since the remote
    /// browser runs on Linux. Shift goes for named keys only: a printable
    /// key's character is already shifted.
    static func modifiers(_ flags: UIKeyModifierFlags, printable: Bool) -> [UInt32] {
        var held: [UInt32] = []
        if flags.contains(.control) || flags.contains(.command) { held.append(VNCKeys.control) }
        if flags.contains(.alternate) { held.append(VNCKeys.alt) }
        if flags.contains(.shift), !printable { held.append(VNCKeys.shift) }
        return held
    }
}

extension LiveBrowserVNCView: UIKeyInput {
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if !armed.isEmpty, let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 {
            // Ctrl-C from the row: the letter, lower case.
            let letter = Unicode.Scalar(String(scalar).lowercased()) ?? scalar
            return press(VNCKeys.keysym(for: letter))
        }
        sendText?(text)
    }

    func deleteBackward() { press(VNCKeys.backSpace) }

    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .default } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }
}
#endif
