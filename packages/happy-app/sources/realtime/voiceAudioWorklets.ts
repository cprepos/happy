/**
 * AudioWorklet code for web voice, kept as source strings: the app loads it
 * from a Blob URL (see `loadVoiceWorklets` in webVoiceAudio.ts), so the
 * bundler never has to ship a separate worklet file.
 *
 * `VOICE_DSP_SOURCE` holds the signal processing as plain classes with no
 * Web Audio dependencies; the tests evaluate that exact string, so what is
 * tested is what runs. Keep it plain ES2017 (it is not transpiled) and keep
 * the per-block paths free of allocations.
 *
 * - `Downsampler`: context rate → 16 kHz. A 63-tap Blackman-windowed sinc
 *   low-pass (cut at 45% of the output rate) evaluated only where output
 *   samples land, with linear interpolation between neighbouring filtered
 *   input samples; delay ≈ 0.3 ms at 48 kHz.
 * - `UplinkEncoder`: downsampled audio → PCM16 frames of a fixed size, with
 *   the RMS of each frame.
 * - `VoiceActivity`: frame RMS → speaking flag (threshold, attack, hangover).
 * - `JitterBuffer`: 24 kHz PCM16 frames → context-rate float output. Ring
 *   buffer read with Catmull-Rom interpolation; adaptive start level, fades
 *   around underruns and flushes, slight speed-up to drain excess latency.
 */

/** Jitter buffer defaults, in milliseconds unless noted. */
export const VOICE_JITTER_DEFAULTS = {
    /** Buffered audio needed to start playing, and the floor it shrinks back to. */
    startMs: 40,
    /** Ceiling for the start level after repeated underruns. */
    maxMs: 120,
    /** Start level added per underrun that looked like network jitter. */
    growMs: 20,
    /** Start level removed after `shrinkAfterSec` without an underrun. */
    shrinkMs: 10,
    shrinkAfterSec: 10,
    /** Data resuming within this long after an underrun counts as jitter (else a pause in speech). */
    jitterGapMs: 250,
    /** Fade length around underruns, flushes and restarts. */
    fadeMs: 4,
};

export const VOICE_CAPTURE_PROCESSOR = 'happy-voice-capture';
export const VOICE_PLAYBACK_PROCESSOR = 'happy-voice-playback';

