#if canImport(UIKit)
import UIKit

/// A button's name and what it does, shown while it is held: a small
/// bubble, its title bold over a one-line description, an arrow at the
/// button. Holding never presses the button (the hold cancels the tap);
/// a light tap plays as it shows, and it goes about 1.5 s after the
/// finger lifts. The description is VoiceOver's hint too.
///
/// It stands clear of the finger and the hand under it:
/// - `.below` (a header): under the button, shifted sideways away from
///   the touch;
/// - `.leading` (a column at the trailing edge): beside it, to the
///   leading side;
/// - `.above` (the floating player's bar): over the button's superview,
///   or under it where there is no room above.
///
/// Always inside the window's safe area.
@MainActor
enum HoldTip {
    enum Placement {
        case below, leading, above
    }

    enum Metrics {
        static let hold: TimeInterval = 0.4
        static let linger: TimeInterval = 1.5
        static let gap: CGFloat = 8
        static let arrow: CGFloat = 6
        static let margin: CGFloat = 8
        static let maxWidth: CGFloat = 280
        /// How far past the finger's point a `.below` bubble starts.
        static let finger: CGFloat = 28
    }

    /// The bubble showing now, if any (tests).
    private(set) static weak var shown: HoldTipBubble?
    private static var hiding: DispatchWorkItem?

    /// Adds the hold to `view`: its tip says `title` and `detail`.
    @discardableResult
    static func attach(to view: UIView, title: String, detail: String, placement: Placement = .below) -> UILongPressGestureRecognizer {
        view.gestureRecognizers?.compactMap { $0 as? HoldTipGesture }.forEach(view.removeGestureRecognizer)
        let hold = HoldTipGesture(title: title, detail: detail, placement: placement)
        view.addGestureRecognizer(hold)
        view.accessibilityHint = detail
        return hold
    }

    /// Says something else from now on (a button whose meaning turns, as
    /// Take and Release control).
    static func update(_ view: UIView, title: String, detail: String) {
        guard let hold = gesture(on: view) else { return }
        hold.title = title
        hold.detail = detail
        view.accessibilityHint = detail
    }

    static func gesture(on view: UIView) -> HoldTipGesture? {
        view.gestureRecognizers?.lazy.compactMap { $0 as? HoldTipGesture }.first
    }

    /// Shows `view`'s tip as a hold at `touch` (the window's points) would.
    static func show(for view: UIView, at touch: CGPoint) {
        guard let hold = gesture(on: view), let window = view.window else { return }
        hiding?.cancel()
        hiding = nil
        shown?.removeFromSuperview()
        let bubble = HoldTipBubble(title: hold.title, detail: hold.detail)
        let source = view.convert(view.bounds, to: window)
        let container = view.superview.map { $0.convert($0.bounds, to: window) } ?? source
        let safe = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: Metrics.margin, dy: Metrics.margin)
        let size = bubble.measure(maxWidth: min(Metrics.maxWidth, safe.width))
        let place = frame(size: size, source: source, container: container, touch: touch, safe: safe, placement: hold.placement)
        bubble.frame = place.frame
        bubble.point(at: place.arrow, edge: place.edge)
        window.addSubview(bubble)
        shown = bubble
        Haptics.play(.hold)
        bubble.alpha = 0
        UIView.animate(withDuration: 0.15) { bubble.alpha = 1 }
    }

    /// Goes after `linger`, unless another shows first.
    static func hide(after delay: TimeInterval = Metrics.linger) {
        hiding?.cancel()
        let hide = DispatchWorkItem {
            guard let bubble = shown else { return }
            UIView.animate(withDuration: 0.2, animations: { bubble.alpha = 0 }) { _ in bubble.removeFromSuperview() }
            shown = nil
        }
        hiding = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: hide)
    }

    /// The bubble's frame, the arrow's point on it (in the window's
    /// points) and the edge the arrow stands on.
    static func frame(size: CGSize, source: CGRect, container: CGRect, touch: CGPoint, safe: CGRect,
                      placement: Placement) -> (frame: CGRect, arrow: CGPoint, edge: UIRectEdge) {
        typealias M = Metrics
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, safe.minX), max(safe.minX, safe.maxX - size.width)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, safe.minY), max(safe.minY, safe.maxY - size.height)) }
        switch placement {
        case .below:
            // Under the bar, beside the finger: past it on the side with
            // more room.
            let y = clampY(source.maxY + M.gap + M.arrow)
            let rightward = touch.x <= (safe.minX + safe.maxX) / 2
            let x = clampX(rightward ? touch.x + M.finger : touch.x - M.finger - size.width)
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            let arrowX = min(max(source.midX, frame.minX + 12), frame.maxX - 12)
            return (frame, CGPoint(x: arrowX, y: frame.minY), .top)
        case .leading:
            let x = clampX(source.minX - M.gap - M.arrow - size.width)
            let y = clampY(source.midY - size.height / 2)
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            let arrowY = min(max(source.midY, frame.minY + 10), frame.maxY - 10)
            return (frame, CGPoint(x: frame.maxX, y: arrowY), .right)
        case .above:
            let x = clampX(source.midX - size.width / 2)
            var y = container.minY - M.gap - M.arrow - size.height
            var edge: UIRectEdge = .bottom
            if y < safe.minY {
                // No room over it: under it instead, still off the bar.
                y = container.maxY + M.gap + M.arrow
                edge = .top
            }
            let frame = CGRect(x: x, y: clampY(y), width: size.width, height: size.height)
            let arrowX = min(max(source.midX, frame.minX + 12), frame.maxX - 12)
            return (frame, CGPoint(x: arrowX, y: edge == .top ? frame.minY : frame.maxY), edge)
        }
    }
}

