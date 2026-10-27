/**
 * Adopting live sessions after a daemon restart.
 *
 * The decision logic runs against described processes; the last block runs it
 * against real child processes this test spawns (and only those) on Linux.
 */

import { spawn, type ChildProcess } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { PersistedSession } from '@/persistence';
import { ADOPTED_SESSION_STARTED_BY, adoptLiveSessions, processMismatch, readProcessInfo, type ProcessInfo } from './adoptSessions';

const BOOT = 1_000_000;
const SAVED = 2_000_000;
const ENTRY = '/home/u/happy/packages/happy-cli/dist/index.mjs';

function record(pid: number, overrides: Partial<PersistedSession> = {}, flavor = 'opencode'): PersistedSession {
    return {
        encryptionKey: Buffer.from('k'.repeat(32)).toString('base64'),
        encryptionVariant: 'dataKey',
        seq: 7,
        metadataVersion: 3,
        agentStateVersion: 2,
        metadata: { path: '/w', host: 'h', hostPid: pid, flavor } as PersistedSession['metadata'],
        savedAt: SAVED,
        lastAliveAt: SAVED,
        ...overrides,
    };
}

function proc(argv: string[], overrides: Partial<ProcessInfo> = {}): ProcessInfo {
    return { argv, startTimeMs: SAVED - 5_000, env: {}, processGroupId: null, ...overrides };
}

function adopt(persisted: Record<string, PersistedSession>, processes: Record<number, ProcessInfo>, alive = new Set(Object.keys(processes).map(Number))) {
    return adoptLiveSessions(persisted, BOOT, {
        isAlive: (pid) => alive.has(pid),
        readProcess: (pid) => processes[pid] ?? null,
    });
}

describe('adoptLiveSessions', () => {
    it('adopts a live session whose process is the recorded Happy session', () => {
        const adopted = adopt({ s1: record(4242) }, { 4242: proc(['/usr/bin/node', '--no-warnings', ENTRY, 'opencode']) });

        expect(adopted).toHaveLength(1);
        expect(adopted[0]).toMatchObject({
            startedBy: ADOPTED_SESSION_STARTED_BY,
            happySessionId: 's1',
            pid: 4242,
            ownsProcessGroup: false,
            encryption: { encryptionVariant: 'dataKey', seq: 7, metadataVersion: 3, agentStateVersion: 2 },
        });
        expect(Buffer.from(adopted[0].encryption!.encryptionKey).toString()).toBe('k'.repeat(32));
    });

    it('marks a process that leads its own group (daemon-spawned, detached)', () => {
        const adopted = adopt({ s1: record(4242) }, { 4242: proc(['node', ENTRY, 'opencode', '--started-by', 'daemon'], { processGroupId: 4242 }) });
        expect(adopted[0].ownsProcessGroup).toBe(true);
    });

    it('skips dead processes', () => {
        expect(adopt({ s1: record(4242) }, { 4242: proc(['node', ENTRY, 'opencode']) }, new Set())).toEqual([]);
    });

    it('skips records written before this boot', () => {
        expect(adopt({ s1: record(4242, { savedAt: BOOT - 1 }) }, { 4242: proc(['node', ENTRY, 'opencode'], { startTimeMs: BOOT - 10 }) })).toEqual([]);
    });

    it('skips a PID that was reused by a process started after the record', () => {
        expect(adopt({ s1: record(4242) }, { 4242: proc(['node', ENTRY, 'opencode'], { startTimeMs: SAVED + 60_000 }) })).toEqual([]);
    });

    it('skips processes whose start time or command line cannot be read', () => {
        expect(adopt({ s1: record(4242) }, { 4242: proc(['node', ENTRY, 'opencode'], { startTimeMs: null }) })).toEqual([]);
        expect(adopt({ s1: record(4242) }, {}, new Set([4242]))).toEqual([]);
    });

    it('skips processes that are not Happy sessions', () => {
        expect(adopt({ s1: record(4242) }, { 4242: proc(['/usr/bin/vim', 'notes.txt']) })).toEqual([]);
        expect(adopt({ s1: record(4242) }, { 4242: proc(['node', ENTRY, 'daemon', 'start-sync']) })).toEqual([]);
    });

    it('skips a Happy session of another flavor', () => {
        expect(adopt({ s1: record(4242) }, { 4242: proc(['node', ENTRY, 'codex']) })).toEqual([]);
    });

    it('skips a process launched for another Happy session', () => {
        const byFlag = proc(['node', ENTRY, 'opencode', '--resume', 'ses_x', '--happy-session', 'other']);
        const byEnv = proc(['node', ENTRY, 'opencode'], { env: { HAPPY_RECONNECT_SESSION_ID: 'other' } });
        expect(adopt({ s1: record(4242) }, { 4242: byFlag })).toEqual([]);
        expect(adopt({ s1: record(4242) }, { 4242: byEnv })).toEqual([]);
    });

    it('accepts a process launched for this very session', () => {
        const byFlag = proc(['node', ENTRY, 'opencode', '--resume', 'ses_x', '--happy-session', 's1']);
        const byEnv = proc(['node', ENTRY, 'opencode'], { env: { HAPPY_RECONNECT_SESSION_ID: 's1' } });
        expect(adopt({ s1: record(4242) }, { 4242: byFlag })).toHaveLength(1);
        expect(adopt({ s1: record(4242) }, { 4242: byEnv })).toHaveLength(1);
    });

    it('keeps only the newest record when several name the same process', () => {
        const adopted = adopt(
            { older: record(4242, { savedAt: SAVED - 1_000 }), newer: record(4242), stale: record(4242, { savedAt: SAVED - 2_000 }) },
            { 4242: proc(['node', ENTRY, 'opencode'], { startTimeMs: SAVED - 10_000 }) },
        );
        expect(adopted.map((s) => s.happySessionId)).toEqual(['newer']);
    });

    it('never adopts its own process or records without a PID', () => {
        const noPid = record(0);
        expect(adopt({ self: record(process.pid), noPid }, { [process.pid]: proc(['node', ENTRY, 'opencode']) })).toEqual([]);
    });
});

