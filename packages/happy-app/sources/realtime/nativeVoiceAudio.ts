import {
    VOICE_STREAM_DOWNLINK_RATE,
    VOICE_STREAM_UPLINK_FRAME_SAMPLES,
    VOICE_STREAM_UPLINK_RATE,
} from '@slopus/happy-wire';
import type { HappyVoiceAudio, HappyVoiceAudioHandlers } from './happyVoiceSession';
import { VOICE_JITTER_DEFAULTS } from './voiceAudioWorklets';
import { UplinkEncoder, VoiceActivity } from './voiceDsp';
import { VoicePlaybackScheduler } from './voicePlaybackScheduler';

/** Mic RMS counted as speech (≈ -36 dBFS), as on the web. */
const SPEECH_THRESHOLD = 0.015;
/** Frames (20 ms) above the threshold before speaking, and below it before not. */
const SPEECH_ATTACK_FRAMES = 2;
const SPEECH_RELEASE_FRAMES = 10;
/** Microphone callbacks per second (one per 20 ms). */
const CAPTURE_CALLBACKS_PER_SEC = 50;
const FALLBACK_CAPTURE_RATE = 48000;

/*
 * The slices of react-native-audio-api (0.8) this file uses, typed
 * structurally so tests can pass fakes; RealtimeVoiceSession.tsx passes the
 * real module.
 */

export interface NativeAudioParam {
    value: number;
    setValueAtTime(value: number, time: number): unknown;
    linearRampToValueAtTime(value: number, time: number): unknown;
}

export interface NativeAudioNode {
    // The library's own node classes; `any` keeps them assignable here.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    connect(destination: any): unknown;
    disconnect(): void;
}

export interface NativeGainNode extends NativeAudioNode {
    readonly gain: NativeAudioParam;
}

export interface NativeAudioBuffer {
    readonly length: number;
    getChannelData(channel: number): Float32Array;
    copyToChannel(source: Float32Array, channel: number): void;
}

export interface NativeBufferSourceNode extends NativeAudioNode {
    buffer: NativeAudioBuffer | null;
    start(when?: number): void;
    stop(when?: number): void;
}

export interface NativeAudioContext {
    readonly currentTime: number;
    readonly sampleRate: number;
    readonly destination: NativeAudioNode;
    createGain(): NativeGainNode;
    createBuffer(channels: number, length: number, sampleRate: number): NativeAudioBuffer;
    createBufferSource(options?: { pitchCorrection: boolean }): NativeBufferSourceNode;
    close(): Promise<unknown>;
}

export interface NativeAudioRecorder {
    start(): void;
    stop(): void;
    onAudioReady(callback: (event: { buffer: NativeAudioBuffer; numFrames: number }) => void): void;
}

export interface NativeAudioManager {
    getDevicePreferredSampleRate(): number;
    setAudioSessionActivity(enabled: boolean): Promise<boolean>;
    setAudioSessionOptions(options: { iosCategory?: string; iosMode?: string; iosOptions?: string[] }): void;
    requestRecordingPermissions(): Promise<string>;
    observeAudioInterruptions(enabled: boolean): void;
    addSystemEventListener(name: 'interruption', callback: (event: { type: 'began' | 'ended' }) => void): { remove(): void };
}

export interface NativeVoiceAudioDeps {
    platform: 'ios' | 'android';
    createContext(options: { sampleRate: number }): NativeAudioContext;
    createRecorder(options: { sampleRate: number; bufferLengthInSamples: number }): NativeAudioRecorder;
    audioManager: NativeAudioManager;
    /** Wall clock in ms (Date.now), for the capture rate check. */
    now?: () => number;
}

const STANDARD_RATES = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 96000];

/**
 * Checks the microphone delivers the rate we asked for. The iOS recorder
 * believes the session's rate when it is created; if voice processing or a
 * route change moves the hardware rate afterwards, frames arrive at another
 * rate and the uplink would be pitch-shifted. After `afterMs` of audio this
 * returns the standard rate closest to what was measured, if that is off by
 * more than 8%, else null; it decides once.
 */
export class CaptureRateMonitor {
    private startedAt = -1;
    private samples = 0;
    private decided = false;

    constructor(private readonly assumedRate: number, private readonly afterMs = 3000) {}

