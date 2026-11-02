import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A harness's name on a worktree's line, in the line's own text style, and
/// the separator ahead of it.
public struct HomeRowHarnessText {
    public var name: Measurable
    public var separator: Measurable

    public init(name: Measurable, separator: Measurable) {
        self.name = name
        self.separator = separator
    }
}

/// `feature-x · OpenCode` across `lane`, from `x`: the harness keeps its
/// whole width and the worktree's name truncates first. A harness wider than
/// the lane is clamped to it and stands alone, with no name or separator.
///
/// Neither text moves the row's height: the name keeps the height it was
/// measured at in the whole lane, whatever width is left of it here.
struct HomeRowHarnessLine {
    var labelWidth: CGFloat
    var separator: CGRect?
    var harness: CGRect

    init(_ text: HomeRowHarnessText, x: CGFloat, midY: CGFloat, lane: CGFloat, label: CGFloat) {
        func frame(_ size: CGSize, x: CGFloat) -> CGRect {
            CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
        }
        let name = text.name.size(fitting: lane)
        let mark = text.separator.size(fitting: lane)
        let tail = HomeRowHarness.gap * 2 + mark.width + name.width
        labelWidth = min(label, max(0, lane - tail))
        guard labelWidth > 0 else {
            separator = nil
            harness = frame(name, x: x)
            return
        }
        let separator = frame(mark, x: x + labelWidth + HomeRowHarness.gap)
        self.separator = separator
        harness = frame(name, x: separator.maxX + HomeRowHarness.gap)
    }
}
