import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the live browser's approval bar goes: the action the agent waits
/// on, its summary, the agent's reason and the page, Deny and Approve.
/// Never over the picture's place, and nothing else moves for it.
///
///     phone upright, full screen     elsewhere in full screen   the chat
///     ┌ header ─────────┐            ┌──────────────────────┐   │          │
///     ├ picture ────────┤            │ page                 │   │ ┌ bar ─┐ │
///     │                 │            │                      │   │ └──────┘ │
///     ├─────────────────┤            │  ┌ bar, compact ──┐  │   ├ status ──┤
///     │ ┌ bar ────────┐ │            │  └────────────────┘  │   ├ card ────┤
///     │ └─────────────┘ │            └──────────────────────┘
///     └─────────────────┘
///
/// A phone upright, the agent driving, it stands in the room under the
/// picture, 12 in from the safe area's sides. Sideways, on an iPad or a
/// Mac, or while the person holds the browser (noVNC or the native viewer
/// has the whole page), it floats over the bottom, compact (Deny and
/// Approve beside the text where it is wide enough), centred clear of the
/// phone's side strip and no
/// wider than `Metrics.maxWidth`, 12 above the safe area, or above
/// `floor`, the top of the held page's own controls at the bottom (the
/// native viewer's bar, the keyboard's key row over it, noVNC's keyboard
/// button), where it is higher. In the chat it stands on the status line
/// (`anchor`), as wide as the composer card.
///
/// The bar's height is what its content measures at `width`, held to
/// `maxHeight`, or to `expandedMaxHeight` once Details shows every line
/// and the script (`frame(height:expanded:)`). Inside, `Content` places
/// the summary, the lines, Details and the buttons.
public struct LiveBrowserApprovalBarLayout: Equatable, Sendable {
    public enum Metrics {
        /// From the screen's safe area, and from the picture above it.
        public static let margin: CGFloat = 12
        /// Over the chat's status line.
        public static let gap: CGFloat = 8
        /// A floating bar is no wider than this.
        public static let maxWidth: CGFloat = 520
        /// The least room under the picture the bar stands in; less, and
        /// it floats over the bottom instead.
        public static let minRoom: CGFloat = 72
        /// What noVNC's page keeps at its bottom for its keyboard button,
        /// which is inside the page where nothing here can measure it.
        public static let noVNCReserve: CGFloat = 56
        /// A floating bar's tallest, and the chat's.
        public static let overlayMaxHeight: CGFloat = 132
        public static let chatMaxHeight: CGFloat = 168
        /// Any bar's tallest with Details open, where there is the room.
        public static let expandedMaxHeight: CGFloat = 360
        /// The content's padding inside the bar, and its corner.
        public static let padding: CGFloat = 12
        public static let radius: CGFloat = 14
        /// Deny's and Approve's height; a compact bar this wide or wider
        /// puts them on the summary's row.
        public static let button: CGFloat = 36
        public static let inlineWidth: CGFloat = 400
        /// The icon's column, and the text's start after it.
        public static let icon = CGSize(width: 18, height: 20)
        public static let textInset: CGFloat = 24
        /// Between the summary and the lines, and between lines.
        public static let lineGap: CGFloat = 4
        /// Over the buttons' row, and between Deny and Approve.
        public static let rowGap: CGFloat = 10
        public static let buttonGap: CGFloat = 8
        /// Details' row under the text, where the buttons are inline.
        public static let toggle: CGFloat = 24
        /// The script's text inside its block.
        public static let codeInset: CGFloat = 8
        /// The agent's reason shows this many lines before Details.
        public static let leadLines = 3
        /// A button is never narrower than this.
        public static let minButton: CGFloat = 76
    }

    public enum Place: Equatable, Sendable {
        /// The full screen: the picture's frame (the page's, where it is
        /// the whole screen), whether this is a phone, whether the person
        /// holds the browser, a sideways phone's column of controls, and
        /// the top of the controls at the bottom, if any.
        case fullScreen(picture: CGRect, phone: Bool, held: Bool, strip: CGRect?, floor: CGFloat? = nil)
        /// The chat: the composer card, and the top of what stands on it
        /// (the status line, the voice strip or the keyboard).
        case chat(card: CGRect, anchor: CGFloat)
    }

    public enum Mode: Equatable, Sendable {
        /// In the room under a phone's upright picture.
        case belowPicture
        /// Over the bottom of the full screen, compact.
        case overlay
        /// Over the chat's composer card.
        case chat
    }

    public var mode: Mode
    public var x: CGFloat
    public var width: CGFloat
    /// The bar's top under the picture; its bottom elsewhere.
    public var edge: CGFloat
    public var maxHeight: CGFloat
    /// With Details open: taller where there is the room, never over
    /// what `maxHeight` keeps clear (the picture, the held page's
    /// controls, the safe area).
    public var expandedMaxHeight: CGFloat
    /// Floating over the full screen's bottom.
    public var compact: Bool

