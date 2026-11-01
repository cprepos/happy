import Foundation
@testable import HappyCore
import XCTest

/// The cases of happy-app's voicePlaybackScheduler.test.ts.
final class VoicePlaybackSchedulerTests: XCTestCase {
    private let rate = 24000.0
    private let size = 480

    private func frame(_ value: Int16 = 8192) -> [Int16] { [Int16](repeating: value, count: size) }

    private func scheduler() -> VoicePlaybackScheduler { VoicePlaybackScheduler(rate: rate, contextRate: rate) }

    private func feed(_ scheduler: inout VoicePlaybackScheduler, start: Double, count: Int, interval: Double = 0.02) -> (chunks: [VoicePlaybackChunk], now: Double) {
        var chunks: [VoicePlaybackChunk] = []
        var now = start
        for _ in 0..<count {
            chunks.append(scheduler.push(frame(), now: now))
            now += interval
        }
        return (chunks, now)
    }

    private func startFrame(_ when: Double) -> Int { Int((when * rate).rounded(.down)) }

    func testStartsStartMsAheadAndSchedulesFramesBackToBack() {
        var scheduler = scheduler()
        let chunks = feed(&scheduler, start: 1, count: 10).chunks
        XCTAssertTrue(chunks[0].restart)
        XCTAssertEqual(startFrame(chunks[0].when), Int((1.04 * rate).rounded(.up)))
        for i in 1..<chunks.count {
            XCTAssertFalse(chunks[i].restart)
            XCTAssertEqual(startFrame(chunks[i].when) - startFrame(chunks[i - 1].when), size)
            XCTAssertEqual(chunks[i].samples.count, size)
        }
    }

    func testFadesInOnRestartAndPassesSteadyAudioThroughUntouched() {
        var scheduler = scheduler()
        let chunks = feed(&scheduler, start: 0, count: 2).chunks
        let first = chunks[0].samples
        XCTAssertEqual(first[0], 0)
        XCTAssertEqual(first[48], 0.125, accuracy: 1e-5)
        XCTAssertLessThan(first[47], first[48])
        XCTAssertEqual(first[96], 0.25)
        XCTAssertTrue(chunks[1].samples.allSatisfy { $0 == 0.25 })
    }

    func testGrowsTheTargetOnAJitterUnderrunNotOnAPauseInSpeech() {
        var scheduler = scheduler()
        _ = feed(&scheduler, start: 0, count: 5)
        // Scheduled audio ends at 0.04 + 0.1 = 0.14; the next frame comes 30 ms after that.
        var now = 0.17
        let late = scheduler.push(frame(), now: now)
        XCTAssertTrue(late.restart)
        XCTAssertEqual(scheduler.stats(now: now).targetMs, 60, accuracy: 0.01)
        XCTAssertEqual(scheduler.stats(now: now).underruns, 1)
        XCTAssertEqual(startFrame(late.when), Int(((now + 0.06) * rate).rounded(.up)))

        // A long pause: counted, but the target stays.
        now = feed(&scheduler, start: now + 0.02, count: 3).now
        _ = scheduler.push(frame(), now: now + 2)
        XCTAssertEqual(scheduler.stats(now: now + 2).targetMs, 60, accuracy: 0.01)
        XCTAssertEqual(scheduler.stats(now: now + 2).underruns, 2)
    }

    func testNeverGrowsPastMaxAndShrinksBackAfterASmoothStretch() {
        var scheduler = scheduler()
        var now = 0.0
        for _ in 0..<10 {
            let chunk = scheduler.push(frame(), now: now)
            now = Double(startFrame(chunk.when) + size) / rate + 0.01 // always 10 ms late
        }
        XCTAssertEqual(scheduler.stats(now: now).targetMs, 120, accuracy: 0.01)

        // 10 s of on-time frames: one shrink step.
        now = feed(&scheduler, start: now, count: 520).now
        XCTAssertEqual(scheduler.stats(now: now).targetMs, 110, accuracy: 0.01)
    }

    func testAFrameDueWithinTheGuardIsAnUnderrun() {
        var scheduler = scheduler()
        _ = scheduler.push(frame(), now: 0) // ends at 0.06
        XCTAssertTrue(scheduler.push(frame(), now: 0.055).restart)
    }

