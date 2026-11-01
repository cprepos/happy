#if canImport(UIKit)
import Foundation
import os

/// Downlink audio laid out on a timeline of rendered frames, for the audio
/// render thread to pull from. The frames rendered so far are the clock
/// `VoicePlaybackScheduler` schedules against, and a flush can fade exactly the
/// next few frames, which an already scheduled `AVAudioPlayerNode` buffer can't.
///
/// `render` runs on the render thread, so it never blocks or allocates: when a
/// writer holds the lock it outputs silence and catches up on the next call.
final class VoicePlaybackBuffer: @unchecked Sendable {
    let rate: Double
    private let capacity: Int
    private let mask: Int
    private let samples: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Frames rendered so far; guarded by `lock`.
    private var position = 0
    /// Where written audio ends; guarded by `lock`.
    private var end = 0
    /// A flush's fade reaches silence at this frame; guarded by `lock`.
    private var fadeEnd = 0
    private var fadeFrames = 1
    /// Frames rendered as silence while a writer held the lock. Render thread only.
    private var missed = 0

    /// - Parameter capacityLog2: the timeline holds 2^n frames ahead of the clock.
    init(rate: Double, capacityLog2: Int = 18) {
        self.rate = rate
        capacity = 1 << capacityLog2
        mask = capacity - 1
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        samples.deallocate()
        lock.deallocate()
    }

    /// The audio clock, in seconds.
    var now: Double {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return Double(position) / rate
    }

    /// Lays a chunk down at the clock time `when`. Anything already past the
    /// clock is cut. Returns false when the chunk doesn't fit, dropping it.
    @discardableResult
    func write(_ chunk: [Float], when: Double) -> Bool {
        let start = Int((when * rate).rounded(.down))
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let stop = start + chunk.count
        guard stop - position <= capacity else { return false }
        let first = max(start, position)
        guard first < stop else { return true }
        for frame in first..<stop { samples[frame & mask] = chunk[frame - start] }
        end = max(end, stop)
        return true
    }

    /// Fades what is playing to silence over the next `fadeFrames` and drops the
    /// rest. A fade already running keeps its course, so the level never jumps
    /// back up.
    func flush(fadeFrames frames: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if position >= fadeEnd {
            fadeEnd = position + max(1, frames)
            fadeFrames = max(1, frames)
        }
        if end > fadeEnd {
            for frame in fadeEnd..<end { samples[frame & mask] = 0 }
            end = fadeEnd
        }
    }

    /// Fills `output` and advances the clock. Returns whether it holds any audio.
    @discardableResult
    func render(into output: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        guard os_unfair_lock_trylock(lock) else {
            output.update(repeating: 0, count: frames)
            missed += frames
            return false
        }
        defer { os_unfair_lock_unlock(lock) }
        if missed > 0 {
            for frame in position..<(position + min(missed, capacity)) { samples[frame & mask] = 0 }
            position += missed
            missed = 0
        }
        let audible = position < end
        for index in 0..<frames {
            let frame = position + index
            let slot = frame & mask
            var sample = samples[slot]
            samples[slot] = 0
            if frame < fadeEnd { sample *= Float(fadeEnd - frame) / Float(fadeFrames) }
            output[index] = sample
        }
        position += frames
        return audible
    }
}

/// Spreads captured frames back out to one per tick. A tap delivers about 100 ms
/// of audio at a time, and the server drops uplink frames that arrive in a burst
/// (voiceBridge.ts `pushAudio`). The oldest go past `limit`: fresh audio matters
/// more than complete audio.
struct VoiceUplinkPacer: Sendable {
    private let limit: Int
    private var frames: [Data] = []

    init(limit: Int = 12) { self.limit = limit }

    var count: Int { frames.count }

    mutating func push(_ frame: Data) {
        frames.append(frame)
        if frames.count > limit { frames.removeFirst(frames.count - limit) }
    }

    mutating func next() -> Data? {
        frames.isEmpty ? nil : frames.removeFirst()
    }
}
#endif
