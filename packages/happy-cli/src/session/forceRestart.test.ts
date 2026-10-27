import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtempSync, renameSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Metadata } from '@/api/types';
import type { PersistedSession } from '@/persistence';
import { writeTuiState, type OpencodeTuiState } from '@/opencode/tui/opencodeProcesses';
import {
    commandLineNames,
    isRestartableFlavor,
    locateSessionProcesses,
    looksLikeHappySession,
    opencodeOwnerArgs,
    opencodePolicyFromPermissionMode,
    opencodeRestartPlan,
    parseElapsed,
    stopSessionProcesses,
} from './forceRestart';
import { FakeProcessTable } from './fakeProcessTable.testkit';

// Fake pids are above the kernel's pid_max, so no real process can ever be hit.
const PID = 5_000_000;
const HAPPY = 'node /opt/happy/dist/index.mjs';

function record(metadata: Partial<Metadata>, savedAt: number): PersistedSession {
    return {
        encryptionKey: 'key',
        encryptionVariant: 'dataKey',
        seq: 0,
        metadataVersion: 0,
        agentStateVersion: 0,
        metadata: { path: '/work', host: 'host', ...metadata } as Metadata,
        savedAt,
    };
}

function state(overrides: Partial<OpencodeTuiState>): OpencodeTuiState {
    return {
        ownerPid: PID + 10,
        serverPid: PID + 11,
        url: 'http://127.0.0.1:4096',
        password: 'pw',
        cwd: '/work/project',
        opencodeSessionId: 'ses_A',
        happySessionId: 'happy-1',
        startedAt: 0,
        ownerTuiAttached: true,
        ...overrides,
    };
}

let table: FakeProcessTable;
let stateDir: string;
let scratch: string;

beforeEach(() => {
    table = new FakeProcessTable();
    table.selfPid = PID + 1;
    // This process (the daemon) and its parent shell.
    table.add({ pid: PID, ppid: 1, commandLine: '/bin/bash', startTimeMs: table.boot + 1_000 });
    table.add({ pid: PID + 1, ppid: PID, commandLine: `${HAPPY} daemon start-sync`, startTimeMs: table.boot + 2_000 });
    scratch = mkdtempSync(join(tmpdir(), 'force-restart-test-'));
    stateDir = join(scratch, 'opencode-tui');
    mkdirSync(stateDir);
});

afterEach(() => {
    // Keep the scratch directory out of the way instead of deleting it.
    try {
        renameSync(scratch, `${scratch}-done`);
    } catch {
        // Nothing to move.
    }
});

describe('command lines', () => {
    it('recognises happy session processes per flavor', () => {
        expect(looksLikeHappySession(`${HAPPY} --happy-starting-mode remote --started-by daemon`, 'claude')).toBe(true);
        expect(looksLikeHappySession('node /home/u/.npm/bin/happy.mjs claude --resume abc', 'claude')).toBe(true);
        expect(looksLikeHappySession(`${HAPPY} codex --resume thr`, 'claude')).toBe(false);
        expect(looksLikeHappySession(`${HAPPY} daemon start-sync`, 'claude')).toBe(false);
        expect(looksLikeHappySession(`${HAPPY} --started-by daemon`, 'claude')).toBe(true);
        expect(looksLikeHappySession(`${HAPPY} claude --flag opencode`, 'opencode')).toBe(false);
        expect(looksLikeHappySession(`${HAPPY} codex --resume thr`, 'codex')).toBe(true);
        expect(looksLikeHappySession(`${HAPPY} opencode --resume ses_A --headless`, 'opencode')).toBe(true);
        expect(looksLikeHappySession(`${HAPPY} opencode --resume ses_A --restart`, 'opencode')).toBe(false);
        expect(looksLikeHappySession('/usr/bin/vim notes.txt', 'claude')).toBe(false);
        expect(looksLikeHappySession('opencode serve --port 4096', 'opencode')).toBe(false);
        expect(looksLikeHappySession(null, 'codex')).toBe(false);
    });

    it('matches ids only as whole arguments', () => {
        expect(commandLineNames(`${HAPPY} opencode --resume ses_A`, 'ses_A')).toBe(true);
        expect(commandLineNames(`${HAPPY} opencode --resume ses_AB`, 'ses_A')).toBe(false);
        expect(commandLineNames(`${HAPPY} opencode`, undefined)).toBe(false);
    });

    it('parses ps elapsed times', () => {
        expect(parseElapsed('05:07')).toBe(307);
        expect(parseElapsed('01:00:00')).toBe(3600);
        expect(parseElapsed('2-03:04:05')).toBe(2 * 86400 + 3 * 3600 + 4 * 60 + 5);
        expect(parseElapsed('garbage')).toBeNull();
    });

    it('supports only claude, codex and opencode', () => {
        expect(isRestartableFlavor(undefined)).toBe(true);
        expect(isRestartableFlavor('codex')).toBe(true);
        expect(isRestartableFlavor('opencode')).toBe(true);
        expect(isRestartableFlavor('gemini')).toBe(false);
        expect(isRestartableFlavor('openclaw')).toBe(false);
    });
});

