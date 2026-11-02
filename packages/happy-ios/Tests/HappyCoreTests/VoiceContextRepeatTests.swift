@testable import HappyCore
import XCTest

/// The cases of happy-app's contextRepeat.test.ts.
final class VoiceContextRepeatTests: XCTestCase {
    func testDropsAnIdenticalRepeatInsideTheWindow() {
        var filter = VoiceContextRepeatFilter(window: 2)
        XCTAssertFalse(filter.isRepeat("Read(file.ts)", now: 1))
        XCTAssertTrue(filter.isRepeat("Read(file.ts)", now: 1.001))
    }

    func testLetsTheSameTextThroughOnceTheWindowHasPassed() {
        var filter = VoiceContextRepeatFilter(window: 2)
        XCTAssertFalse(filter.isRepeat("Read(file.ts)", now: 1))
        XCTAssertFalse(filter.isRepeat("Read(file.ts)", now: 3.001))
    }

    func testDoesNotConfuseDistinctUpdatesThatInterleave() {
        var filter = VoiceContextRepeatFilter(window: 2)
        XCTAssertFalse(filter.isRepeat("a", now: 1))
        XCTAssertFalse(filter.isRepeat("b", now: 1.001))
        XCTAssertTrue(filter.isRepeat("a", now: 1.002))
        XCTAssertTrue(filter.isRepeat("b", now: 1.003))
    }

    func testRemembersOnlyTheMostRecentFew() {
        var filter = VoiceContextRepeatFilter(window: 2, keep: 2)
        _ = filter.isRepeat("a", now: 1)
        _ = filter.isRepeat("b", now: 1.001)
        _ = filter.isRepeat("c", now: 1.002)
        XCTAssertFalse(filter.isRepeat("a", now: 1.003), "fell off a two-slot memory")
        XCTAssertTrue(filter.isRepeat("c", now: 1.004))
    }

    /// happy-app resets its filter when a call starts; here each call has its own.
    func testANewCallForgetsEverything() {
        var filter = VoiceContextRepeatFilter(window: 2)
        XCTAssertFalse(filter.isRepeat("a", now: 1))
        filter = VoiceContextRepeatFilter(window: 2)
        XCTAssertFalse(filter.isRepeat("a", now: 1.001))
    }
}
