import { describe, expect, it } from 'vitest';
import { VOICE_DSP_SOURCE, VOICE_JITTER_DEFAULTS, VOICE_WORKLET_SOURCE } from './voiceAudioWorklets';

// The exact source the worklet runs, evaluated outside a worklet.
const dsp = new Function(`${VOICE_DSP_SOURCE}\nreturn { Downsampler, UplinkEncoder, VoiceActivity, JitterBuffer };`)() as {
    Downsampler: new (inRate: number, outRate: number) => {
        maxOutput(n: number): number;
        process(input: Float32Array, out: Float32Array): number;
    };
    UplinkEncoder: new (inRate: number, outRate: number, frameSamples: number, onFrame: (frame: Int16Array, rms: number) => void) => {
        push(input: Float32Array): void;
    };
    VoiceActivity: new (threshold: number, attack: number, release: number) => { push(rms: number): boolean };
    JitterBuffer: new (inRate: number, outRate: number, options: typeof VOICE_JITTER_DEFAULTS) => {
        push(pcm: Int16Array): void;
        flush(): void;
        render(out: Float32Array): void;
        level(): number;
        stats(): { playing: boolean; targetMs: number; levelMs: number; speed: number; underruns: number };
    };
};

const BLOCK = 128;

function sine(rate: number, freq: number, seconds: number, amplitude = 0.5) {
    const out = new Float32Array(Math.round(rate * seconds));
    for (let i = 0; i < out.length; i++) out[i] = amplitude * Math.sin((2 * Math.PI * freq * i) / rate);
    return out;
}

function rms(samples: ArrayLike<number>, from = 0) {
    let sum = 0;
    for (let i = from; i < samples.length; i++) sum += samples[i] * samples[i];
    return Math.sqrt(sum / (samples.length - from));
}

/** Runs input through an encoder in 128-sample render quanta. */
function encode(inRate: number, input: Float32Array) {
    const frames: Int16Array[] = [];
    const levels: number[] = [];
    const encoder = new dsp.UplinkEncoder(inRate, 16000, 320, (frame, level) => {
        frames.push(frame);
        levels.push(level);
    });
    for (let i = 0; i < input.length; i += BLOCK) encoder.push(input.subarray(i, i + BLOCK));
    return { frames, levels };
}

function concat(frames: Int16Array[]) {
    const out = new Float32Array(frames.length * 320);
    frames.forEach((frame, f) => frame.forEach((s, i) => { out[f * 320 + i] = s / 32768; }));
    return out;
}

/** A 24 kHz PCM16 frame (20 ms) of a sine, continuing phase from `start`. */
function downlinkFrame(start: number, freq = 440, amplitude = 0.5) {
    const frame = new Int16Array(480);
    for (let i = 0; i < 480; i++) frame[i] = Math.round(amplitude * 32767 * Math.sin((2 * Math.PI * freq * (start + i)) / 24000));
    return frame;
}

function renderBlocks(buffer: InstanceType<typeof dsp.JitterBuffer>, blocks: number) {
    const out = new Float32Array(blocks * BLOCK);
    const block = new Float32Array(BLOCK);
    for (let b = 0; b < blocks; b++) {
        buffer.render(block);
        out.set(block, b * BLOCK);
    }
    return out;
}

describe('uplink encoder', () => {
    it.each([48000, 44100, 16000])('emits 320-sample frames from %i Hz', (rate) => {
        const { frames } = encode(rate, sine(rate, 440, 1));
        // One second minus the filter delay.
        expect(frames.length).toBeGreaterThanOrEqual(49);
        expect(frames.length).toBeLessThanOrEqual(50);
        for (const frame of frames) {
            expect(frame.length).toBe(320);
            expect(frame.buffer.byteLength).toBe(640);
        }
        // Frames are handed off, never reused.
        expect(new Set(frames.map((f) => f.buffer)).size).toBe(frames.length);
    });

    it('passes speech-band audio at full level', () => {
        const { frames } = encode(48000, sine(48000, 1000, 1));
        expect(rms(concat(frames), 1600)).toBeCloseTo(0.5 / Math.SQRT2, 2);
    });

    it('attenuates what would alias above 8 kHz', () => {
        for (const rate of [48000, 44100]) {
            // 12 kHz folds back to 4 kHz without an anti-alias filter.
            const { frames } = encode(rate, sine(rate, 12000, 1));
            expect(rms(concat(frames), 1600)).toBeLessThan(0.5 / Math.SQRT2 / 300); // < -50 dB
        }
    });

    it('reports frame level', () => {
        const { levels } = encode(48000, sine(48000, 500, 0.5, 0.1));
        expect(levels[levels.length - 1]).toBeCloseTo(0.1 / Math.SQRT2, 2);
    });
});

