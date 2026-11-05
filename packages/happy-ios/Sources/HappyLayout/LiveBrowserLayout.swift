import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The status line over a chat's composer card: the blue voice line on the
/// left, 16 in, and the red live-browser line on the right, its dot on the
/// card's right edge. Both share the row's font, centre and height
/// (`AgentInputLayout.Metrics`); where they would meet, the voice text
/// gives way, 12 short of the browser text.
///
///     ┌ ● Voice Assistant · Listening …      Live browser · Watching ● ┐
///     ├ card ──────────────────────────────────────────────────────────┤
public struct ChatStatusLineLayout: Equatable, Sendable {
    public typealias Row = AgentInputLayout.StatusRow
    /// The least room between the voice text and the browser text.
    public static let voiceGap: CGFloat = 12

    public var frame: CGRect
    public var voice: Row?
    /// The red line; its `frame` is its tap target, the row's height from
    /// its text to the card's edge.
    public var browser: Row?

    /// The row's height for these texts; nil when neither shows.
    public static func height(voice: CGSize?, browser: CGSize?) -> CGFloat? {
        typealias M = AgentInputLayout.Metrics
        guard voice != nil || browser != nil else { return nil }
        let dotBox = M.statusDotSize + M.statusDotMarginTop
        let group = max(dotBox, voice?.height ?? 0, browser?.height ?? 0)
        return max(M.statusMinHeight, group + M.statusPaddingBottom)
    }

    /// The row from `x`, `y`, as wide as the card under it.
    public init?(x: CGFloat, y: CGFloat, width: CGFloat, voice: CGSize?, browser: CGSize?) {
        typealias M = AgentInputLayout.Metrics
        guard let height = Self.height(voice: voice, browser: browser) else { return nil }
        let dotBox = M.statusDotSize + M.statusDotMarginTop
        let group = height - M.statusPaddingBottom
        let groupY = y + (height - M.statusPaddingBottom - group) / 2
        let dotY = groupY + (group - dotBox) / 2 + M.statusDotMarginTop
        let left = x + M.statusPaddingH
        let right = x + width
        frame = CGRect(x: x, y: y, width: width, height: height)

        if let text = browser {
            let dot = CGRect(x: right - M.statusDotSize, y: dotY, width: M.statusDotSize, height: M.statusDotSize)
            let textWidth = min(text.width, max(0, dot.minX - M.statusDotGap - left))
            let textRect = CGRect(x: dot.minX - M.statusDotGap - textWidth, y: groupY + (group - text.height) / 2, width: textWidth, height: text.height)
            self.browser = Row(
                frame: CGRect(x: textRect.minX, y: y, width: right - textRect.minX, height: height),
                dot: dot, text: textRect
            )
        } else {
            self.browser = nil
        }

        if let text = voice {
            let textX = left + M.statusDotSize + M.statusDotGap
            let limit = self.browser.map { $0.text.minX - Self.voiceGap } ?? (right - M.statusPaddingH)
            self.voice = Row(
                frame: frame,
                dot: CGRect(x: left, y: dotY, width: M.statusDotSize, height: M.statusDotSize),
                text: CGRect(x: textX, y: groupY + (group - text.height) / 2, width: min(text.width, max(0, limit - textX)), height: text.height)
            )
        } else {
            self.voice = nil
        }
    }

    /// The row standing on `card`.
    public init?(above card: CGRect, voice: CGSize?, browser: CGSize?) {
        guard let height = Self.height(voice: voice, browser: browser) else { return nil }
        self.init(x: card.minX, y: card.minY - height, width: card.width, voice: voice, browser: browser)
    }
}

