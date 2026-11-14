import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Our plugins' additions to `AvatarBadge`: Claude Desktop's badge, kept
/// out of AvatarBadge.swift so upstream merges do not conflict there.
extension AvatarBadge {
    /// Below this badge circle (points) Claude Desktop's display would not
    /// read, so its badge is Claude's mark alone, as Claude Code's is.
    public static let desktopMinimumCircle: CGFloat = 16

    /// Claude Desktop's badge, in the circle's own coordinates: Claude's
    /// mark up and to the left, and a display glyph on a plate of the
    /// badge's colour over the mark's lower right, cut out of it. The plate
    /// stays inside the circle. A circle under `desktopMinimumCircle` gets
    /// Claude Code's centred mark and no display.
    public static func desktopBadge(circle side: CGFloat) -> (mark: CGRect, plate: CGRect?, display: CGRect?) {
        guard side >= desktopMinimumCircle else {
            let mark = (side * badgeGlyphRatio(harness: "claude") / 0.42).rounded()
            return (CGRect(x: (side - mark) / 2, y: (side - mark) / 2, width: mark, height: mark), nil, nil)
        }
        func square(centre: CGFloat, side: CGFloat) -> CGRect {
            let origin = (centre - side / 2).rounded()
            return CGRect(x: origin, y: origin, width: side, height: side)
        }
        let mark = square(centre: side * 0.42, side: (side * 0.6).rounded())
        let plate = square(centre: side * 0.67, side: (side * 0.5).rounded())
        let display = (plate.width * 0.72).rounded()
        let inset = ((plate.width - display) / 2).rounded()
        return (mark, plate, CGRect(x: plate.minX + inset, y: plate.minY + inset, width: display, height: display))
    }
}
