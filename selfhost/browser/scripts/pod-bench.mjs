// Times browser pod starts through the real launcher: cold (a pod created for the chat) and warm
// (a spare taken over), each phase's p50 and p95. Run by `make browser-pod-bench` from
// $HAPPY_BROWSER_HOME/run (the socket path is used relatively: an absolute one can pass the unix
// socket length limit). Refuses to run while any pod is up, so it never touches a chat's browser:
// point it at a test project (BROWSER_PROJECT, HAPPY_BROWSER_HOME, POD_*_BASE).
// Prints numbers only, never a token or password, and writes them to <home>/bench/.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { createLauncherClient, createPodClient, createPodManager } from '../bridge/lib/pods.mjs';

const home = process.env.HAPPY_BROWSER_HOME;
const runs = Math.max(1, Number(process.env.RUNS) || 5);
const version = process.env.VERSION || '0.0.1';
const token = readFileSync(join(home, 'secrets/api-token'), 'utf8').trim();
const launcher = createLauncherClient(process.env.LAUNCHER_SOCKET || 'launcher.sock', { timeoutMs: 120_000 });
const bases = { novnc: Number(process.env.POD_NOVNC_BASE || 6100), api: Number(process.env.POD_API_BASE || 8100), playwright: Number(process.env.POD_PLAYWRIGHT_BASE || 9300) };

const up = await launcher.call('list', {});
if (up.pods.length) {
    console.error(`pod-bench: ${up.pods.length} pod(s) are up in this project; it runs only with none (use a test project).`);
    process.exit(2);
}

const store = { forChat: () => ({ id: randomBytes(16).toString('hex') }) };
const makeManager = (warm) => createPodManager({
    launcher, store, maxPods: 2, warm, portBases: bases,
    clientFor: ({ apiPort }) => createPodClient({ baseUrl: `http://127.0.0.1:${apiPort}`, token }),
    log: (m) => { if (!/password|token/i.test(m)) console.log(`  ${m}`); },
});
const q = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.ceil(p * s.length) - 1)]; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function round(kind) {
    const mgr = makeManager(kind === 'warm' ? 1 : 0);
    const rows = [];
    for (let i = 0; i < runs; i++) {
        if (kind === 'warm') {
            await mgr.refill();
            // A spare that is up and idle, as a chat would find it.
            for (let t = 0; t < 120 && ![...mgr._pods.values()].some((p) => p.state === 'ready'); t++) await sleep(500);
            await sleep(1000);
        }
        const key = randomBytes(16).toString('hex');
        const t0 = Date.now();
        await mgr.ensure(key, { source: 'bench' });
        const ensureMs = Date.now() - t0;
        const t1 = Date.now();
        await mgr.stopChat(key, 'bench');
        const row = { ...mgr.timings.at(-1), ensure_ms: ensureMs, stop_ms: Date.now() - t1 };
        rows.push(row);
        console.log(`${kind} ${i + 1}/${runs}: ${JSON.stringify(row)}`);
    }
    // Stop the spare the warm round left.
    for (const p of [...mgr._pods.values()]) await launcher.call('stop', { slot: p.slot }).catch(() => {});
    mgr.close();
    return rows;
}

const out = { version, runs, at: new Date().toISOString(), cold: await round('cold'), warm: await round('warm') };
const phases = ['ensure_ms', 'total_ms', 'created_ms', 'node_ready_ms', 'ctl_ready_ms', 'session_ms', 'stop_ms'];
out.summary = {};
for (const kind of ['cold', 'warm']) {
    out.summary[kind] = {};
    for (const ph of phases) {
        const xs = out[kind].map((r) => r[ph]).filter((v) => typeof v === 'number');
        if (xs.length) out.summary[kind][ph] = { p50: q(xs, 0.5), p95: q(xs, 0.95) };
    }
}
console.log('\nphase            cold p50/p95      warm p50/p95');
for (const ph of phases) {
    const c = out.summary.cold[ph], w = out.summary.warm[ph];
    const f = (x) => (x ? `${x.p50}/${x.p95} ms` : '-');
    console.log(`${ph.padEnd(16)} ${f(c).padEnd(17)} ${f(w)}`);
}
const dir = join(home, 'bench', `v${version}`);
mkdirSync(dir, { recursive: true });
const file = join(dir, `pod-bench-${out.at.replace(/[:.]/g, '-')}.json`);
writeFileSync(file, JSON.stringify(out, null, 2) + '\n');
console.log(`\nwritten to ${file}`);
process.exit(0);
