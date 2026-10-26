import { describe, expect, it, vi } from 'vitest';
import {
    CaptureRateMonitor,
    createNativeVoiceAudio,
    type NativeAudioBuffer,
    type NativeAudioContext,
    type NativeAudioManager,
    type NativeAudioRecorder,
    type NativeBufferSourceNode,
    type NativeGainNode,
    type NativeVoiceAudioDeps,
} from './nativeVoiceAudio';
import type { HappyVoiceAudioHandlers } from './happyVoiceSession';

class FakeBuffer implements NativeAudioBuffer {
    data: Float32Array;
    constructor(readonly length: number) { this.data = new Float32Array(length); }
    getChannelData() { return this.data; }
    copyToChannel(source: Float32Array) { this.data.set(source); }
}

class FakeSource implements NativeBufferSourceNode {
    buffer: NativeAudioBuffer | null = null;
    startedAt: number | null = null;
    stoppedAt: number | null = null;
    connected: unknown = null;
    connect(node: unknown) { this.connected = node; return node; }
    disconnect() {}
    start(when = 0) { this.startedAt = when; }
    stop(when = 0) { this.stoppedAt = when; }
}

class FakeGain implements NativeGainNode {
    events: [string, number, number][] = [];
    disconnected = false;
    gain = {
        value: 1,
        setValueAtTime: (v: number, t: number) => this.events.push(['set', v, t]),
        linearRampToValueAtTime: (v: number, t: number) => this.events.push(['ramp', v, t]),
    };
    connect(node: unknown) { return node; }
    disconnect() { this.disconnected = true; }
}

class FakeContext implements NativeAudioContext {
    currentTime = 0;
    destination = { connect: () => null, disconnect: () => {} };
    gains: FakeGain[] = [];
    sources: FakeSource[] = [];
    closed = false;
    constructor(readonly sampleRate: number) {}
    createGain() { const g = new FakeGain(); this.gains.push(g); return g; }
    createBuffer(_channels: number, length: number) { return new FakeBuffer(length); }
    createBufferSource() { const s = new FakeSource(); this.sources.push(s); return s; }
    async close() { this.closed = true; }
}

class FakeRecorder implements NativeAudioRecorder {
    callback: ((event: { buffer: NativeAudioBuffer; numFrames: number }) => void) | null = null;
    running = false;
    constructor(readonly options: { sampleRate: number; bufferLengthInSamples: number }) {}
    start() { this.running = true; }
    stop() { this.running = false; }
    onAudioReady(callback: FakeRecorder['callback']) { this.callback = callback; }
    /** Delivers `count` callbacks of a sine at `amplitude`. */
    deliver(count: number, amplitude: number) {
        const n = this.options.bufferLengthInSamples;
        for (let c = 0; c < count; c++) {
            const buffer = new FakeBuffer(n);
            for (let i = 0; i < n; i++) buffer.data[i] = amplitude * Math.sin((2 * Math.PI * 440 * i) / this.options.sampleRate);
            this.callback?.({ buffer, numFrames: n });
        }
    }
}

function setup(options: { platform?: 'ios' | 'android'; permission?: string } = {}) {
    const order: string[] = [];
    const contexts: FakeContext[] = [];
    const recorders: FakeRecorder[] = [];
    let interruptionCallback: ((event: { type: 'began' | 'ended' }) => void) | null = null;
    const audioManager = {
        getDevicePreferredSampleRate: vi.fn(() => 48000),
        setAudioSessionActivity: vi.fn(async (enabled: boolean) => { order.push(`session:${enabled}`); return true; }),
        setAudioSessionOptions: vi.fn(() => { order.push('options'); }),
        requestRecordingPermissions: vi.fn(async () => options.permission ?? 'Granted'),
        observeAudioInterruptions: vi.fn(),
        addSystemEventListener: vi.fn((_name: 'interruption', cb: (event: { type: 'began' | 'ended' }) => void) => {
            interruptionCallback = cb;
            return { remove: vi.fn(() => { interruptionCallback = null; }) };
        }),
    } satisfies NativeAudioManager;
    const deps: NativeVoiceAudioDeps = {
        platform: options.platform ?? 'ios',
        audioManager,
        createContext: ({ sampleRate }) => {
            order.push('context');
            const ctx = new FakeContext(sampleRate);
            contexts.push(ctx);
            return ctx;
        },
        createRecorder: (opts) => {
            order.push('recorder');
            const recorder = new FakeRecorder(opts);
            const start = recorder.start.bind(recorder);
            recorder.start = () => { order.push('recorder:start'); start(); };
            recorders.push(recorder);
            return recorder;
        },
        now: () => 0,
    };
    const handlers = {
        onFrame: vi.fn((_frame: ArrayBuffer) => {}),
        onSpeaking: vi.fn((_speaking: boolean) => {}),
        onEnded: vi.fn(),
    } satisfies HappyVoiceAudioHandlers;
    const audio = createNativeVoiceAudio(deps);
    return { audio, deps, audioManager, handlers, order, contexts, recorders, interrupt: (type: 'began' | 'ended') => interruptionCallback?.({ type }) };
}

function downlink(value = 8192) {
    return new Int16Array(480).fill(value).buffer;
}

