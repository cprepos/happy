#if canImport(UIKit)
import AVFoundation
import HappyIcons
import HappyLayout
import UIKit

/// Whether the camera cell may show the camera live.
enum AttachCameraAccess: Equatable, Sendable {
    case authorized
    /// Not asked yet. The cell never asks; the full camera does.
    case notDetermined
    /// Denied, or restricted by the device's owner.
    case denied
    /// No camera, as in the simulator.
    case unavailable
}

/// The camera behind the cell: a capture session and its preview.
///
/// `startRunning` and `stopRunning` block and are only ever called on the
/// cell's serial queue, never on the main thread.
protocol AttachCaptureSource: AnyObject, Sendable {
    /// Read on the main thread, so it must be cheap.
    var access: AttachCameraAccess { get }
    /// The live picture, which the cell sizes and places.
    @MainActor var preview: CALayer { get }
    /// Configures the session the first time, then runs it. Whether it runs.
    func startRunning() -> Bool
    func stopRunning()
}

extension AttachMenuEnvironment {
    /// The camera the menu's cell shows live. Tests swap it before the menu opens.
    static var captureSource: () -> AttachCaptureSource = {
        #if DEBUG || HAPPY_FIXTURES
        // Screenshots in the simulator: `-attachCamera fake`.
        if ProcessInfo.processInfo.arguments.contains("-attachCamera") { return FixtureAttachCaptureSource() }
        #endif
        return CameraAttachCaptureSource()
    }
}

/// The camera's cell, two pictures tall, after Telegram's
/// (`TGAttachmentCameraView`, `MediaPickerScreen`): the back camera live,
/// a full-screen camera's picture cropped to the cell, with the camera's
/// glyph at its top right. Until the first picture arrives, and whenever
/// the camera can't be shown (not asked yet, denied, no camera), it is
/// black with the glyph.
///
/// It runs itself: the camera starts once the cell is in a window, the
/// app in front and the cell scrolled into its scroll view's bounds, and
/// stops when any of that ends. A tap stops it for good, as the full
/// camera takes over; `start()` undoes that. The session is started and
/// stopped on a serial queue, never on the main thread.
final class AttachCameraTile: UIControl {
    /// One queue for every cell, since there is one camera.
    nonisolated private static let queue = DispatchQueue(label: "engineering.happy.attach-camera", qos: .userInitiated)

    let source: AttachCaptureSource
    /// Asked to run: the camera starts once it would show.
    private(set) var running = false
    /// The first picture has come since the cell was made.
    private(set) var live = false
    /// Stopped by `stop()` or a tap, until `start()`.
    private var stopped = false
    /// Paused by `pause()`, until `resume()`.
    private var paused = false
    private var background = UIApplication.shared.applicationState == .background
    /// Telegram's `isCameraPreviewVisible`: the cell meets its scroll view's bounds.
    private(set) var onScreen = true
    /// Each start's number, so a start that was overtaken shows nothing.
    private var generation = 0
    private var scrolling: NSKeyValueObservation?

    private let content = UIView()
    private let previewHost = UIView()
    /// The black over the preview until the first picture.
    let fade = UIView()
    /// Telegram's glyph, at the top right.
    let icon = IconView(.ionicons("camera"), size: AttachCameraTileLayout.Metrics.glyph, tint: Palette.attachMenuCameraGlyph)

