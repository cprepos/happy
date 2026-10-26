import { describe, expect, it } from 'vitest';
import { VOICE_DSP_SOURCE } from './voiceAudioWorklets';
import { Downsampler, UplinkEncoder, VoiceActivity } from './voiceDsp';

// The worklet's copy of the same algorithms, evaluated outside a worklet.
const worklet = new Function(`${VOICE_DSP_SOURCE}\nreturn { Downsampler, UplinkEncoder, VoiceActivity };`)() as {
    Downsampler: new (inRate: number, outRate: number) => { process(input: Float32Array, out: Float32Array): number; maxOutput(n: number): number };
    UplinkEncoder: new (inRate: number, outRate: number, frameSamples: number, onFrame: (frame: Int16Array, rms: number) => void) => { push(input: Float32Array): void };
    VoiceActivity: new (threshold: number, attack: number, release: number) => { push(rms: number): boolean };
};

/** Deterministic noise plus a sweep, so every filter tap matters. */
function signal(rate: number, seconds: number) {
    const out = new Float32Array(Math.round(rate * seconds));
    let seed = 12345;
    for (let i = 0; i < out.length; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        const noise = (seed / 0x7fffffff - 0.5) * 0.2;
        out[i] = 0.6 * Math.sin((2 * Math.PI * (200 + i / 20) * i) / rate) + noise;
    }
    return out;
}

/** Odd block sizes, like a native recorder callback. */
function blocks(input: Float32Array, size: number) {
    const out: Float32Array[] = [];
    for (let i = 0; i < input.length; i += size) out.push(input.subarray(i, i + size));
    return out;
}

describe('voiceDsp matches the worklet DSP', () => {
    it.each([48000, 44100, 24000, 16000])('downsampler output is identical from %i Hz', (rate) => {
        const ours = new Downsampler(rate, 16000);
        const theirs = new worklet.Downsampler(rate, 16000);
        for (const block of blocks(signal(rate, 0.5), 941)) {
            const a = new Float32Array(ours.maxOutput(block.length));
            const b = new Float32Array(theirs.maxOutput(block.length));
            const na = ours.process(block, a);
            const nb = theirs.process(block, b);
            expect(na).toBe(nb);
            expect(Array.from(a.subarray(0, na))).toEqual(Array.from(b.subarray(0, nb)));
        }
    });

    it('uplink encoder frames and levels are identical', () => {
        const ours: [Int16Array, number][] = [];
        const theirs: [Int16Array, number][] = [];
        const a = new UplinkEncoder(48000, 16000, 320, (frame, rms) => ours.push([frame, rms]));
        const b = new worklet.UplinkEncoder(48000, 16000, 320, (frame, rms) => theirs.push([frame, rms]));
        for (const block of blocks(signal(48000, 1), 960)) {
            a.push(block);
            b.push(block);
        }
        expect(ours.length).toBeGreaterThanOrEqual(49);
        expect(ours.length).toBe(theirs.length);
        ours.forEach(([frame, rms], i) => {
            expect(frame.length).toBe(320);
            expect(Array.from(frame)).toEqual(Array.from(theirs[i][0]));
            expect(rms).toBe(theirs[i][1]);
        });
    });

    it('voice activity decisions are identical', () => {
        const ours = new VoiceActivity(0.015, 2, 10);
        const theirs = new worklet.VoiceActivity(0.015, 2, 10);
        const levels = [0, 0.02, 0.03, 0.01, 0.02, 0.02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.5, 0.5];
        expect(levels.map((l) => ours.push(l))).toEqual(levels.map((l) => theirs.push(l)));
        expect(ours.speaking).toBe(true);
    });
});