describe('createNativeVoiceAudio', () => {
    it('configures the iOS session, starts the mic before playback, at the right rates', async () => {
        const { audio, audioManager, handlers, order, contexts, recorders } = setup();
        await audio.start(handlers);
        expect(audioManager.setAudioSessionOptions).toHaveBeenCalledWith({
            iosCategory: 'playAndRecord',
            iosMode: 'voiceChat',
            iosOptions: ['defaultToSpeaker', 'allowBluetooth', 'allowBluetoothA2DP'],
        });
        expect(order).toEqual(['options', 'session:true', 'recorder', 'recorder:start', 'context']);
        expect(recorders[0].options).toEqual({ sampleRate: 48000, bufferLengthInSamples: 960 });
        expect(contexts[0].sampleRate).toBe(24000);
    });

    it('skips iOS session options on Android', async () => {
        const { audio, audioManager, handlers } = setup({ platform: 'android' });
        await audio.start(handlers);
        expect(audioManager.setAudioSessionOptions).not.toHaveBeenCalled();
        expect(audioManager.setAudioSessionActivity).toHaveBeenCalledWith(true);
    });

    it('fails without microphone permission and opens nothing', async () => {
        const { audio, handlers, recorders, contexts, audioManager } = setup({ permission: 'Denied' });
        await expect(audio.start(handlers)).rejects.toThrow('Microphone permission denied');
        expect(recorders).toHaveLength(0);
        expect(contexts).toHaveLength(0);
        expect(audioManager.setAudioSessionActivity).not.toHaveBeenCalled();
    });

    it('emits 640-byte 16 kHz uplink frames and the speaking flag', async () => {
        const { audio, handlers, recorders } = setup();
        await audio.start(handlers);
        recorders[0].deliver(50, 0.3); // one second of speech-level audio
        expect(handlers.onFrame.mock.calls.length).toBeGreaterThanOrEqual(49);
        for (const [frame] of handlers.onFrame.mock.calls) expect(frame.byteLength).toBe(640);
        expect(handlers.onSpeaking).toHaveBeenCalledWith(true);
        recorders[0].deliver(20, 0);
        expect(handlers.onSpeaking).toHaveBeenLastCalledWith(false);
    });

    it('schedules downlink frames back to back into the output gain', async () => {
        const { audio, handlers, contexts } = setup();
        await audio.start(handlers);
        const ctx = contexts[0];
        ctx.currentTime = 1;
        audio.play(downlink());
        audio.play(downlink());
        expect(ctx.sources).toHaveLength(2);
        const [a, b] = ctx.sources;
        expect(a.connected).toBe(ctx.gains[0]);
        expect(Math.floor(b.startedAt! * 24000) - Math.floor(a.startedAt! * 24000)).toBe(480);
        expect(a.startedAt!).toBeCloseTo(1.04, 3);
        expect((b.buffer as FakeBuffer).data[100]).toBe(0.25);
    });

    it('flush fades the output, stops scheduled audio and plays later audio through a fresh gain', async () => {
        vi.useFakeTimers();
        try {
            const { audio, handlers, contexts } = setup();
            await audio.start(handlers);
            const ctx = contexts[0];
            ctx.currentTime = 1;
            audio.play(downlink());
            audio.play(downlink());
            ctx.currentTime = 1.05;
            audio.flush();
            const old = ctx.gains[0];
            expect(old.events).toEqual([['set', 1, 1.05], ['ramp', 0, 1.054]]);
            for (const s of ctx.sources) expect(s.stoppedAt).toBeCloseTo(1.054, 6);
            audio.play(downlink());
            const next = ctx.sources[2];
            expect(next.connected).toBe(ctx.gains[1]);
            expect(next.startedAt!).toBeCloseTo(1.09, 3);
            vi.advanceTimersByTime(300);
            expect(old.disconnected).toBe(true);
        } finally {
            vi.useRealTimers();
        }
    });

    it('ends on an audio interruption', async () => {
        const { audio, handlers, interrupt } = setup();
        await audio.start(handlers);
        interrupt('ended');
        expect(handlers.onEnded).not.toHaveBeenCalled();
        interrupt('began');
        expect(handlers.onEnded).toHaveBeenCalledTimes(1);
    });

    it('stop releases playback, then the mic, then the session; later audio is ignored', async () => {
        const { audio, handlers, contexts, recorders, audioManager, order } = setup();
        await audio.start(handlers);
        order.length = 0;
        await audio.stop();
        expect(contexts[0].closed).toBe(true);
        expect(recorders[0].running).toBe(false);
        expect(order).toEqual(['session:false']);
        expect(audioManager.observeAudioInterruptions).toHaveBeenLastCalledWith(false);
        recorders[0].deliver(5, 0.3);
        audio.play(downlink());
        expect(handlers.onFrame).not.toHaveBeenCalled();
        expect(contexts[0].sources).toHaveLength(0);
        await audio.stop(); // idempotent
    });

    it('a stop during start cancels it', async () => {
        const { audio, handlers, recorders } = setup();
        const starting = audio.start(handlers);
        await audio.stop();
        await expect(starting).rejects.toThrow('stopped while starting');
        expect(recorders).toHaveLength(0);
    });
});

describe('CaptureRateMonitor', () => {
    it('accepts the assumed rate', () => {
        const monitor = new CaptureRateMonitor(48000);
        let result: number | null = null;
        for (let t = 0; t <= 4000; t += 20) result = monitor.push(960, t) ?? result;
        expect(result).toBeNull();
    });

    it('reports the nearest standard rate when the mic runs at another one', () => {
        const monitor = new CaptureRateMonitor(48000);
        const results: number[] = [];
        for (let t = 0; t <= 5000; t += 20) {
            const r = monitor.push(320, t); // 16 kHz delivered
            if (r) results.push(r);
        }
        expect(results).toEqual([16000]);
    });
});