    init(source: AttachCaptureSource = AttachMenuEnvironment.captureSource()) {
        self.source = source
        super.init(frame: .zero)
        backgroundColor = UIColor(Palette.attachMenuCamera)
        clipsToBounds = true
        content.isUserInteractionEnabled = false
        addSubview(content)
        previewHost.isUserInteractionEnabled = false
        previewHost.layer.addSublayer(source.preview)
        content.addSubview(previewHost)
        fade.backgroundColor = UIColor(Palette.attachMenuCamera)
        fade.isUserInteractionEnabled = false
        content.addSubview(fade)
        content.addSubview(icon)
        for view in [content, previewHost, fade, icon] { view.accessibilityIgnoresInvertColors = true }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "attach-camera"
        accessibilityLabel = Strings.AttachMenu.camera
        accessibilityHint = Strings.AttachMenu.cameraHint
        // The full camera takes over; this one lets the device go first.
        addAction(UIAction { [weak self] _ in self?.stop() }, for: .touchUpInside)
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enteringForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // Not `isolated deinit`: that aborts on the iOS 26.3 runtime (see
    // `Watch`). The scroll observation goes with the cell.
    deinit {
        guard running else { return }
        let source = source
        Self.queue.async { source.stopRunning() }
    }

    // MARK: Running

    /// Lets the camera run again after `stop()` or a tap.
    func start() {
        stopped = false
        update()
    }

    /// Stops the camera until `start()`.
    func stop() {
        stopped = true
        update()
    }

    /// Holds the camera, as Telegram does while something covers the menu.
    func pause() {
        paused = true
        update()
    }

    func resume() {
        paused = false
        update()
    }

    /// Whether the camera would show now.
    private var wanted: Bool {
        source.access == .authorized && window != nil && !isHidden && !background && onScreen && !stopped && !paused
    }

    private func update() {
        let wanted = wanted
        guard wanted != running else { return }
        running = wanted
        generation += 1
        let source = source
        if wanted {
            let generation = generation
            let started: @MainActor @Sendable () -> Void = { [weak self] in self?.started(generation) }
            Self.queue.async {
                guard source.startRunning() else { return }
                Task { @MainActor in started() }
            }
        } else {
            Self.queue.async { source.stopRunning() }
        }
    }

    /// The first picture fades in over the black, as Telegram's preview
    /// does: 0.3 s, linear, after 0.05.
    private func started(_ generation: Int) {
        guard generation == self.generation, running else { return }
        orient()
        guard !live else { return }
        live = true
        UIView.animate(withDuration: 0.3, delay: 0.05, options: [.curveLinear, .beginFromCurrentState]) {
            self.fade.alpha = 0
        }
    }

    /// The picture upright for the interface.
    private func orient() {
        guard let connection = (source.preview as? AVCaptureVideoPreviewLayer)?.connection else { return }
        let angle: CGFloat = switch window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait {
        case .landscapeLeft: 180
        case .landscapeRight: 0
        case .portraitUpsideDown: 270
        default: 90
        }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }

    @objc private func enteredBackground() {
        background = true
        update()
    }

    @objc private func enteringForeground() {
        background = false
        update()
    }

    // MARK: Where it is

    override var isHidden: Bool {
        didSet { if isHidden != oldValue { update() } }
    }

    override var frame: CGRect {
        didSet { if frame != oldValue { checkOnScreen() } }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        scrolling?.invalidate()
        scrolling = (superview as? UIScrollView)?.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.checkOnScreen() }
        }
        checkOnScreen()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
        update()
    }

    private func checkOnScreen() {
        onScreen = (superview as? UIScrollView).map { $0.bounds.intersects(frame) } ?? true
        update()
    }

    // MARK: Drawing

    override var isHighlighted: Bool {
        didSet { content.alpha = isHighlighted ? 0.6 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let screen = window?.windowScene?.screen.bounds.size ?? bounds.size
        let layout = AttachCameraTileLayout(size: bounds.size, screenWidth: min(screen.width, screen.height), scale: traitCollection.displayScale)
        content.frame = bounds
        fade.frame = bounds
        icon.frame = layout.glyph
        previewHost.transform = .identity
        previewHost.bounds = CGRect(origin: .zero, size: layout.previewSize)
        previewHost.center = layout.previewCenter
        previewHost.transform = CGAffineTransform(scaleX: layout.previewScale, y: layout.previewScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        source.preview.frame = previewHost.bounds
        CATransaction.commit()
        if running { orient() }
    }
}

/// The device's back camera at a low resolution: no audio, no frames
/// read, only the preview. Everything but making the preview runs on the
/// cell's queue.
final class CameraAttachCaptureSource: AttachCaptureSource, @unchecked Sendable {
    @MainActor let preview: CALayer
    /// Only touched on the cell's queue, after `init`.
    private let session = AVCaptureSession()
    private var configured: Bool?

    @MainActor init() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        preview = layer
    }

    var access: AttachCameraAccess {
        #if targetEnvironment(simulator)
        return .unavailable
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
        #endif
    }

    func startRunning() -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard configure() else { return false }
        if !session.isRunning { session.startRunning() }
        return session.isRunning
    }

    func stopRunning() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        if session.isRunning { session.stopRunning() }
    }

    private func configure() -> Bool {
        if let configured { return configured }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            configured = false
            return false
        }
        session.addInput(input)
        configured = true
        return true
    }
}

#if DEBUG || HAPPY_FIXTURES
/// A drawn stand-in for the camera, for screenshots in the simulator: an
/// evening sky over hills, never a real picture.
final class FixtureAttachCaptureSource: AttachCaptureSource, @unchecked Sendable {
    let access: AttachCameraAccess
    @MainActor let preview = CALayer()

    @MainActor init(access: AttachCameraAccess = .authorized) {
        self.access = access
        preview.contentsGravity = .resizeAspectFill
    }

    func startRunning() -> Bool {
        let frame = Self.draw()
        Task { @MainActor in self.preview.contents = frame.cgImage }
        return true
    }

    func stopRunning() {}

    private static func draw() -> UIImage {
        let size = CGSize(width: 270, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let sky = [UIColor(red: 0.16, green: 0.22, blue: 0.45, alpha: 1).cgColor, UIColor(red: 0.95, green: 0.55, blue: 0.35, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: sky, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height * 0.7), options: [.drawsAfterEndLocation])
            }
            UIColor(red: 1, green: 0.85, blue: 0.55, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 150, y: 250, width: 70, height: 70))
            for (index, color) in [UIColor(red: 0.2, green: 0.3, blue: 0.25, alpha: 1), UIColor(red: 0.1, green: 0.17, blue: 0.14, alpha: 1)].enumerated() {
                let base = size.height * (0.66 + CGFloat(index) * 0.1)
                let hill = UIBezierPath()
                hill.move(to: CGPoint(x: 0, y: size.height))
                hill.addLine(to: CGPoint(x: 0, y: base))
                hill.addCurve(to: CGPoint(x: size.width, y: base - 20), controlPoint1: CGPoint(x: size.width * 0.3, y: base - 70), controlPoint2: CGPoint(x: size.width * 0.6, y: base + 40))
                hill.addLine(to: CGPoint(x: size.width, y: size.height))
                hill.close()
                color.setFill()
                hill.fill()
            }
        }
    }
}
#endif
#endif