/// The hold that shows a view's tip, and what it says.
final class HoldTipGesture: UILongPressGestureRecognizer {
    var title: String
    var detail: String
    let placement: HoldTip.Placement

    init(title: String, detail: String, placement: HoldTip.Placement) {
        self.title = title
        self.detail = detail
        self.placement = placement
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(held))
        minimumPressDuration = HoldTip.Metrics.hold
        // Recognised, the button's touch is cancelled: no tap after.
        cancelsTouchesInView = true
    }

    @objc private func held() {
        guard let view else { return }
        switch state {
        case .began: HoldTip.show(for: view, at: location(in: nil))
        case .ended, .cancelled, .failed: HoldTip.hide()
        default: break
        }
    }
}

/// The tip's bubble: the card's colours, a hairline, a shadow.
final class HoldTipBubble: UIView {
    let title = UILabel()
    let detail = UILabel()
    private let shape = CAShapeLayer()
    private let padding = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    private var arrow: (CGPoint, UIRectEdge)?

    init(title: String, detail: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "hold-tip"
        backgroundColor = .clear
        layer.addSublayer(shape)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        self.title.text = title
        self.title.font = Fonts.ui(.semiBold, size: 13)
        self.title.textColor = UIColor(Palette.cardTitle)
        self.detail.text = detail
        self.detail.font = Fonts.ui(.regular, size: 12)
        self.detail.textColor = UIColor(Palette.cardDetail)
        self.detail.numberOfLines = 0
        addSubview(self.title)
        addSubview(self.detail)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.setNeedsLayout() }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Its size: the description on one line where it fits, else wrapped
    /// at `maxWidth`.
    func measure(maxWidth: CGFloat) -> CGSize {
        let inner = maxWidth - padding.left - padding.right
        let titleSize = title.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude))
        let detailSize = detail.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude))
        let width = min(maxWidth, ceil(max(titleSize.width, detailSize.width)) + padding.left + padding.right)
        return CGSize(width: width, height: ceil(titleSize.height + 2 + detailSize.height) + padding.top + padding.bottom)
    }

    /// The arrow's tip, in the window's points, on `edge`.
    func point(at tip: CGPoint, edge: UIRectEdge) {
        arrow = (tip, edge)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.inset(by: padding)
        let titleHeight = ceil(title.sizeThatFits(CGSize(width: inner.width, height: .greatestFiniteMagnitude)).height)
        title.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: titleHeight)
        detail.frame = CGRect(x: inner.minX, y: title.frame.maxY + 2, width: inner.width, height: max(0, inner.maxY - title.frame.maxY - 2))
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: 10)
        if let (tip, edge) = arrow {
            let a = HoldTip.Metrics.arrow
            let local = CGPoint(x: tip.x - frame.minX, y: tip.y - frame.minY)
            let triangle = UIBezierPath()
            switch edge {
            case .top:
                triangle.move(to: CGPoint(x: local.x - a, y: 0))
                triangle.addLine(to: CGPoint(x: local.x, y: -a))
                triangle.addLine(to: CGPoint(x: local.x + a, y: 0))
            case .bottom:
                triangle.move(to: CGPoint(x: local.x - a, y: bounds.maxY))
                triangle.addLine(to: CGPoint(x: local.x, y: bounds.maxY + a))
                triangle.addLine(to: CGPoint(x: local.x + a, y: bounds.maxY))
            default:
                triangle.move(to: CGPoint(x: bounds.maxX, y: local.y - a))
                triangle.addLine(to: CGPoint(x: bounds.maxX + a, y: local.y))
                triangle.addLine(to: CGPoint(x: bounds.maxX, y: local.y + a))
            }
            triangle.close()
            path.append(triangle)
        }
        shape.frame = bounds
        shape.path = path.cgPath
        shape.fillColor = UIColor(Palette.cardFill).resolvedColor(with: traitCollection).cgColor
        shape.strokeColor = UIColor(Palette.divider).resolvedColor(with: traitCollection).cgColor
        shape.lineWidth = 1 / max(traitCollection.displayScale, 1)
        layer.shadowPath = path.cgPath
    }
}
#endif
