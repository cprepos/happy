#if canImport(UIKit)
import HappyLayout
import os
import UIKit

/// The keyboard's readings, for a look on a device:
/// `log stream --level debug --predicate 'subsystem == "engineering.happy" AND category == "keyboard"'`.
let keyboardLog = Logger(subsystem: "engineering.happy", category: "keyboard")

/// The keyboard's frame as the app last heard it, for a screen made while
/// the keyboard was already up: no notification tells it where the
/// keyboard is, and its keyboard layout guide says how far up the keyboard
/// covers, never where an iPad's minimized bar sits across the bottom
/// (`KeyboardCover`'s `remembered`).
///
/// Listening from launch (`start()`), so the frame is there before any
/// screen asks. Gone with the app into the background, where the keyboard
/// can change unheard.
@MainActor
public final class KeyboardFrames: NSObject {
    public static let shared = KeyboardFrames()

    /// The keyboard's frame at the end of its last notification, in the
    /// screen's coordinates; nil before any.
    private(set) var screenFrame: CGRect?

    /// From the app's launch.
    public static func start() { _ = shared }

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(changed(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(changed(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(forget), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func changed(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        keyboardLog.debug("\(notification.name.rawValue, privacy: .public) end=\(String(describing: frame), privacy: .public)")
        screenFrame = frame
    }

    /// A guide that follows the undocked keyboard (`UndockedKeyboardGuide`)
    /// has seen the minimized bar on this device: it says where the bar
    /// is from now on.
    public internal(set) var undockedSeesBar = false

    /// Nothing remembered, as at launch.
    @objc func forget() { screenFrame = nil }

    /// The remembered frame in `view`.
    func frame(in view: UIView) -> CGRect? {
        screenFrame.map(view.keyboardFrame(fromScreen:))
    }
}

/// The keyboard layout guide of a view laid over a screen, following the
/// undocked keyboard: iPadOS counts the minimized bar as undocked, which
/// the screen's own guide, `followsUndockedKeyboard` off, doesn't follow.
/// Clear, untouchable and out of accessibility, filling the screen; it
/// says when its guide moves (`changed`).
@MainActor
final class UndockedKeyboardGuide: UIView {
    /// Its guide moved; the object is the guide's view.
    static let changed = Notification.Name("UndockedKeyboardGuide.changed")

    private var lastFrame: CGRect?

    /// The one over `view`, added once.
    static func over(_ view: UIView) -> UndockedKeyboardGuide {
        if let guide = view.subviews.lazy.compactMap({ $0 as? UndockedKeyboardGuide }).first { return guide }
        let guide = UndockedKeyboardGuide()
        guide.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(guide, at: 0)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guide.topAnchor.constraint(equalTo: view.topAnchor),
            guide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return guide
    }

    private override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        keyboardLayoutGuide.followsUndockedKeyboard = true
        // A view on the guide, so its every move lays this out.
        let tracker = UIView()
        tracker.isUserInteractionEnabled = false
        tracker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tracker)
        NSLayoutConstraint.activate([
            tracker.leadingAnchor.constraint(equalTo: keyboardLayoutGuide.leadingAnchor),
            tracker.trailingAnchor.constraint(equalTo: keyboardLayoutGuide.trailingAnchor),
            tracker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            tracker.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Back in a window, its guide is read afresh and said again: what it
    /// read out of the window doesn't count.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        lastFrame = nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = keyboardLayoutGuide.layoutFrame
        guard frame != lastFrame else { return }
        lastFrame = frame
        // The bar floats over the bottom edge or stands narrower than the
        // screen: a docked keyboard a finger drags down is neither.
        if let superview, let cover = KeyboardCover(bounds: superview.bounds, safeBottom: superview.safeAreaInsets.bottom,
                                                    frame: nil, undocked: self.frame(in: superview)),
           superview.bounds.maxY - cover.top <= KeyboardCover.Metrics.barMaxCover,
           cover.rect.maxY < superview.bounds.maxY - 1 || cover.rect.width < superview.bounds.width - 1 {
            KeyboardFrames.shared.undockedSeesBar = true
        }
        keyboardLog.debug("undocked guide \(String(describing: frame), privacy: .public) in \(String(describing: self.bounds), privacy: .public) safe=\(self.safeAreaInsets.bottom, privacy: .public)")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// The guide's frame in `view`, nil out of a window.
    func frame(in view: UIView) -> CGRect? {
        guard window != nil else { return nil }
        return convert(keyboardLayoutGuide.layoutFrame, to: view)
    }
}

extension UIView {
    /// A keyboard notification's frame, given in the screen's coordinates,
    /// in this view: through the window's screen, so a window away from the
    /// screen's origin (Stage Manager, Split View, Slide Over) reads it
    /// where it is. Out of a window, the window's coordinates stand in.
    func keyboardFrame(fromScreen frame: CGRect) -> CGRect {
        guard let screen = window?.screen else { return convert(frame, from: nil) }
        return convert(frame, from: screen.coordinateSpace)
    }

    /// What the keyboard covers of this view (`KeyboardCover`): `frame` in
    /// the screen's coordinates as this view's screen last heard it (nil:
    /// none heard), with the app's last frame and the layout guide's top.
    func keyboardCover(heard frame: CGRect?, guideTop: CGFloat?, undocked: UndockedKeyboardGuide? = nil) -> KeyboardCover? {
        KeyboardCover(
            bounds: bounds, safeBottom: safeAreaInsets.bottom,
            frame: frame.map(keyboardFrame(fromScreen:)),
            remembered: frame == nil ? KeyboardFrames.shared.frame(in: self) : nil,
            guideTop: guideTop,
            undocked: undocked?.frame(in: self),
            undockedSeesBar: KeyboardFrames.shared.undockedSeesBar
        )
    }
}
#endif
