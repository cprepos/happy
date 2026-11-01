#if canImport(UIKit)
import AVFAudio
import Foundation
import HappyCore
import os

/// What a call asks of the microphone and speaker. Callbacks arrive off the
/// main thread.
struct VoiceAudioHandlers: Sendable {
    /// One uplink frame, at most one per 20 ms.
    let frame: @Sendable (Data) -> Void
    /// The microphone level started or stopped counting as speech.
    let speaking: @Sendable (Bool) -> Void
    /// Audio stopped working mid-call and can't be brought back.
    let failed: @Sendable () -> Void
}

protocol VoiceAudio: AnyObject, Sendable {
    func start(_ handlers: VoiceAudioHandlers) async throws
    /// One downlink frame.
    func play(_ frame: Data)
    /// Drops the agent audio not yet played.
    func flush()
    /// Safe at any time and more than once. The audio device is free when it returns.
    func stop() async
}

enum VoiceAudioError: Error {
    case noMicrophone
}

/// A call's audio on `AVAudioEngine`, for one start and one stop. The session
/// and engine calls can block, so all of it runs on its own queue, never main:
/// - microphone: a tap at the input's rate, with voice processing (echo
///   cancellation) on, downsampled to 16 kHz frames (`VoiceUplinkEncoder`);
/// - playback: `VoicePlaybackScheduler` places 24 kHz frames on the timeline of
///   a `VoicePlaybackBuffer`, which a source node pulls from.
///
/// See happy-app's nativeVoiceAudio.ts, whose order this keeps: session options,
/// activate, read the rate, microphone, then playback; on stop, playback first,
/// because removing the microphone rebuilds the engine with whatever is left.
final class VoiceAudioEngine: VoiceAudio, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.slopus.happy", category: "voice-audio")
    private static let framesPerSecond = 50.0
    private static let maxRebuilds = 5
    private static let rebuildWindow = 10.0

    private let queue = DispatchQueue(label: "happy.voice.audio", qos: .userInteractive)
    /// Bumped by every build and by stop, so a stale start, tap or notification
    /// knows it no longer counts. The tap reads it off the queue.
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let playback = VoicePlaybackBuffer(rate: VoiceStreamAudio.downlinkRate)
    private let fadeFrames: Int

    // The rest belongs to the queue.
    private var scheduler = VoicePlaybackScheduler(contextRate: VoiceStreamAudio.downlinkRate)
    private var pacer = VoiceUplinkPacer()
    private var pacerTimer: DispatchSourceTimer?
    private var handlers: VoiceAudioHandlers?
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var observer: NSObjectProtocol?
    private var inputRate = 0.0
    private var sessionActive = false
    private var rebuilds: [Date] = []

    init() {
        fadeFrames = Int((VoiceJitterOptions().fadeMs * VoiceStreamAudio.downlinkRate / 1000).rounded())
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start(_ handlers: VoiceAudioHandlers) async throws {
        let started = generation.withLock { value in
            value += 1
            return value
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard isCurrent(started) else { throw CancellationError() }
                    self.handlers = handlers
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .voiceChat,
                                            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
                    try? session.setPreferredIOBufferDuration(1 / Self.framesPerSecond)
                    sessionActive = true
                    try session.setActive(true)
                    guard isCurrent(started) else { throw CancellationError() }
                    try build()
                    startPacer()
                    continuation.resume()
                } catch {
                    release()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func play(_ frame: Data) {
        guard frame.count >= 2 else { return }
        queue.async { [self] in
            guard engine != nil else { return }
            let chunk = scheduler.push(frame, now: playback.now)
            if !playback.write(chunk.samples, when: chunk.when) {
                Self.log.warning("Playback buffer full, dropped a frame")
            }
        }
    }

    func flush() {
        queue.async { [self] in
            guard engine != nil else { return }
            scheduler.flush()
            playback.flush(fadeFrames: fadeFrames)
        }
    }

    func stop() async {
        generation.withLock { $0 += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                release()
                continuation.resume()
            }
        }
    }

    private func isCurrent(_ built: Int) -> Bool {
        generation.withLock { $0 == built }
    }

    // MARK: Building

    /// An `AVAudioEngine` raises an exception Swift can't catch on a bad format,
    /// so everything it is given here comes from the input node itself.
    private func build() throws {
        let built = generation.withLock { value in
            value += 1
            return value
        }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // Before playback attaches, or playback isn't cancelled from the microphone.
        try input.setVoiceProcessingEnabled(true)
        // After activation and voice processing: both can move the rate.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceAudioError.noMicrophone }
        inputRate = format.sampleRate
        let hardwareRate = AVAudioSession.sharedInstance().sampleRate
        Self.log.info("Microphone \(format.sampleRate) Hz, \(format.channelCount) channels; session \(hardwareRate) Hz")

        let capture = VoiceCapture(rate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / Self.framesPerSecond), format: format) { [weak self] buffer, _ in
            self?.captured(buffer, capture: capture, built: built)
        }

        guard let downlink = AVAudioFormat(standardFormatWithSampleRate: VoiceStreamAudio.downlinkRate, channels: 1) else {
            throw VoiceAudioError.noMicrophone
        }
        let source = AVAudioSourceNode(format: downlink, renderBlock: Self.renderBlock(playback))
        self.source = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: downlink)

        // Bound to this engine, so another engine's changes aren't heard.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.configurationChanged(built: built) }
        }
        // With voice processing on, an engine can stop itself just after starting.
        // This read sometimes prevents it: observed, undocumented behaviour, so
        // `configurationChanged` restarts the engine when it doesn't.
        _ = engine.outputNode.outputFormat(forBus: 0)
        engine.prepare()
        try engine.start()
    }

    /// A static function so the render thread can only reach the buffer.
    private static func renderBlock(_ playback: VoicePlaybackBuffer) -> AVAudioSourceNodeRenderBlock {
        { isSilence, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let audible = playback.render(into: first, frames: frames)
            for buffer in buffers.dropFirst() {
                buffer.mData?.assumingMemoryBound(to: Float.self).update(from: first, count: frames)
            }
            isSilence.pointee = ObjCBool(!audible)
            return noErr
        }
    }

    /// Playback first: see the type's comment.
    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        if let source {
            engine.disconnectNodeOutput(source)
            engine.detach(source)
        }
        source = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func release() {
        pacerTimer?.cancel()
        pacerTimer = nil
        tearDown()
        handlers = nil
        guard sessionActive else { return }
        sessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.log.warning("Audio session deactivation failed: \(error.localizedDescription)")
        }
    }

    /// A new route or rate. The engine stops itself on a real change; one that
    /// leaves it running at the same rate, as switching voice processing on can
    /// fire, needs nothing. One that stops it at the same rate gets a restart
    /// first: an engine built right after a stop can find no microphone. Each
    /// attempt counts towards the cap, so a restart loop still ends in `failed`.
    private func configurationChanged(built: Int) {
        guard isCurrent(built), let engine else { return }
        let rate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        guard !engine.isRunning || rate != inputRate else { return }
        let now = Date()
        rebuilds = rebuilds.filter { now.timeIntervalSince($0) < Self.rebuildWindow } + [now]
        do {
            guard rebuilds.count <= Self.maxRebuilds else { throw VoiceAudioError.noMicrophone }
            if !engine.isRunning, rate == inputRate {
                do {
                    try engine.start()
                    Self.log.info("Audio configuration changed, restarted at \(rate) Hz")
                    return
                } catch {
                    Self.log.warning("Audio restart failed: \(error.localizedDescription)")
                }
            }
            Self.log.info("Audio configuration changed, rebuilding at \(rate) Hz")
            tearDown()
            try build()
        } catch {
            Self.log.error("Audio rebuild failed: \(error.localizedDescription)")
            let failed = handlers?.failed
            generation.withLock { $0 += 1 }
            release()
            failed?()
        }
    }

    // MARK: Microphone

    /// On the tap's own thread, one call at a time.
    private func captured(_ buffer: AVAudioPCMBuffer, capture: VoiceCapture, built: Int) {
        guard isCurrent(built), let channels = buffer.floatChannelData else { return }
        // Channel 0 is the processed microphone, whatever else voice processing reports.
        let samples = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        let result = capture.push(samples, rate: buffer.format.sampleRate)
        guard !result.frames.isEmpty || result.speaking != nil else { return }
        queue.async { [self] in
            guard isCurrent(built) else { return }
            for frame in result.frames { pacer.push(frame) }
            if let speaking = result.speaking { handlers?.speaking(speaking) }
        }
    }

    private func startPacer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / Self.framesPerSecond, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, let frame = pacer.next() else { return }
            handlers?.frame(frame)
        }
        timer.resume()
        pacerTimer = timer
    }
}

/// One engine build's capture state. The tap's calls never overlap, so nothing
/// else touches it.
private final class VoiceCapture: @unchecked Sendable {
    private var rate: Double
    private var encoder: VoiceUplinkEncoder
    private var activity = VoiceActivityDetector()

    init(rate: Double) {
        self.rate = rate
        encoder = VoiceUplinkEncoder(inRate: rate)
    }

    /// The frames this block completes, and the speaking flag if it changed.
    func push(_ samples: UnsafeBufferPointer<Float>, rate: Double) -> (frames: [Data], speaking: Bool?) {
        // Believe the buffer: a wrong rate would pitch-shift everything sent.
        if rate != self.rate, rate > 0 {
            self.rate = rate
            encoder = VoiceUplinkEncoder(inRate: rate)
        }
        let was = activity.speaking
        var frames: [Data] = []
        for frame in encoder.push(samples) {
            frames.append(frame.data)
            activity.push(frame.rms)
        }
        return (frames, activity.speaking != was ? activity.speaking : nil)
    }
}
#endif