    push(samples: number, nowMs: number): number | null {
        if (this.decided) return null;
        if (this.startedAt < 0) {
            // The first callback's samples were captured before the clock started.
            this.startedAt = nowMs;
            return null;
        }
        this.samples += samples;
        const elapsed = nowMs - this.startedAt;
        if (elapsed < this.afterMs) return null;
        this.decided = true;
        const measured = (this.samples * 1000) / elapsed;
        if (Math.abs(measured / this.assumedRate - 1) <= 0.08) return null;
        return STANDARD_RATES.reduce((best, rate) => (Math.abs(rate - measured) < Math.abs(best - measured) ? rate : best));
    }
}

/** A typed array the native side can copy whole (no offset, no spare bytes). */
function compact(samples: Float32Array): Float32Array {
    return samples.byteOffset === 0 && samples.buffer.byteLength === samples.byteLength ? samples : samples.slice();
}

interface Scheduled {
    node: NativeBufferSourceNode;
    end: number;
}

/**
 * Native (iOS/Android) audio for `HappyVoiceSession`, on react-native-audio-api:
 * - microphone: an `AudioRecorder` at the hardware rate, 20 ms callbacks,
 *   downsampled to 16 kHz PCM16 frames in JS (`UplinkEncoder`, the same
 *   filter as the web worklet), plus the speaking flag;
 * - playback: an `AudioContext` at 24 kHz; each downlink frame becomes an
 *   `AudioBufferSourceNode` scheduled back to back by
 *   `VoicePlaybackScheduler` into a gain node. A flush ramps that gain to
 *   zero over the fade time, stops what was scheduled and starts a fresh
 *   gain node for what follows.
 * - iOS session: playAndRecord / voiceChat (echo cancellation through the
 *   voice-processing patch in patches/enable-react-native-audio-api-voice-processing.cjs),
 *   speaker by default, Bluetooth headsets allowed; held only while a
 *   conversation runs.
 */