describe('locateSessionProcesses', () => {
    it('takes the tracked pid and signals its group when the daemon spawned it', () => {
        table.add({ pid: PID + 20, commandLine: `${HAPPY} --started-by daemon`, startTimeMs: table.clock - 60_000 });
        const located = locateSessionProcesses({
            flavor: 'claude',
            happySessionId: 'happy-1',
            tracked: [{ pid: PID + 20, daemonSpawned: true }],
            persisted: {},
            ops: table.ops(),
        });
        expect(located.targets).toHaveLength(1);
        expect(located.targets[0]).toMatchObject({ pid: PID + 20, source: 'tracked', signal: 'SIGTERM', group: true, happySessionId: 'happy-1' });
        expect(located.unverified).toEqual([]);
    });

    it('ignores a tracked pid that is already gone', () => {
        const located = locateSessionProcesses({
            flavor: 'claude', happySessionId: 'happy-1', tracked: [{ pid: PID + 20, daemonSpawned: true }], persisted: {}, ops: table.ops(),
        });
        expect(located.targets).toEqual([]);
    });

    it('finds an untracked session through the hostPid it saved in sessions.json', () => {
        const started = table.clock - 120_000;
        table.add({ pid: PID + 30, commandLine: `${HAPPY} codex --resume thr-1`, startTimeMs: started });
        const located = locateSessionProcesses({
            flavor: 'codex',
            happySessionId: 'happy-1',
            resumeTarget: 'thr-1',
            persisted: { 'happy-1': record({ flavor: 'codex', hostPid: PID + 30, codexThreadId: 'thr-1' }, started + 2_000) },
            ops: table.ops(),
        });
        expect(located.targets.map((target) => [target.pid, target.source])).toEqual([[PID + 30, 'sessions.json']]);
    });

    it('never takes the hostPid of another session', () => {
        table.add({ pid: PID + 30, commandLine: `${HAPPY} codex`, startTimeMs: table.clock - 120_000 });
        const located = locateSessionProcesses({
            flavor: 'codex',
            happySessionId: 'happy-1',
            persisted: { 'happy-2': record({ flavor: 'codex', hostPid: PID + 30 }, table.clock - 100_000) },
            ops: table.ops(),
        });
        expect(located.targets).toEqual([]);
    });

    it('ignores a sessions.json pid saved before this boot', () => {
        table.add({ pid: PID + 30, commandLine: `${HAPPY} codex`, startTimeMs: table.boot + 5_000 });
        const located = locateSessionProcesses({
            flavor: 'codex',
            happySessionId: 'happy-1',
            persisted: { 'happy-1': record({ flavor: 'codex', hostPid: PID + 30 }, table.boot - 60_000) },
            ops: table.ops(),
        });
        expect(located.targets).toEqual([]);
        expect(located.unverified).toEqual([]);
    });

    it('ignores a sessions.json pid recycled by another program', () => {
        table.add({ pid: PID + 30, commandLine: '/usr/bin/vim notes.txt', startTimeMs: table.clock - 200_000 });
        const located = locateSessionProcesses({
            flavor: 'claude',
            happySessionId: 'happy-1',
            persisted: { 'happy-1': record({ hostPid: PID + 30 }, table.clock - 100_000) },
            ops: table.ops(),
        });
        expect(located.targets).toEqual([]);
    });

    it('ignores a sessions.json pid recycled by a later happy process', () => {
        const savedAt = table.clock - 100_000;
        table.add({ pid: PID + 30, commandLine: `${HAPPY} --started-by terminal`, startTimeMs: savedAt + 30_000 });
        const located = locateSessionProcesses({
            flavor: 'claude',
            happySessionId: 'happy-1',
            persisted: { 'happy-1': record({ hostPid: PID + 30 }, savedAt) },
            ops: table.ops(),
        });
        expect(located.targets).toEqual([]);
    });

    it('reports a pid whose start time cannot be read instead of signalling it', () => {
        table.add({ pid: PID + 30, commandLine: `${HAPPY} --started-by terminal`, startTimeMs: 0 });
        const ops = { ...table.ops(), startTimeMs: () => null };
        const located = locateSessionProcesses({
            flavor: 'claude', happySessionId: 'happy-1', persisted: { 'happy-1': record({ hostPid: PID + 30 }, table.clock - 1_000) }, ops,
        });
        expect(located.targets).toEqual([]);
        expect(located.unverified.map((entry) => entry.pid)).toEqual([PID + 30]);
    });

    it('accepts a pid of unknown start time whose command line names the session', () => {
        table.add({ pid: PID + 30, commandLine: `${HAPPY} claude --resume claude-ses`, startTimeMs: 0 });
        const ops = { ...table.ops(), startTimeMs: () => null };
        const located = locateSessionProcesses({
            flavor: 'claude', happySessionId: 'happy-1', resumeTarget: 'claude-ses',
            persisted: { 'happy-1': record({ hostPid: PID + 30 }, table.clock - 1_000) }, ops,
        });
        expect(located.targets.map((target) => target.pid)).toEqual([PID + 30]);
        expect(located.unverified).toEqual([]);
    });

    it('never targets itself or its ancestors', () => {
        const located = locateSessionProcesses({
            flavor: 'claude',
            happySessionId: 'happy-1',
            tracked: [{ pid: PID + 1, daemonSpawned: false }],
            persisted: { 'happy-1': record({ hostPid: PID }, table.clock - 1_000) },
            ops: table.ops(),
        });
        expect(located.targets).toEqual([]);
    });

    it('finds the OpenCode owner from its state file and its server as a helper', () => {
        table.add({ pid: PID + 10, commandLine: `${HAPPY} opencode --resume ses_A --headless`, startTimeMs: table.clock - 50_000 });
        table.add({ pid: PID + 11, ppid: PID + 10, commandLine: 'opencode serve --port 4096', startTimeMs: table.clock - 49_000 });
        writeTuiState(stateDir, state({ startedAt: table.clock - 49_500, restartSignal: 'SIGUSR2', permissionPolicy: 'ask' }));
        const located = locateSessionProcesses({
            flavor: 'opencode', happySessionId: 'happy-1', resumeTarget: 'ses_A', persisted: {}, opencodeStateDir: stateDir, ops: table.ops(),
        });
        expect(located.targets).toHaveLength(1);
        expect(located.targets[0]).toMatchObject({ pid: PID + 10, source: 'opencode-state', signal: 'SIGUSR2', opencodeSessionId: 'ses_A' });
        expect(located.targets[0].helpers.map((helper) => helper.pid)).toEqual([PID + 11]);
        expect(opencodeRestartPlan(located, { happySessionId: 'happy-1', opencodeSessionId: 'ses_A' })).toEqual({
            opencodeSessionId: 'ses_A', happySessionId: 'happy-1', cwd: '/work/project', permissionPolicy: 'ask',
        });
    });

    it('ignores a state file whose owner pid was reused after it was written', () => {
        table.add({ pid: PID + 10, commandLine: `${HAPPY} opencode --resume ses_Z --headless`, startTimeMs: table.clock - 1_000 });
        writeTuiState(stateDir, state({ startedAt: table.clock - 100_000 }));
        const located = locateSessionProcesses({
            flavor: 'opencode', happySessionId: 'happy-1', resumeTarget: 'ses_A', persisted: {}, opencodeStateDir: stateDir, ops: table.ops(),
        });
        expect(located.targets).toEqual([]);
    });

    it('follows the owner onto the session it switched to in its TUI', () => {
        // The app still knows ses_A; the owner switched to ses_B, whose state
        // file and link point back to the same Happy session.
        table.add({ pid: PID + 10, commandLine: `${HAPPY} opencode --resume ses_A --headless`, startTimeMs: table.clock - 50_000 });
        table.add({ pid: PID + 11, ppid: PID + 10, commandLine: 'opencode serve --port 4096', startTimeMs: table.clock - 49_000 });
        writeTuiState(stateDir, state({ opencodeSessionId: 'ses_B', startedAt: table.clock - 10_000, cwd: '/work/b' }));
        writeFileSync(join(stateDir, 'happy-sessions.json'), JSON.stringify({ ses_A: { happySessionId: 'happy-1' }, ses_B: { happySessionId: 'happy-1' } }));
        const located = locateSessionProcesses({
            flavor: 'opencode', happySessionId: 'happy-1', resumeTarget: 'ses_A', persisted: {}, opencodeStateDir: stateDir, ops: table.ops(),
        });
        expect(located.opencodeSessionIds.sort()).toEqual(['ses_A', 'ses_B']);
        expect(located.targets.map((target) => target.pid)).toEqual([PID + 10]);
        expect(opencodeRestartPlan(located, { happySessionId: 'happy-1', opencodeSessionId: 'ses_A' })).toMatchObject({
            opencodeSessionId: 'ses_B', cwd: '/work/b',
        });
    });

    it('resolves the Happy session from the link file when only an OpenCode id is given', () => {
        table.add({ pid: PID + 30, commandLine: `${HAPPY} opencode --resume ses_A --headless`, startTimeMs: table.clock - 50_000 });
        writeFileSync(join(stateDir, 'happy-sessions.json'), JSON.stringify({ ses_A: { happySessionId: 'happy-1' } }));
        const located = locateSessionProcesses({
            flavor: 'opencode',
            resumeTarget: 'ses_A',
            persisted: { 'happy-1': record({ flavor: 'opencode', hostPid: PID + 30, opencodeSessionId: 'ses_A' }, table.clock - 40_000) },
            opencodeStateDir: stateDir,
            ops: table.ops(),
        });
        expect(located.targets).toHaveLength(1);
        expect(located.targets[0]).toMatchObject({ pid: PID + 30, source: 'sessions.json', happySessionId: 'happy-1' });
        expect(opencodeRestartPlan(located, { opencodeSessionId: 'ses_A' }).happySessionId).toBe('happy-1');
    });

    it('finds an owner whose state file is gone by its command line and server child', () => {
        table.add({ pid: PID + 40, commandLine: `${HAPPY} opencode --resume ses_A`, startTimeMs: table.clock - 50_000 });
        table.add({ pid: PID + 41, ppid: PID + 40, commandLine: 'opencode serve --port 5000', startTimeMs: table.clock - 49_000 });
        // A TUI attached to that server: not an owner.
        table.add({ pid: PID + 50, commandLine: `${HAPPY} opencode --resume ses_A`, startTimeMs: table.clock - 20_000 });
        table.add({ pid: PID + 51, ppid: PID + 50, commandLine: 'opencode attach http://127.0.0.1:5000', startTimeMs: table.clock - 19_000 });
        // An owner of an unrelated session.
        table.add({ pid: PID + 60, commandLine: `${HAPPY} opencode --resume ses_Q`, startTimeMs: table.clock - 20_000 });
        table.add({ pid: PID + 61, ppid: PID + 60, commandLine: 'opencode serve --port 5001', startTimeMs: table.clock - 19_000 });
        const located = locateSessionProcesses({
            flavor: 'opencode', happySessionId: 'happy-1', resumeTarget: 'ses_A', persisted: {}, opencodeStateDir: stateDir, ops: table.ops(),
        });
        expect(located.targets.map((target) => [target.pid, target.source])).toEqual([[PID + 40, 'command-line']]);
        expect(located.targets[0].helpers.map((helper) => helper.pid)).toEqual([PID + 41]);
    });

    it('finds both owners when two run the same session', () => {
        table.add({ pid: PID + 10, commandLine: `${HAPPY} opencode --resume ses_A --headless`, startTimeMs: table.clock - 50_000 });
        table.add({ pid: PID + 11, ppid: PID + 10, commandLine: 'opencode serve --port 4096', startTimeMs: table.clock - 49_000 });
        writeTuiState(stateDir, state({ startedAt: table.clock - 49_500 }));
        table.add({ pid: PID + 40, commandLine: `${HAPPY} opencode --resume ses_A`, startTimeMs: table.clock - 30_000 });
        table.add({ pid: PID + 41, ppid: PID + 40, commandLine: 'opencode acp', startTimeMs: table.clock - 29_000 });
        const located = locateSessionProcesses({
            flavor: 'opencode', happySessionId: 'happy-1', resumeTarget: 'ses_A', persisted: {}, opencodeStateDir: stateDir, ops: table.ops(),
        });
        expect(located.targets.map((target) => [target.pid, target.source]).sort()).toEqual([
            [PID + 10, 'opencode-state'],
            [PID + 40, 'command-line'],
        ]);
    });

    it('merges a pid found by several sources into one target', () => {
        table.add({ pid: PID + 10, commandLine: `${HAPPY} opencode --resume ses_A --headless`, startTimeMs: table.clock - 50_000 });
        table.add({ pid: PID + 11, ppid: PID + 10, commandLine: 'opencode serve --port 4096', startTimeMs: table.clock - 49_000 });
        writeTuiState(stateDir, state({ startedAt: table.clock - 49_500, restartSignal: 'SIGUSR2' }));
        const located = locateSessionProcesses({
            flavor: 'opencode',
            happySessionId: 'happy-1',
            resumeTarget: 'ses_A',
            tracked: [{ pid: PID + 10, daemonSpawned: true }],
            persisted: { 'happy-1': record({ flavor: 'opencode', hostPid: PID + 10, opencodeSessionId: 'ses_A' }, table.clock - 40_000) },
            opencodeStateDir: stateDir,
            ops: table.ops(),
        });
        expect(located.targets).toHaveLength(1);
        expect(located.targets[0]).toMatchObject({ pid: PID + 10, source: 'tracked', signal: 'SIGUSR2', group: true });
        expect(located.targets[0].opencodeState?.opencodeSessionId).toBe('ses_A');
    });
});