export const VOICE_DSP_SOURCE = String.raw`
var REBASE = 16777216; // multiple of every ring size below, keeps indices exact int32

function makeLowpass(taps, cutoff) {
    // Blackman-windowed sinc, cutoff as a fraction of the sample rate, unity DC gain.
    var h = new Float32Array(taps);
    var mid = (taps - 1) / 2;
    var sum = 0;
    for (var i = 0; i < taps; i++) {
        var x = i - mid;
        var sinc = x === 0 ? 2 * cutoff : Math.sin(2 * Math.PI * cutoff * x) / (Math.PI * x);
        var phase = (2 * Math.PI * i) / (taps - 1);
        var window = 0.42 - 0.5 * Math.cos(phase) + 0.08 * Math.cos(2 * phase);
        h[i] = sinc * window;
        sum += h[i];
    }
    for (var j = 0; j < taps; j++) h[j] /= sum;
    return h;
}

class Downsampler {
    constructor(inRate, outRate) {
        this.step = inRate / outRate;
        this.taps = 63;
        this.coeffs = makeLowpass(this.taps, (0.45 * Math.min(inRate, outRate)) / inRate);
        this.delay = (this.taps - 1) / 2;
        this.size = 4096;
        this.mask = this.size - 1;
        this.history = new Float32Array(this.size);
        this.written = 0; // input samples seen
        this.next = 0; // input time of the next output sample
    }

    /** Most output samples one call can produce for an input of length n. */
    maxOutput(n) {
        return Math.ceil(n / this.step) + 2;
    }

    filtered(k) {
        var h = this.coeffs, x = this.history, m = this.mask, acc = 0;
        for (var j = 0; j < this.taps; j++) acc += h[j] * x[(k - j) & m];
        return acc;
    }

    /** Resamples input into out (from 0); returns the number of samples written. */
    process(input, out) {
        var n = input.length, m = this.mask;
        for (var i = 0; i < n; i++) this.history[(this.written + i) & m] = input[i];
        this.written += n;
        var count = 0;
        for (;;) {
            // The causal filter delays by this.delay samples.
            var t = this.next + this.delay;
            var k = Math.floor(t);
            if (k + 1 >= this.written) break;
            var frac = t - k;
            var a = this.filtered(k);
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

class UplinkEncoder {
    /** onFrame(frame: Int16Array, rms: number) gets each full frame; the frame is not reused. */
    constructor(inRate, outRate, frameSamples, onFrame) {
        this.down = new Downsampler(inRate, outRate);
        this.frameSamples = frameSamples;
        this.onFrame = onFrame;
        this.scratch = new Float32Array(this.down.maxOutput(128));
        this.frame = new Int16Array(frameSamples);
        this.filled = 0;
        this.energy = 0;
    }

    push(input) {
        if (this.scratch.length < this.down.maxOutput(input.length)) {
            this.scratch = new Float32Array(this.down.maxOutput(input.length));
        }
        var n = this.down.process(input, this.scratch);
        for (var i = 0; i < n; i++) {
            var s = this.scratch[i];
            if (s > 1) s = 1;
            else if (s < -1) s = -1;
            this.energy += s * s;
            this.frame[this.filled++] = s < 0 ? Math.round(s * 32768) : Math.round(s * 32767);
            if (this.filled === this.frameSamples) {
                var frame = this.frame;
                var rms = Math.sqrt(this.energy / this.frameSamples);
                this.frame = new Int16Array(this.frameSamples);
                this.filled = 0;
                this.energy = 0;
                this.onFrame(frame, rms);
            }
        }
    }
}

class VoiceActivity {
    constructor(threshold, attackFrames, releaseFrames) {
        this.threshold = threshold;
        this.attackFrames = attackFrames;
        this.releaseFrames = releaseFrames;
        this.above = 0;
        this.below = 0;
        this.speaking = false;
    }

    /** Feeds one frame's RMS; returns the speaking flag after it. */
    push(rms) {
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

class JitterBuffer {
    constructor(inRate, outRate, options) {
        var o = options || {};
        var ms = function (value) { return Math.round((value * inRate) / 1000); };
        this.inRate = inRate;
        this.outRate = outRate;
        this.baseStep = inRate / outRate;
        this.speed = 1;
        this.minTarget = ms(o.startMs);
        this.maxTarget = ms(o.maxMs);
        this.growBy = ms(o.growMs);
        this.shrinkBy = ms(o.shrinkMs);
        this.shrinkAfter = Math.round(o.shrinkAfterSec * outRate); // output samples
        this.jitterGap = Math.round((o.jitterGapMs * outRate) / 1000); // output samples
        this.fadeLen = Math.max(1, Math.round((o.fadeMs * outRate) / 1000)); // output samples
        this.drainWindow = Math.round(outRate / 2); // output samples
        this.target = this.minTarget;
        this.size = 65536; // ~2.7 s at 24 kHz
        this.mask = this.size - 1;
        this.ring = new Float32Array(this.size);
        this.read = 0;
        this.write = 0;
        this.frac = 0;
        this.end = -1; // after a flush: where the kept audio ends
        this.resumeAt = 0; // after a flush: where audio pushed since then starts
        this.playing = false;
        this.fadeIn = 0;
        this.starved = -1; // output samples since an underrun with no new data, -1 if not starving
        this.smooth = 0; // output samples played since the last underrun or shrink
        this.windowMin = Infinity;
        this.windowLeft = this.drainWindow;
        this.underruns = 0;
    }

    /** Buffered input samples. */
    level() {
        return (this.end >= 0 ? this.end : this.write) - this.read;
    }

    push(pcm) {
        if (this.starved >= 0) {
            if (this.starved < this.jitterGap) {
                this.target = Math.min(this.maxTarget, this.target + this.growBy);
            }
            this.starved = -1;
        }
        var n = pcm.length, m = this.mask, w = this.write;
        for (var i = 0; i < n; i++) this.ring[(w + i) & m] = pcm[i] / 32768;
        this.write = w + n;
        if (this.write - this.read > this.size - 4) {
            // Overflow: drop the oldest audio.
            this.read = this.write - (this.size - 4);
            this.frac = 0;
        }
    }

    /** Drops queued audio; what is playing fades out within fadeMs. */
    flush() {
        this.starved = -1;
        if (!this.playing) {
            this.read = this.write;
            this.frac = 0;
            this.end = -1;
            return;
        }
        // Keep just enough to fade out; audio pushed after this plays once it has.
        var keep = Math.ceil(this.fadeLen * this.baseStep * this.speed) + 3;
        var end = Math.min(this.write, this.read + keep);
        this.end = this.end >= 0 ? Math.min(this.end, end) : end;
        this.resumeAt = this.write;
    }

    render(out) {
        var n = out.length;
        if (!this.playing) {
            if (this.end < 0 && this.write - this.read >= this.target && this.target > 0) {
                this.playing = true;
                this.fadeIn = this.fadeLen;
                this.windowMin = Infinity;
                this.windowLeft = this.drainWindow;
            } else {
                out.fill(0);
                if (this.starved >= 0) this.starved += n;
                return;
            }
        }

        var step = this.baseStep * this.speed;
        var stop = this.end >= 0 ? this.end : this.write;
        var avail = stop - this.read;
        // Output sample k reads input read + floor(frac + k * step) .. + 2.
        var can = avail >= 3 ? Math.max(0, Math.ceil((avail - 2 - this.frac) / step)) : 0;
        var produce = can < n ? can : n;
        // Running out within this block: fade the last samples instead of clicking.
        var fadeFrom = can <= n ? produce - Math.min(produce, this.fadeLen) : n;
        var fadeSpan = produce - fadeFrom;

        var ring = this.ring, m = this.mask, r = this.read, f = this.frac;
        for (var i = 0; i < produce; i++) {
            var x0 = ring[(r - 1) & m], x1 = ring[r & m], x2 = ring[(r + 1) & m], x3 = ring[(r + 2) & m];
            var c1 = 0.5 * (x2 - x0);
            var c2 = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3;
            var c3 = 0.5 * (x3 - x0) + 1.5 * (x1 - x2);
            var s = ((c3 * f + c2) * f + c1) * f + x1;
            if (this.fadeIn > 0) {
                s *= 1 - this.fadeIn / this.fadeLen;
                this.fadeIn--;
            }
            if (i >= fadeFrom) s *= (produce - i) / (fadeSpan + 1);
            out[i] = s;
            f += step;
            var advance = f | 0;
            r += advance;
            f -= advance;
        }
        this.read = r;
        this.frac = f;

        if (produce < n) {
            for (var z = produce; z < n; z++) out[z] = 0;
            this.playing = false;
            this.fadeIn = 0;
            this.speed = 1;
            this.smooth = 0;
            this.read = stop;
            this.frac = 0;
            if (this.end >= 0) {
                // Flush done: skip the dropped audio, keep what came after it.
                this.end = -1;
                this.read = this.resumeAt;
            } else {
                this.underruns++;
                this.starved = n - produce;
            }
        } else {
            this.trackLatency(n);
        }
        if (this.read >= REBASE) {
            this.read -= REBASE;
            this.write -= REBASE;
            if (this.end >= 0) {
                this.end -= REBASE;
                this.resumeAt -= REBASE;
            }
        }
    }

    trackLatency(n) {
        this.smooth += n;
        if (this.smooth >= this.shrinkAfter) {
            this.smooth = 0;
            if (this.target > this.minTarget) this.target = Math.max(this.minTarget, this.target - this.shrinkBy);
        }
        var level = this.level();
        if (level < this.windowMin) this.windowMin = level;
        this.windowLeft -= n;
        if (this.windowLeft <= 0) {
            // More than the target never drained in half a second: play
            // slightly fast (inaudible at 1%) until it does.
            var excess = this.windowMin - this.target;
            this.speed = excess > (this.inRate / 10) ? 1.04 : excess > 0 ? 1.01 : 1;
            this.windowMin = Infinity;
            this.windowLeft = this.drainWindow;
        }
    }

    /** Snapshot for tests and logs. */
    stats() {
        return {
            playing: this.playing,
            targetMs: (this.target * 1000) / this.inRate,
            levelMs: (this.level() * 1000) / this.inRate,
            speed: this.speed,
            underruns: this.underruns,
        };
    }
}
`;

