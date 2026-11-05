#if canImport(UIKit)
import HappyLayout
import UIKit

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
        screenFrame = frame
    }

    /// Nothing remembered, as at launch.
    @objc func forget() { screenFrame = nil }

    /// The remembered frame in `view`.
    func frame(in view: UIView) -> CGRect? {
        screenFrame.map(view.keyboardFrame(fromScreen:))
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
    func keyboardCover(heard frame: CGRect?, guideTop: CGFloat?) -> KeyboardCover? {
        KeyboardCover(
            bounds: bounds, safeBottom: safeAreaInsets.bottom,
            frame: frame.map(keyboardFrame(fromScreen:)),
            remembered: frame == nil ? KeyboardFrames.shared.frame(in: self) : nil,
            guideTop: guideTop
        )
    }
}
#endif
