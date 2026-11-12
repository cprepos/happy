import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the live browser's approval bar goes: the action the agent waits
/// on, its summary, Deny and Approve. Never over the picture's place, and
/// nothing else moves for it.
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
/// picture, 12 in from the safe area's sides, its details shown. Sideways,
/// on an iPad or a Mac, or while the person holds the browser (noVNC or
/// the native viewer has the whole page), it floats over the bottom,
/// compact (no details), centred clear of the phone's side strip and no
/// wider than `Metrics.maxWidth`, 12 above the safe area. In the chat it
/// stands on the status line (`anchor`), as wide as the composer card.
///
/// The bar's height is what its content measures at `width`, held to
/// `maxHeight` (`frame(height:)`).
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
        /// A floating bar's tallest, and the chat's.
        public static let overlayMaxHeight: CGFloat = 132
        public static let chatMaxHeight: CGFloat = 168
        /// The content's padding inside the bar, and its corner.
        public static let padding: CGFloat = 12
        public static let radius: CGFloat = 14
        /// Deny's and Approve's height; a compact bar this wide or wider
        /// puts them on the summary's row.
        public static let button: CGFloat = 36
        public static let inlineWidth: CGFloat = 400
    }

    public enum Place: Equatable, Sendable {
        /// The full screen: the picture's frame (the page's, where it is
        /// the whole screen), whether this is a phone, whether the person
        /// holds the browser, and a sideways phone's column of controls.
        case fullScreen(picture: CGRect, phone: Bool, held: Bool, strip: CGRect?)
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
    /// The approval's details show (not compact).
    public var showsDetails: Bool

    public init(size: CGSize, safeArea: LayoutInsets, place: Place) {
        typealias M = Metrics
        switch place {
        case let .fullScreen(picture, phone, held, strip):
            let top = picture.maxY + M.margin
            let room = size.height - safeArea.bottom - M.margin - top
            if phone, !held, strip == nil, room >= M.minRoom {
                mode = .belowPicture
                x = safeArea.left + M.margin
                width = max(0, size.width - safeArea.left - safeArea.right - 2 * M.margin)
                edge = top
                maxHeight = room
                showsDetails = true
            } else {
                let left = safeArea.left
                let right = strip?.minX ?? (size.width - safeArea.right)
                let span = max(0, right - left - 2 * M.margin)
                mode = .overlay
                width = min(M.maxWidth, span)
                x = (left + (right - left - width) / 2).rounded()
                edge = size.height - safeArea.bottom - M.margin
                maxHeight = max(0, min(M.overlayMaxHeight, edge - safeArea.top - M.margin))
                showsDetails = false
            }
        case let .chat(card, anchor):
            mode = .chat
            x = card.minX
            width = card.width
            edge = anchor - M.gap
            maxHeight = max(0, min(M.chatMaxHeight, edge - safeArea.top - M.gap))
            showsDetails = true
        }
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

    /// The bar's frame for content that measures `height` at `width`.
    public func frame(height: CGFloat) -> CGRect {
        let height = min(max(0, height), maxHeight)
        let y = mode == .belowPicture ? edge : edge - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Deny and Approve on the summary's row: a compact bar wide enough.
    public var inline: Bool { !showsDetails && width >= Metrics.inlineWidth }

    /// Whatever stands on the bar's top: a bottom-corner player keeps
    /// above it, as it keeps above the status line.
    public func anchor(height: CGFloat) -> CGFloat { frame(height: height).minY }
}
