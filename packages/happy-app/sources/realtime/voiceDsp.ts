/**
 * Microphone-side voice DSP as ordinary (bundled, transpiled) code, for the
 * native app.
 *
 * The web app runs the same algorithms inside an AudioWorklet from the source
 * string `VOICE_DSP_SOURCE` (voiceAudioWorklets.ts). That string can't be
 * reused on native: Hermes compiles code at runtime without `class` support.
 * These classes are a line-for-line port of `Downsampler`, `UplinkEncoder`
 * and `VoiceActivity` there; voiceDsp.test.ts checks both produce identical
 * output, so change them together.
 */

const REBASE = 16777216; // multiple of every ring size below, keeps indices exact int32

/** Blackman-windowed sinc, cutoff as a fraction of the sample rate, unity DC gain. */
export function makeLowpass(taps: number, cutoff: number): Float32Array {
    const h = new Float32Array(taps);
    const mid = (taps - 1) / 2;
    let sum = 0;
    for (let i = 0; i < taps; i++) {
        const x = i - mid;
        const sinc = x === 0 ? 2 * cutoff : Math.sin(2 * Math.PI * cutoff * x) / (Math.PI * x);
        const phase = (2 * Math.PI * i) / (taps - 1);
        const window = 0.42 - 0.5 * Math.cos(phase) + 0.08 * Math.cos(2 * phase);
        h[i] = sinc * window;
        sum += h[i];
    }
    for (let j = 0; j < taps; j++) h[j] /= sum;
    return h;
}

/**
 * Any rate → a lower one: a 63-tap low-pass (cut at 45% of the output rate)
 * evaluated only where output samples land, linear interpolation between
 * neighbouring filtered input samples.
 */
export class Downsampler {
    readonly step: number;
    private readonly taps = 63;
    private readonly coeffs: Float32Array;
    private readonly delay: number;
    private readonly size = 4096;
    private readonly mask = this.size - 1;
    private readonly history = new Float32Array(this.size);
    private written = 0; // input samples seen
    private next = 0; // input time of the next output sample

    constructor(inRate: number, outRate: number) {
        this.step = inRate / outRate;
        this.coeffs = makeLowpass(this.taps, (0.45 * Math.min(inRate, outRate)) / inRate);
        this.delay = (this.taps - 1) / 2;
    }

    /** Most output samples one call can produce for an input of length n. */
    maxOutput(n: number): number {
        return Math.ceil(n / this.step) + 2;
    }

    private filtered(k: number): number {
        const h = this.coeffs, x = this.history, m = this.mask;
        let acc = 0;
        for (let j = 0; j < this.taps; j++) acc += h[j] * x[(k - j) & m];
        return acc;
    }

    /** Resamples input into out (from 0); returns the number of samples written. */
    process(input: ArrayLike<number>, out: Float32Array): number {
        const n = input.length, m = this.mask;
        for (let i = 0; i < n; i++) this.history[(this.written + i) & m] = input[i];
        this.written += n;
        let count = 0;
        for (;;) {
            // The causal filter delays by this.delay samples.
            const t = this.next + this.delay;
            const k = Math.floor(t);
            if (k + 1 >= this.written) break;
            const frac = t - k;
            const a = this.filtered(k);
            out[count++] = frac === 0 ? a : a + (this.filtered(k + 1) - a) * frac;
            this.next += this.step;
        }
        if (this.written >= REBASE) {
            this.written -= REBASE;
            this.next -= REBASE;
        }
        return count;
    }
}

/** Downsampled audio → PCM16 frames of a fixed size, with the RMS of each frame. */
export class UplinkEncoder {
    private readonly down: Downsampler;
    private scratch: Float32Array;
    private frame: Int16Array;
    private filled = 0;
    private energy = 0;

    /** onFrame gets each full frame; the frame is not reused. */
    constructor(
        inRate: number,
        outRate: number,
        private readonly frameSamples: number,
        private readonly onFrame: (frame: Int16Array, rms: number) => void,
    ) {
        this.down = new Downsampler(inRate, outRate);
        this.scratch = new Float32Array(this.down.maxOutput(128));
        this.frame = new Int16Array(frameSamples);
    }

    push(input: ArrayLike<number>): void {
        if (this.scratch.length < this.down.maxOutput(input.length)) {
            this.scratch = new Float32Array(this.down.maxOutput(input.length));
        }
        const n = this.down.process(input, this.scratch);
        for (let i = 0; i < n; i++) {
            let s = this.scratch[i];
            if (s > 1) s = 1;
            else if (s < -1) s = -1;
            this.energy += s * s;
            this.frame[this.filled++] = s < 0 ? Math.round(s * 32768) : Math.round(s * 32767);
            if (this.filled === this.frameSamples) {
                const frame = this.frame;
                const rms = Math.sqrt(this.energy / this.frameSamples);
                this.frame = new Int16Array(this.frameSamples);
                this.filled = 0;
                this.energy = 0;
                this.onFrame(frame, rms);
            }
        }
    }
}

/** Frame RMS → speaking flag (threshold, attack, hangover). */
export class VoiceActivity {
    speaking = false;
    private above = 0;
    private below = 0;

    constructor(
        private readonly threshold: number,
        private readonly attackFrames: number,
        private readonly releaseFrames: number,
    ) {}

    /** Feeds one frame's RMS; returns the speaking flag after it. */
    push(rms: number): boolean {
        if (rms >= this.threshold) {
            this.above++;
            this.below = 0;
            if (!this.speaking && this.above >= this.attackFrames) this.speaking = true;
        } else {
            this.above = 0;
            this.below++;
            if (this.speaking && this.below >= this.releaseFrames) this.speaking = false;
        }
        return this.speaking;
    }
}
