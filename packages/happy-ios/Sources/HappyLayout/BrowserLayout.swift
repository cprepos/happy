import Foundation

/// The browser screen. The page runs under the header and down to the
/// screen's bottom edge, under the home indicator: WebKit insets its
/// content by the safe area itself, so the frame never depends on the
/// header and nothing moves when it appears. The loading bar sits on the
/// header's bottom edge, and the error page covers the page whole.
public struct BrowserLayout: Equatable, Sendable {
    public let web: CGRect
    public let progress: CGRect
    public let failure: CGRect

    public init(size: CGSize, top: CGFloat) {
        let bounds = CGRect(origin: .zero, size: CGSize(width: max(0, size.width), height: max(0, size.height)))
        web = bounds
        failure = bounds
        progress = CGRect(x: 0, y: min(max(0, top), bounds.height), width: bounds.width, height: BrowserMetrics.progressHeight)
    }

    /// The filled part of a loading bar of `bar`'s size at `value`, from
    /// the leading edge.
    public static func progressFill(bar: CGSize, value: Double) -> CGRect {
        let value = value.isFinite ? min(max(value, 0), 1) : 0
        return CGRect(x: 0, y: 0, width: max(0, bar.width) * CGFloat(value), height: max(0, bar.height))
    }
}

/// The error page's glyph, title, words and button, one under another,
/// centred across and a little above the middle of the area the header
/// and the home indicator leave. A block taller than that area starts at
/// its top.
public struct BrowserFailureLayout: Equatable, Sendable {
    public let icon: CGRect
    public let title: CGRect
    public let message: CGRect
    public let button: CGRect

    /// The width the title and message are measured at.
    public static func textWidth(size: CGSize, insets: LayoutInsets) -> CGFloat {
        let free = size.width - insets.left - insets.right - BrowserMetrics.failureMargin * 2
        return max(0, min(BrowserMetrics.failureTextWidth, free))
    }

    public init(size: CGSize, insets: LayoutInsets, title: Measurable, message: Measurable, button: CGSize) {
        let width = Self.textWidth(size: size, insets: insets)
        let titleSize = title.size(fitting: width)
        let messageSize = message.size(fitting: width)
        let iconSide = BrowserMetrics.failureIcon
        let height = iconSide + BrowserMetrics.failureIconToTitle + titleSize.height
            + (messageSize.height > 0 ? BrowserMetrics.failureTitleToMessage + messageSize.height : 0)
            + BrowserMetrics.failureMessageToButton + button.height
        let freeTop = insets.top
        let freeHeight = max(0, size.height - insets.top - insets.bottom)
        let centred = freeTop + (freeHeight - height) / 2 - BrowserMetrics.failureLift
        let top = max(freeTop, centred)
        let midX = insets.left + (size.width - insets.left - insets.right) / 2

        icon = CGRect(x: midX - iconSide / 2, y: top, width: iconSide, height: iconSide)
        self.title = CGRect(x: midX - width / 2, y: icon.maxY + BrowserMetrics.failureIconToTitle, width: width, height: titleSize.height)
        let messageTop = self.title.maxY + (messageSize.height > 0 ? BrowserMetrics.failureTitleToMessage : 0)
        self.message = CGRect(x: midX - width / 2, y: messageTop, width: width, height: messageSize.height)
        let buttonWidth = min(button.width, width)
        self.button = CGRect(x: midX - buttonWidth / 2, y: self.message.maxY + BrowserMetrics.failureMessageToButton, width: buttonWidth, height: button.height)
    }
}

/// A live browser's card in a conversation (`LiveBrowserCardView`), across
/// the column at a fixed height: the browser's latest frame over the top,
/// its status pill in the frame's top-left corner, and the page's title
/// and address in the strip under it. A sentence instead of a frame (the
/// browser can't be reached, or is gone) sits centred in the frame's place.
public struct LiveBrowserCardLayout: Equatable, Sendable {
    public enum Metrics {
        public static let height: CGFloat = 236
        public static let radius: CGFloat = 12
        /// The strip under the frame.
        public static let footer: CGFloat = 56
        public static let padding: CGFloat = 12
        public static let titleHeight: CGFloat = 20
        public static let addressHeight: CGFloat = 16
        public static let pillInset: CGFloat = 8
        public static let pillHeight: CGFloat = 24
        public static let pillPadding: CGFloat = 10
        public static let dot: CGFloat = 8
        public static let dotGap: CGFloat = 6
        public static let messageInset: CGFloat = 24
    }

    public var frame: CGRect
    public var pill: CGRect
    public var dot: CGRect
    public var pillLabel: CGRect
    public var title: CGRect
    public var address: CGRect
    public var message: CGRect

    /// `pillLabel` is the status's one line, as measured; `message` wraps
    /// inside the frame, less its inset each side.
    public init(size: CGSize, pillLabel: CGSize, message: Measurable? = nil) {
        typealias M = Metrics
        let width = max(0, size.width)
        let height = max(0, size.height)
        frame = CGRect(x: 0, y: 0, width: width, height: max(0, height - M.footer))
        let labelWidth = min(ceil(pillLabel.width), max(0, width - 2 * M.pillInset - 2 * M.pillPadding - M.dot - M.dotGap))
        pill = CGRect(x: M.pillInset, y: M.pillInset, width: M.pillPadding + M.dot + M.dotGap + labelWidth + M.pillPadding, height: M.pillHeight)
        dot = CGRect(x: pill.minX + M.pillPadding, y: pill.midY - M.dot / 2, width: M.dot, height: M.dot)
        let labelHeight = min(ceil(pillLabel.height), M.pillHeight)
        self.pillLabel = CGRect(x: dot.maxX + M.dotGap, y: pill.midY - labelHeight / 2, width: labelWidth, height: labelHeight)
        let textWidth = max(0, width - 2 * M.padding)
        let top = frame.maxY + (M.footer - M.titleHeight - M.addressHeight) / 2
        title = CGRect(x: M.padding, y: top, width: textWidth, height: M.titleHeight)
        address = CGRect(x: M.padding, y: title.maxY, width: textWidth, height: M.addressHeight)
        let measure = max(0, width - 2 * M.messageInset)
        let messageHeight = min(message?.size(fitting: measure).height ?? 0, frame.height)
        self.message = CGRect(x: M.messageInset, y: frame.minY + (frame.height - messageHeight) / 2, width: measure, height: messageHeight)
    }
}
