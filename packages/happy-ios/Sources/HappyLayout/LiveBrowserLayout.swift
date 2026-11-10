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

/// The chat's floating live browser: small at the corner it was left in,
/// or big across the chat's top, its buttons on a bar over it and a footer
/// under it. Nothing stands on the picture, so the page and its title read
/// whole.
///
///     ┌ bar ───────────────────┐   ✕ close and ••• (End browser) on the
///     │ ✕  •••          ⤢  ⇲   │   left, ⤢ full screen and ⇲ big or
///     ├ picture ───────────────┤   small on the right, each a 44-point
///     │                        │   target; a narrow player keeps ✕ and
///     │                        │   ⇲, and too narrow for both, ✕ alone
///     ├ footer ────────────────┤
///     └────────────────────────┘   pill · Take over / Release
///
/// Every idiom: small is 60% of the card (at most 420) at a corner; big
/// is the chat pane's whole width under the header, square cornered, the
/// picture at the frame's aspect, and the chat's content starts under it
/// (`topInset`). ⇲ and a tap on the picture go between the two. Where the
/// whole width would make big too tall, it is as wide as its height
/// allows, centred: a phone's up to the room above the composer (turned
/// sideways). An iPad's or a Mac's is 75% of the pane's width, centred,
/// shrunk only to leave the chat 120 points under it, and never smaller
/// than small (`Idiom`).
///
/// A bottom corner keeps its right or left edge on the composer card's and
/// its bottom 8 over `anchor`: the status line's top, the voice strip's or
/// the keyboard's, whichever is highest. A top corner keeps 8 under the
/// safe area.
///
/// Between and beyond the presets the size is continuous: a grip flush
/// inside the player's bottom corner (`grips`: a phone's at the bottom
/// right whatever its corner, an iPad's or a Mac's one at each bottom
/// corner) drags the picture's width, its
/// height following at the frame's aspect, and the width asked for
/// (`Input.width`) is held to `limits`: no narrower than the old mini
/// player, no wider than the pane (a floating player's card), and short
/// enough to leave the chat `chatRoom` under or over it. A floating
/// player's docked corner stays where it is and it grows toward the chat;
/// big stays centred under the header and grows from its middle.
///
///     a phone's                     an iPad's or a Mac's
///       ┌──────────┐                ┌──────────────┐
///       │  ◂ Take ▸│                │ ◂   Take   ▸ │
///       │         ◢│                │◣            ◢│
///       └──────────┘                └──────────────┘
public struct LiveBrowserDockLayout: Equatable, Sendable {
    public enum Corner: String, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
        public var isTop: Bool { self == .topLeft || self == .topRight }
        public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    }

    /// Where a chat's player was left: its corner, small or big, and a
    /// dragged width, kept as `corner|small` or `corner|big`, then
    /// `|width` when it was dragged. An older "large" was a phone's big,
    /// so reads as big there; on an iPad or a Mac it was the bigger corner
    /// player, now small. An older reader takes the first two parts and
    /// ignores the width.
    public struct Kept: Equatable, Sendable {
        public var corner: Corner
        public var big: Bool
        /// The dragged picture width; nil is the preset.
        public var width: CGFloat?

        public init(corner: Corner = .bottomRight, big: Bool = false, width: CGFloat? = nil) {
            self.corner = corner; self.big = big; self.width = width
        }

        public init(stored: String?, phone: Bool) {
            let parts = (stored ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            corner = parts.first.flatMap(Corner.init(rawValue:)) ?? .bottomRight
            big = parts.count > 1 && (parts[1] == "big" || (phone && parts[1] == "large"))
            width = parts.count > 2 ? Double(parts[2]).flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil } : nil
        }

        public var stored: String {
            "\(corner.rawValue)|\(big ? "big" : "small")" + (width.map { "|\(Int($0.rounded()))" } ?? "")
        }
    }

    public enum Metrics {
        public static let minWidth: CGFloat = 112
        public static let minWidthWide: CGFloat = 176
        /// Small's width, of the card's.
        public static let smallShare: CGFloat = 0.6
        public static let smallMaxWidth: CGFloat = 420
        /// An iPad's or a Mac's big: this share of the chat pane's width,
        /// centred.
        public static let bigShareOfWidth: CGFloat = 0.75
        /// The least of the chat an iPad's or a Mac's big leaves between
        /// itself and the composer, unless that would make it smaller than
        /// small.
        public static let padChatRoom: CGFloat = 120
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
        /// The least of the chat a dragged size leaves beside the player:
        /// what an iPad's big leaves (`padChatRoom`).
        public static var chatRoom: CGFloat { padChatRoom }
        /// A grip's touch target, flush in the player's bottom corner.
        public static let grip: CGFloat = 44
        /// VoiceOver's increment or decrement of the grip: this much width.
        public static let resizeStep: CGFloat = 40
        /// The size shown while a grip is dragged: its text inside this
        /// much padding.
        public static let badgePaddingH: CGFloat = 10
        public static let badgePaddingV: CGFloat = 5
    }

    /// A resize grip: the player's corner it sits in, in the player's
    /// bounds (flush inside them).
    public struct Grip: Equatable, Sendable {
        public var corner: Corner
        public var frame: CGRect
        public init(corner: Corner, frame: CGRect) { self.corner = corner; self.frame = frame }
    }

    /// Big's width: a phone's the whole pane, up to the room above the
    /// composer; an iPad's or a Mac's (Designed for iPad) 75% of the pane,
    /// leaving the chat some room.
    public enum Idiom: Sendable { case phone, pad }

    public struct Input: Equatable, Sendable {
        /// The chat pane's size: big runs its whole width.
        public var size: CGSize
        public var safeArea: LayoutInsets
        /// The composer card's frame: the sides the player lines up with.
        public var card: CGRect
        /// The highest thing a bottom corner keeps above.
        public var anchor: CGFloat
        public var corner: Corner
        /// Big, docked at the chat's top; else small, at `corner`.
        public var big: Bool
        public var idiom: Idiom
        /// A dragged picture width, held to `limits`; nil is the preset
        /// (small's or big's).
        public var width: CGFloat?

        public init(size: CGSize, safeArea: LayoutInsets, card: CGRect, anchor: CGFloat, corner: Corner = .bottomRight, big: Bool = false, idiom: Idiom = .phone, width: CGFloat? = nil) {
            self.size = size; self.safeArea = safeArea; self.card = card; self.anchor = anchor; self.corner = corner; self.big = big; self.idiom = idiom; self.width = width
        }
    }

    public var frame: CGRect
    /// In `frame`'s bounds from here on.
    /// The bar the buttons stand on, over the picture.
    public var bar: CGRect
    public var picture: CGRect
    public var close: CGRect
    /// Nil on a player too narrow for four buttons.
    public var fullScreen: CGRect?
    /// Nil on a player too narrow for two buttons.
    public var resize: CGRect?
    /// The menu (End browser), beside close; nil where full screen is.
    public var menu: CGRect?
    public var footer: CGRect
    /// The status pill shows in the footer when there is room.
    public var showsPill: Bool
    /// The big player: at the chat's top, centred, square cornered, never
    /// moved to a corner; the chat's content starts under it.
    public var isBig: Bool
    public var radius: CGFloat
    /// The widths a drag can reach here: from the old mini player's to the
    /// pane's (a floating player's card), leaving the chat some room.
    public var limits: ClosedRange<CGFloat>
    /// The resize grips, flush inside the bottom corners: a phone's one at
    /// the bottom right, an iPad's or a Mac's one at each bottom corner,
    /// whatever corner the player is in, small or big.
    public var grips: [Grip]
    /// The room on the bar between the buttons at its sides, centred on
    /// it: Take control (or Release, Review, Retry) stands in its middle.
    /// Nil where the bar has no room left for a 44-point button; the
    /// footer has it then.
    public var control: CGRect?

    /// Small's width: 60% of the card, at most 420 and at least 112
    /// (176 on a wide screen), never wider than the card.
    public static func smallWidth(card: CGRect, size: CGSize) -> CGFloat {
        typealias M = Metrics
        let least = AgentInputLayout.isWide(screenWidth: size.width) ? M.minWidthWide : M.minWidth
        return min(card.width, max(least, min(M.smallMaxWidth, (card.width * M.smallShare).rounded())))
    }

    public init(_ input: Input) {
        typealias M = Metrics
        let top = input.safeArea.top + M.gap
        let bottom = input.anchor - M.gap
        // Never taller than the room between the bars.
        let room = max(0, bottom - top)
        let chrome = M.barHeight + M.footerHeight
        let big = input.big
        isBig = big
        radius = big ? 0 : M.radius
        let least = input.idiom == .pad ? M.minWidthWide : M.minWidth
        let fitting = { (height: CGFloat) in max(0, (height - chrome) * M.aspect).rounded(.down) }
        var width: CGFloat
        let range: ClosedRange<CGFloat>
        if big {
            // The whole width, under the header, the picture as tall as
            // the frame's aspect. Where that is taller than the room above
            // the composer (a phone turned sideways: big stays the
            // windowed player there, landscape is full screen's), as wide
            // as the room's height allows, centred. An iPad's or a Mac's
            // is 75% of the pane, shrunk to leave the chat 120 under it,
            // but never smaller than small, so ⇲ never shrinks it.
            let room = max(0, bottom - input.safeArea.top)
            width = min(input.size.width, fitting(room))
            if input.idiom == .pad {
                let share = (input.size.width * M.bigShareOfWidth).rounded(.down)
                let fit = min(share, fitting(room - M.padChatRoom))
                width = min(width, max(fit, Self.smallWidth(card: input.card, size: input.size)))
            }
            // Dragged: up to the pane's width, leaving the chat room under
            // it, but never short of the preset.
            let most = max(width, min(input.size.width, fitting(room - M.chatRoom)))
            range = min(least, most)...most
        } else {
            width = Self.smallWidth(card: input.card, size: input.size)
            if width / M.aspect + chrome > room { width = fitting(room) }
            // Dragged: up to the card's width (the side it lines up with),
            // leaving the chat room over or under it, never short of small.
            let most = min(input.card.width, max(width, fitting(room - M.chatRoom)))
            range = min(least, most)...most
        }
        limits = range
        if let asked = input.width { width = Self.clamp(asked.rounded(), to: range) }
        let pictureHeight = (width / M.aspect).rounded()
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
        // Each side keeps as much as the wider: the middle is the bar's.
        let side = four ? 2 * b : b
        control = width - 2 * side >= b ? CGRect(x: side, y: 0, width: width - 2 * side, height: b) : nil
        let corners: [Corner] = input.idiom == .pad ? [.bottomLeft, .bottomRight] : [.bottomRight]
        grips = corners.map { corner in
            Grip(corner: corner, frame: CGRect(
                x: corner.isLeft ? 0 : width - M.grip, y: height - M.grip,
                width: M.grip, height: M.grip
            ))
        }
    }

    static func clamp(_ width: CGFloat, to limits: ClosedRange<CGFloat>) -> CGFloat {
        min(max(width, limits.lowerBound), limits.upperBound)
    }

    /// `width` held to this player's limits.
    public func clamp(_ width: CGFloat) -> CGFloat { Self.clamp(width, to: limits) }

    /// The width a grip at `corner`, dragged by `translation` from a player
    /// `start` wide, asks for (before `clamp`). Down grows it and up
    /// shrinks it, out to the grip's side grows it and in shrinks it, by
    /// the width it adds (half of it under big, which grows from its
    /// middle) across and the height down, at the frame's aspect; the drag
    /// is read along that diagonal, so a hand off it still resizes
    /// smoothly. The player's docked corner stays where it is.
    public func width(dragging corner: Corner, from start: CGFloat, by translation: CGPoint) -> CGFloat {
        let across: CGFloat = (isBig ? 0.5 : 1) * (corner.isLeft ? -1 : 1)
        let down: CGFloat = (corner.isTop ? -1 : 1) / Metrics.aspect
        return start + (translation.x * across + translation.y * down) / (across * across + down * down)
    }

    /// The size shown over the picture's middle while a grip is dragged:
    /// `text` measured, padded, never wider than the picture.
    public func badge(_ text: CGSize) -> CGRect {
        typealias M = Metrics
        let width = min(picture.width - 2 * M.gap, text.width + 2 * M.badgePaddingH)
        let height = text.height + 2 * M.badgePaddingV
        return CGRect(x: (picture.midX - width / 2).rounded(), y: (picture.midY - height / 2).rounded(), width: max(0, width), height: height)
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

    /// How far the big player pushes the chat's content down from
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
