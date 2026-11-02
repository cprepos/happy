import Foundation
@testable import HappyCore
import XCTest

final class VoiceContextUpdatesTests: XCTestCase {
    /// `Session became focused:\s*(\S+)` in happy_voice/context.py, which this
    /// app must not change: what it captures becomes the agent's default target.
    func testTheFocusLineParsesToTheBareSessionId() throws {
        let line = VoiceContext.focusLine("session-1")
        let regex = try NSRegularExpression(pattern: #"Session became focused:\s*(\S+)"#)
        let match = try XCTUnwrap(regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)))
        XCTAssertEqual(Range(match.range(at: 1), in: line).map { String(line[$0]) }, "session-1")
    }
}
