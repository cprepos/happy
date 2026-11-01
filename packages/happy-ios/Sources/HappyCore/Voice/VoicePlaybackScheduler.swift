import Foundation

/// How playback rides out network jitter. The defaults are happy-app's
/// `VOICE_JITTER_DEFAULTS`.
public struct VoiceJitterOptions: Equatable, Sendable {
    /// Buffered audio needed to start playing, and the floor it shrinks back to.
    public var startMs = 40.0
    /// Ceiling for the start level after repeated underruns.
    public var maxMs = 120.0
    /// Start level added per underrun that looked like network jitter.
    public var growMs = 20.0
    /// Start level removed after `shrinkAfterSec` without an underrun.
    public var shrinkMs = 10.0
    public var shrinkAfterSec = 10.0
    /// Data resuming within this long after an underrun counts as jitter, else a pause in speech.
    public var jitterGapMs = 250.0
    /// Fade length around underruns, flushes and restarts.
    public var fadeMs = 4.0

    public init() {}
}

/// One downlink frame, ready to schedule on the audio clock.
public struct VoicePlaybackChunk: Equatable, Sendable {
    /// Clock time to start at; lands half a frame inside the target sample frame.
    public let when: Double
    /// Samples at the stream rate, faded in when `restart`.
    public let samples: [Float]
    /// Playback (re)started with this chunk: after silence, an underrun or a flush.
    public let restart: Bool
}

public struct VoicePlaybackStats: Equatable, Sendable {
    public let playing: Bool
    public let targetMs: Double
    public let leadMs: Double
    public let speed: Double
    public let underruns: Int
}

/// For an audio API that schedules buffers instead of pulling samples: each
/// downlink frame goes right behind the previous one, `target` ahead of the
/// clock when playback (re)starts. The target starts at `startMs`, grows on an
/// underrun that looks like jitter and shrinks after a smooth stretch; audio
/// that never drains below the target plays 1% or 4% fast until it does.
/// A port of happy-app's voicePlaybackScheduler.ts.
///
/// Pure: the caller passes the audio clock (`now`, seconds) on every call.
public struct VoicePlaybackScheduler: Sendable {
    private let rate: Double
    private let contextRate: Double
    private let minTarget: Double
    private let maxTarget: Double
    private let growBy: Double
    private let shrinkBy: Double
    private let shrinkAfter: Double
    private let jitterGap: Double
    private let fadeLength: Int
    /// A frame due sooner than this is too late to schedule seamlessly.
    private let guardTime: Double
    private let drainWindow = 0.5

    private var target: Double
    /// Clock frame where scheduled audio ends, -1 when nothing is scheduled.
    private var endFrame = -1
    private var flushed = false
    private var speed = 1.0
    /// Time-compression read position carried into the next frame, and the sample before it.
    private var carry = 0.0
    private var previous = 0.0
    private var smoothSince = 0.0
    private var windowStart = 0.0
    private var windowMin = Double.infinity
    private var underruns = 0

    /// - Parameters:
    ///   - rate: the stream's sample rate.
    ///   - contextRate: the audio clock's sample rate.
    public init(rate: Double = VoiceStreamAudio.downlinkRate, contextRate: Double, options: VoiceJitterOptions = VoiceJitterOptions(), guardMs: Double = 10) {
        self.rate = rate
        self.contextRate = contextRate
        minTarget = options.startMs / 1000
        maxTarget = options.maxMs / 1000
        growBy = options.growMs / 1000
        shrinkBy = options.shrinkMs / 1000
        shrinkAfter = options.shrinkAfterSec
        jitterGap = options.jitterGapMs / 1000
        fadeLength = max(1, Int(voiceRound(options.fadeMs * rate / 1000)))
        guardTime = guardMs / 1000
        target = minTarget
    }

    /// Schedules one downlink frame's bytes given the audio clock `now`.
    public mutating func push(_ frame: Data, now: Double) -> VoicePlaybackChunk {
        push(VoiceStreamAudio.samples(frame), now: now)
    }