    public init(size: CGSize, safeArea: LayoutInsets, place: Place) {
        typealias M = Metrics
        switch place {
        case let .fullScreen(picture, phone, held, strip, floor):
            let top = picture.maxY + M.margin
            let bottom = min(size.height - safeArea.bottom, floor ?? .infinity)
            let room = bottom - M.margin - top
            if phone, !held, strip == nil, room >= M.minRoom {
                mode = .belowPicture
                x = safeArea.left + M.margin
                width = max(0, size.width - safeArea.left - safeArea.right - 2 * M.margin)
                edge = top
                maxHeight = room
                expandedMaxHeight = room
                compact = false
            } else {
                let left = safeArea.left
                let right = strip?.minX ?? (size.width - safeArea.right)
                let span = max(0, right - left - 2 * M.margin)
                mode = .overlay
                width = min(M.maxWidth, span)
                x = (left + (right - left - width) / 2).rounded()
                edge = bottom - M.margin
                maxHeight = max(0, min(M.overlayMaxHeight, edge - safeArea.top - M.margin))
                expandedMaxHeight = max(0, min(M.expandedMaxHeight, edge - safeArea.top - M.margin))
                compact = true
            }
        case let .chat(card, anchor):
            mode = .chat
            x = card.minX
            width = card.width
            edge = anchor - M.gap
            maxHeight = max(0, min(M.chatMaxHeight, edge - safeArea.top - M.gap))
            expandedMaxHeight = max(0, min(M.expandedMaxHeight, edge - safeArea.top - M.gap))
            compact = false
        }
    }

    /// noVNC's `floor`: its keyboard button's reserve over the bottom of
    /// its page, where the page reaches the safe area's bottom (an iPad,
    /// a sideways phone); nil where the page ends above it (a phone
    /// upright, its picture's height), the bottom being clear there.
    public static func noVNCFloor(size: CGSize, safeArea: LayoutInsets, page: CGRect) -> CGFloat? {
        let bottom = size.height - safeArea.bottom
        return page.maxY >= bottom ? bottom - Metrics.noVNCReserve : nil
    }

    /// Yolo's "Yolo mode enabled" in the full screen: a line under the
    /// header (and noVNC's address row), `top` being where they end, 12
    /// in from the safe area's sides and clear of a sideways phone's
    /// column; `height` its text's. The approval bar's notices still
    /// show where the bar goes.
    public static func yoloLine(size: CGSize, safeArea: LayoutInsets, top: CGFloat, strip: CGRect?, height: CGFloat) -> CGRect {
        typealias M = Metrics
        let left = safeArea.left + M.margin
        let right = (strip?.minX ?? (size.width - safeArea.right)) - M.margin
        return CGRect(x: left, y: max(top, safeArea.top) + 6, width: max(0, right - left), height: height)
    }

    /// The bar's tallest, Details open or not.
    public func maxHeight(expanded: Bool) -> CGFloat { expanded ? max(maxHeight, expandedMaxHeight) : maxHeight }

    /// The bar's frame for content that measures `height` at `width`.
    public func frame(height: CGFloat, expanded: Bool = false) -> CGRect {
        let height = min(max(0, height), maxHeight(expanded: expanded))
        let y = mode == .belowPicture ? edge : edge - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Deny and Approve on the summary's row: a compact bar wide enough.
    public var inline: Bool { compact && width >= Metrics.inlineWidth }

    /// Whatever stands on the bar's top: a bottom-corner player keeps
    /// above it, as it keeps above the status line.
    public func anchor(height: CGFloat, expanded: Bool = false) -> CGFloat { frame(height: height, expanded: expanded).minY }
}

extension LiveBrowserApprovalBarLayout {
    /// Inside the bar, `width` wide and never taller than `maxHeight`:
    ///
    ///     ┌──────────────────────────────────┐
    ///     │ ◇ summary                        │
    ///     │   ┌ body (scrolls) ────────────┐ │
    ///     │   │ Agent says: … (3 lines)    │ │
    ///     │   │ Page: …                    │ │
    ///     │   └────────────────────────────┘ │
    ///     │   Details         [Deny][Approve]│
    ///     └──────────────────────────────────┘
    ///
    /// The body is a stack of measured pieces, `lineGap` apart: the reason
    /// and the page; with Details open, every line and the script's
    /// block. It shows what fits under `maxHeight` and scrolls the rest;
    /// the summary and the buttons always show. Inline, Deny and Approve
    /// sit at the right, centred, and Details goes under the body.
    public struct Content: Equatable, Sendable {
        public var icon: CGRect
        public var summary: CGRect
        /// The body's window, and its pieces inside it, from its top.
        public var body: CGRect
        public var pieces: [CGRect]
        public var bodyHeight: CGFloat
        /// Details or Hide; nil where there is nothing more to show.
        public var toggle: CGRect?
        public var deny: CGRect
        public var approve: CGRect
        /// The bar's height.
        public var height: CGFloat