export function createNativeVoiceAudio(deps: NativeVoiceAudioDeps): HappyVoiceAudio {
    const now = deps.now ?? (() => Date.now());
    const fadeSec = VOICE_JITTER_DEFAULTS.fadeMs / 1000;
    let context: NativeAudioContext | null = null;
    let output: NativeGainNode | null = null;
    let recorder: NativeAudioRecorder | null = null;
    let interruption: { remove(): void } | null = null;
    let scheduler: VoicePlaybackScheduler | null = null;
    let scheduled: Scheduled[] = [];
    let sessionActive = false;
    // Bumped by stop, so a start still awaiting (and stale callbacks) know they were cancelled.
    let generation = 0;

    const newOutput = (ctx: NativeAudioContext): NativeGainNode => {
        const gain = ctx.createGain();
        gain.connect(ctx.destination);
        return gain;
    };

    const release = async () => {
        interruption?.remove();
        interruption = null;
        scheduled = [];
        scheduler = null;
        const closing = context;
        const stopping = recorder;
        context = null;
        output = null;
        recorder = null;
        // Playback first, then the microphone: on iOS removing the
        // microphone rebuilds the engine with whatever is still attached.
        if (closing) {
            try {
                await closing.close();
            } catch (error) {
                console.warn('[Voice] AudioContext close failed:', error);
            }
        }
        if (stopping) {
            try {
                stopping.stop();
            } catch (error) {
                console.warn('[Voice] Recorder stop failed:', error);
            }
        }
        try {
            deps.audioManager.observeAudioInterruptions(false);
        } catch {
            // best effort
        }
        if (sessionActive) {
            sessionActive = false;
            try {
                await deps.audioManager.setAudioSessionActivity(false);
            } catch (error) {
                console.warn('[Voice] Audio session deactivation failed:', error);
            }
        }
    };

    return {
        async start(handlers: HappyVoiceAudioHandlers) {
            const started = ++generation;
            const cancelled = () => started !== generation;
            const { audioManager } = deps;

            const permission = await audioManager.requestRecordingPermissions();
            if (cancelled()) throw new Error('Voice audio stopped while starting');
            if (permission !== 'Granted') {
                throw new Error('Microphone permission denied');
            }

            if (deps.platform === 'ios') {
                audioManager.setAudioSessionOptions({
                    iosCategory: 'playAndRecord',
                    iosMode: 'voiceChat',
                    iosOptions: ['defaultToSpeaker', 'allowBluetooth', 'allowBluetoothA2DP'],
                });
            }
            sessionActive = true;
            const activated = await audioManager.setAudioSessionActivity(true);
            if (cancelled()) throw new Error('Voice audio stopped while starting');
            if (!activated) console.warn('[Voice] Audio session did not activate');

            try {
                // Read after activation: that is when iOS settles the hardware rate.
                const captureRate = Math.round(audioManager.getDevicePreferredSampleRate()) || FALLBACK_CAPTURE_RATE;
                const activity = new VoiceActivity(SPEECH_THRESHOLD, SPEECH_ATTACK_FRAMES, SPEECH_RELEASE_FRAMES);
                const makeEncoder = (rate: number) => new UplinkEncoder(rate, VOICE_STREAM_UPLINK_RATE, VOICE_STREAM_UPLINK_FRAME_SAMPLES, (frame, rms) => {
                    if (cancelled()) return;
                    handlers.onFrame(frame.buffer as ArrayBuffer);
                    const was = activity.speaking;
                    if (activity.push(rms) !== was) handlers.onSpeaking(activity.speaking);
                });
                let encoder = makeEncoder(captureRate);
                const monitor = new CaptureRateMonitor(captureRate);

                // On iOS the microphone goes first: voice processing (echo
                // cancellation) must be switched on before playback attaches.
                const mic = deps.createRecorder({
                    sampleRate: captureRate,
                    bufferLengthInSamples: Math.round(captureRate / CAPTURE_CALLBACKS_PER_SEC),
                });
                mic.onAudioReady(({ buffer, numFrames }) => {
                    if (cancelled()) return;
                    const data = buffer.getChannelData(0);
                    const samples = numFrames < data.length ? data.subarray(0, numFrames) : data;
                    const corrected = monitor.push(samples.length, now());
                    if (corrected) {
                        console.warn(`[Voice] Microphone delivers ~${corrected} Hz, not ${captureRate} Hz; resampling from ${corrected}`);
                        encoder = makeEncoder(corrected);
                    }
                    encoder.push(samples);
                });
                recorder = mic;
                mic.start();

                const ctx = deps.createContext({ sampleRate: VOICE_STREAM_DOWNLINK_RATE });
                context = ctx;
                output = newOutput(ctx);
                scheduler = new VoicePlaybackScheduler(VOICE_STREAM_DOWNLINK_RATE, ctx.sampleRate);

                // A phone call or Siri takes the audio session: end the conversation
                // like a browser ends it when the microphone goes away.
                audioManager.observeAudioInterruptions(true);
                interruption = audioManager.addSystemEventListener('interruption', (event) => {
                    if (!cancelled() && event.type === 'began') handlers.onEnded();
                });
                console.log(`[Voice] Native audio: mic ${captureRate} Hz, output ${ctx.sampleRate} Hz`);
            } catch (error) {
                if (!cancelled()) {
                    generation++;
                    await release();
                }
                throw error;
            }
        },

        play(frame: ArrayBuffer) {
            const ctx = context;
            if (!ctx || !output || !scheduler || frame.byteLength < 2) return;
            const t = ctx.currentTime;
            const chunk = scheduler.push(new Int16Array(frame, 0, frame.byteLength >> 1), t);
            if (chunk.samples.length === 0) return;
            try {
                const buffer = ctx.createBuffer(1, chunk.samples.length, VOICE_STREAM_DOWNLINK_RATE);
                buffer.copyToChannel(compact(chunk.samples), 0);
                const node = ctx.createBufferSource({ pitchCorrection: false });
                node.buffer = buffer;
                node.connect(output);
                node.start(chunk.when);
                scheduled = scheduled.filter((s) => s.end > t);
                scheduled.push({ node, end: chunk.when + chunk.samples.length / VOICE_STREAM_DOWNLINK_RATE });
            } catch (error) {
                console.warn('[Voice] Playback scheduling failed:', error);
            }
        },

        flush() {
            const ctx = context;
            const gain = output;
            if (!ctx || !gain || !scheduler) return;
            const t = ctx.currentTime;
            const until = t + fadeSec;
            try {
                gain.gain.setValueAtTime(1, t);
                gain.gain.linearRampToValueAtTime(0, until);
            } catch (error) {
                console.warn('[Voice] Flush fade failed:', error);
            }
            for (const { node, end } of scheduled) {
                if (end <= t) continue;
                try {
                    node.stop(until);
                } catch {
                    // already stopped
                }
            }
            scheduled = [];
            scheduler.flush();
            // Later audio goes through a fresh gain node; the faded one goes once silent.
            output = newOutput(ctx);
            setTimeout(() => {
                try {
                    gain.disconnect();
                } catch {
                    // context already closed
                }
            }, 250);
        },

        async stop() {
            generation++;
            await release();
        },
    };
}