describe('processMismatch flavors', () => {
    const claude = record(1, {}, 'claude');
    it.each([
        [['node', ENTRY]],
        [['node', ENTRY, 'claude']],
        [['node', ENTRY, '--happy-starting-mode', 'remote', '--started-by', 'daemon']],
        [['node', '/usr/local/bin/happy']],
        [['node', '/opt/happy/bin/happy.mjs', '--continue']],
    ])('claude matches %j', (argv) => {
        expect(processMismatch('s', claude, proc(argv))).toBeNull();
    });

    it('claude does not match another subcommand', () => {
        expect(processMismatch('s', claude, proc(['node', ENTRY, 'gemini']))).not.toBeNull();
        expect(processMismatch('s', claude, proc(['node', ENTRY, 'doctor']))).not.toBeNull();
    });

    it('an agent flavor matches its subcommand or the generic acp runner', () => {
        const gemini = record(1, {}, 'gemini');
        expect(processMismatch('s', gemini, proc(['node', ENTRY, 'gemini']))).toBeNull();
        expect(processMismatch('s', gemini, proc(['node', ENTRY, 'acp', 'gemini']))).toBeNull();
        expect(processMismatch('s', gemini, proc(['node', ENTRY]))).not.toBeNull();
    });

    it('a missing flavor is treated as claude', () => {
        const legacy = record(1);
        delete (legacy.metadata as { flavor?: string }).flavor;
        expect(processMismatch('s', legacy, proc(['node', ENTRY]))).toBeNull();
    });
});

describe.runIf(process.platform === 'linux')('against real processes', () => {
    const children: ChildProcess[] = [];
    let dir = '';

    afterEach(() => {
        for (const child of children.splice(0)) {
            if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
        }
        if (dir) rmSync(dir, { recursive: true, force: true });
        dir = '';
    });

    async function spawnFakeSession(args: string[], env: Record<string, string> = {}): Promise<ChildProcess> {
        dir = mkdtempSync(join(tmpdir(), 'adopt-'));
        mkdirSync(join(dir, 'dist'));
        const entry = join(dir, 'dist', 'index.mjs');
        writeFileSync(entry, 'console.log("ready"); setInterval(() => {}, 1000);\n');
        const child = spawn(process.execPath, [entry, ...args], { env: { ...process.env, ...env }, detached: true, stdio: ['ignore', 'pipe', 'ignore'] });
        children.push(child);
        await new Promise<void>((resolve) => child.stdout!.once('data', () => resolve()));
        return child;
    }

    it('reads the command line, start time, environment and group of a process', async () => {
        const child = await spawnFakeSession(['opencode'], { HAPPY_RECONNECT_SESSION_ID: 'real-1' });
        const info = readProcessInfo(child.pid!)!;

        expect(info.argv.slice(-2)).toEqual([join(dir, 'dist', 'index.mjs'), 'opencode']);
        expect(Math.abs(info.startTimeMs! - Date.now())).toBeLessThan(30_000);
        expect(info.env?.HAPPY_RECONNECT_SESSION_ID).toBe('real-1');
        expect(info.processGroupId).toBe(child.pid);
    });

    it('adopts a real live session and refuses it once its PID is gone', async () => {
        const child = await spawnFakeSession(['opencode'], { HAPPY_RECONNECT_SESSION_ID: 'real-1' });
        const persisted = { 'real-1': record(child.pid!, { savedAt: Date.now() + 1 }) };

        const adopted = adoptLiveSessions(persisted, 0);
        expect(adopted.map((s) => [s.happySessionId, s.pid, s.ownsProcessGroup])).toEqual([['real-1', child.pid, true]]);
        expect(adoptLiveSessions({ 'other': record(child.pid!, { savedAt: Date.now() + 1 }) }, 0)).toEqual([]);

        const exited = new Promise((resolve) => child.once('exit', resolve));
        child.kill('SIGKILL');
        await exited;
        expect(adoptLiveSessions(persisted, 0)).toEqual([]);
    });

    it('refuses a record written before the process started', async () => {
        const savedBefore = Date.now() - 60_000;
        const child = await spawnFakeSession(['opencode']);
        expect(adoptLiveSessions({ s: record(child.pid!, { savedAt: savedBefore }) }, 0)).toEqual([]);
    });
});
