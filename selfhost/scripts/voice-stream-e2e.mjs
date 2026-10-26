#!/usr/bin/env node
// Headless latency harness for the voice stream (app <-> happy-server <-> LiveKit <-> agent).
//
// Plays the part of the app on wss://<server>/v1/voice/stream (protocol:
// packages/happy-wire/src/voiceStream.ts) without any app code: sends `hello`, answers the
// agent's RPCs with a minimal config, streams speech (Kokoro TTS, resampled to 16 kHz) in real
// time as 20 ms PCM16 frames with continuous silence around it, and measures:
//   - end of user speech -> first agent audio frame, per turn
//   - downlink frame interval (p50/p95/max), gaps > 40 ms, underruns of a 40 ms jitter buffer
//   - frame totals
//
//   node selfhost/scripts/voice-stream-e2e.mjs [--url wss://.../v1/voice/stream] [--turns about,thanks]
//        [--tts http://127.0.0.1:8880/v1] [--voice am_michael] [--wav speech.wav] [--session <id>]
//
// Token: $HAPPY_TOKEN, else the `token` field of $HAPPY_HOME_DIR/access.key (default
// ~/.happy/access.key, where the happy CLI stores its credentials). Never printed.
// Exit codes: 0 every turn got a reply; 1 test failure; 2 endpoint missing or unreachable.
//
// Latency is defined like packages/happy-voice-agent/tests/e2e_fake_app.py so the numbers compare:
// end of speech = moment the last loud sample (|x| > 300) of the clip leaves the mic, first agent
// audio = first received agent frame with RMS > 400 after that (a new onset, speech segments end
// after 0.6 s below the threshold). Same utterances and TTS voice by default.

import { spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import https from 'node:https';
import http from 'node:http';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';

// Node 20 ships WebSocket behind a flag; re-run with it when needed.
if (typeof globalThis.WebSocket !== 'function') {
    if (process.env.VOICE_E2E_REEXEC) {
        console.error('this Node has no WebSocket client (need Node >= 20.10)');
        process.exit(2);
    }
    const r = spawnSync(process.execPath, ['--experimental-websocket', '--no-warnings', ...process.argv.slice(1)], {
        stdio: 'inherit',
        env: { ...process.env, VOICE_E2E_REEXEC: '1' },
    });
    process.exit(r.status ?? 1);
}

// --- protocol constants (mirrors packages/happy-wire/src/voiceStream.ts) ---
const UP_RATE = 16000;
const DOWN_RATE = 24000;
const FRAME_MS = 20;
const UP_SAMPLES = (UP_RATE * FRAME_MS) / 1000; // 320
const DOWN_BYTES = ((DOWN_RATE * FRAME_MS) / 1000) * 2; // 960

// --- measurement constants (mirrors e2e_fake_app.py) ---
const LOUD_SAMPLE = 300;
const SPEECH_RMS = 400;
const SPEECH_RELEASE_MS = 600;
const GAP_MS = 40;
const PAUSE_MS = 500; // a longer silence on the downlink is a pause in the stream, not jitter
const JITTER_BUFFER_MS = 40;

const SESSION_ID = 'sess_e2e_42';
const UTTERANCES = {
    list_files: 'Hi Happy, can you tell Claude to list the files in the source folder?',
    about: 'Happy, what is this session about?',
    allow: 'Yes, allow it.',
    thanks: 'Happy, how many sessions do I have open right now?',
};
const SYSTEM_PROMPT_APP =
    'You are a voice interface for Happy - a coding agent orchestrator application on mobile and web. ' +
    'You are a friendly woman, but very direct and to the point.\n\n' +
    '# Runtime counters\n- onboarding_prompt_load_count: 0\n- voice_message_count: 0\n\n' +
    '# Conversation history so far\nAvailable sessions:\n' +
    `- ${SESSION_ID}: "Refactor the auth module of the web server"\n- sess_other_7: "Fix dark mode"\n\n` +
    'CURRENT SESSION:\n\n' +
    `# Session ID: ${SESSION_ID}\n\n# Project path: /home/dev/webserver\n\n` +
    '# Session summary:\nRefactor the auth module of the web server\n\n' +
    '## Our interaction history so far\n\n' +
    `History of messages in session: ${SESSION_ID}\n\n` +
    'User sent message: \n<text>Please refactor the login handler to use the new token service.</text>\n\n' +
    'Claude Code: \n<text>I refactored the login handler. It now calls TokenService.issue and all 42 tests pass.</text>';
const CONFIG = {
    systemPrompt: SYSTEM_PROMPT_APP,
    firstMessage: 'Hi, Happy here',
    initialContext: '',
    language: 'en',
    sessionId: SESSION_ID,
};

// --- args ---
function parseArgs(argv) {
    const o = {
        url: process.env.VOICE_STREAM_URL || 'wss://happy.girthbass.duckdns.org/v1/voice/stream',
        tts: process.env.TTS_URL || 'http://127.0.0.1:8880/v1',
        voice: 'am_michael',
        turns: 'about,thanks',
        wav: null,
        session: null,
        verbose: false,
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        const v = () => {
            if (i + 1 >= argv.length) fatal(1, `${a} needs a value`);
            return argv[++i];
        };
        if (a === '--url') o.url = v();
        else if (a === '--tts') o.tts = v();
        else if (a === '--voice') o.voice = v();
        else if (a === '--turns') o.turns = v();
        else if (a === '--wav') o.wav = v();
        else if (a === '--session') o.session = v();
        else if (a === '-v' || a === '--verbose') o.verbose = true;
        else if (a === '-h' || a === '--help') {
            console.log(readFileSync(new URL(import.meta.url)).toString().split('\n').filter((l) => l.startsWith('//')).map((l) => l.slice(3)).join('\n'));
            process.exit(0);
        } else fatal(1, `unknown argument ${a}`);
    }
    return o;
}

function fatal(code, msg) {
    console.error(`FAIL: ${msg}`);
    process.exit(code);
}

const t0 = performance.now();
const ts = () => ((performance.now() - t0) / 1000).toFixed(2).padStart(6);
const log = (...a) => console.log(`[${ts()}]`, ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- token ---
function readToken() {
    if (process.env.HAPPY_TOKEN) return process.env.HAPPY_TOKEN.trim();
    const home = (process.env.HAPPY_HOME_DIR || join(homedir(), '.happy')).replace(/^~/, homedir());
    const p = join(home, 'access.key');
    if (!existsSync(p)) fatal(1, `no HAPPY_TOKEN and no ${p} (log in with the happy CLI first)`);
    try {
        const t = JSON.parse(readFileSync(p, 'utf8')).token;
        if (typeof t === 'string' && t) return t;
    } catch {}
    fatal(1, `${p} has no token field`);
}

// --- WAV + resampling ---
function readWav(buf) {
    if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') throw new Error('not a WAV file');
    let off = 12;
    let fmt = null;
    while (off + 8 <= buf.length) {
        const id = buf.toString('ascii', off, off + 4);
        let size = buf.readUInt32LE(off + 4);
        const body = off + 8;
        if (id === 'fmt ') {
            fmt = { format: buf.readUInt16LE(body), channels: buf.readUInt16LE(body + 2), rate: buf.readUInt32LE(body + 4), bits: buf.readUInt16LE(body + 14) };
        } else if (id === 'data') {
            if (!fmt) throw new Error('WAV data before fmt');
            if (fmt.format !== 1 || fmt.bits !== 16) throw new Error('WAV must be PCM 16-bit');
            if (size === 0xffffffff || body + size > buf.length) size = buf.length - body; // streamed WAVs
            const n = Math.floor(size / 2 / fmt.channels);
            const out = new Int16Array(n);
            for (let i = 0; i < n; i++) out[i] = buf.readInt16LE(body + i * 2 * fmt.channels); // first channel
            return { rate: fmt.rate, samples: out };
        }
        off = body + size + (size & 1);
    }
    throw new Error('WAV has no data chunk');
}

function writeWav(samples, rate) {
    const b = Buffer.alloc(44 + samples.length * 2);
    b.write('RIFF', 0, 'ascii');
    b.writeUInt32LE(36 + samples.length * 2, 4);
    b.write('WAVEfmt ', 8, 'ascii');
    b.writeUInt32LE(16, 16);
    b.writeUInt16LE(1, 20);
    b.writeUInt16LE(1, 22);
    b.writeUInt32LE(rate, 24);
    b.writeUInt32LE(rate * 2, 28);
    b.writeUInt16LE(2, 32);
    b.writeUInt16LE(16, 34);
    b.write('data', 36, 'ascii');
    b.writeUInt32LE(samples.length * 2, 40);
    for (let i = 0; i < samples.length; i++) b.writeInt16LE(samples[i], 44 + i * 2);
    return b;
}

/** Windowed-sinc resampler (offline; quality is plenty for STT input). */
function resample(input, from, to) {
    if (from === to) return input;
    const ratio = to / from;
    const cutoff = Math.min(1, ratio) * 0.92; // relative to the input Nyquist
    const half = 24; // taps each side, in input samples (scaled when downsampling)
    const width = Math.ceil(half / Math.min(1, ratio));
    const n = Math.floor(input.length * ratio);
    const out = new Int16Array(n);
    for (let j = 0; j < n; j++) {
        const x = j / ratio;
        const c = Math.floor(x);
        let acc = 0;
        let norm = 0;
        for (let k = c - width + 1; k <= c + width; k++) {
            if (k < 0 || k >= input.length) continue;
            const d = x - k;
            const arg = Math.PI * d * cutoff;
            const sinc = d === 0 ? 1 : Math.sin(arg) / arg;
            const w = 0.5 + 0.5 * Math.cos((Math.PI * d) / width); // Hann
            const h = sinc * w;
            acc += input[k] * h;
            norm += h;
        }
        out[j] = Math.max(-32768, Math.min(32767, Math.round(acc / (norm || 1))));
    }
    return out;
}

async function speechClip(opts, key) {
    if (opts.wav) {
        const w = readWav(readFileSync(opts.wav));
        return resample(w.samples, w.rate, UP_RATE);
    }
    const text = UTTERANCES[key];
    const cacheDir = join(process.env.XDG_CACHE_HOME || join(homedir(), '.cache'), 'happy-voice-stream-e2e');
    const file = join(cacheDir, `${opts.voice}-${createHash('sha1').update(text).digest('hex').slice(0, 12)}-16k.wav`);
    if (existsSync(file)) return readWav(readFileSync(file)).samples;
    let res;
    try {
        res = await fetch(`${opts.tts.replace(/\/$/, '')}/audio/speech`, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ model: 'kokoro', input: text, voice: opts.voice, response_format: 'wav', stream: false }),
            signal: AbortSignal.timeout(60000),
        });
    } catch (e) {
        fatal(1, `TTS at ${opts.tts} unreachable (${e.cause?.code || e.message}); pass --wav <file> instead`);
    }
    if (!res.ok) fatal(1, `TTS answered ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const w = readWav(Buffer.from(await res.arrayBuffer()));
    const pcm = resample(w.samples, w.rate, UP_RATE);
    mkdirSync(cacheDir, { recursive: true });
    writeFileSync(file, writeWav(pcm, UP_RATE));
    return pcm;
}

// --- endpoint preflight: a WebSocket handshake by hand, so a missing route shows its HTTP status ---
function preflight(url) {
    return new Promise((resolve) => {
        const u = new URL(url);
        const secure = u.protocol === 'wss:';
        const mod = secure ? https : http;
        const req = mod.request({
            host: u.hostname,
            port: u.port || (secure ? 443 : 80),
            path: u.pathname + u.search,
            method: 'GET',
            timeout: 10000,
            headers: {
                Connection: 'Upgrade',
                Upgrade: 'websocket',
                'Sec-WebSocket-Version': '13',
                'Sec-WebSocket-Key': randomBytes(16).toString('base64'),
            },
        });
        req.on('upgrade', (res, socket) => {
            socket.destroy();
            resolve({ ok: true, status: res.statusCode });
        });
        req.on('response', (res) => {
            res.resume();
            resolve({ ok: false, status: res.statusCode });
        });
        req.on('timeout', () => req.destroy(new Error('timeout')));
        req.on('error', (e) => resolve({ ok: false, error: e.code || e.message }));
        req.end();
    });
}

// --- stats ---
function pct(sorted, p) {
    if (!sorted.length) return NaN;
    const i = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
    return sorted[i];
}
const f1 = (x) => (Number.isFinite(x) ? x.toFixed(1) : '-');
const f0 = (x) => (Number.isFinite(x) ? x.toFixed(0) : '-');

function rms(buf) {
    const n = buf.length >> 1;
    if (!n) return 0;
    let s = 0;
    for (let i = 0; i < n; i++) {
        const v = buf.readInt16LE(i * 2);
        s += v * v;
    }
    return Math.sqrt(s / n);
}

async function main() {
    const opts = parseArgs(process.argv.slice(2));
    const turnNames = opts.wav ? ['wav'] : opts.turns.split(',').map((s) => s.trim()).filter(Boolean);
    for (const t of turnNames) if (t !== 'wav' && !UTTERANCES[t]) fatal(1, `unknown turn ${t} (have: ${Object.keys(UTTERANCES).join(', ')})`);
    const token = readToken();

    log(`preflight ${opts.url}`);
    const pf = await preflight(opts.url);
    if (!pf.ok) {
        // Without the route, happy-server drops unknown WebSocket upgrades (Caddy then answers 502).
        if (pf.status === 404 || pf.status === 502 || pf.error === 'ECONNRESET')
            fatal(
                2,
                `${opts.url} refused the WebSocket upgrade (${pf.status || pf.error}): the voice stream route is ` +
                    'probably not deployed on this server yet (needs happy-server with /v1/voice/stream)',
            );
        if (pf.status) fatal(2, `${opts.url} refused the WebSocket upgrade with HTTP ${pf.status}`);
        fatal(2, `${opts.url} unreachable: ${pf.error}`);
    }

    log(opts.wav ? `loading ${opts.wav}` : `speech clips via TTS ${opts.tts} (${opts.voice}), cached under ~/.cache/happy-voice-stream-e2e`);
    const clips = {};
    for (const t of turnNames) clips[t] = await speechClip(opts, t);

    // --- state ---
    const st = {
        ready: false,
        conversationId: null,
        agentPresent: false,
        agentState: '',
        agentStates: [],
        configRequests: 0,
        rpcs: [],
        flushes: 0,
        error: null,
        closed: null,
        down: [], // arrival times (ms) of downlink frames
        downLoud: [], // parallel: frame is speech
        downBad: 0,
        inSpeech: false,
        lastLoud: -Infinity,
        onsets: [],
        upFrames: 0,
        upLate: 0,
    };

    const ws = new WebSocket(opts.url);
    ws.binaryType = 'arraybuffer';
    const opened = new Promise((resolve, reject) => {
        ws.addEventListener('open', resolve, { once: true });
        ws.addEventListener('error', () => reject(new Error('WebSocket error')), { once: true });
    });

    ws.addEventListener('message', (ev) => {
        const now = performance.now();
        if (typeof ev.data !== 'string') {
            const buf = Buffer.from(ev.data);
            if (buf.length !== DOWN_BYTES) st.downBad++;
            const loud = rms(buf) > SPEECH_RMS;
            st.down.push(now);
            st.downLoud.push(loud);
            if (loud) {
                if (!st.inSpeech) {
                    st.inSpeech = true;
                    st.onsets.push(now);
                }
                st.lastLoud = now;
            } else if (st.inSpeech && now - st.lastLoud > SPEECH_RELEASE_MS) st.inSpeech = false;
            return;
        }
        let m;
        try {
            m = JSON.parse(ev.data);
        } catch {
            log(`bad JSON from server: ${String(ev.data).slice(0, 100)}`);
            return;
        }
        if (opts.verbose && m.type !== 'rpc') log('<-', JSON.stringify(m).slice(0, 160));
        switch (m.type) {
            case 'ready':
                st.ready = true;
                st.conversationId = m.conversationId;
                break;
            case 'error':
                st.error = m;
                break;
            case 'agent':
                st.agentPresent = !!m.present;
                if (m.state && m.state !== st.agentState) {
                    st.agentState = m.state;
                    st.agentStates.push([now, m.state]);
                    log(`agent state: ${m.state}`);
                }
                break;
            case 'flush':
                st.flushes++;
                break;
            case 'rpc': {
                st.rpcs.push([now, m.method]);
                let result;
                if (m.method === 'happy.getConfig') {
                    st.configRequests++;
                    result = JSON.stringify(CONFIG);
                } else if (m.method === 'sendMessageToSession') result = "sent [DO NOT say anything else, simply say 'sent']";
                else if (m.method === 'processPermissionRequest') result = "done [DO NOT say anything else, simply say 'done']";
                log(`<- rpc ${m.method}`);
                if (result !== undefined) ws.send(JSON.stringify({ type: 'rpcResult', id: m.id, result }));
                else ws.send(JSON.stringify({ type: 'rpcResult', id: m.id, error: `unsupported method ${m.method}` }));
                break;
            }
            default:
                break;
        }
    });
    ws.addEventListener('close', (ev) => {
        st.closed = { code: ev.code, reason: ev.reason };
    });

    try {
        await opened;
    } catch (e) {
        fatal(2, `could not open ${opts.url}: ${e.message}`);
    }
    log('connected; sending hello');
    const hello = { type: 'hello', token, language: 'en' };
    if (opts.session) hello.sessionId = opts.session;
    ws.send(JSON.stringify(hello));

    const waitFor = async (pred, timeoutMs, step = 20) => {
        const end = performance.now() + timeoutMs;
        while (performance.now() < end) {
            if (pred() || st.error || st.closed) return pred();
            await sleep(step);
        }
        return pred();
    };
    const bail = (msg) => {
        if (st.error) msg += ` (server error ${st.error.code}: ${st.error.message})`;
        else if (st.closed) msg += ` (socket closed ${st.closed.code} ${st.closed.reason || ''})`;
        try {
            ws.close();
        } catch {}
        fatal(1, msg);
    };

    if (!(await waitFor(() => st.ready, 10000))) {
        if (st.error?.code === 'unauthorized') bail('server rejected the token');
        bail('no ready from server within 10 s');
    }
    log(`ready, conversation ${st.conversationId}`);

    // --- uplink pacer: one 20 ms frame per tick, silence unless a clip is playing ---
    const silence = Buffer.alloc(UP_SAMPLES * 2);
    const queue = [];
    let current = null;
    let pos = 0;
    let running = true;
    const start = performance.now();
    let k = 0;
    const pace = () => {
        if (!running || ws.readyState !== WebSocket.OPEN) return;
        const now = performance.now();
        if (now - (start + k * FRAME_MS) > FRAME_MS) st.upLate++;
        if (!current && queue.length) {
            current = queue.shift();
            pos = 0;
        }
        let frame = silence;
        if (current) {
            const chunk = current.pcm.subarray(pos, pos + UP_SAMPLES);
            frame = Buffer.alloc(UP_SAMPLES * 2);
            for (let i = 0; i < chunk.length; i++) frame.writeInt16LE(chunk[i], i * 2);
            // frame covers samples [pos, pos + 320); it leaves "now", i.e. at the end of its capture
            if (current.lastLoud >= pos && current.lastLoud < pos + UP_SAMPLES) {
                const after = pos + UP_SAMPLES - 1 - current.lastLoud;
                current.resolve(now - (after * 1000) / UP_RATE);
            }
            pos += UP_SAMPLES;
            if (pos >= current.pcm.length) current = null;
        }
        ws.send(frame);
        st.upFrames++;
        k++;
        setTimeout(pace, Math.max(0, start + k * FRAME_MS - performance.now()));
    };
    pace();
    const say = (pcm) =>
        new Promise((resolve) => {
            let lastLoud = -1;
            for (let i = pcm.length - 1; i >= 0; i--)
                if (Math.abs(pcm[i]) > LOUD_SAMPLE) {
                    lastLoud = i;
                    break;
                }
            if (lastLoud < 0) lastLoud = pcm.length - 1;
            queue.push({ pcm, lastLoud, resolve });
        });

    const onsetAfter = (t) => st.onsets.find((o) => o >= t);
    const waitQuiet = (timeoutMs = 25000) =>
        waitFor(
            () => (st.agentStates.length === 0 || st.agentState === 'listening') && !st.inSpeech && performance.now() - st.lastLoud > 800,
            timeoutMs,
        );

    // --- conversation ---
    const turns = [];
    if (!(await waitFor(() => st.agentPresent, 20000))) bail('agent did not join within 20 s (is the voice-agent worker up?)');
    log('agent joined');
    await waitFor(() => st.configRequests > 0, 15000);
    if (!st.configRequests) log('WARN: agent never called happy.getConfig');
    if (await waitFor(() => st.onsets.length > 0, 20000)) log(`greeting audio after ${f0(st.onsets[0] - start)} ms of streaming`);
    else log('WARN: no greeting audio');

    for (const name of turnNames) {
        await waitQuiet();
        const text = name === 'wav' ? opts.wav : UTTERANCES[name];
        log(`user says: ${JSON.stringify(text)} (${f1(clips[name].length / UP_RATE)} s)`);
        const end = await say(clips[name]);
        const got = await waitFor(() => onsetAfter(end) !== undefined, 15000);
        const first = onsetAfter(end);
        const turn = { name, end, first: got ? first : undefined };
        turns.push(turn);
        if (got) log(`  first agent audio ${f0(first - end)} ms after end of speech`);
        else log('  no agent audio within 15 s');
        if (st.error || st.closed) break;
    }
    await waitQuiet();
    await sleep(1000); // ~1 s of trailing silence
    running = false;
    if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'end' }));
        await sleep(200);
        ws.close();
    }

    // --- report ---
    const lat = turns.filter((t) => t.first !== undefined).map((t) => t.first - t.end);
    const intervals = [];
    const speechIntervals = [];
    let gaps = 0;
    let speechGaps = 0;
    let pauses = 0;
    for (let i = 1; i < st.down.length; i++) {
        const d = st.down[i] - st.down[i - 1];
        if (d > PAUSE_MS) {
            pauses++;
            continue;
        }
        intervals.push(d);
        const speech = st.downLoud[i] || st.downLoud[i - 1];
        if (speech) speechIntervals.push(d);
        if (d > GAP_MS) {
            gaps++;
            if (speech) speechGaps++;
        }
    }
    // playout simulation: fixed 40 ms buffer, rebuffer on underrun; pauses restart playout
    let underruns = 0;
    let speechUnderruns = 0;
    let playStart = NaN;
    let idx = 0;
    for (let i = 0; i < st.down.length; i++) {
        const a = st.down[i];
        if (i === 0 || a - st.down[i - 1] > PAUSE_MS) {
            playStart = a + JITTER_BUFFER_MS;
            idx = 0;
        } else if (a > playStart + idx * FRAME_MS) {
            underruns++;
            if (st.downLoud[i]) speechUnderruns++;
            playStart = a + JITTER_BUFFER_MS - idx * FRAME_MS;
        }
        idx++;
    }
    const si = [...intervals].sort((a, b) => a - b);
    const ssi = [...speechIntervals].sort((a, b) => a - b);
    const dev = intervals.map((d) => Math.abs(d - FRAME_MS)).sort((a, b) => a - b);

    console.log('\n=== voice stream e2e ===');
    console.log(`url                   ${opts.url}`);
    console.log(`conversation          ${st.conversationId}`);
    console.log(
        `end of speech -> first agent audio: ${lat.map((x) => f0(x)).join(', ') || '-'} ms` +
            (lat.length ? `; p50 ${f0(pct([...lat].sort((a, b) => a - b), 50))} ms, max ${f0(Math.max(...lat))} ms` : ''),
    );
    console.log(`downlink frames       ${st.down.length} (${st.downBad} not ${DOWN_BYTES} B), ${st.onsets.length} speech segments, ${pauses} stream pauses > ${PAUSE_MS} ms`);
    console.log(`downlink interval     p50 ${f1(pct(si, 50))} / p95 ${f1(pct(si, 95))} / max ${f1(si.at(-1))} ms; |interval-20| p95 ${f1(pct(dev, 95))} ms`);
    console.log(`  during speech       p50 ${f1(pct(ssi, 50))} / p95 ${f1(pct(ssi, 95))} / max ${f1(ssi.at(-1))} ms (${ssi.length} intervals)`);
    console.log(`gaps > ${GAP_MS} ms           ${gaps} (${speechGaps} during speech)`);
    console.log(`${JITTER_BUFFER_MS} ms jitter buffer   ${underruns} underruns (${speechUnderruns} during speech)`);
    console.log(`uplink frames         ${st.upFrames} (${st.upLate} sent > 20 ms late by this process)`);
    console.log(`rpcs                  ${st.rpcs.map((r) => r[1]).join(', ') || '-'}; flushes ${st.flushes}`);
    console.log(`agent states          ${st.agentStates.map((s) => s[1]).join(' -> ') || '-'}`);

    if (st.error) fatal(1, `server error ${st.error.code}: ${st.error.message}`);
    if (lat.length !== turns.length || turns.length !== turnNames.length) fatal(1, `only ${lat.length}/${turnNames.length} turns got an audible reply`);
    console.log('PASS');
    process.exit(0);
}

main().catch((e) => fatal(1, e.stack || String(e)));
