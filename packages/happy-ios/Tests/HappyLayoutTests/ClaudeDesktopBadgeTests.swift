import Foundation
@testable import HappyLayout
import XCTest

/// Claude Desktop's avatar badge: Claude's mark with a display glyph on a
/// plate, the plate inside the circle, and the mark alone where the display
/// would not read.
final class ClaudeDesktopBadgeTests: XCTestCase {
    func testTheDisplaySitsOnAPlateInsideTheCircle() throws {
        let circle: CGFloat = 25 // a 60pt home row avatar's badge
        let badge = AvatarBadge.desktopBadge(circle: circle)
        let plate = try XCTUnwrap(badge.plate)
        let display = try XCTUnwrap(badge.display)
        XCTAssertEqual(badge.mark, CGRect(x: 3, y: 3, width: 15, height: 15))
        XCTAssertEqual(plate, CGRect(x: 10, y: 10, width: 13, height: 13))
        XCTAssertEqual(display, CGRect(x: 12, y: 12, width: 9, height: 9))
        let farthest = hypot(plate.midX - circle / 2, plate.midY - circle / 2) + plate.width / 2
        XCTAssertLessThanOrEqual(farthest, circle / 2)
    }

    func testASmallBadgeIsClaudesMarkAlone() {
        let small = AvatarBadge.desktopBadge(circle: 12) // a 28pt header avatar's badge
        XCTAssertNil(small.plate)
        XCTAssertNil(small.display)
        XCTAssertEqual(small.mark, CGRect(x: 1, y: 1, width: 10, height: 10))
    }
}
