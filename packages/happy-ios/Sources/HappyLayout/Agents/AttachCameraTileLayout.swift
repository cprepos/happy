import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The attach menu's live camera cell, measured as Telegram's
/// (`TGAttachmentCameraView`, `MediaPickerScreen`):
///
///     ┌──────────[📷]┐   the glyph 3 in from the top right, a pixel
///     │              │   higher than that
///     │   the live   │
///     │   preview    │   a full-screen camera's picture (the screen's
///     │              │   width, 16:9 tall) scaled to fill the cell,
///     │              │   centred, the rest cropped
///     └──────────────┘
public struct AttachCameraTileLayout: Equatable, Sendable {
    public enum Metrics {
        public static let glyph: CGFloat = 30
        public static let glyphInset: CGFloat = 3
        /// A full-screen camera's height for its width (`1.77778`).
        public static let previewAspect: CGFloat = 1.77778
    }

    /// The camera's glyph, in the cell.
    public let glyph: CGRect
    /// The preview at its own size: a full-screen camera's picture.
    public let previewSize: CGSize
    /// Where the preview's middle sits, in the cell.
    public let previewCenter: CGPoint
    /// How much the preview is scaled to fill the cell.
    public let previewScale: CGFloat

    /// - Parameters:
    ///   - size: the cell's.
    ///   - screenWidth: the screen's shorter side, its width upright.
    ///   - scale: the screen's pixels per point.
    public init(size: CGSize, screenWidth: CGFloat, scale: CGFloat) {
        let pixel = scale > 0 ? 1 / scale : 0
        let side = Metrics.glyph
        glyph = CGRect(x: size.width - side - Metrics.glyphInset, y: Metrics.glyphInset - pixel, width: side, height: side)

        let tall = scale > 0 ? (screenWidth * Metrics.previewAspect * scale).rounded(.down) / scale : screenWidth * Metrics.previewAspect
        previewSize = CGSize(width: screenWidth, height: tall)
        previewCenter = CGPoint(x: size.width / 2, y: size.height / 2)
        previewScale = screenWidth > 0 && tall > 0 ? max(size.width / screenWidth, size.height / tall) : 1
    }

    /// The preview's frame in the cell once scaled.
    public var preview: CGRect {
        let width = previewSize.width * previewScale
        let height = previewSize.height * previewScale
        return CGRect(x: previewCenter.x - width / 2, y: previewCenter.y - height / 2, width: width, height: height)
    }
}
