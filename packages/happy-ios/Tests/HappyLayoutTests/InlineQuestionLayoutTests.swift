import XCTest
import CoreGraphics
@testable import HappyLayout

final class InlineQuestionLayoutTests: XCTestCase {
    func testDismissHangsOverTheFormsTopRightCorner() {
        let layout = InlineQuestionDismissLayout(form: CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(layout.glyph, CGRect(x: 282, y: 16, width: 32, height: 32))
        XCTAssertEqual(layout.hit, CGRect(x: 274, y: 8, width: 48, height: 48))
    }

    func testAShortFieldKeepsItsMinimumHeight() {
        let layout = InlineQuestionFieldLayout(
            width: 300,
            text: .fixed(width: 100, height: 17),
            placeholder: .fixed(width: 100, height: 17)
        )
        XCTAssertEqual(layout.size, CGSize(width: 300, height: 44))
        XCTAssertEqual(layout.placeholder, CGRect(x: 12, y: 10, width: 276, height: 17))
    }

    func testATallTextGrowsTheFieldByItsPadding() {
        let layout = InlineQuestionFieldLayout(
            width: 300,
            text: .fixed(width: 276, height: 68),
            placeholder: .fixed(width: 100, height: 17)
        )
        XCTAssertEqual(layout.size, CGSize(width: 300, height: 88))
        XCTAssertEqual(layout.placeholder, CGRect(x: 12, y: 10, width: 276, height: 17))
    }

    func testTheTextIsMeasuredInsideThePadding() {
        var fitted: [CGFloat] = []
        let text = Measurable { width in
            fitted.append(width)
            return CGSize(width: width, height: 17)
        }
        _ = InlineQuestionFieldLayout(width: 200, text: text, placeholder: .fixed(width: 0, height: 0))
        XCTAssertEqual(fitted, [176])
    }

    func testANarrowFieldNeverMeasuresANegativeWidth() {
        let layout = InlineQuestionFieldLayout(
            width: 10,
            text: .fixed(width: 0, height: 17),
            placeholder: .fixed(width: 0, height: 17)
        )
        XCTAssertEqual(layout.size, CGSize(width: 10, height: 44))
        XCTAssertEqual(layout.placeholder, CGRect(x: 12, y: 10, width: 0, height: 17))
    }
}
