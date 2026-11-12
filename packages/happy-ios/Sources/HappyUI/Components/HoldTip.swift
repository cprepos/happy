#if canImport(UIKit)
import HappyLayout
import UIKit

/// A button's name and what it does, shown while it is held: a small
/// bubble, its title bold over a one-line description, an arrow at the
/// button. Holding never presses the button (the hold cancels the tap);
/// a light tap plays as it shows, and it goes about 1.5 s after the
/// finger lifts. The description is VoiceOver's hint too.
///
/// It stands well clear of the finger and the hand under it:
/// - `.below` (a header): `Metrics.clear` under the touch, centred
///   across the screen;
/// - `.leading` (a column at the trailing edge): in the middle of the
///   room to the leading side;
/// - `.above` (the floating player's bar): `Metrics.clear` over the
///   player, or at the top where there is no room.
///
/// Always inside the window's safe area. `showAll` shows every tip of a
/// bar at once (the "?" button): numbered bubbles in columns clear of
/// the bar, each button wearing its number.
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
        /// How far a held tip stands from the touch (`.below`) or the
        /// player (`.above`): past the fingertip and the hand.
        static let clear: CGFloat = 120
        static let aboveClear: CGFloat = 48
        /// Between the bubbles of `showAll`.
        static let spacing: CGFloat = 8
    }

    /// The bubble showing now, if any (tests).
    private(set) static weak var shown: HoldTipBubble?
    /// `showAll`'s overlay, if up (tests).
    private(set) static weak var help: HoldTipHelp?
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
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, safe.minX), max(safe.minX, safe.maxX - size.width)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, safe.minY), max(safe.minY, safe.maxY - size.height)) }
        switch placement {
        case .below:
            // Well under the finger and the hand, across the screen's
            // middle: no arrow, the title says whose it is.
            let y = clampY(max(source.maxY + M.gap + M.arrow, touch.y + M.clear))
            let x = clampX(safe.midX - size.width / 2)
            return (CGRect(x: x, y: y, width: size.width, height: size.height), .zero, [])
        case .leading:
            // The middle of the room to the column's leading side.
            let room = CGRect(x: safe.minX, y: safe.minY, width: max(0, source.minX - M.gap - safe.minX), height: safe.height)
            let x = clampX(room.midX - size.width / 2)
            let y = clampY(source.midY - size.height / 2)
            return (CGRect(x: x, y: y, width: size.width, height: size.height), .zero, [])
        case .above:
            let x = clampX(container.midX - size.width / 2)
            let over = container.minY - M.aboveClear - size.height
            // No room over the player: the top of the screen, far from it.
            let y = over >= safe.minY ? over : safe.minY
            let frame = CGRect(x: x, y: clampY(y), width: size.width, height: size.height)
            if frame.intersects(container) {
                return (CGRect(x: x, y: clampY(container.maxY + M.aboveClear), width: size.width, height: size.height), .zero, [])
            }
            return (frame, .zero, [])
        }
    }

    // MARK: Every tip at once

    /// Shows the tips of `views` (those with a hold, on screen) at once
    /// over a dimmed window: each button numbered, its bubble numbered
    /// the same, the bubbles in columns clear of the bar. A tap anywhere
    /// closes it.
    @discardableResult
    static func showAll(for views: [UIView], placement: Placement) -> HoldTipHelp? {
        let shownViews = views.filter { view in
            guard let window = view.window, gesture(on: view) != nil else { return false }
            var current: UIView? = view
            while let v = current { if v.isHidden || v.alpha < 0.01 { return false }; current = v.superview }
            return window.bounds.intersects(view.convert(view.bounds, to: window))
        }
        guard let window = shownViews.first?.window else { return nil }
        hiding?.cancel()
        shown?.removeFromSuperview()
        help?.removeFromSuperview()
        let overlay = HoldTipHelp(frame: window.bounds)
        let safe = window.bounds.inset(by: window.safeAreaInsets).insetBy(dx: M.margin, dy: M.margin)
        let sources = shownViews.map { $0.convert($0.bounds, to: window) }
        let bubbles = shownViews.enumerated().map { index, view -> HoldTipBubble in
            let hold = gesture(on: view)!
            return HoldTipBubble(title: "\(index + 1)  \(hold.title)", detail: hold.detail)
        }
        let frames = columns(sizes: bubbles.map { $0.measure(maxWidth: min(M.maxWidth, safe.width)) },
                             sources: sources, safe: safe, placement: placement)
        for (index, bubble) in bubbles.enumerated() {
            bubble.frame = frames[index]
            bubble.accessibilityIdentifier = "hold-tip-help-bubble"
            overlay.addSubview(bubble)
            overlay.mark(sources[index], number: index + 1)
        }
        overlay.alpha = 0
        window.addSubview(overlay)
        help = overlay
        Haptics.play(.hold)
        UIView.animate(withDuration: 0.15) { overlay.alpha = 1 }
        return overlay
    }

    private typealias M = Metrics

    /// The bubbles' frames: columns filled top to bottom (bottom to top
    /// over a player), a new column beside when one is full; none on the
    /// bar (`sources`).
    static func columns(sizes: [CGSize], sources: [CGRect], safe: CGRect, placement: Placement) -> [CGRect] {
        guard !sizes.isEmpty else { return [] }
        let bar = sources.dropFirst().reduce(sources.first ?? .zero) { $0.union($1) }
        let room: CGRect
        switch placement {
        case .below:
            let top = min(safe.maxY, bar.maxY + M.gap * 2)
            room = CGRect(x: safe.minX, y: top, width: safe.width, height: max(0, safe.maxY - top))
        case .leading:
            room = CGRect(x: safe.minX, y: safe.minY, width: max(0, bar.minX - M.gap * 2 - safe.minX), height: safe.height)
        case .above:
            let bottom = max(safe.minY, bar.minY - M.gap * 2)
            if bottom - safe.minY >= (sizes.map(\.height).max() ?? 0) {
                room = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: bottom - safe.minY)
            } else {
                room = safe
            }
        }
        let width = min(M.maxWidth, room.width, sizes.map(\.width).max() ?? 0)
        // Fill columns, then centre them across the room.
        var columns: [[Int]] = [[]]
        var used: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if used + size.height > room.height, !(columns.last?.isEmpty ?? true) {
                columns.append([])
                used = 0
            }
            columns[columns.count - 1].append(index)
            used += size.height + M.spacing
        }
        let total = CGFloat(columns.count) * width + CGFloat(columns.count - 1) * M.spacing
        let left = max(room.minX, room.midX - total / 2)
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        for (c, column) in columns.enumerated() {
            let x = left + CGFloat(c) * (width + M.spacing)
            let height = column.reduce(CGFloat(0)) { $0 + sizes[$1].height } + CGFloat(max(0, column.count - 1)) * M.spacing
            var y: CGFloat
            switch placement {
            case .below: y = room.minY
            case .leading: y = max(room.minY, room.midY - height / 2)
            case .above: y = max(room.minY, room.maxY - height)
            }
            for index in column {
                frames[index] = CGRect(x: x, y: y, width: width, height: sizes[index].height)
                y += sizes[index].height + M.spacing
            }
        }
        return frames
    }
}

