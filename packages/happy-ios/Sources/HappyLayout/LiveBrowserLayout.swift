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
/// in, small or large, its buttons on a bar over it and a footer under it.
/// Nothing stands on the picture, so the page and its title read whole.
///
///     ┌ bar ───────────────────┐   ✕ close and ••• (End browser) on the
///     │ ✕  •••          ⤢  ⇲   │   left, ⤢ full screen and ⇲ bigger or
///     ├ picture ───────────────┤   smaller on the right, each a 44-point
///     │                        │   target; a narrow player keeps ✕ and
///     │                        │   ⇲ (the picture opens full screen, and
///     ├ footer ────────────────┤   full screen has End browser)
///     └────────────────────────┘   pill (large only) · Take over / Release
///
/// A phone (`Input.phone`): small is the large size at a corner; big
/// (`large`) is the screen's whole width under the header, square
/// cornered, the picture at the frame's aspect, and the chat's content
/// starts under it (`topInset`). ⇲ goes between the two.
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
        /// The bar over the picture, as tall as its buttons.
        public static let barHeight: CGFloat = 44
        /// A button's target, square.
        public static let button: CGFloat = 44
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
        /// An iPhone: small is the large width at a corner; `large` is
        /// big, the screen's whole width docked at the chat's top.
        public var phone: Bool

        public init(size: CGSize, safeArea: LayoutInsets, card: CGRect, anchor: CGFloat, corner: Corner = .bottomRight, large: Bool = false, phone: Bool = false) {
            self.size = size; self.safeArea = safeArea; self.card = card; self.anchor = anchor; self.corner = corner; self.large = large; self.phone = phone
        }
    }

    public var frame: CGRect
    /// In `frame`'s bounds from here on.
    /// The bar the buttons stand on, over the picture.
    public var bar: CGRect
    public var picture: CGRect
    public var close: CGRect
    /// Nil on a player too narrow for four buttons: the picture opens it.
    public var fullScreen: CGRect?
    /// Nil on a player too narrow for two buttons.
    public var resize: CGRect?
    /// The menu (End browser), beside close; nil where full screen is.
    public var menu: CGRect?
    public var footer: CGRect
    /// The status pill shows in the footer when there is room: large only.
    public var showsPill: Bool
    /// A phone's big player: edge to edge at the chat's top, square
    /// cornered, not dragged; the chat's content starts under it.
    public var isBig: Bool
    public var radius: CGFloat

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
        let chrome = M.barHeight + M.footerHeight
        let big = input.phone && input.large
        isBig = big
        radius = big ? 0 : M.radius
        var width: CGFloat
        let pictureHeight: CGFloat
        if big {
            // The whole width, under the header, the picture as tall as
            // the frame's aspect. Where that is taller than the room (the
            // phone turned sideways: big stays the windowed player there,
            // landscape is full screen's), as wide as the room's height
            // allows, centred.
            let room = max(0, bottom - input.safeArea.top)
            width = min(input.size.width, max(0, (room - chrome) * M.aspect).rounded(.down))
            pictureHeight = (width / M.aspect).rounded()
        } else {
            width = Self.width(card: input.card, size: input.size, large: input.large || input.phone)
            if width / M.aspect + chrome > room { width = max(0, (room - chrome) * M.aspect).rounded(.down) }
            pictureHeight = (width / M.aspect).rounded()
        }
        let height = M.barHeight + pictureHeight + M.footerHeight
        if big {
            frame = CGRect(x: ((input.size.width - width) / 2).rounded(), y: input.safeArea.top, width: width, height: height)
        } else {
            let x = input.corner.isLeft ? input.card.minX : input.card.maxX - width
            let y = input.corner.isTop ? top : bottom - height
            frame = CGRect(x: x, y: y, width: width, height: height)
        }
        bar = CGRect(x: 0, y: 0, width: width, height: M.barHeight)
        picture = CGRect(x: 0, y: M.barHeight, width: width, height: pictureHeight)
        let b = M.button
        close = CGRect(x: 0, y: 0, width: b, height: b)
        resize = width >= 2 * b ? CGRect(x: width - b, y: 0, width: b, height: b) : nil
        let four = width >= 4 * b
        menu = four ? CGRect(x: b, y: 0, width: b, height: b) : nil
        fullScreen = four ? CGRect(x: width - 2 * b, y: 0, width: b, height: b) : nil
        footer = CGRect(x: 0, y: M.barHeight + pictureHeight, width: width, height: M.footerHeight)
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

    /// How far a phone's big player pushes the chat's content down from
    /// the safe area's top: its height, and a gap; nothing otherwise.
    public var topInset: CGFloat { isBig ? frame.height + Metrics.gap : 0 }

    /// The highest of what a bottom corner keeps above; nils are ignored.
    public static func anchor(_ tops: CGFloat?...) -> CGFloat {
        tops.compactMap { $0 }.min() ?? 0
    }
}

/// The full screen's live page on a phone. Upright, the picture runs
/// edge to edge under the header, as tall as the frame's aspect makes it,
/// the controls in the header above it. Turned sideways (the device's
/// own turn, never forced), the header goes and its controls stand in a
/// column at the trailing edge, inside the safe area, so the page has the
/// whole height:
///
///     upright                    sideways
///     ┌ header ─────────┐        ┌─────────────────────────┬──┐
///     ├ picture ────────┤        │ page                    │⌄ │
///     │                 │        │                         │⊗ │
///     ├─────────────────┤        │                         │… │
///     │                 │        │                         │✋│
///     └─────────────────┘        └─────────────────────────┴──┘
///
/// Elsewhere (iPad, Mac) the page fills the screen as it always has.
public struct LiveBrowserFullScreenLayout: Equatable, Sendable {
    public enum Metrics {
        /// The column's width: a 44-point target and 4 either side.
        public static let stripWidth: CGFloat = 52
        public static let button: CGFloat = 44
        /// When no frame has said otherwise: the bridge's 1920x1200.
        public static let aspect: CGFloat = 1.6
    }

    /// The page's frame.
    public var content: CGRect
    /// The column of controls; nil where the header has them.
    public var strip: CGRect?

    /// Sideways: a phone whose height is the short side.
    public static func usesStrip(phone: Bool, size: CGSize) -> Bool {
        phone && size.width > size.height
    }

    /// `top` is where the header ends (the safe area's top, header
    /// included); `aspect` the frame's width over its height.
    public init(size: CGSize, safeArea: LayoutInsets, top: CGFloat, phone: Bool, aspect: CGFloat?) {
        typealias M = Metrics
        if Self.usesStrip(phone: phone, size: size) {
            let strip = CGRect(x: size.width - safeArea.right - M.stripWidth, y: safeArea.top,
                               width: M.stripWidth, height: max(0, size.height - safeArea.top - safeArea.bottom))
            self.strip = strip
            content = CGRect(x: safeArea.left, y: 0, width: max(0, strip.minX - safeArea.left), height: size.height)
        } else if phone {
            let ratio = aspect.flatMap { $0 > 0 ? $0 : nil } ?? M.aspect
            strip = nil
            content = CGRect(x: 0, y: top, width: size.width, height: min(max(0, size.height - top), (size.width / ratio).rounded()))
        } else {
            strip = nil
            content = CGRect(origin: .zero, size: size)
        }
    }
}
