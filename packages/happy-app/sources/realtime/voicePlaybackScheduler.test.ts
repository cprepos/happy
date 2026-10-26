import { describe, expect, it } from 'vitest';
import { VoicePlaybackScheduler } from './voicePlaybackScheduler';

const RATE = 24000;
const FRAME = 480; // 20 ms

function frame(value = 8192) {
    return new Int16Array(FRAME).fill(value);
}

/** Feeds `count` frames `interval` seconds apart from `start`; returns the chunks and the clock after. */
function feed(scheduler: VoicePlaybackScheduler, start: number, count: number, interval = 0.02) {
    const chunks = [];
    let now = start;
    for (let i = 0; i < count; i++) {
        chunks.push(scheduler.push(frame(), now));
        now += interval;
    }
    return { chunks, now };
}

const startFrame = (when: number) => Math.floor(when * RATE);

describe('VoicePlaybackScheduler', () => {
    it('starts startMs ahead and schedules frames back to back, sample-exact', () => {
        const scheduler = new VoicePlaybackScheduler(RATE, RATE);
        const { chunks } = feed(scheduler, 1, 10);
        expect(chunks[0].restart).toBe(true);
        expect(startFrame(chunks[0].when)).toBe(Math.ceil(1.04 * RATE));
        for (let i = 1; i < chunks.length; i++) {
            expect(chunks[i].restart).toBe(false);
            expect(startFrame(chunks[i].when) - startFrame(chunks[i - 1].when)).toBe(FRAME);
            expect(chunks[i].samples.length).toBe(FRAME);
        }
    });

    it('fades in on restart and passes steady audio through untouched', () => {
        const scheduler = new VoicePlaybackScheduler(RATE, RATE);
        const { chunks } = feed(scheduler, 0, 2);
        const first = chunks[0].samples;
        expect(first[0]).toBe(0);
        expect(first[48]).toBeCloseTo(0.125, 5); // halfway through the 4 ms (96 sample) fade
        expect(first[47]).toBeLessThan(first[48]);
        expect(first[96]).toBe(0.25);
        expect(Array.from(chunks[1].samples).every((s) => s === 0.25)).toBe(true);
    });

    it('grows the target on a jitter underrun, not on a pause in speech', () => {
        const scheduler = new VoicePlaybackScheduler(RATE, RATE);
        let { now } = feed(scheduler, 0, 5);
        // Scheduled audio ends at 0.04 + 0.1 = 0.14; the next frame comes 30 ms after that.
        now = 0.17;
        const late = scheduler.push(frame(), now);
        expect(late.restart).toBe(true);
        expect(scheduler.stats(now).targetMs).toBeCloseTo(60);
        expect(scheduler.stats(now).underruns).toBe(1);
        expect(startFrame(late.when)).toBe(Math.ceil((now + 0.06) * RATE));

        // A long pause: counted, but the target stays.
        ({ now } = feed(scheduler, now + 0.02, 3));
        scheduler.push(frame(), now + 2);
        expect(scheduler.stats(now + 2).targetMs).toBeCloseTo(60);
        expect(scheduler.stats(now + 2).underruns).toBe(2);
    });

    it('never grows past maxMs and shrinks back after a smooth stretch', () => {
        const scheduler = new VoicePlaybackScheduler(RATE, RATE);
        let now = 0;
        for (let i = 0; i < 10; i++) {
            const chunk = scheduler.push(frame(), now);
            now = (startFrame(chunk.when) + FRAME) / RATE + 0.01; // always 10 ms late
        }
        expect(scheduler.stats(now).targetMs).toBeCloseTo(120);

        // 10 s of on-time frames: one shrink step.
        ({ now } = feed(scheduler, now, 520));
        expect(scheduler.stats(now).targetMs).toBeCloseTo(110);
    });

    it('treats a frame due within the guard as an underrun', () => {
        const scheduler = new VoicePlaybackScheduler(RATE, RATE);
        scheduler.push(frame(), 0); // ends at 0.06
        const chunk = scheduler.push(frame(), 0.055);
        expect(chunk.restart).toBe(true);
    });

    it('after a flush restarts without counting an underrun', () => {
        const scheduler = new VoicePlaybackScheduler(RATE, RATE);
        const { now } = feed(scheduler, 0, 5);
        scheduler.flush();
        const chunk = scheduler.push(frame(), now);
        expect(chunk.restart).toBe(true);
        expect(startFrame(chunk.when)).toBe(Math.ceil((now + 0.04) * RATE));
        expect(scheduler.stats(now).underruns).toBe(0);
        expect(scheduler.stats(now).targetMs).toBeCloseTo(40);
    });

    it('drains excess latency by playing slightly fast, then returns to 1x', () => {
        const scheduler = new VoicePlaybackScheduler(RATE, RATE);
        // A burst of 15 frames at once (300 ms of audio), then real-time pacing.
        let now = 0;
        for (let i = 0; i < 15; i++) scheduler.push(frame(), now);
        const lengths: number[] = [];
        let total = 0;
        for (let i = 0; i < 1500; i++) {
            now += 0.02;
            const chunk = scheduler.push(frame(), now);
            lengths.push(chunk.samples.length);
            total += chunk.samples.length;
            expect(chunk.restart).toBe(false);
        }
        expect(Math.min(...lengths)).toBeLessThan(FRAME); // sped up
        expect(total).toBeLessThan(1500 * FRAME);
        const stats = scheduler.stats(now);
        expect(stats.speed).toBe(1);
        expect(stats.leadMs).toBeLessThan(80);
        expect(lengths[lengths.length - 1]).toBe(FRAME);
    });

    it('time compression is continuous across frames', () => {
        const scheduler = new VoicePlaybackScheduler(RATE, RATE);
        // A slow ramp: compressed output must stay monotonic across frame seams.
        let value = -20000;
        const ramp = () => {
            const f = new Int16Array(FRAME);
            for (let i = 0; i < FRAME; i++) f[i] = value++;
            return f;
        };
        let now = 0;
        for (let i = 0; i < 15; i++) scheduler.push(ramp(), now);
        const out: number[] = [];
        for (let i = 0; i < 60; i++) {
            now += 0.02;
            out.push(...scheduler.push(ramp(), now).samples);
        }
        for (let i = 1; i < out.length; i++) {
            const delta = out[i] - out[i - 1];
            expect(delta).toBeGreaterThan(0);
            expect(delta).toBeLessThan(1.05 / 32768);
        }
    });
});
