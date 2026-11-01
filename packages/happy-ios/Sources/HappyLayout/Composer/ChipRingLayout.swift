import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The model chip's usage warning: desktop's 12pt ring before the model's
/// name (`composer-model-control__warning`), 6 apart as the pill's `gap: 6`,
/// there only while the selected account runs low, so a quiet chip keeps
/// no room for it. The ring stays whole and the name gives way when the
/// chip is cut.
public struct ChipRingLayout: Equatable, Sendable {
    public static let ringSize: CGFloat = 12
    public static let gap: CGFloat = 6
    /// The ring's stroke; the track and the arc share it.
    public static let stroke: CGFloat = 2

    public var ring: CGRect
    public var label: CGRect

    /// What the chip measures for its content: the ring, the gap, the name.
    public static func contentSize(label: CGSize) -> CGSize {
        CGSize(width: ringSize + gap + label.width, height: max(ringSize, label.height))
    }

    /// `content` is the chip's label frame (`AgentInputCardLayout`'s,
    /// sized by `contentSize`); `labelHeight` the name's one line.
    public init(content: CGRect, labelHeight: CGFloat) {
        ring = CGRect(x: content.minX, y: content.midY - Self.ringSize / 2, width: min(Self.ringSize, content.width), height: Self.ringSize)
        let labelX = min(content.maxX, ring.maxX + Self.gap)
        label = CGRect(x: labelX, y: content.midY - labelHeight / 2, width: max(0, content.maxX - labelX), height: labelHeight)
    }
}