describe('voice activity', () => {
    it('needs consecutive loud frames to start and a hangover to stop', () => {
        const vad = new dsp.VoiceActivity(0.015, 2, 10);
        expect(vad.push(0.1)).toBe(false);
        expect(vad.push(0.001)).toBe(false);
        expect(vad.push(0.1)).toBe(false);
        expect(vad.push(0.1)).toBe(true);
        for (let i = 0; i < 9; i++) expect(vad.push(0.001)).toBe(true);
        expect(vad.push(0.001)).toBe(false);
    });
});

describe('jitter buffer', () => {
    const make = (outRate = 48000) => new dsp.JitterBuffer(24000, outRate, VOICE_JITTER_DEFAULTS);

    it('stays silent until the start level is buffered', () => {
        const buffer = make();
        buffer.push(downlinkFrame(0));
        expect(rms(renderBlocks(buffer, 4))).toBe(0);
        expect(buffer.stats().playing).toBe(false);
        buffer.push(downlinkFrame(480)); // 40 ms buffered
        renderBlocks(buffer, 1);
        expect(buffer.stats().playing).toBe(true);
    });

    it.each([48000, 44100])('plays 24 kHz audio at %i Hz without changing pitch or level', (outRate) => {
        const buffer = make(outRate);
        for (let f = 0; f < 50; f++) buffer.push(downlinkFrame(f * 480, 1000));
        // Under half a second, before the drain would speed up a backlog this deep.
        const out = renderBlocks(buffer, Math.floor((outRate * 0.45) / BLOCK));
        expect(buffer.stats().speed).toBe(1);
        let crossings = 0;
        for (let i = 1; i < out.length; i++) if (out[i - 1] < 0 && out[i] >= 0) crossings++;
        expect(crossings / (out.length / outRate)).toBeCloseTo(1000, -1);
        expect(rms(out, 1000)).toBeCloseTo(0.5 / Math.SQRT2, 2);
    });

    it('fades out on underrun instead of clicking', () => {
        const buffer = make();
        buffer.push(downlinkFrame(0));
        buffer.push(downlinkFrame(480));
        const out = renderBlocks(buffer, 20); // 53 ms of output for 40 ms of input
        const last = out.findLastIndex((s) => s !== 0);
        expect(last).toBeGreaterThan(0);
        // The last few samples ramp down to near zero.
        expect(Math.abs(out[last])).toBeLessThan(0.02);
        expect(buffer.stats().underruns).toBe(1);
        expect(buffer.stats().playing).toBe(false);
    });

    it('grows the start level on jitter underruns, up to the maximum', () => {
        const buffer = make();
        let t = 0;
        const expected = [60, 80, 100, 120, 120];
        for (const targetMs of expected) {
            // Fill exactly to the current start level, play it dry, then resume quickly.
            while (!buffer.stats().playing) {
                buffer.push(downlinkFrame(t));
                t += 480;
                renderBlocks(buffer, 1);
            }
            while (buffer.stats().playing) renderBlocks(buffer, 1);
            buffer.push(downlinkFrame(t)); // data back within the jitter gap
            t += 480;
            expect(buffer.stats().targetMs).toBe(targetMs);
        }
    });

    it('does not grow after a pause in speech', () => {
        const buffer = make();
        buffer.push(downlinkFrame(0));
        buffer.push(downlinkFrame(480));
        renderBlocks(buffer, 40);
        renderBlocks(buffer, 200); // ~530 ms of silence
        buffer.push(downlinkFrame(960));
        expect(buffer.stats().targetMs).toBe(40);
    });

    it('shrinks back slowly after smooth playback', () => {
        const buffer = make();
        let t = 0;
        // Two jitter underruns: start level 80 ms.
        for (let i = 0; i < 2; i++) {
            while (!buffer.stats().playing) { buffer.push(downlinkFrame(t)); t += 480; renderBlocks(buffer, 1); }
            while (buffer.stats().playing) renderBlocks(buffer, 1);
        }
        buffer.push(downlinkFrame(t)); t += 480;
        expect(buffer.stats().targetMs).toBe(80);
        // 11 s of steady real-time input: 20 ms frames, 7.5 blocks each at 48 kHz.
        let rendered = 0;
        for (let f = 0; f < 550; f++) {
            buffer.push(downlinkFrame(t)); t += 480;
            const due = Math.floor(((f + 1) * 960) / BLOCK) - rendered;
            renderBlocks(buffer, due);
            rendered += due;
        }
        expect(buffer.stats().underruns).toBe(2);
        expect(buffer.stats().targetMs).toBe(70);
    });

    it('drains excess latency by playing slightly fast', () => {
        const buffer = make();
        for (let f = 0; f < 20; f++) buffer.push(downlinkFrame(f * 480)); // 400 ms burst
        let t = 20 * 480;
        let rendered = 0;
        for (let f = 0; f < 50; f++) {
            buffer.push(downlinkFrame(t)); t += 480;
            const due = Math.floor(((f + 1) * 960) / BLOCK) - rendered;
            renderBlocks(buffer, due);
            rendered += due;
        }
        expect(buffer.stats().speed).toBeGreaterThan(1);
    });

    it('flush stops playback within the fade and drops the rest', () => {
        const buffer = make();
        for (let f = 0; f < 10; f++) buffer.push(downlinkFrame(f * 480));
        renderBlocks(buffer, 4);
        expect(buffer.stats().playing).toBe(true);
        buffer.flush();
        const after = renderBlocks(buffer, 4);
        const fadeSamples = (VOICE_JITTER_DEFAULTS.fadeMs * 48000) / 1000;
        for (let i = fadeSamples + 4; i < after.length; i++) expect(after[i]).toBe(0);
        expect(buffer.stats().playing).toBe(false);
        expect(buffer.level()).toBe(0);
        expect(buffer.stats().underruns).toBe(0);
    });

    it('plays audio pushed after a flush, but not the flushed audio', () => {
        const buffer = make();
        for (let f = 0; f < 10; f++) buffer.push(downlinkFrame(f * 480));
        renderBlocks(buffer, 4);
        buffer.flush();
        buffer.push(new Int16Array(480).fill(16384));
        buffer.push(new Int16Array(480).fill(16384));
        renderBlocks(buffer, 2); // fade out the old tail
        const out = renderBlocks(buffer, 10);
        expect(out[out.length - 1]).toBeCloseTo(0.5, 3);
        expect(buffer.level()).toBeLessThan(960);
    });

    it('flush while buffering empties it at once', () => {
        const buffer = make();
        buffer.push(downlinkFrame(0));
        buffer.flush();
        expect(buffer.level()).toBe(0);
        buffer.push(downlinkFrame(0));
        buffer.push(downlinkFrame(480));
        renderBlocks(buffer, 1);
        expect(buffer.stats().playing).toBe(true);
    });
});

describe('worklet module', () => {
    it('registers both processors', () => {
        const registered: string[] = [];
        new Function('AudioWorkletProcessor', 'registerProcessor', 'sampleRate', VOICE_WORKLET_SOURCE)(
            class {},
            (name: string) => registered.push(name),
            48000,
        );
        expect(registered).toEqual(['happy-voice-capture', 'happy-voice-playback']);
    });
});
