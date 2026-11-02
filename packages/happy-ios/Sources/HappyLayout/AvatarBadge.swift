import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where a session avatar's harness badge goes (components/Avatar.tsx). A
/// session without a picture wears its `AvatarPlaceholder`, not happy-app's
/// generated faces.
public enum AvatarBadge {
    /// `harnessBadgeSizes`: each harness mark keeps clear air inside the
    /// circle. Happy Agent's square "H" needs the most.
    public static func badgeGlyphRatio(harness: String) -> CGFloat {
        switch harness {
        case "rig": 0.26
        case "codex": 0.3
        case "claude": 0.34
        default: 0.42
        }
    }

    /// Avatar.tsx `harnessBadgeSizes`: the circle in the bottom-right corner
    /// that names the harness, and the glyph inside it.
    public static func badge(avatarSize size: CGFloat, glyphRatio: CGFloat) -> (circle: CGRect, glyph: CGRect) {
        let circle = (size * 0.42).rounded()
        let glyph = (size * glyphRatio).rounded()
        // bottom: -2, right: -2
        let frame = CGRect(x: size + 2 - circle, y: size + 2 - circle, width: circle, height: circle)
        return (frame, CGRect(x: frame.midX - glyph / 2, y: frame.midY - glyph / 2, width: glyph, height: glyph))
    }

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
