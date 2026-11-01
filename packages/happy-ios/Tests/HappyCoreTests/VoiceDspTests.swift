import Foundation
@testable import HappyCore
import XCTest

final class VoiceDspTests: XCTestCase {
    /// A sweep plus noise, so every filter tap matters. The expected values
    /// below came from running happy-app's voiceDsp.ts on this same signal.
    private func signal(rate: Double, seconds: Double) -> [Float] {
        var seed = 12345
        return (0..<Int(rate * seconds)).map { i in
            seed = (seed * 75 + 74) % 65537
            let noise = (Double(seed) / 65537 - 0.5) * 0.2
            return Float(0.6 * sin(2 * .pi * (200 + Double(i) / 20) * Double(i) / rate) + noise)
        }
    }

    private func encode(_ input: [Float], rate: Double, block: Int) -> [VoiceUplinkFrame] {
        var encoder = VoiceUplinkEncoder(inRate: rate)
        var frames: [VoiceUplinkFrame] = []
        for start in stride(from: 0, to: input.count, by: block) {
            frames += encoder.push(input[start..<min(start + block, input.count)])
        }
        return frames
    }

    func testEncoderMatchesTheExpoImplementationOnTheSameSignal() {
        typealias Point = (frame: Int, sample: Int, value: Int16)
        let expected: [(rate: Double, frames: Int, points: [Point], rms: [Double])] = [
            (48000, 49, [(0, 40, -2029), (0, 200, -11079), (1, 0, -4468), (5, 77, 17048), (10, 319, 9750), (20, 160, 8477), (30, 13, -1621), (48, 319, -14288)], [0.427039126, 0.426045506, 0.425737396]),
            (44100, 49, [(0, 40, -3224), (0, 200, -14282), (1, 0, -13475), (5, 77, 17342), (10, 319, -16855), (20, 160, -17972), (30, 13, 12271), (48, 319, 9502)], [0.419544603, 0.424195341, 0.419950490]),
            (24000, 49, [(0, 40, -4081), (0, 200, -20204), (1, 0, 3606), (5, 77, 15160), (10, 319, 4586), (20, 160, -19145), (30, 13, 18538), (48, 319, 15379)], [0.428921619, 0.419316169, 0.423733167]),
            (16000, 49, [(0, 40, 859), (0, 200, -13753), (1, 0, 19492), (5, 77, -16635), (10, 319, -18164), (20, 160, 6228), (30, 13, -6393), (48, 319, 19222)], [0.429492999, 0.424104461, 0.429356459]),
        ]
        for row in expected {
            let frames = encode(signal(rate: row.rate, seconds: 1), rate: row.rate, block: 941)
            XCTAssertEqual(frames.count, row.frames)
            XCTAssertTrue(frames.allSatisfy { $0.samples.count == 320 && $0.data.count == 640 })
            for point in row.points {
                // Within one count: sin() may differ by an ulp between platforms.
                XCTAssertEqual(Int(frames[point.frame].samples[point.sample]), Int(point.value), accuracy: 1, "\(row.rate) \(point)")
            }
            for (frame, rms) in zip([1, 10, 30], row.rms) {
                XCTAssertEqual(frames[frame].rms, rms, accuracy: 1e-6)
            }
        }
    }

    func testAtLeast49FramesPerSecondOf48kHz() {
        XCTAssertGreaterThanOrEqual(encode(signal(rate: 48000, seconds: 1), rate: 48000, block: 960).count, 49)
    }

    func testOutputDoesNotDependOnBlockSizeEvenBeyondTheRing() {
        let input = signal(rate: 48000, seconds: 1)
        let small = encode(input, rate: 48000, block: 128)
        XCTAssertEqual(encode(input, rate: 48000, block: 941), small)
        XCTAssertEqual(encode(input, rate: 48000, block: input.count), small)
    }

    func testDownsamplerStaysWithinItsDeclaredMaximum() {
        var downsampler = VoiceDownsampler(inRate: 48000, outRate: 16000)
        XCTAssertEqual(downsampler.step, 3)
        let block = [Float](repeating: 0.5, count: 960)
        for _ in 0..<5 {
            XCTAssertLessThanOrEqual(downsampler.process(block).count, downsampler.maxOutput(960))
        }
    }

    func testDownsamplerHasUnityGainAtDC() {
        var downsampler = VoiceDownsampler(inRate: 48000, outRate: 16000)
        let output = downsampler.process([Float](repeating: 0.5, count: 4800))
        XCTAssertEqual(output.last ?? 0, 0.5, accuracy: 1e-4)
    }

    func testEncoderClampsAndRoundsAsymmetrically() {
        var high = VoiceUplinkEncoder(inRate: 16000, frameSamples: 4)
        var low = VoiceUplinkEncoder(inRate: 16000, frameSamples: 4)
        let top = high.push([Float](repeating: 4, count: 400)).last
        let bottom = low.push([Float](repeating: -4, count: 400)).last
        XCTAssertEqual(top?.samples.last, 32767)
        XCTAssertEqual(bottom?.samples.last, -32768)
        XCTAssertEqual(top?.rms ?? 0, 1, accuracy: 1e-6)
    }

    func testFramesAreLittleEndianBothWays() {
        let samples: [Int16] = [1, -2, 0x1234, -32768]
        let data = VoiceStreamAudio.data(samples)
        XCTAssertEqual([UInt8](data), [0x01, 0x00, 0xfe, 0xff, 0x34, 0x12, 0x00, 0x80])
        XCTAssertEqual(VoiceStreamAudio.samples(data), samples)
        XCTAssertEqual(VoiceStreamAudio.samples(data + Data([9])), samples)
        XCTAssertEqual(VoiceStreamAudio.samples(data.dropFirst(2)), Array(samples.dropFirst()))
    }

    func testVoiceActivityLevelsFromTheExpoTest() {
        var detector = VoiceActivityDetector()
        let levels = [0, 0.02, 0.03, 0.01, 0.02, 0.02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.5, 0.5]
        let flags = levels.map { detector.push($0) }
        let on = true, off = false
        XCTAssertEqual(flags, [off, off, on, on, on, on, on, on, on, on, on, on, on, on, on, off, off, off, on])
        XCTAssertTrue(detector.speaking)
    }
}
