import Foundation

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