        /// The text's width beside the icon, and beside the buttons where
        /// they are inline: what the summary and the pieces measure at.
        public static func textWidth(width: CGFloat, inline: Bool, asking: Bool, deny: CGFloat, approve: CGFloat) -> CGFloat {
            typealias M = LiveBrowserApprovalBarLayout.Metrics
            let buttons = inline && asking ? buttonsWidth(deny: deny, approve: approve) + M.padding : 0
            return max(0, width - 2 * M.padding - M.textInset - buttons)
        }

        /// A button's width for what it measures: never under `minButton`.
        public static func buttonWidth(_ measured: CGFloat) -> CGFloat {
            max(LiveBrowserApprovalBarLayout.Metrics.minButton, measured.rounded(.up))
        }

        static func buttonsWidth(deny: CGFloat, approve: CGFloat) -> CGFloat {
            buttonWidth(deny) + Metrics.buttonGap + buttonWidth(approve)
        }

        /// The script's text in its block.
        public static func code(in block: CGRect) -> CGRect {
            block.insetBy(dx: Metrics.codeInset, dy: Metrics.codeInset)
        }

        /// The script's block for text that measures `height`.
        public static func codeBlock(text height: CGFloat) -> CGFloat {
            height > 0 ? height + 2 * Metrics.codeInset : 0
        }

        /// `summary` and `pieces` are heights measured at `textWidth`,
        /// `deny`, `approve` and `toggle` widths as measured (`toggle` nil
        /// for none); `asking` is false for a notice, which has no buttons.
        public init(width: CGFloat, maxHeight: CGFloat, inline: Bool, asking: Bool, summary: CGFloat, pieces: [CGFloat],
                    deny: CGFloat, approve: CGFloat, toggle: CGFloat?) {
            typealias M = LiveBrowserApprovalBarLayout.Metrics
            let inline = inline && asking
            let text = Self.textWidth(width: width, inline: inline, asking: asking, deny: deny, approve: approve)
            let textX = M.padding + M.textInset
            let summaryHeight = max(M.icon.height, summary.rounded(.up))
            var y: CGFloat = 0
            var stacked: [CGRect] = []
            for piece in pieces where piece > 0 {
                if !stacked.isEmpty { y += M.lineGap }
                stacked.append(CGRect(x: 0, y: y, width: text, height: piece.rounded(.up)))
                y += piece.rounded(.up)
            }
            self.pieces = stacked
            bodyHeight = y
            let lead = bodyHeight > 0 ? M.lineGap : 0
            let toggleWidth = toggle.map { min(text, $0.rounded(.up)) }
            let approveWidth = Self.buttonWidth(approve), denyWidth = Self.buttonWidth(deny)
            let shown: CGFloat, top: CGFloat, total: CGFloat
            if inline {
                let toggleRow = toggleWidth != nil ? M.lineGap + M.toggle : 0
                let room = maxHeight - 2 * M.padding - summaryHeight - lead - toggleRow
                shown = max(0, min(bodyHeight, room))
                let block = summaryHeight + (bodyHeight > 0 ? lead + shown : 0) + toggleRow
                total = 2 * M.padding + max(block, M.button)
                top = M.padding + max(0, (M.button - block) / 2)
            } else {
                let row = asking || toggleWidth != nil ? M.rowGap + M.button : 0
                let room = maxHeight - 2 * M.padding - summaryHeight - row - lead
                shown = max(0, min(bodyHeight, room))
                total = 2 * M.padding + summaryHeight + (bodyHeight > 0 ? lead + shown : 0) + row
                top = M.padding
            }
            height = total
            icon = CGRect(origin: CGPoint(x: M.padding, y: top), size: M.icon)
            self.summary = CGRect(x: textX, y: top, width: text, height: summaryHeight)
            let body = CGRect(x: textX, y: top + summaryHeight + lead, width: text, height: shown)
            self.body = body
            let buttonY = inline ? (total - M.button) / 2 : total - M.padding - M.button
            let approveFrame = CGRect(x: width - M.padding - approveWidth, y: buttonY, width: approveWidth, height: M.button)
            self.approve = approveFrame
            self.deny = CGRect(x: approveFrame.minX - M.buttonGap - denyWidth, y: buttonY, width: denyWidth, height: M.button)
            self.toggle = toggleWidth.map { toggleWidth in
                inline ? CGRect(x: textX, y: body.maxY + M.lineGap, width: toggleWidth, height: M.toggle)
                    : CGRect(x: textX, y: buttonY, width: toggleWidth, height: M.button)
            }
        }
    }
}
