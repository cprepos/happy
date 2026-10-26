import { VOICE_JITTER_DEFAULTS } from './voiceAudioWorklets';

/** One downlink frame, ready to schedule as a buffer source. */
export interface PlaybackChunk {
    /** Context time to start at; lands half a frame inside the target sample frame. */
    when: number;
    /** Samples at the stream rate, faded in when `restart`. */
    samples: Float32Array;
    /** Playback (re)started with this chunk: after silence, an underrun or a flush. */
    restart: boolean;
}

export type PlaybackJitterOptions = typeof VOICE_JITTER_DEFAULTS;

/**
 * The native counterpart of the worklet `JitterBuffer`, for an audio API
 * that schedules buffers instead of pulling samples: each downlink frame is
 * scheduled right behind the previous one, `target` ahead of the clock when
 * playback (re)starts. Same policy as the web: the target starts at
 * `startMs`, grows by `growMs` (up to `maxMs`) on an underrun that looks like
 * jitter, shrinks by `shrinkMs` after `shrinkAfterSec` without one; audio
 * that never drains below the target plays 1% (or 4%) fast until it does;
 * restarts fade in over `fadeMs`.
 *
 * Pure: the caller passes the audio clock (`now`, seconds) on every call.
 */
export class VoicePlaybackScheduler {
    private readonly minTarget: number;
    private readonly maxTarget: number;
    private readonly growBy: number;
    private readonly shrinkBy: number;
    private readonly shrinkAfter: number;
    private readonly jitterGap: number;
    private readonly fadeLen: number;
    /** A frame due sooner than this is too late to schedule seamlessly. */
    private readonly guard: number;
    private readonly drainWindow = 0.5;

    private target: number;
    /** Context frame where scheduled audio ends, -1 when nothing is scheduled. */
    private endFrame = -1;
    private flushed = false;
    private speed = 1;
    /** Time-compression read position carried into the next frame, and the sample before it. */
    private carry = 0;
    private prev = 0;
    private smoothSince = 0;
    private windowStart = 0;
    private windowMin = Infinity;
    private underruns = 0;

    constructor(
        private readonly rate: number,
        private readonly contextRate: number,
        options: PlaybackJitterOptions = VOICE_JITTER_DEFAULTS,
        guardMs = 10,
    ) {
        this.minTarget = options.startMs / 1000;
        this.maxTarget = options.maxMs / 1000;
        this.growBy = options.growMs / 1000;
        this.shrinkBy = options.shrinkMs / 1000;
        this.shrinkAfter = options.shrinkAfterSec;
        this.jitterGap = options.jitterGapMs / 1000;
        this.fadeLen = Math.max(1, Math.round((options.fadeMs * rate) / 1000));
        this.guard = guardMs / 1000;
        this.target = this.minTarget;
    }

    /** Schedules one PCM16 frame given the audio clock `now`. */
    push(pcm: Int16Array, now: number): PlaybackChunk {
        const end = this.endFrame >= 0 ? this.endFrame / this.contextRate : -1;
        const lead = end - now;
        let restart = false;
        let startFrame: number;
        if (this.endFrame < 0 || lead < this.guard) {
            restart = true;
            if (this.endFrame >= 0 && !this.flushed) {
                // Ran dry mid-stream. Data back soon after counts as jitter
                // (else it was a pause in speech).
                this.underruns++;
                if (now - end < this.jitterGap) {
                    this.target = Math.min(this.maxTarget, this.target + this.growBy);
                }
            }
            this.flushed = false;
            this.speed = 1;
            this.carry = 0;
            this.prev = 0;
            this.smoothSince = now;
            this.windowStart = now;
            this.windowMin = Infinity;
            startFrame = Math.ceil((now + this.target) * this.contextRate);
        } else {
            this.trackLatency(lead, now);
            startFrame = this.endFrame;
        }

        const samples = this.resample(pcm);
        if (restart) {
            const fade = Math.min(this.fadeLen, samples.length);
            for (let i = 0; i < fade; i++) samples[i] *= i / fade;
        }
        this.endFrame = startFrame + Math.round((samples.length * this.contextRate) / this.rate);
        return { when: (startFrame + 0.5) / this.contextRate, samples, restart };
    }

    /** Forget scheduled audio (the caller silences it); the next frame restarts playback. */
    flush(): void {
        if (this.endFrame >= 0) this.flushed = true;
        this.endFrame = -1;
    }

    /** Clears everything, including the learned target. */
    reset(): void {
        this.endFrame = -1;
        this.flushed = false;
        this.target = this.minTarget;
        this.speed = 1;
        this.carry = 0;
        this.prev = 0;
        this.underruns = 0;
    }

    /** Snapshot for tests and logs. */
    stats(now: number) {
        return {
            playing: this.endFrame >= 0 && this.endFrame / this.contextRate > now,
            targetMs: this.target * 1000,
            leadMs: this.endFrame >= 0 ? Math.max(0, this.endFrame / this.contextRate - now) * 1000 : 0,
            speed: this.speed,
            underruns: this.underruns,
        };
    }

    private trackLatency(lead: number, now: number) {
        if (now - this.smoothSince >= this.shrinkAfter) {
            this.smoothSince = now;
            if (this.target > this.minTarget) this.target = Math.max(this.minTarget, this.target - this.shrinkBy);
        }
        if (lead < this.windowMin) this.windowMin = lead;
        if (now - this.windowStart >= this.drainWindow) {
            // More than the target never drained in half a second: play
            // slightly fast (inaudible at 1%) until it does.
            const excess = this.windowMin - this.target;
            this.speed = excess > 0.1 ? 1.04 : excess > 0.005 ? 1.01 : 1;
            if (this.speed === 1) this.carry = 0;
            this.windowStart = now;
            this.windowMin = Infinity;
        }
    }

    /** PCM16 → float, time-compressed by `speed` (linear interpolation, continuous across frames). */
    private resample(pcm: Int16Array): Float32Array {
        const n = pcm.length;
        if (this.speed === 1 && this.carry === 0) {
            const out = new Float32Array(n);
            for (let i = 0; i < n; i++) out[i] = pcm[i] / 32768;
            if (n > 0) this.prev = out[n - 1];
            return out;
        }
        const step = this.speed;
        const out = new Float32Array(Math.ceil((n - this.carry) / step) + 1);
        let count = 0;
        let t = this.carry; // in (-1, n - 1]; -1 is the previous frame's last sample
        while (t <= n - 1) {
            const k = Math.floor(t);
            const frac = t - k;
            const a = k < 0 ? this.prev : pcm[k] / 32768;
            const b = k + 1 < n ? pcm[k + 1] / 32768 : a;
            out[count++] = a + (b - a) * frac;
            t += step;
        }
        this.carry = t - n;
        if (n > 0) this.prev = pcm[n - 1] / 32768;
        return out.subarray(0, count);
    }
}