    /// Schedules one PCM16 frame given the audio clock `now`.
    public mutating func push(_ pcm: [Int16], now: Double) -> VoicePlaybackChunk {
        let end = endFrame >= 0 ? Double(endFrame) / contextRate : -1
        let lead = end - now
        var restart = false
        let startFrame: Int
        if endFrame < 0 || lead < guardTime {
            restart = true
            if endFrame >= 0, !flushed {
                // Ran dry mid-stream. Data back soon after counts as jitter,
                // else it was a pause in speech.
                underruns += 1
                if now - end < jitterGap {
                    target = min(maxTarget, target + growBy)
                }
            }
            flushed = false
            speed = 1
            carry = 0
            previous = 0
            smoothSince = now
            windowStart = now
            windowMin = .infinity
            startFrame = Int(((now + target) * contextRate).rounded(.up))
        } else {
            trackLatency(lead: lead, now: now)
            startFrame = endFrame
        }

        var samples = resample(pcm)
        if restart {
            let fade = min(fadeLength, samples.count)
            for i in 0..<fade {
                samples[i] = Float(Double(samples[i]) * (Double(i) / Double(fade)))
            }
        }
        endFrame = startFrame + Int(voiceRound(Double(samples.count) * contextRate / rate))
        return VoicePlaybackChunk(when: (Double(startFrame) + 0.5) / contextRate, samples: samples, restart: restart)
    }

    /// Forget scheduled audio (the caller silences it); the next frame restarts playback.
    public mutating func flush() {
        if endFrame >= 0 { flushed = true }
        endFrame = -1
    }

    /// Clears everything, including the learned target.
    public mutating func reset() {
        endFrame = -1
        flushed = false
        target = minTarget
        speed = 1
        carry = 0
        previous = 0
        underruns = 0
    }

    /// A snapshot for tests and logs.
    public func stats(now: Double) -> VoicePlaybackStats {
        let end = Double(endFrame) / contextRate
        return VoicePlaybackStats(
            playing: endFrame >= 0 && end > now,
            targetMs: target * 1000,
            leadMs: endFrame >= 0 ? max(0, end - now) * 1000 : 0,
            speed: speed,
            underruns: underruns
        )
    }

    private mutating func trackLatency(lead: Double, now: Double) {
        if now - smoothSince >= shrinkAfter {
            smoothSince = now
            if target > minTarget { target = max(minTarget, target - shrinkBy) }
        }
        if lead < windowMin { windowMin = lead }
        if now - windowStart >= drainWindow {
            // More than the target never drained in half a second: play
            // slightly fast (inaudible at 1%) until it does.
            let excess = windowMin - target
            speed = excess > 0.1 ? 1.04 : excess > 0.005 ? 1.01 : 1
            if speed == 1 { carry = 0 }
            windowStart = now
            windowMin = .infinity
        }
    }

    /// PCM16 to float, time-compressed by `speed` with linear interpolation,
    /// continuous across frames.
    private mutating func resample(_ pcm: [Int16]) -> [Float] {
        let n = pcm.count
        if speed == 1, carry == 0 {
            let out = pcm.map { Float(Double($0) / 32768) }
            if let last = out.last { previous = Double(last) }
            return out
        }
        var out: [Float] = []
        out.reserveCapacity(Int((Double(n) - carry) / speed) + 2)
        // In (-1, n - 1]; -1 is the previous frame's last sample.
        var t = carry
        while t <= Double(n - 1) {
            let k = Int(t.rounded(.down))
            let frac = t - Double(k)
            let a = k < 0 ? previous : Double(pcm[k]) / 32768
            let b = k + 1 < n ? Double(pcm[k + 1]) / 32768 : a
            out.append(Float(a + (b - a) * frac))
            t += speed
        }
        carry = t - Double(n)
        if let last = pcm.last { previous = Double(last) / 32768 }
        return out
    }
}
