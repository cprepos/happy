import Foundation
import HappyLayout
import XCTest

final class PullRefreshLayoutTests: XCTestCase {
    func testPullingPastTheThresholdArmsOnceAndLettingGoRefreshes() {
        var pull = PullRefreshLayout()
        XCTAssertNil(pull.scrolled(overscroll: 32, tracking: true))
        XCTAssertEqual(pull.state, .pulling(progress: 0.5))
        XCTAssertEqual(pull.scrolled(overscroll: 64, tracking: true), .armed)
        XCTAssertNil(pull.scrolled(overscroll: 80, tracking: true), "armed taps once")
        XCTAssertEqual(pull.state, .armed)
        XCTAssertEqual(pull.released(), .beginRefresh)
        XCTAssertEqual(pull.state, .refreshing)
        XCTAssertEqual(pull.heldInset, PullRefreshMetrics.heldInset)
    }

    func testLettingGoShortOfTheThresholdDoesNothing() {
        var pull = PullRefreshLayout()
        pull.scrolled(overscroll: 50, tracking: true)
        XCTAssertNil(pull.released())
        XCTAssertEqual(pull.state, .idle)
        XCTAssertEqual(pull.heldInset, 0)
    }

    func testPullingBackUnderTheThresholdDisarms() {
        var pull = PullRefreshLayout()
        pull.scrolled(overscroll: 70, tracking: true)
        XCTAssertEqual(pull.state, .armed)
        pull.scrolled(overscroll: 16, tracking: true)
        XCTAssertEqual(pull.state, .pulling(progress: 0.25))
        XCTAssertNil(pull.released())
        XCTAssertEqual(pull.state, .idle)
    }

    func testABounceWithNoOneHoldingNeverArms() {
        var pull = PullRefreshLayout()
        XCTAssertNil(pull.scrolled(overscroll: 120, tracking: false))
        XCTAssertEqual(pull.state, .idle)
    }

    func testDisabledListNeverArms() {
        var pull = PullRefreshLayout()
        XCTAssertNil(pull.scrolled(overscroll: 100, tracking: true, enabled: false))
        XCTAssertEqual(pull.state, .idle)
        pull.scrolled(overscroll: 100, tracking: true)
        XCTAssertEqual(pull.state, .armed)
        XCTAssertNil(pull.released(enabled: false), "paging began before the finger lifted")
        XCTAssertEqual(pull.state, .idle)
    }

    func testIndirectInputNeedsALongerPull() {
        var pull = PullRefreshLayout(input: .indirect)
        XCTAssertEqual(pull.threshold, 90)
        XCTAssertNil(pull.scrolled(overscroll: 64, tracking: true))
        XCTAssertEqual(pull.state, .pulling(progress: 64 / 90))
        XCTAssertEqual(pull.scrolled(overscroll: 90, tracking: true), .armed)
    }

    func testRefreshingIgnoresScrollsUntilFinished() {
        var pull = PullRefreshLayout()
        pull.scrolled(overscroll: 70, tracking: true)
        pull.released()
        XCTAssertNil(pull.scrolled(overscroll: 90, tracking: true))
        XCTAssertNil(pull.released())
        XCTAssertEqual(pull.state, .refreshing)
        XCTAssertNil(pull.begin(), "one refresh at a time")
    }

    func testFinishingWhileStillPulledEndsThenSettles() {
        var pull = PullRefreshLayout()
        pull.scrolled(overscroll: 70, tracking: true)
        pull.released()
        pull.scrolled(overscroll: 20, tracking: false)
        XCTAssertEqual(pull.finished(), .endRefresh)
        XCTAssertEqual(pull.state, .ending)
        XCTAssertEqual(pull.heldInset, 0)
        pull.scrolled(overscroll: 8, tracking: false)
        XCTAssertEqual(pull.state, .ending)
        pull.scrolled(overscroll: 0, tracking: false)
        XCTAssertEqual(pull.state, .idle)
    }

    func testFinishingAtRestGoesStraightToIdle() {
        var pull = PullRefreshLayout()
        XCTAssertEqual(pull.begin(), .beginRefresh)
        XCTAssertEqual(pull.finished(), .endRefresh)
        XCTAssertEqual(pull.state, .idle)
        XCTAssertNil(pull.finished())
    }

    func testEndedSettlesAnEndingPull() {
        var pull = PullRefreshLayout()
        pull.scrolled(overscroll: 70, tracking: true)
        pull.released()
        pull.scrolled(overscroll: 30, tracking: false)
        pull.finished()
        pull.ended()
        XCTAssertEqual(pull.state, .idle)
    }

    func testProgressFollowsThePull() {
        var pull = PullRefreshLayout()
        XCTAssertEqual(pull.progress, 0)
        pull.scrolled(overscroll: 48, tracking: true)
        XCTAssertEqual(pull.progress, 0.75)
        pull.scrolled(overscroll: 100, tracking: true)
        XCTAssertEqual(pull.progress, 1)
    }

    func testTheSpinnerRidesThePullThenWaitsInTheHeldRoom() {
        var pull = PullRefreshLayout()
        XCTAssertFalse(pull.indicatorVisible)
        pull.scrolled(overscroll: 40, tracking: true)
        XCTAssertTrue(pull.indicatorVisible)
        // Centred in the 40 the pull shows above a content top at 100.
        XCTAssertEqual(pull.indicatorFrame(contentTop: 100, width: 390), CGRect(x: 185, y: 70, width: 20, height: 20))
        pull.scrolled(overscroll: 120, tracking: true)
        // No lower than the middle of the held room.
        XCTAssertEqual(pull.indicatorFrame(contentTop: 100, width: 390), CGRect(x: 185, y: 62, width: 20, height: 20))
        pull.released()
        pull.scrolled(overscroll: 0, tracking: false)
        XCTAssertEqual(pull.indicatorFrame(contentTop: 100, width: 390), CGRect(x: 185, y: 62, width: 20, height: 20))
        pull.finished()
        XCTAssertFalse(pull.indicatorVisible)
    }
}
