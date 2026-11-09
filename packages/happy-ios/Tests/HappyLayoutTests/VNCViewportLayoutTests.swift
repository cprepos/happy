import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import HappyLayout
import XCTest

/// The native live-browser viewer's desktop on screen: fitted and centred,
/// pinched about a point, panned within its edges, turned with the phone,
/// and touches mapped to desktop pixels.
final class VNCViewportLayoutTests: XCTestCase {
    /// A 1920 × 1200 desktop on a phone held upright, under its bar.
    private let phone = CGSize(width: 402, height: 600)
    private let desktop = CGSize(width: 1920, height: 1200)

    func testTheDesktopFitsWholeAndCentred() {
        let viewport = VNCViewport(bounds: phone, content: desktop)
        XCTAssertEqual(viewport.fitScale, 0.209375)
        XCTAssertEqual(viewport.imageFrame, CGRect(x: 0, y: 174, width: 402, height: 251.25))
        XCTAssertFalse(viewport.isZoomed)
    }

    func testPinchingKeepsThePixelUnderTheFingers() {
        var viewport = VNCViewport(bounds: phone, content: desktop)
        let anchor = CGPoint(x: 201, y: 300)
        let under = viewport.toDesktop(anchor)
        viewport.zoom(by: 2, around: anchor)
        XCTAssertTrue(viewport.isZoomed)
        XCTAssertEqual(viewport.scale, 0.41875)
        // Wider than the view: edge to edge about the anchor. Still
        // shorter: centred, rounded down.
        XCTAssertEqual(viewport.imageFrame, CGRect(x: -201, y: 48, width: 804, height: 502.5))
        XCTAssertEqual(viewport.toDesktop(anchor).x, under.x, accuracy: 1e-9)

        viewport.zoom(by: 100, around: anchor)
        XCTAssertEqual(viewport.zoom, VNCViewport.maximumZoom)
        viewport.zoom(by: 0.001, around: anchor)
        XCTAssertEqual(viewport.zoom, 1)
        XCTAssertEqual(viewport.imageFrame, CGRect(x: 0, y: 174, width: 402, height: 251.25), "back where it fits")
        viewport.zoom(by: .nan, around: anchor)
        XCTAssertEqual(viewport.zoom, 1)
    }

    func testPanningStopsAtTheEdges() {
        var viewport = VNCViewport(bounds: phone, content: desktop)
        viewport.pan(by: CGPoint(x: 50, y: 50))
        XCTAssertEqual(viewport.imageFrame.origin, CGPoint(x: 0, y: 174), "nothing to pan at fit")
        viewport.zoom(by: 4, around: CGPoint(x: 201, y: 300))
        viewport.pan(by: CGPoint(x: 5000, y: 5000))
        XCTAssertEqual(viewport.imageFrame.origin, .zero)
        viewport.pan(by: CGPoint(x: -99999, y: -99999))
        let frame = viewport.imageFrame
        XCTAssertEqual(frame.maxX, phone.width, accuracy: 1e-9)
        XCTAssertEqual(frame.maxY, phone.height, accuracy: 1e-9)
        viewport.reset()
        XCTAssertEqual(viewport.imageFrame, CGRect(x: 0, y: 174, width: 402, height: 251.25))
    }

    func testTurningThePhoneKeepsTheZoomAndANewDesktopFitsAgain() {
        var viewport = VNCViewport(bounds: phone, content: desktop)
        let landscape = CGSize(width: 600, height: 402)
        viewport.resize(bounds: landscape, content: desktop)
        XCTAssertEqual(viewport.fitScale, 0.3125)
        XCTAssertEqual(viewport.imageFrame, CGRect(x: 0, y: 13, width: 600, height: 375))

        viewport.zoom(by: 2, around: CGPoint(x: 300, y: 201))
        let centre = viewport.toDesktop(CGPoint(x: 300, y: 201))
        viewport.resize(bounds: phone, content: desktop)
        XCTAssertEqual(viewport.zoom, 2)
        XCTAssertEqual(viewport.toDesktop(CGPoint(x: 201, y: 300)).x, centre.x, accuracy: 1e-6, "the middle stays the middle")

        viewport.resize(bounds: phone, content: CGSize(width: 1280, height: 800))
        XCTAssertEqual(viewport.zoom, 1, "a resized desktop shows whole")
        XCTAssertEqual(viewport.fitScale, 402.0 / 1280)
    }

    func testTouchesMapToDesktopPixels() {
        let viewport = VNCViewport(bounds: phone, content: desktop)
        XCTAssertEqual(viewport.toDesktop(CGPoint(x: 201, y: 174 + 125.625)), CGPoint(x: 960, y: 600))
        XCTAssertEqual(viewport.toView(CGPoint(x: 960, y: 600)), CGPoint(x: 201, y: 299.625))
        // In the letterbox: the desktop's edge, unless asked not to.
        XCTAssertEqual(viewport.toDesktop(CGPoint(x: 0, y: 0)), .zero)
        XCTAssertEqual(viewport.toDesktop(CGPoint(x: 402, y: 600)), CGPoint(x: 1919, y: 1199))
        XCTAssertLessThan(viewport.toDesktop(CGPoint(x: 0, y: 0), clamped: false).y, 0)
        XCTAssertEqual(viewport.desktopDistance(CGPoint(x: 0.209375 * 10, y: 0)).x, 10, accuracy: 1e-9)
    }

    func testRevealPansJustEnoughForTheTrackpadCursor() {
        var viewport = VNCViewport(bounds: phone, content: desktop)
        viewport.zoom(by: 4, around: CGPoint(x: 201, y: 300))
        let before = viewport.imageFrame.origin
        let shown = viewport.toDesktop(CGPoint(x: 201, y: 300))
        viewport.reveal(shown)
        XCTAssertEqual(viewport.imageFrame.origin, before, "already in view")

        viewport.reveal(CGPoint(x: 1900, y: 600))
        let cursor = viewport.toView(CGPoint(x: 1900, y: 600))
        XCTAssertEqual(cursor.x, phone.width - 24, accuracy: 1e-6, "inside the margin, no further")
        viewport.reveal(.zero)
        XCTAssertEqual(viewport.imageFrame.origin.x, 0, "as far as the edge allows")
    }
}
