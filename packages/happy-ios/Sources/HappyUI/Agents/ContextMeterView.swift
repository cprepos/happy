#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// Desktop's ContextMeter under the agent chat's composer: the bar alone at
/// rest, the percentage and the token counts sliding out to its left when it
/// is tapped (desktop's hover) and for as long as it is held. It takes colour
/// only once compacting is the next thing to do. A grown fill bumps the track
/// and sends a shine across it; a shrunk one (a compaction) squashes it.
/// Placed by `ChatScreenLayout.meter`; laid out by `ContextMeterLayout`.
final class ContextMeterView: UIView {
    private let readout = UIView()
    private let percent = UILabel()
    private let tokens = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let notch = UIView()
    private let shine = CAGradientLayer()
    private var hiding: DispatchWorkItem?
    private(set) var layout = ContextMeterLayout(.init(percent: .zero, tokens: .zero, revealed: false, fraction: 0, compactFraction: AgentContextGauge.defaultCompactFraction))

    private(set) var gauge: AgentContextGauge?
    /// The numbers are out.
    private(set) var revealed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        readout.clipsToBounds = true
        readout.isUserInteractionEnabled = false
        let font = Fonts.tabular(Fonts.ui(.regular, size: ContextMeterLayout.Metrics.fontSize))
        for label in [percent, tokens] {
            label.font = font
            readout.addSubview(label)
        }
        tokens.alpha = ContextMeterStyle.tokensOpacity
        addSubview(readout)
        track.clipsToBounds = true
        track.isUserInteractionEnabled = false
        track.backgroundColor = UIColor(Palette.contextMeterTrack)
        track.addSubview(fill)
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.opacity = 0
        track.layer.addSublayer(shine)
        notch.alpha = ContextMeterStyle.notchOpacity
        notch.backgroundColor = UIColor(Palette.surface)
        track.addSubview(notch)
        addSubview(track)
        readout.alpha = 0
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityIdentifier = "context-meter"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.3
        addGestureRecognizer(hold)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.applyColors() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A new reading. The fill eases to it; growing bumps the track and
    /// shines, shrinking squashes it, as desktop's `contextMeterAnimate`.
    func show(_ gauge: AgentContextGauge) {
        guard gauge != self.gauge else { return }
        let previous = self.gauge
        self.gauge = gauge
        percent.text = Strings.ContextMeter.percent(gauge)
        tokens.text = Strings.ContextMeter.tokens(gauge)
        accessibilityLabel = Strings.ContextMeter.title(gauge)
        applyColors()
        let animates = previous != nil && previous?.fraction != gauge.fraction && window != nil && !UIAccessibility.isReduceMotionEnabled
        if animates {
            UIView.animate(withDuration: ContextMeterStyle.fillDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.place()
            }
            bounce(grew: gauge.fraction > previous?.fraction ?? 0)
        } else {
            setNeedsLayout()
        }
    }

    // MARK: Revealing

    @objc private func tapped() {
        reveal(!revealed)
        guard revealed else { return }
        let hide = DispatchWorkItem { [weak self] in self?.reveal(false) }
        hiding = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + ContextMeterStyle.revealSeconds, execute: hide)
    }

    @objc private func held(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began: reveal(true)
        case .ended, .cancelled, .failed: reveal(false)
        default: break
        }
    }

    func reveal(_ shown: Bool) {
        hiding?.cancel()
        hiding = nil
        guard shown != revealed else { return }
        revealed = shown
        let change = {
            self.place()
            self.readout.alpha = shown ? 1 : 0
        }
        if window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: ContextMeterStyle.revealDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: change)
        } else {
            change()
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
    }

    private func place() {
        let gauge = gauge
        layout = ContextMeterLayout(.init(
            percent: percent.sizeThatFits(.zero),
            tokens: tokens.sizeThatFits(.zero),
            revealed: revealed,
            fraction: gauge?.fraction ?? 0,
            compactFraction: gauge?.compactFraction ?? AgentContextGauge.defaultCompactFraction
        ))
        readout.frame = layout.readout
        percent.frame = layout.percent
        tokens.frame = layout.tokens
        track.bounds = CGRect(origin: .zero, size: layout.track.size)
        track.center = CGPoint(x: layout.track.midX, y: layout.track.midY)
        track.layer.cornerRadius = layout.track.height / 2
        fill.frame = layout.fill
        fill.layer.cornerRadius = layout.fill.height / 2
        notch.frame = layout.notch
        shine.frame = layout.shine
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        layout.touch.contains(point)
    }

    private func applyColors() {
        let tone = gauge?.tone ?? .ample
        let ink: ColorToken = switch tone {
        case .ample: Palette.contextMeterInk
        case .compact: Palette.contextMeterCompact
        case .critical: Palette.contextMeterCritical
        }
        let color = UIColor(ink)
        percent.textColor = color
        tokens.textColor = color
        fill.backgroundColor = color
        // Plenty of room stays in the row's own voice.
        alpha = tone == .ample ? ContextMeterStyle.ampleOpacity : 1
        let surface = UIColor(Palette.surface).resolvedColor(with: traitCollection)
        shine.colors = [surface.withAlphaComponent(0).cgColor, surface.withAlphaComponent(0.88).cgColor, surface.withAlphaComponent(0).cgColor]
    }

    // MARK: Motion

    private func bounce(grew: Bool) {
        track.layer.removeAnimation(forKey: "bounce")
        let scales: [(CGFloat, CGFloat)] = grew
            ? [(1, 1), (1.025, 1.45), (0.995, 0.92), (1, 1)]
            : [(1, 1), (0.92, 1.55), (1.035, 0.88), (0.99, 1.08), (1, 1)]
        let bounce = CAKeyframeAnimation(keyPath: "transform")
        bounce.values = scales.map { NSValue(caTransform3D: CATransform3DMakeScale($0.0, $0.1, 1)) }
        bounce.keyTimes = (grew ? [0, 0.32, 0.68, 1] : [0, 0.24, 0.58, 0.8, 1]).map { NSNumber(value: $0) }
        bounce.duration = grew ? ContextMeterStyle.growDuration : ContextMeterStyle.shrinkDuration
        bounce.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        track.layer.add(bounce, forKey: "bounce")
        guard grew else { return }
        let pass = CAKeyframeAnimation(keyPath: "position.x")
        pass.values = [layout.shinePass.lowerBound, layout.shinePass.upperBound]
        pass.duration = ContextMeterStyle.shineDuration
        pass.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.82, 0]
        fade.keyTimes = [0, 0.24, 1]
        fade.duration = ContextMeterStyle.shineDuration
        shine.add(pass, forKey: "pass")
        shine.add(fade, forKey: "fade")
    }
}
#endif
