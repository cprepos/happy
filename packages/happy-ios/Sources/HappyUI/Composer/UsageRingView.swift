#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// Desktop's UsageRing: how much of a usage window is left, read like a
/// battery. The arc runs clockwise from twelve and drains as the window is
/// spent: quiet while there is room, yellow when little is left, red when
/// almost nothing is or the account is blocked, its track then tinted, and
/// all red once nothing is left.
final class UsageRingView: UIView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    /// The share left, 0–100, and how it is coloured.
    var reading: (left: Int, tone: AccountUsage.Tone) = (100, .ample) {
        didSet {
            guard reading != oldValue else { return }
            applyColors()
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = ChipRingLayout.stroke
            layer.addSublayer(shape)
        }
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.applyColors() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        let (left, tone) = reading
        let ink: ColorToken = switch tone {
        case .ample: Palette.usageArc
        case .low: Palette.usageLow
        case .critical: Palette.usageCritical
        }
        arc.strokeColor = UIColor(ink).resolvedColor(with: traitCollection).cgColor
        let critical = UIColor(Palette.usageCritical).resolvedColor(with: traitCollection)
        track.strokeColor = tone != .critical ? UIColor(Palette.usageTrack).resolvedColor(with: traitCollection).cgColor
            : left <= 0 ? critical.cgColor : critical.withAlphaComponent(0.4).cgColor
        arc.lineCap = left < 100 ? .round : .butt
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let ring = bounds.insetBy(dx: ChipRingLayout.stroke / 2, dy: ChipRingLayout.stroke / 2)
        track.path = UIBezierPath(ovalIn: ring).cgPath
        let left = CGFloat(max(0, min(100, reading.left))) / 100
        arc.path = UIBezierPath(arcCenter: CGPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * left, clockwise: true).cgPath
        arc.isHidden = left <= 0
    }
}
#endif
