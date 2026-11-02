import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// InlineQuestionForm's dismiss X: a 32 square hung 4 past the form's top
/// right corner, taking touches 8 further out.
///
///          ┌ 32 ┐
///     ─────│ X  │  4 over the top
///     form └────┘  4 past the right
public struct InlineQuestionDismissLayout: Equatable, Sendable {
    public enum Metrics {
        public static let size: CGFloat = 32
        public static let overhang: CGFloat = 4
        public static let hitSlop: CGFloat = 8
        public static let glyphSize: CGFloat = 20
    }

    /// Where the glyph is drawn, centred in this square.
    public var glyph: CGRect
    public var hit: CGRect

    public init(form: CGRect) {
        glyph = CGRect(
            x: form.maxX - Metrics.size + Metrics.overhang,
            y: form.minY - Metrics.overhang,
            width: Metrics.size,
            height: Metrics.size
        )
        hit = glyph.insetBy(dx: -Metrics.hitSlop, dy: -Metrics.hitSlop)
    }
}

/// InlineQuestionForm's customInput: the field for a written answer, as tall
/// as its text or the placeholder, and never under the minimum.
///
///     ┌ 12 text or placeholder 12 ┐ radius 8, 10 above and below
///     └───────────────────────────┘ min 44
public struct InlineQuestionFieldLayout: Equatable, Sendable {
    public enum Metrics {
        public static let minHeight: CGFloat = 44
        public static let paddingH: CGFloat = 12
        public static let paddingV: CGFloat = 10
        public static let radius: CGFloat = 8
        public static let borderWidth: CGFloat = 1
    }

    public var size: CGSize
    /// In the field's own coordinates.
    public var placeholder: CGRect

    /// `text` is what the field holds, or the placeholder while it is empty.
    public init(width: CGFloat, text: Measurable, placeholder: Measurable) {
        let inner = max(0, width - Metrics.paddingH * 2)
        size = CGSize(
            width: width,
            height: max(Metrics.minHeight, text.height(fitting: inner) + Metrics.paddingV * 2)
        )
        self.placeholder = CGRect(
            x: Metrics.paddingH,
            y: Metrics.paddingV,
            width: inner,
            height: placeholder.height(fitting: inner)
        )
    }
}
