import Foundation

/// The server voice stream's audio: PCM16 little-endian mono in 20 ms frames.
public enum VoiceStreamAudio {
    public static let uplinkRate = 16000.0
    public static let uplinkFrameSamples = 320
    /// The server closes the call on any other uplink frame size.
    public static let uplinkFrameBytes = 640
    public static let downlinkRate = 24000.0
    public static let downlinkFrameSamples = 480

    /// A downlink frame's samples. A stray odd byte is dropped.
    public static func samples(_ frame: Data) -> [Int16] {
        var samples = [Int16](repeating: 0, count: frame.count / 2)
        for (index, offset) in stride(from: frame.startIndex, to: frame.startIndex + samples.count * 2, by: 2).enumerated() {
            samples[index] = Int16(bitPattern: UInt16(frame[offset]) | UInt16(frame[offset + 1]) << 8)
        }
        return samples
    }

    /// Samples as bytes on the wire.
    public static func data(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xff))
            data.append(UInt8(bits >> 8))
        }
        return data
    }
}

/// JavaScript's Math.round, which the frames and frame counts this port must
/// match were computed with: halves round up, not away from zero.
func voiceRound(_ value: Double) -> Double {
    (value + 0.5).rounded(.down)
}

/// Blackman-windowed sinc, cutoff as a fraction of the sample rate, unity DC gain.
func voiceLowpass(taps: Int, cutoff: Double) -> [Float] {
    var h = [Float](repeating: 0, count: taps)
    let mid = Double(taps - 1) / 2
    var sum = 0.0
    for i in 0..<taps {
        let x = Double(i) - mid
        let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
        let phase = 2 * Double.pi * Double(i) / Double(taps - 1)
        let window = 0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)
        h[i] = Float(sinc * window)
        sum += Double(h[i])
    }
    for j in 0..<taps { h[j] = Float(Double(h[j]) / sum) }
    return h
}

/// Any rate to a lower one: a 63-tap low-pass cut at 45% of the output rate,
/// evaluated only where output samples land, with linear interpolation between
/// neighbouring filtered input samples. A port of happy-app's voiceDsp.ts.
public struct VoiceDownsampler: Sendable {
    private static let taps = 63
    private static let size = 4096
    private static let mask = size - 1
    /// A multiple of the ring size, so rebasing keeps indices on the same slots.
    private static let rebase = 16_777_216
    /// An input longer than the ring would overwrite samples still to be
    /// filtered, so long blocks run in pieces; the output doesn't depend on them.
    private static let maxBlock = 2048

    public let step: Double
    private let coefficients: [Float]
    private let delay = Double(VoiceDownsampler.taps - 1) / 2
    private var history = [Float](repeating: 0, count: size)
    private var written = 0
    private var next = 0.0

    public init(inRate: Double, outRate: Double) {
        step = inRate / outRate
        coefficients = voiceLowpass(taps: Self.taps, cutoff: 0.45 * min(inRate, outRate) / inRate)
    }

    /// The most output samples one call can produce for an input of length n.
    public func maxOutput(_ n: Int) -> Int {
        Int((Double(n) / step).rounded(.up)) + 2
    }

    private func filtered(_ k: Int) -> Double {
        var sum = 0.0
        for j in 0..<Self.taps {
            sum += Double(coefficients[j]) * Double(history[(k - j) & Self.mask])
        }
        return sum
    }

    private mutating func drain(into out: inout [Float]) {
        while true {
            // The causal filter delays by `delay` samples.
            let t = next + delay
            let k = Int(t.rounded(.down))
            if k + 1 >= written { break }
            let frac = t - Double(k)
            let a = filtered(k)
            out.append(Float(frac == 0 ? a : a + (filtered(k + 1) - a) * frac))
            next += step
        }
    }

    /// Resamples one block of any size, returning the samples it completes.
    public mutating func process(_ input: some Collection<Float>) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(maxOutput(input.count))
        var pending = 0
        for sample in input {
            history[written & Self.mask] = sample
            written += 1
            pending += 1
            if pending == Self.maxBlock {
                drain(into: &out)
                pending = 0
            }
        }
        if pending > 0 { drain(into: &out) }
        if written >= Self.rebase {
            written -= Self.rebase
            next -= Double(Self.rebase)
        }
        return out
    }
}

/// One encoded uplink frame and its level.
public struct VoiceUplinkFrame: Equatable, Sendable {
    public let samples: [Int16]
    public let rms: Double
    /// The bytes `VoiceStreamClient.sendAudio` takes.
    public var data: Data { VoiceStreamAudio.data(samples) }
}

/// Captured float audio to PCM16 frames of a fixed size.
public struct VoiceUplinkEncoder: Sendable {
    private var downsampler: VoiceDownsampler
    private let frameSamples: Int
    private var frame: [Int16]
    private var energy = 0.0

    public init(inRate: Double, outRate: Double = VoiceStreamAudio.uplinkRate, frameSamples: Int = VoiceStreamAudio.uplinkFrameSamples) {
        downsampler = VoiceDownsampler(inRate: inRate, outRate: outRate)
        self.frameSamples = frameSamples
        frame = []
        frame.reserveCapacity(frameSamples)
    }

    /// Feeds one captured block, returning every frame it completes.
    public mutating func push(_ input: some Collection<Float>) -> [VoiceUplinkFrame] {
        var frames: [VoiceUplinkFrame] = []
        for sample in downsampler.process(input) {
            let s = Double(max(-1, min(1, sample)))
            energy += s * s
            frame.append(Int16(voiceRound(s < 0 ? s * 32768 : s * 32767)))
            if frame.count == frameSamples {
                frames.append(VoiceUplinkFrame(samples: frame, rms: (energy / Double(frameSamples)).squareRoot()))
                frame.removeAll(keepingCapacity: true)
                energy = 0
            }
        }
        return frames
    }
}

/// A frame's RMS to a speaking flag: threshold, attack and hangover.
public struct VoiceActivityDetector: Sendable {
    public private(set) var speaking = false
    private let threshold: Double
    private let attackFrames: Int
    private let releaseFrames: Int
    private var above = 0
    private var below = 0

    public init(threshold: Double = 0.015, attackFrames: Int = 2, releaseFrames: Int = 10) {
        self.threshold = threshold
        self.attackFrames = attackFrames
        self.releaseFrames = releaseFrames
    }

    /// Feeds one frame's RMS; returns the speaking flag after it.
    @discardableResult
    public mutating func push(_ rms: Double) -> Bool {
        if rms >= threshold {
            above += 1
            below = 0
            if !speaking, above >= attackFrames { speaking = true }
        } else {
            above = 0
            below += 1
            if speaking, below >= releaseFrames { speaking = false }
        }
        return speaking
    }
}