/// `showAll`'s overlay: the window dimmed, each button's number on it.
final class HoldTipHelp: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "hold-tip-help"
        backgroundColor = UIColor.black.withAlphaComponent(0.35)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismiss)))
        isAccessibilityElement = false
        accessibilityViewIsModal = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The bubbles, in order (tests).
    var bubbles: [HoldTipBubble] { subviews.compactMap { $0 as? HoldTipBubble } }

    /// A small numbered disc at the button's top trailing corner.
    func mark(_ source: CGRect, number: Int) {
        let badge = UILabel()
        badge.text = "\(number)"
        badge.font = Fonts.ui(.semiBold, size: 11)
        badge.textAlignment = .center
        badge.textColor = .white
        badge.backgroundColor = .tintColor
        badge.layer.cornerRadius = 9
        badge.layer.masksToBounds = true
        badge.accessibilityIdentifier = "hold-tip-help-number"
        let size: CGFloat = 18
        badge.frame = CGRect(x: min(source.maxX - size + 2, bounds.maxX - size), y: max(source.minY - 2, 0), width: size, height: size)
        addSubview(badge)
        // The button itself stays lit under the dim.
        let ring = UIView(frame: source.insetBy(dx: 2, dy: 2))
        ring.isUserInteractionEnabled = false
        ring.layer.cornerRadius = min(ring.bounds.width, ring.bounds.height) / 2
        ring.layer.borderColor = UIColor.tintColor.cgColor
        ring.layer.borderWidth = 2
        insertSubview(ring, at: 0)
    }

    @objc func dismiss() {
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in self.removeFromSuperview() }
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
        if let (tip, edge) = arrow, !edge.isEmpty {
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
            case .right:
                triangle.move(to: CGPoint(x: bounds.maxX, y: local.y - a))
                triangle.addLine(to: CGPoint(x: bounds.maxX + a, y: local.y))
                triangle.addLine(to: CGPoint(x: bounds.maxX, y: local.y + a))
            default:
                break
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
