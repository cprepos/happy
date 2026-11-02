/**
 * Claude Desktop hub tests, through the real daemon control server over HTTP.
 *
 * The attach spawner is a plain function (the daemon's real one spawns
 * `happy attach`, which is out of scope here); the phone-started flow runs a
 * real fake `claude` script through the real command runner.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startDaemonControlServer } from './controlServer';
import {
    createDesktopHub,
    DesktopAdoptRequest,
    DesktopAttachResult,
    DesktopHub,
    runDesktopCommand,
    startDesktopSessionFromPhone,
} from './desktopHub';

type Harness = {
    hub: DesktopHub;
    port: number;
    stop: () => Promise<void>;
    spawned: DesktopAdoptRequest[];
    nextAttach: (request: DesktopAdoptRequest) => Promise<DesktopAttachResult>;
};

async function startHarness(): Promise<Harness> {
    const spawned: DesktopAdoptRequest[] = [];
    const harness = {
        spawned,
        nextAttach: async (_request: DesktopAdoptRequest): Promise<DesktopAttachResult> => ({
            type: 'success',
            happySessionId: `happy-${spawned.length}`,
            attachPid: 40_000 + spawned.length,
        }),
    } as Harness;
    harness.hub = createDesktopHub({
        spawnAttach: (request) => {
            spawned.push(request);
            return harness.nextAttach(request);
        },
    });
    const server = await startDaemonControlServer({
        getChildren: () => [],
        stopSession: () => false,
        spawnSession: async () => ({ type: 'error', errorMessage: 'not used' }),
        requestShutdown: () => {},
        onHappySessionWebhook: () => {},
        desktopHub: harness.hub,
    });
    harness.port = server.port;
    harness.stop = server.stop;
    return harness;
}

async function post(port: number, path: string, body: unknown): Promise<{ status: number; body: any }> {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
    });
    const text = await response.text();
    return { status: response.status, body: text ? JSON.parse(text) : null };
}

async function get(port: number, path: string): Promise<{ status: number; body: any; elapsedMs: number }> {
    const startedAt = Date.now();
    const response = await fetch(`http://127.0.0.1:${port}${path}`);
    const text = await response.text();
    return { status: response.status, body: text ? JSON.parse(text) : null, elapsedMs: Date.now() - startedAt };
}

const adoptBody = (claudeSessionId: string, pid: number) => ({
    claudeSessionId,
    pid,
    cwd: '/tmp/project',
    transcriptPath: `/tmp/project/${claudeSessionId}.jsonl`,
});

describe('desktop hub over the control server', () => {
    let h: Harness;

    beforeEach(async () => {
        h = await startHarness();
    });

    afterEach(async () => {
        await h.stop();
    });

    it('adopts once per claudeSessionId, even when SessionStart races itself', async () => {
        let release!: () => void;
        const gate = new Promise<void>((resolve) => { release = resolve; });
        h.nextAttach = async () => {
            await gate;
            return { type: 'success', happySessionId: 'happy-A', attachPid: 41_000 };
        };

        const first = post(h.port, '/desktop/adopt', adoptBody('claude-A', 500));
        const second = post(h.port, '/desktop/adopt', adoptBody('claude-A', 500));
        await new Promise((resolve) => setTimeout(resolve, 50));
        release();

        expect(await first).toEqual({ status: 200, body: { happySessionId: 'happy-A' } });
        expect(await second).toEqual({ status: 200, body: { happySessionId: 'happy-A' } });
        expect(await post(h.port, '/desktop/adopt', adoptBody('claude-A', 500))).toEqual({ status: 200, body: { happySessionId: 'happy-A' } });
        expect(h.spawned).toEqual([adoptBody('claude-A', 500)]);
        expect(h.hub.get('claude-A')?.attachPid).toBe(41_000);
    });

    it('re-points the mirror when the same pid reports a new id, and the old id keeps working', async () => {
        await post(h.port, '/desktop/adopt', adoptBody('claude-old', 600));
        const repointed = await post(h.port, '/desktop/adopt', { ...adoptBody('claude-new', 600), transcriptPath: '/tmp/new.jsonl' });

        expect(repointed).toEqual({ status: 200, body: { happySessionId: 'happy-1' } });
        expect(h.spawned).toHaveLength(1);
        expect(h.hub.get('claude-old')).toMatchObject({ claudeSessionId: 'claude-new', transcriptPath: '/tmp/new.jsonl', happySessionId: 'happy-1' });
        // attach polls the old id and learns the new one from this event.
        const repointEvent = { seq: 1, events: [{ type: 'idle', claudeSessionId: 'claude-new', transcriptPath: '/tmp/new.jsonl' }] };
        expect((await get(h.port, '/desktop/events/claude-old?after=0')).body).toEqual(repointEvent);
        expect((await get(h.port, '/desktop/events/claude-new?after=0')).body).toEqual(repointEvent);

        // attach still speaks the id it was started with; hooks speak the new one.
        expect(await post(h.port, '/desktop/enqueue', { claudeSessionId: 'claude-old', localId: 'L1', text: 'hi' })).toEqual({ status: 200, body: { queued: 1 } });
        expect(await get(h.port, '/desktop/inbox/claude-new?wait=0')).toMatchObject({ status: 200, body: { localId: 'L1', text: 'hi' } });

        // A different desktop process is a different mirror.
        expect(await post(h.port, '/desktop/adopt', adoptBody('claude-other', 601))).toEqual({ status: 200, body: { happySessionId: 'happy-2' } });
    });

    it('answers a failed attach with an error status and retries on the next adopt', async () => {
        h.nextAttach = async () => ({ type: 'error', errorMessage: 'attach did not report in' });
        expect(await post(h.port, '/desktop/adopt', adoptBody('claude-F', 700))).toEqual({ status: 500, body: { error: 'attach did not report in' } });
        expect(h.hub.get('claude-F')).toBeUndefined();

        h.nextAttach = async () => ({ type: 'success', happySessionId: 'happy-F', attachPid: 42_000 });
        expect(await post(h.port, '/desktop/adopt', adoptBody('claude-F', 700))).toEqual({ status: 200, body: { happySessionId: 'happy-F' } });
        expect(h.spawned).toHaveLength(2);
    });

    it('spawns a fresh attach when a session that ended is adopted again', async () => {
        await post(h.port, '/desktop/adopt', adoptBody('claude-E', 800));
        expect(await post(h.port, '/desktop/ended', { claudeSessionId: 'claude-E' })).toEqual({ status: 200, body: { ok: true } });
        expect(await post(h.port, '/desktop/adopt', adoptBody('claude-E', 800))).toEqual({ status: 200, body: { happySessionId: 'happy-2' } });

        h.hub.attachExited(40_002);
        expect(h.hub.get('claude-E')?.ended).toBe(true);
        expect(await post(h.port, '/desktop/adopt', adoptBody('claude-E', 800))).toEqual({ status: 200, body: { happySessionId: 'happy-3' } });
    });

    it('takes back a running mirror after a daemon restart, without spawning another', async () => {
        const reattachBody = { ...adoptBody('claude-R', 2500), happySessionId: 'happy-kept', attachPid: 43_000 };
        // A fresh hub knows nothing: this is what the mirror sees after a restart.
        expect((await get(h.port, '/desktop/events/claude-R')).status).toBe(404);

        expect(await post(h.port, '/desktop/reattach', reattachBody)).toEqual({ status: 200, body: { ok: true } });
        expect(h.spawned).toEqual([]);
        expect(h.hub.get('claude-R')).toMatchObject({ happySessionId: 'happy-kept', attachPid: 43_000, pid: 2500 });

        // Hooks and the phone work again, and the next adopt reuses the mirror.
        expect((await post(h.port, '/desktop/busy', { claudeSessionId: 'claude-R' })).status).toBe(200);
        expect(await post(h.port, '/desktop/adopt', adoptBody('claude-R', 2500))).toEqual({ status: 200, body: { happySessionId: 'happy-kept' } });
        expect(h.spawned).toEqual([]);
        const waiting = get(h.port, '/desktop/inbox/claude-R?wait=5000');
        await new Promise((resolve) => setTimeout(resolve, 50));
        expect(await post(h.port, '/desktop/enqueue', { claudeSessionId: 'claude-R', localId: 'L1', text: 'after restart' })).toEqual({ status: 200, body: { queued: 0 } });
        expect(await waiting).toMatchObject({ status: 200, body: { localId: 'L1', text: 'after restart' } });
    });

    it('lets a reattach take over a hook that was already waiting', async () => {
        const waiting = get(h.port, '/desktop/inbox/claude-W?wait=5000');
        await new Promise((resolve) => setTimeout(resolve, 50));
        await post(h.port, '/desktop/reattach', { ...adoptBody('claude-W', 2600), happySessionId: 'happy-W', attachPid: 43_100 });
        await post(h.port, '/desktop/enqueue', { claudeSessionId: 'claude-W', localId: 'L2', text: 'to the early hook' });
        expect(await waiting).toMatchObject({ status: 200, body: { localId: 'L2', text: 'to the early hook' } });
        expect(h.spawned).toEqual([]);
    });

    it('answers 404 for sessions it never adopted', async () => {
        expect((await post(h.port, '/desktop/busy', { claudeSessionId: 'nope' })).status).toBe(404);
        expect((await post(h.port, '/desktop/enqueue', { claudeSessionId: 'nope', localId: 'x', text: 'y' })).status).toBe(404);
        expect((await get(h.port, '/desktop/events/nope')).status).toBe(404);
    });

    it('holds an inbox waiter that arrives before its adopt, and delivers after it', async () => {
        const waiting = get(h.port, '/desktop/inbox/claude-early?wait=5000');
        await new Promise((resolve) => setTimeout(resolve, 50));
        expect(h.hub.get('claude-early')).toMatchObject({ claudeSessionId: 'claude-early', pid: 0 });

        expect(await post(h.port, '/desktop/adopt', adoptBody('claude-early', 1500))).toEqual({ status: 200, body: { happySessionId: 'happy-1' } });
        expect(h.spawned).toEqual([adoptBody('claude-early', 1500)]);
        expect(await post(h.port, '/desktop/enqueue', { claudeSessionId: 'claude-early', localId: 'L0', text: 'first prompt' })).toEqual({ status: 200, body: { queued: 0 } });
        expect(await waiting).toMatchObject({ status: 200, body: { localId: 'L0', text: 'first prompt' } });
        expect((await get(h.port, '/desktop/events/claude-early')).body).toEqual({ seq: 1, events: [{ type: 'delivered', localId: 'L0' }] });
    });

    it('carries an early waiter over when its adopt re-points an existing mirror', async () => {
        await post(h.port, '/desktop/adopt', adoptBody('claude-before', 1600));
        const olderOnOldId = get(h.port, '/desktop/inbox/claude-before?wait=5000');
        await new Promise((resolve) => setTimeout(resolve, 50));
        const early = get(h.port, '/desktop/inbox/claude-after?wait=5000');
        await new Promise((resolve) => setTimeout(resolve, 50));

        expect(await post(h.port, '/desktop/adopt', adoptBody('claude-after', 1600))).toEqual({ status: 200, body: { happySessionId: 'happy-1' } });
        expect((await olderOnOldId).status).toBe(204);
        // attach still enqueues on the id it was started with.
        expect((await post(h.port, '/desktop/enqueue', { claudeSessionId: 'claude-before', localId: 'L9', text: 'after clear' })).body).toEqual({ queued: 0 });
        expect(await early).toMatchObject({ status: 200, body: { localId: 'L9', text: 'after clear' } });
        expect(h.spawned).toHaveLength(1);
    });

    it('forgets an early waiter whose adopt never comes', async () => {
        expect((await get(h.port, '/desktop/inbox/claude-ghost?wait=100')).status).toBe(204);
        expect(h.hub.get('claude-ghost')).toBeUndefined();
    });

    it('holds the SessionStart waiter of an ended id the desktop resumes', async () => {
        await post(h.port, '/desktop/adopt', adoptBody('claude-R', 1700));
        await post(h.port, '/desktop/ended', { claudeSessionId: 'claude-R' });
        const waiting = get(h.port, '/desktop/inbox/claude-R?wait=5000');
        await new Promise((resolve) => setTimeout(resolve, 50));
        expect(await post(h.port, '/desktop/adopt', adoptBody('claude-R', 1701))).toEqual({ status: 200, body: { happySessionId: 'happy-2' } });
        await post(h.port, '/desktop/enqueue', { claudeSessionId: 'claude-R', localId: 'LR', text: 'welcome back' });
        expect(await waiting).toMatchObject({ status: 200, body: { localId: 'LR' } });
    });

    it('returns 204 when the inbox wait runs out', async () => {
        await post(h.port, '/desktop/adopt', adoptBody('claude-T', 900));
        const result = await get(h.port, '/desktop/inbox/claude-T?wait=150');
        expect(result.status).toBe(204);
        expect(result.elapsedMs).toBeGreaterThanOrEqual(140);
    });

    it('lets only the newest inbox waiter receive', async () => {
        await post(h.port, '/desktop/adopt', adoptBody('claude-W', 1000));
        const older = get(h.port, '/desktop/inbox/claude-W?wait=5000');
        await new Promise((resolve) => setTimeout(resolve, 50));
        const newer = get(h.port, '/desktop/inbox/claude-W?wait=5000');

        const released = await older;
        expect(released.status).toBe(204);
        expect(released.elapsedMs).toBeLessThan(1000);

        expect(await post(h.port, '/desktop/enqueue', { claudeSessionId: 'claude-W', localId: 'L-new', text: 'run the tests' })).toEqual({ status: 200, body: { queued: 0 } });
        expect(await newer).toMatchObject({ status: 200, body: { localId: 'L-new', text: 'run the tests' } });
    });

    it('queues while nobody waits, delivers in order, and logs delivered events', async () => {
        await post(h.port, '/desktop/adopt', adoptBody('claude-Q', 1100));
        expect((await post(h.port, '/desktop/enqueue', { claudeSessionId: 'claude-Q', localId: 'L1', text: 'one' })).body).toEqual({ queued: 1 });
        expect((await post(h.port, '/desktop/enqueue', { claudeSessionId: 'claude-Q', localId: 'L2', text: 'two' })).body).toEqual({ queued: 2 });

        expect((await get(h.port, '/desktop/inbox/claude-Q?wait=1000')).body).toEqual({ localId: 'L1', text: 'one' });
        expect((await get(h.port, '/desktop/inbox/claude-Q?wait=1000')).body).toEqual({ localId: 'L2', text: 'two' });
        expect((await get(h.port, '/desktop/events/claude-Q?after=0')).body).toEqual({
            seq: 2,
            events: [{ type: 'delivered', localId: 'L1' }, { type: 'delivered', localId: 'L2' }],
        });
    });

    it('long-polls events after a seq', async () => {
        await post(h.port, '/desktop/adopt', adoptBody('claude-V', 1200));
        await post(h.port, '/desktop/busy', { claudeSessionId: 'claude-V' });
        expect((await get(h.port, '/desktop/events/claude-V?after=0&wait=0')).body).toEqual({ seq: 1, events: [{ type: 'busy' }] });

        const waiting = get(h.port, '/desktop/events/claude-V?after=1&wait=5000');
        await new Promise((resolve) => setTimeout(resolve, 100));
        await post(h.port, '/desktop/idle', { claudeSessionId: 'claude-V' });
        const woke = await waiting;
        expect(woke.body).toEqual({ seq: 2, events: [{ type: 'idle' }] });
        expect(woke.elapsedMs).toBeGreaterThanOrEqual(90);
        expect(woke.elapsedMs).toBeLessThan(2000);

        const empty = await get(h.port, '/desktop/events/claude-V?after=2&wait=100');
        expect(empty.body).toEqual({ seq: 2, events: [] });

        await post(h.port, '/desktop/ended', { claudeSessionId: 'claude-V' });
        expect((await get(h.port, '/desktop/events/claude-V?after=2')).body).toEqual({ seq: 3, events: [{ type: 'ended' }] });
    });

    it('releases the inbox waiter when the session ends', async () => {
        await post(h.port, '/desktop/adopt', adoptBody('claude-X', 1300));
        const waiting = get(h.port, '/desktop/inbox/claude-X?wait=5000');
        await new Promise((resolve) => setTimeout(resolve, 50));
        await post(h.port, '/desktop/ended', { claudeSessionId: 'claude-X' });
        const result = await waiting;
        expect(result.status).toBe(204);
        expect(result.elapsedMs).toBeLessThan(1000);
    });

    it('resolves a pending phone spawn once the id is adopted and attached', async () => {
        const pending = h.hub.waitForAdoption('claude-P', 5000);
        await post(h.port, '/desktop/adopt', adoptBody('claude-P', 1400));
        expect(await pending).toEqual({ type: 'success', happySessionId: 'happy-1' });
        // Already attached: resolves straight away.
        expect(await h.hub.waitForAdoption('claude-P', 5000)).toEqual({ type: 'success', happySessionId: 'happy-1' });
    });

    it('times out a pending phone spawn nobody adopts', async () => {
        const startedAt = Date.now();
        const result = await h.hub.waitForAdoption('claude-never', 150);
        expect(result.type).toBe('error');
        expect(Date.now() - startedAt).toBeGreaterThanOrEqual(140);
    });
});

describe('phone-started desktop session', () => {
    let h: Harness;
    let dir: string;
    let fakeClaude: string;
    let callLog: string;

    beforeEach(async () => {
        h = await startHarness();
        dir = mkdtempSync(join(tmpdir(), 'happy-desktop-'));
        fakeClaude = join(dir, 'fake-claude.cjs');
        callLog = join(dir, 'calls.jsonl');
        // Stands in for Claude Code: logs each call; for `--desktop --resume`
        // it does what the desktop's SessionStart hook would, an adopt POST.
        writeFileSync(fakeClaude, `
const fs = require('fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_CLAUDE_LOG, JSON.stringify({ args, managed: process.env.HAPPY_MANAGED ?? null, cwd: process.cwd() }) + '\\n');
if (process.env.FAKE_CLAUDE_EXIT) process.exit(Number(process.env.FAKE_CLAUDE_EXIT));
const resume = args.indexOf('--resume');
if (args.includes('--desktop') && resume !== -1) {
    fetch('http://127.0.0.1:' + process.env.FAKE_DAEMON_PORT + '/desktop/adopt', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ claudeSessionId: args[resume + 1], transcriptPath: '/tmp/t.jsonl', cwd: process.cwd(), pid: 4242 }),
    }).then(() => process.exit(0), () => process.exit(9));
}
`);
    });

    afterEach(async () => {
        await h.stop();
        rmSync(dir, { recursive: true, force: true });
    });

    const ttyWrapper = process.platform === 'darwin' ? ['script', '-q', '/dev/null'] : [];
    const calls = () => readFileSync(callLog, 'utf8').trim().split('\n').map((line) => JSON.parse(line));

    it('seeds with /cost, opens it in the desktop, and returns the adopted Happy session', async () => {
        const result = await startDesktopSessionFromPhone({
            hub: h.hub,
            directory: dir,
            claudeCommand: [process.execPath, fakeClaude],
            ttyWrapper,
            env: { ...process.env, FAKE_CLAUDE_LOG: callLog, FAKE_DAEMON_PORT: String(h.port), HAPPY_MANAGED: '1' },
            runCommand: runDesktopCommand,
            adoptTimeoutMs: 10_000,
        });

        expect(result).toEqual({ type: 'success', happySessionId: 'happy-1' });
        const [seed, launch] = calls();
        expect(seed.args.slice(0, 2)).toEqual(['-p', '--session-id']);
        expect(seed.args[3]).toBe('/cost');
        expect(seed.managed).toBe('1');
        expect(launch.args).toEqual(['--desktop', '--resume', seed.args[2]]);
        // The desktop's own Claude must be adoptable.
        expect(launch.managed).toBeNull();
        expect(h.spawned[0].claudeSessionId).toBe(seed.args[2]);
    });

    it('fails fast when the seed fails', async () => {
        const result = await startDesktopSessionFromPhone({
            hub: h.hub,
            directory: dir,
            claudeCommand: [process.execPath, fakeClaude],
            ttyWrapper,
            env: { ...process.env, FAKE_CLAUDE_LOG: callLog, FAKE_CLAUDE_EXIT: '3' },
            runCommand: runDesktopCommand,
            adoptTimeoutMs: 10_000,
        });
        expect(result).toMatchObject({ type: 'error' });
        expect(calls()).toHaveLength(1);
        expect(h.spawned).toHaveLength(0);
    });

    it('times out when the desktop never adopts the session', async () => {
        const silentClaude = join(dir, 'silent-claude.cjs');
        writeFileSync(silentClaude, 'process.exit(0)\n');
        const startedAt = Date.now();
        const result = await startDesktopSessionFromPhone({
            hub: h.hub,
            directory: dir,
            claudeCommand: [process.execPath, silentClaude],
            ttyWrapper,
            env: process.env,
            runCommand: runDesktopCommand,
            adoptTimeoutMs: 300,
        });
        expect(result).toMatchObject({ type: 'error' });
        expect(Date.now() - startedAt).toBeGreaterThanOrEqual(290);
    });
});