/// The chat's floating live browser: the picture at the corner it was left
/// in, small or large, its buttons over it and a footer under it.
///
///     ┌ picture ────────────── ┐   ✕ top left, ⤢ full screen top right,
///     │ ✕                  ⤢   │   ⇲ bigger or smaller bottom right
///     │                    ⇲   │
///     ├ footer ────────────────┤   pill (large only) · Take over / Release
///     └────────────────────────┘
///
/// A bottom corner keeps its right or left edge on the composer card's and
/// its bottom 8 over `anchor`: the status line's top, the voice strip's or
/// the keyboard's, whichever is highest. A top corner keeps 8 under the
/// safe area.
public struct LiveBrowserDockLayout: Equatable, Sendable {
    public enum Corner: String, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
        public var isTop: Bool { self == .topLeft || self == .topRight }
        public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    }

    public enum Metrics {
        public static let smallWidth: CGFloat = 112
        public static let smallWidthWide: CGFloat = 176
        /// Of the card's width.
        public static let largeShare: CGFloat = 0.6
        public static let largeMaxWidth: CGFloat = 420
        /// The picture's width over its height.
        public static let aspect: CGFloat = 1.6
        public static let footerHeight: CGFloat = 30
        public static let button: CGFloat = 28
        public static let buttonInset: CGFloat = 4
        public static let gap: CGFloat = 8
        public static let radius: CGFloat = 12
        /// The pill's text and the footer's button's, measured, sit inside
        /// this much padding.
        public static let footerPadding: CGFloat = 6
    }

    public struct Input: Equatable, Sendable {
        public var size: CGSize
        public var safeArea: LayoutInsets
        /// The composer card's frame: the sides the player lines up with.
        public var card: CGRect
        /// The highest thing a bottom corner keeps above.
        public var anchor: CGFloat
        public var corner: Corner
        public var large: Bool

        public init(size: CGSize, safeArea: LayoutInsets, card: CGRect, anchor: CGFloat, corner: Corner = .bottomRight, large: Bool = false) {
            self.size = size; self.safeArea = safeArea; self.card = card; self.anchor = anchor; self.corner = corner; self.large = large
        }
    }

    public var frame: CGRect
    /// In `frame`'s bounds from here on.
    public var picture: CGRect
    public var close: CGRect
    public var fullScreen: CGRect
    public var resize: CGRect
    public var footer: CGRect
    /// The status pill shows in the footer when there is room: large only.
    public var showsPill: Bool

    public static func width(card: CGRect, size: CGSize, large: Bool) -> CGFloat {
        typealias M = Metrics
        let wide = AgentInputLayout.isWide(screenWidth: size.width)
        let small = wide ? M.smallWidthWide : M.smallWidth
        guard large else { return min(small, card.width) }
        return min(card.width, max(small, min(M.largeMaxWidth, (card.width * M.largeShare).rounded())))
    }

    public init(_ input: Input) {
        typealias M = Metrics
        let top = input.safeArea.top + M.gap
        let bottom = input.anchor - M.gap
        // Never taller than the room between the bars.
        let room = max(0, bottom - top)
        var width = Self.width(card: input.card, size: input.size, large: input.large)
        if width / M.aspect + M.footerHeight > room { width = max(0, (room - M.footerHeight) * M.aspect).rounded(.down) }
        let pictureHeight = (width / M.aspect).rounded()
        let height = pictureHeight + M.footerHeight
        let x = input.corner.isLeft ? input.card.minX : input.card.maxX - width
        let y = input.corner.isTop ? top : bottom - height
        frame = CGRect(x: x, y: y, width: width, height: height)
        picture = CGRect(x: 0, y: 0, width: width, height: pictureHeight)
        let b = M.button, i = M.buttonInset
        close = CGRect(x: i, y: i, width: b, height: b)
        fullScreen = CGRect(x: width - i - b, y: i, width: b, height: b)
        resize = CGRect(x: width - i - b, y: pictureHeight - i - b, width: b, height: b)
        footer = CGRect(x: 0, y: pictureHeight, width: width, height: M.footerHeight)
        showsPill = width >= 200
    }

    /// The corner a drag let go at `point` (the player's centre) lands in.
    public static func corner(nearest point: CGPoint, in size: CGSize) -> Corner {
        let left = point.x < size.width / 2
        let top = point.y < size.height / 2
        switch (top, left) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// The highest of what a bottom corner keeps above; nils are ignored.
    public static func anchor(_ tops: CGFloat?...) -> CGFloat {
        tops.compactMap { $0 }.min() ?? 0
    }
}
