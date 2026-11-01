#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// Telegram's badge in a media tile's corner
/// (`ChatMessageInteractiveMediaBadge`): a video's length, then the file's
/// size or how much of it is here, white on dark glass. The tile lays it
/// out (`MediaStatusLayout.badge`); this only measures and applies.
final class MediaBadgeView: UIView {
    private var labels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(Palette.mediaBadge)
        layer.cornerCurve = .continuous
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The lines it says, top to bottom; hidden with none.
    private(set) var lines: [String] = []

    func setLines(_ lines: [String]) {
        guard lines != self.lines else { return }
        self.lines = lines
        isHidden = lines.isEmpty
        while labels.count < lines.count {
            let label = UILabel()
            label.font = Fonts.ui(.medium, size: MediaStatusLayout.badgeFont)
            label.textColor = UIColor(Palette.mediaBadgeText)
            // The numbers keep their width as they count up.
            label.font = label.font.withMonospacedDigits()
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            labels.append(label)
        }
        for (index, label) in labels.enumerated() {
            label.isHidden = index >= lines.count
            label.text = index < lines.count ? lines[index] : nil
        }
        superview?.setNeedsLayout()
    }

    /// Each line's own size.
    func lineSizes() -> [CGSize] {
        labels.prefix(lines.count).map { $0.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)) }
    }

    func apply(_ badge: MediaStatusLayout.Badge) {
        frame = badge.frame
        layer.cornerRadius = badge.radius
        for (label, frame) in zip(labels, badge.lines) { label.frame = frame }
    }
}

extension UIFont {
    func withMonospacedDigits() -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
