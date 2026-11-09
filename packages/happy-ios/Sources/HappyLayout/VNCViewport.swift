import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the remote desktop sits in the VNC viewer: fitted whole into the
/// view at zoom 1 and centred, zoomed by pinching up to `maximumZoom`, and
/// panned while zoomed, never past its own edges. Maps between the view's
/// points and the desktop's pixels.
///
///     ┌ view ─────────────────────┐
///     │ ┌ image (fit × zoom) ───┐ │   zoom 1: centred, letterboxed
///     │ │ desktop 1920 × 1200   │ │   zoom > 1: larger than the view,
///     │ └───────────────────────┘ │   its edges kept to the view's
///     └───────────────────────────┘
public struct VNCViewport: Equatable, Sendable {
    /// At most this many times the fitted size.
    public static let maximumZoom: CGFloat = 8

    public private(set) var bounds: CGSize
    public private(set) var content: CGSize
    public private(set) var zoom: CGFloat = 1
    /// The image's top-left in the view.
    public private(set) var origin: CGPoint = .zero

    public init(bounds: CGSize, content: CGSize) {
        self.bounds = bounds
        self.content = content
        clamp()
    }

    /// View points per desktop pixel at zoom 1.
    public var fitScale: CGFloat {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / content.width, bounds.height / content.height)
    }

    /// View points per desktop pixel now.
    public var scale: CGFloat { fitScale * zoom }

    /// The desktop's image, in view points.
    public var imageFrame: CGRect {
        CGRect(origin: origin, size: CGSize(width: content.width * scale, height: content.height * scale))
    }

    public var isZoomed: Bool { zoom > 1.0001 }

    /// The view or the desktop changed size (rotation, a resize): the zoom
    /// stays, the centre of what showed stays where it can.
    public mutating func resize(bounds: CGSize, content: CGSize) {
        guard bounds != self.bounds || content != self.content else { return }
        let centre = toDesktop(CGPoint(x: self.bounds.width / 2, y: self.bounds.height / 2), clamped: false)
        let sameContent = content == self.content
        self.bounds = bounds
        self.content = content
        if !sameContent { zoom = 1 }
        origin = CGPoint(x: bounds.width / 2 - centre.x * scale, y: bounds.height / 2 - centre.y * scale)
        clamp()
    }

    /// Zooms by `factor` about `anchor` (view points): the desktop pixel
    /// under the anchor stays under it.
    public mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let pixel = toDesktop(anchor, clamped: false)
        zoom = min(Self.maximumZoom, max(1, zoom * factor))
        origin = CGPoint(x: anchor.x - pixel.x * scale, y: anchor.y - pixel.y * scale)
        clamp()
    }

    /// Moves the image by `translation` view points, kept in bounds.
    public mutating func pan(by translation: CGPoint) {
        origin.x += translation.x
        origin.y += translation.y
        clamp()
    }

    /// Back to the whole desktop.
    public mutating func reset() {
        zoom = 1
        clamp()
    }

    /// Keeps `point` (desktop pixels) in view, panning as little as it can,
    /// `margin` view points inside the edge: the trackpad's cursor.
    public mutating func reveal(_ point: CGPoint, margin: CGFloat = 24) {
        let view = toView(point)
        var shift = CGPoint.zero
        if view.x < margin { shift.x = margin - view.x } else if view.x > bounds.width - margin { shift.x = bounds.width - margin - view.x }
        if view.y < margin { shift.y = margin - view.y } else if view.y > bounds.height - margin { shift.y = bounds.height - margin - view.y }
        if shift != .zero { pan(by: shift) }
    }

    /// The image no smaller than the view along an axis covers it edge to
    /// edge; smaller, it is centred.
    private mutating func clamp() {
        let size = imageFrame.size
        if size.width <= bounds.width { origin.x = ((bounds.width - size.width) / 2).rounded(.down) }
        else { origin.x = min(0, max(bounds.width - size.width, origin.x)) }
        if size.height <= bounds.height { origin.y = ((bounds.height - size.height) / 2).rounded(.down) }
        else { origin.y = min(0, max(bounds.height - size.height, origin.y)) }
    }

    /// The desktop pixel under `point` (view points); `clamped`, kept on
    /// the desktop, so a touch in the letterbox lands on its edge.
    public func toDesktop(_ point: CGPoint, clamped: Bool = true) -> CGPoint {
        let scale = self.scale
        var pixel = CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
        if clamped {
            pixel.x = min(max(0, pixel.x), max(0, content.width - 1))
            pixel.y = min(max(0, pixel.y), max(0, content.height - 1))
        }
        return pixel
    }

    /// Where desktop pixel `pixel`'s top-left is, in view points.
    public func toView(_ pixel: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + pixel.x * scale, y: origin.y + pixel.y * scale)
    }

    /// A distance in view points as desktop pixels.
    public func desktopDistance(_ points: CGPoint) -> CGPoint {
        CGPoint(x: points.x / scale, y: points.y / scale)
    }
}