    func testAfterAFlushRestartsWithoutCountingAnUnderrun() {
        var scheduler = scheduler()
        let now = feed(&scheduler, start: 0, count: 5).now
        scheduler.flush()
        let chunk = scheduler.push(frame(), now: now)
        XCTAssertTrue(chunk.restart)
        XCTAssertEqual(startFrame(chunk.when), Int(((now + 0.04) * rate).rounded(.up)))
        XCTAssertEqual(scheduler.stats(now: now).underruns, 0)
        XCTAssertEqual(scheduler.stats(now: now).targetMs, 40, accuracy: 0.01)
    }

    func testDrainsExcessLatencyByPlayingSlightlyFastThenReturnsToNormal() {
        var scheduler = scheduler()
        // A burst of 15 frames at once (300 ms of audio), then real-time pacing.
        var now = 0.0
        for _ in 0..<15 { _ = scheduler.push(frame(), now: now) }
        var lengths: [Int] = []
        for _ in 0..<1500 {
            now += 0.02
            let chunk = scheduler.push(frame(), now: now)
            lengths.append(chunk.samples.count)
            XCTAssertFalse(chunk.restart)
        }
        XCTAssertLessThan(lengths.min() ?? size, size)
        XCTAssertLessThan(lengths.reduce(0, +), 1500 * size)
        let stats = scheduler.stats(now: now)
        XCTAssertEqual(stats.speed, 1)
        XCTAssertLessThan(stats.leadMs, 80)
        XCTAssertEqual(lengths.last, size)
    }

    func testTimeCompressionIsContinuousAcrossFrames() {
        var scheduler = scheduler()
        // A slow ramp: compressed output must stay monotonic across frame seams.
        var value: Int16 = -20000
        func ramp() -> [Int16] {
            (0..<size).map { _ in
                defer { value += 1 }
                return value
            }
        }
        var now = 0.0
        for _ in 0..<15 { _ = scheduler.push(ramp(), now: now) }
        var out: [Float] = []
        for _ in 0..<60 {
            now += 0.02
            out += scheduler.push(ramp(), now: now).samples
        }
        for i in 1..<out.count {
            let delta = out[i] - out[i - 1]
            XCTAssertGreaterThan(delta, 0)
            XCTAssertLessThan(delta, 1.05 / 32768)
        }
    }

    func testNativeSettingsAndWhereTheyBite() {
        let options = VoiceJitterOptions()
        XCTAssertEqual(options.startMs, 40)
        XCTAssertEqual(options.maxMs, 120)
        XCTAssertEqual(options.growMs, 20)
        XCTAssertEqual(options.shrinkMs, 10)
        XCTAssertEqual(options.shrinkAfterSec, 10)
        XCTAssertEqual(options.jitterGapMs, 250)
        XCTAssertEqual(options.fadeMs, 4)

        // An excess of over 100 ms plays 1.04x; between 5 and 100 ms, 1.01x.
        // The first half second holds the burst's own low lead, so the second decides.
        for (frames, speed) in [(15, 1.04), (5, 1.01)] {
            var scheduler = scheduler()
            for _ in 0..<frames { _ = scheduler.push(frame(), now: 0) }
            var now = 0.0
            for _ in 0..<52 {
                now += 0.02
                _ = scheduler.push(frame(), now: now)
            }
            XCTAssertEqual(scheduler.stats(now: now).speed, speed, "\(frames) frames")
        }
    }

    func testResetForgetsTheLearnedTargetAndDataFramesDecode() {
        var scheduler = scheduler()
        _ = scheduler.push(frame(), now: 0)
        _ = scheduler.push(frame(), now: 0.07) // late: the target grows
        XCTAssertEqual(scheduler.stats(now: 0.07).targetMs, 60, accuracy: 0.01)
        scheduler.reset()
        let stats = scheduler.stats(now: 0.07)
        XCTAssertEqual(stats.targetMs, 40, accuracy: 0.01)
        XCTAssertEqual(stats.underruns, 0)
        XCTAssertFalse(stats.playing)

        let chunk = scheduler.push(VoiceStreamAudio.data(frame(8192)), now: 1)
        XCTAssertEqual(chunk.samples.count, size)
        XCTAssertEqual(chunk.samples.last, 0.25)
        XCTAssertEqual(chunk.when, (Double(Int((1.04 * rate).rounded(.up))) + 0.5) / rate)
    }

    func testAClockFasterThanTheStreamSchedulesInItsOwnFrames() {
        var scheduler = VoicePlaybackScheduler(rate: rate, contextRate: 48000)
        let chunks = feed(&scheduler, start: 0, count: 2).chunks
        XCTAssertEqual(chunks[1].when - chunks[0].when, 0.02, accuracy: 1e-9)
        XCTAssertEqual(chunks[0].samples.count, size)
    }
}