describe('stopSessionProcesses', () => {
    const noReap = { reapOrphans: () => [] };

    it('stops a session that exits on SIGTERM without SIGKILL', async () => {
        table.add({ pid: PID + 20, commandLine: `${HAPPY} codex`, startTimeMs: table.clock - 1_000, exitDelayMs: 500 });
        const located = locateSessionProcesses({ flavor: 'codex', happySessionId: 'h', tracked: [{ pid: PID + 20, daemonSpawned: false }], persisted: {}, ops: table.ops() });
        const result = await stopSessionProcesses(located.targets, { ops: table.ops(), ...noReap });
        expect(result).toEqual({ stoppedPids: [PID + 20], survivors: [], killed: [], reaped: [] });
        expect(table.signals).toEqual([{ pid: PID + 20, signal: 'SIGTERM' }]);
    });

    it('SIGKILLs a session that ignores SIGTERM once the grace period is over', async () => {
        const start = table.clock;
        table.add({
            pid: PID + 20, commandLine: `${HAPPY} --started-by daemon`, startTimeMs: table.clock - 1_000,
            onSignal: (signal, fake, pid) => FakeProcessTable.ignoresSoftSignals(signal, fake, pid),
        });
        const located = locateSessionProcesses({ flavor: 'claude', happySessionId: 'h', tracked: [{ pid: PID + 20, daemonSpawned: true }], persisted: {}, ops: table.ops() });
        const result = await stopSessionProcesses(located.targets, { ops: table.ops(), graceMs: 8_000, ...noReap });
        expect(result.stoppedPids).toEqual([PID + 20]);
        expect(result.killed).toEqual([PID + 20]);
        expect(result.survivors).toEqual([]);
        expect(table.signals.map((entry) => entry.signal)).toEqual(['SIGTERM', 'SIGTERM', 'SIGKILL']);
        expect(table.clock - start).toBeGreaterThanOrEqual(8_000);
    });

    it('sends SIGUSR2 to the owner only, never to its process group', async () => {
        table.add({ pid: PID + 10, commandLine: `${HAPPY} opencode --resume ses_A`, startTimeMs: table.clock - 50_000 });
        table.add({ pid: PID + 12, ppid: PID + 10, pgid: PID + 10, commandLine: 'opencode attach http://x', startTimeMs: table.clock - 49_000 });
        writeTuiState(stateDir, state({ startedAt: table.clock - 49_500, restartSignal: 'SIGUSR2', serverPid: PID + 99 }));
        const located = locateSessionProcesses({ flavor: 'opencode', happySessionId: 'happy-1', resumeTarget: 'ses_A', persisted: {}, opencodeStateDir: stateDir, ops: table.ops() });
        await stopSessionProcesses(located.targets, { ops: table.ops(), ...noReap });
        expect(table.signals[0]).toEqual({ pid: PID + 10, signal: 'SIGUSR2' });
        expect(table.signals.some((entry) => entry.pid === PID + 12 && entry.signal === 'SIGUSR2')).toBe(false);
    });

    it('stops the OpenCode server the owner left behind, after the owner', async () => {
        table.add({ pid: PID + 10, commandLine: `${HAPPY} opencode --resume ses_A`, startTimeMs: table.clock - 50_000 });
        // The server runs in its own group and survives the owner.
        table.add({ pid: PID + 11, ppid: PID + 10, pgid: PID + 11, commandLine: 'opencode serve --port 4096', startTimeMs: table.clock - 49_000 });
        writeTuiState(stateDir, state({ startedAt: table.clock - 49_500 }));
        const located = locateSessionProcesses({ flavor: 'opencode', happySessionId: 'happy-1', resumeTarget: 'ses_A', persisted: {}, opencodeStateDir: stateDir, ops: table.ops() });
        const result = await stopSessionProcesses(located.targets, { ops: table.ops(), ...noReap });
        expect(result.stoppedPids).toEqual([PID + 10, PID + 11]);
        expect(table.processes.has(PID + 11)).toBe(false);
        expect(table.signals.findIndex((entry) => entry.pid === PID + 11))
            .toBeGreaterThan(table.signals.findIndex((entry) => entry.pid === PID + 10));
    });

    it('reports a process that survives SIGKILL', async () => {
        table.add({ pid: PID + 20, commandLine: `${HAPPY} codex`, startTimeMs: table.clock - 1_000, onSignal: () => { } });
        const located = locateSessionProcesses({ flavor: 'codex', happySessionId: 'h', tracked: [{ pid: PID + 20, daemonSpawned: false }], persisted: {}, ops: table.ops() });
        const result = await stopSessionProcesses(located.targets, { ops: table.ops(), graceMs: 1_000, ...noReap });
        expect(result.survivors).toEqual([PID + 20]);
        expect(result.stoppedPids).toEqual([]);
    });

    it('does not signal a pid that exited and was reused before the stop', async () => {
        table.add({ pid: PID + 20, commandLine: `${HAPPY} codex`, startTimeMs: table.clock - 1_000 });
        const located = locateSessionProcesses({ flavor: 'codex', happySessionId: 'h', tracked: [{ pid: PID + 20, daemonSpawned: false }], persisted: {}, ops: table.ops() });
        table.exit(PID + 20);
        table.add({ pid: PID + 20, commandLine: '/usr/bin/vim', startTimeMs: table.clock });
        const result = await stopSessionProcesses(located.targets, { ops: table.ops(), ...noReap });
        expect(table.signals).toEqual([]);
        expect(result.stoppedPids).toEqual([]);
        expect(table.processes.has(PID + 20)).toBe(true);
    });

    it('runs the orphan reaper and reports what it stopped', async () => {
        const result = await stopSessionProcesses([], { ops: table.ops(), reapOrphans: () => [PID + 70] });
        expect(result.reaped).toEqual([PID + 70]);
    });
});

describe('restarting OpenCode', () => {
    it('launches the headless TUI-style owner', () => {
        expect(opencodeOwnerArgs({ opencodeSessionId: 'ses_A', happySessionId: 'happy-1', permissionPolicy: 'auto', startedBy: 'daemon' }))
            .toEqual(['opencode', '--resume', 'ses_A', '--headless', '--permission-mode', 'auto', '--happy-session', 'happy-1', '--started-by', 'daemon']);
        expect(opencodeOwnerArgs({ opencodeSessionId: 'ses_A', permissionPolicy: 'ask' }))
            .toEqual(['opencode', '--resume', 'ses_A', '--headless', '--permission-mode', 'ask']);
    });

    it('maps app permission modes onto OpenCode policies', () => {
        expect(opencodePolicyFromPermissionMode('default')).toBe('ask');
        expect(opencodePolicyFromPermissionMode('yolo')).toBe('auto');
        expect(opencodePolicyFromPermissionMode('bypassPermissions')).toBe('auto');
        expect(opencodePolicyFromPermissionMode(undefined)).toBeUndefined();
    });
});