const PROCESSORS_SOURCE = String.raw`
class HappyVoiceCaptureProcessor extends AudioWorkletProcessor {
    constructor(options) {
        super();
        var o = options.processorOptions;
        var port = this.port;
        var activity = new VoiceActivity(o.speechThreshold, o.attackFrames, o.releaseFrames);
        this.running = true;
        this.encoder = new UplinkEncoder(sampleRate, o.outRate, o.frameSamples, function (frame, rms) {
            port.postMessage(frame.buffer, [frame.buffer]);
            var was = activity.speaking;
            if (activity.push(rms) !== was) port.postMessage({ type: 'speaking', speaking: activity.speaking });
        });
        var self = this;
        port.onmessage = function (event) {
            if (event.data && event.data.type === 'stop') self.running = false;
        };
    }

    process(inputs) {
        var channel = inputs[0] && inputs[0][0];
        if (channel) this.encoder.push(channel);
        return this.running;
    }
}

class HappyVoicePlaybackProcessor extends AudioWorkletProcessor {
    constructor(options) {
        super();
        this.buffer = new JitterBuffer(options.processorOptions.inRate, sampleRate, options.processorOptions);
        this.running = true;
        var self = this;
        this.port.onmessage = function (event) {
            var data = event.data;
            if (data instanceof ArrayBuffer) self.buffer.push(new Int16Array(data, 0, data.byteLength >> 1));
            else if (data && data.type === 'flush') self.buffer.flush();
            else if (data && data.type === 'stop') self.running = false;
        };
    }

    process(_inputs, outputs) {
        var out = outputs[0] && outputs[0][0];
        if (out) this.buffer.render(out);
        return this.running;
    }
}

registerProcessor('${VOICE_CAPTURE_PROCESSOR}', HappyVoiceCaptureProcessor);
registerProcessor('${VOICE_PLAYBACK_PROCESSOR}', HappyVoicePlaybackProcessor);
`;

/** The single worklet module: DSP classes plus both processors. */
export const VOICE_WORKLET_SOURCE = VOICE_DSP_SOURCE + PROCESSORS_SOURCE;
