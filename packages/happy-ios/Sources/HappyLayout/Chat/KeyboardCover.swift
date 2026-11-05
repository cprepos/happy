import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What the keyboard covers of a screen, one rule for every screen that
/// keeps a box above it.
///
/// Two readings go in: the keyboard's frame from its notifications, put in
/// the screen's coordinates, and the top of the screen's keyboard layout
/// guide. Either may say the keyboard covers something.
///
///   - A frame counts wherever it sits along the bottom: a docked keyboard
///     reaching the screen's bottom edge, and the bar an iPad shows with a
///     hardware keyboard, minimized, which floats a little above the edge,
///     usually as a pill centred on the screen and sometimes as a short
///     strip the screen's width. A frame whose bottom is more than
///     `floatingBand` above the screen's bottom is a keyboard dragged up the
///     screen, and covers nothing, as the guide reads it with
///     `followsUndockedKeyboard` off.
///   - The guide covers from its top to the screen's bottom.
///   - Neither counts unless it reaches above the safe area's bottom: a
///     hardware keyboard with no bar leaves a strip no taller than the safe
///     area, where nothing stands anyway.
///
/// Both together, the higher top wins: a box above the keyboard clears the
/// top of whatever covers, its own sides as they are.
///
/// A frame remembered from before the screen could hear it (`remembered`,
/// the last notification the app heard) counts only where it can't be
/// stale: while the guide covers something too, or as the minimized bar,
/// no taller than `barMaxHeight`.
///
/// iPadOS counts the minimized bar as an undocked keyboard: the screen's
/// layout guide, `followsUndockedKeyboard` off, rests on the safe area
/// under it, and its notifications can say nothing of it. A second guide
/// that follows the undocked keyboard (`undocked`, its layout frame in the
/// screen's coordinates) sees it: it counts as the bar only along the
/// bottom and no taller than the bar. Once that guide has seen the bar on
/// this device (`undockedSeesBar`), it alone says where the bar is, and a
/// bar-sized frame heard or remembered is set aside.
public struct KeyboardCover: Equatable, Sendable {
    public enum Metrics {
        /// A frame whose bottom is further than this above the screen's
        /// bottom is a keyboard dragged up the screen.
        public static let floatingBand: CGFloat = 60
        /// The tallest remembered frame taken without the guide: the
        /// minimized bar, never a whole keyboard.
        public static let barMaxHeight: CGFloat = 100
        /// The most the minimized bar covers of a screen: its height and
        /// its gap over the bottom edge. A keyboard covering no more is
        /// taken for the bar, whose hides can be a swap for its
        /// suggestions.
        public static let barMaxCover: CGFloat = barMaxHeight + floatingBand
    }

    /// What the keyboard covers, in the screen's coordinates; its top is
    /// the keyboard's top.
    public var rect: CGRect

    /// The keyboard's top in the screen.
    public var top: CGFloat { rect.minY }

    /// `bounds` is the screen's; `safeBottom` its safe area's bottom inset.
    /// `frame` is what the screen's own notifications last said (nil when
    /// it has heard none), `remembered` the app's last, and `guideTop` the
    /// keyboard layout guide's top. Nil when the keyboard covers nothing.
    public init?(bounds: CGRect, safeBottom: CGFloat, frame: CGRect?, remembered: CGRect? = nil, guideTop: CGFloat? = nil,
                 undocked: CGRect? = nil, undockedSeesBar: Bool = false) {
        let isBar = { (rect: CGRect) in bounds.maxY - rect.minY <= Metrics.barMaxCover }
        let guide = guideTop.flatMap { top -> CGRect? in
            guard top.isFinite, bounds.maxY - top > max(0, safeBottom) + 0.5 else { return nil }
            let top = max(bounds.minY, top)
            return CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
        }
        let heard: CGRect?
        if let frame {
            heard = Self.covered(frame, bounds: bounds, safeBottom: safeBottom)
        } else if let remembered, let covered = Self.covered(remembered, bounds: bounds, safeBottom: safeBottom),
                  guide != nil || covered.height <= Metrics.barMaxHeight {
            heard = covered
        } else {
            heard = nil
        }
        let bar = undocked.flatMap { Self.covered($0, bounds: bounds, safeBottom: safeBottom) }.flatMap { isBar($0) ? $0 : nil }
        let trusted = undockedSeesBar ? heard.flatMap { isBar($0) ? nil : $0 } : heard
        var rect: CGRect
        switch (trusted, guide) {
        case (nil, nil):
            guard let bar else { return nil }
            rect = bar
        case let (heard?, nil):
            rect = heard
        case let (nil, guide?):
            rect = guide
        case let (heard?, guide?):
            if guide.minY < heard.minY - 1 {
                rect = guide
            } else {
                let top = min(heard.minY, guide.minY)
                rect = CGRect(x: heard.minX, y: top, width: heard.width, height: heard.maxY - top)
            }
        }
        if let bar, bar.minY < rect.minY - 1 { rect = bar }
        self.rect = rect
    }

    /// The part of `frame` in the screen that counts, or nil.
    public static func covered(_ frame: CGRect, bounds: CGRect, safeBottom: CGFloat) -> CGRect? {
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return nil }
        let part = frame.intersection(bounds)
        guard !part.isNull, part.width > 0.5, part.height > 0.5,
              part.maxY >= bounds.maxY - Metrics.floatingBand,
              bounds.maxY - part.minY > max(0, safeBottom) + 0.5 else { return nil }
        return part
    }
}
