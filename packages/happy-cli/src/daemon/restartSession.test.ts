import { describe, expect, it, vi } from 'vitest';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Metadata } from '@/api/types';
import type { SpawnSessionResult } from '@/modules/common/registerCommonHandlers';
import { FakeProcessTable } from '@/session/fakeProcessTable.testkit';
import { createSessionRestarter, type SessionRestarterDeps } from './restartSession';

// Above the kernel's pid_max: never a real process.
const PID = 5_100_000;
const HAPPY = 'node /opt/happy/dist/index.mjs';

function setup(overrides: Partial<SessionRestarterDeps> & { flavor?: string; metadata?: Partial<Metadata> | null } = {}) {
    const table = new FakeProcessTable();
    table.selfPid = PID + 1;
    table.add({ pid: PID + 1, ppid: 1, commandLine: `${HAPPY} daemon start-sync`, startTimeMs: table.boot });
    table.add({ pid: PID + 20, commandLine: `${HAPPY} codex --resume thr-1`, startTimeMs: table.clock - 10_000 });
    let tracked: number | undefined = PID + 20;
    const stopped: number[] = [];
    const resume = vi.fn(async (): Promise<SpawnSessionResult> => {
        tracked = PID + 99;
        table.add({ pid: PID + 99, commandLine: `${HAPPY} codex --resume thr-1`, startTimeMs: table.clock });
        return { type: 'success', sessionId: 'happy-1' };
    });
    const metadata = overrides.metadata === null
        ? undefined
        : { path: '/work', host: 'h', flavor: overrides.flavor ?? 'codex', codexThreadId: 'thr-1', ...overrides.metadata } as Metadata;
    const deps: SessionRestarterDeps = {
        lookupMetadata: () => metadata,
        trackedPids: () => (tracked === undefined ? [] : [{ pid: tracked, daemonSpawned: true }]),
        readPersisted: () => ({}),
        opencodeStateDir: join(mkdtempSync(join(tmpdir(), 'restart-session-test-')), 'opencode-tui'),
        onStopped: (pid) => {
            stopped.push(pid);
            if (pid === tracked) {
                tracked = undefined;
            }
        },
        resume,
        currentPid: () => tracked,
        ops: table.ops(),
        graceMs: 1_000,
        ...overrides,
    };
    return { table, deps, resume, stopped, restarter: createSessionRestarter(deps) };
}

describe('createSessionRestarter', () => {
    it('stops the running process, resumes the same session and reports both pids', async () => {
        const { restarter, resume, stopped, table } = setup();
        const result = await restarter.restart('happy-1', { model: 'gpt-5', permissionMode: 'yolo' });
        expect(result).toEqual({ type: 'success', sessionId: 'happy-1', stoppedPids: [PID + 20], newPid: PID + 99 });
        expect(stopped).toEqual([PID + 20]);
        expect(table.processes.has(PID + 20)).toBe(false);
        expect(resume).toHaveBeenCalledWith('happy-1', { model: 'gpt-5', permissionMode: 'yolo' }, { afterForceStop: true });
    });

    it('starts a session that was not running', async () => {
        const { restarter, table } = setup();
        table.exit(PID + 20);
        const result = await restarter.restart('happy-1');
        expect(result).toEqual({ type: 'success', sessionId: 'happy-1', stoppedPids: [], newPid: PID + 99 });
    });

    it('runs one restart for concurrent requests', async () => {
        const { restarter, resume } = setup();
        const [first, second] = await Promise.all([restarter.restart('happy-1'), restarter.restart('happy-1')]);
        expect(resume).toHaveBeenCalledTimes(1);
        expect(second).toEqual(first);
    });

    it('exposes the running restart and forgets it once done', async () => {
        const { restarter } = setup();
        const promise = restarter.restart('happy-1');
        expect(restarter.inFlight('happy-1')).toBe(promise);
        await promise;
        expect(restarter.inFlight('happy-1')).toBeUndefined();
    });

    it('answers a repeat within the dedupe window with the same result, and restarts again after it', async () => {
        const { restarter, resume, table } = setup({ dedupeWindowMs: 5_000 });
        const first = await restarter.restart('happy-1');
        const repeat = await restarter.restart('happy-1');
        expect(repeat).toEqual(first);
        expect(resume).toHaveBeenCalledTimes(1);
        table.clock += 6_000;
        await restarter.restart('happy-1');
        expect(resume).toHaveBeenCalledTimes(2);
    });

    it('does not cache a failure', async () => {
        const resume = vi.fn(async (): Promise<SpawnSessionResult> => ({ type: 'error', errorMessage: 'no binary' }));
        const { restarter } = setup({ resume });
        const first = await restarter.restart('happy-1');
        expect(first).toEqual({ type: 'error', errorMessage: `Stopped pid ${PID + 20}, but starting it again failed: no binary` });
        await restarter.restart('happy-1');
        expect(resume).toHaveBeenCalledTimes(2);
    });

    it('refuses an unknown session', async () => {
        const { restarter, resume } = setup({ metadata: null });
        const result = await restarter.restart('happy-1');
        expect(result.type).toBe('error');
        expect(resume).not.toHaveBeenCalled();
    });

    it('refuses flavors it cannot restart, without stopping anything', async () => {
        const { restarter, resume, table } = setup({ flavor: 'gemini' });
        const result = await restarter.restart('happy-1');
        expect(result).toEqual({ type: 'error', errorMessage: 'Restarting is not supported for gemini sessions (only Claude, Codex and OpenCode).' });
        expect(table.signals).toEqual([]);
        expect(resume).not.toHaveBeenCalled();
    });

    it('does not start a second copy when the old process survives SIGKILL', async () => {
        const { restarter, resume, table } = setup();
        table.processes.get(PID + 20)!.onSignal = () => { };
        const result = await restarter.restart('happy-1');
        expect(result.type).toBe('error');
        expect(result.type === 'error' && result.errorMessage).toContain(`pid ${PID + 20} still running after SIGKILL`);
        expect(resume).not.toHaveBeenCalled();
    });

    it('SIGKILLs a wedged session and still restarts it', async () => {
        const { restarter, table } = setup();
        table.processes.get(PID + 20)!.onSignal = (signal, fake, pid) => FakeProcessTable.ignoresSoftSignals(signal, fake, pid);
        const result = await restarter.restart('happy-1');
        expect(result).toMatchObject({ type: 'success', stoppedPids: [PID + 20], newPid: PID + 99 });
        expect(table.signals.some((entry) => entry.signal === 'SIGKILL')).toBe(true);
    });

    it('refuses to signal a recorded pid it cannot verify', async () => {
        const { deps, resume, table } = setup({ trackedPids: () => [] });
        const restarter = createSessionRestarter({
            ...deps,
            readPersisted: () => ({
                'happy-1': {
                    encryptionKey: 'k', encryptionVariant: 'dataKey', seq: 0, metadataVersion: 0, agentStateVersion: 0,
                    metadata: { path: '/w', host: 'h', flavor: 'codex', hostPid: PID + 20 } as Metadata,
                    savedAt: table.clock,
                },
            }),
            // Start times unreadable, and the command line names no id.
            ops: { ...table.ops(), startTimeMs: () => null },
        });
        table.processes.get(PID + 20)!.commandLine = `${HAPPY} codex`;
        const result = await restarter.restart('happy-1');
        expect(result.type).toBe('error');
        expect(result.type === 'error' && result.errorMessage).toContain('cannot be read to rule out pid reuse');
        expect(resume).not.toHaveBeenCalled();
        expect(table.signals).toEqual([]);
    });

    it('reports a directory that no longer exists', async () => {
        const resume = vi.fn(async (): Promise<SpawnSessionResult> => ({ type: 'requestToApproveDirectoryCreation', directory: '/gone' }));
        const { restarter } = setup({ resume });
        expect(await restarter.restart('happy-1')).toEqual({ type: 'error', errorMessage: "The session's directory /gone no longer exists." });
    });

    it('turns an exception into an error result', async () => {
        const resume = vi.fn(async (): Promise<SpawnSessionResult> => { throw new Error('boom'); });
        const { restarter } = setup({ resume });
        expect(await restarter.restart('happy-1')).toEqual({ type: 'error', errorMessage: 'Failed to restart session: boom' });
    });

    it('passes the OpenCode owner plan to the resume, policy from the permission mode', async () => {
        const { restarter, resume, table } = setup({ flavor: 'opencode', metadata: { opencodeSessionId: 'ses_A', codexThreadId: undefined } });
        table.processes.get(PID + 20)!.commandLine = `${HAPPY} opencode --resume ses_A --headless`;
        await restarter.restart('happy-1', { permissionMode: 'default' });
        expect(resume).toHaveBeenCalledWith('happy-1', { permissionMode: 'default' }, {
            afterForceStop: true,
            opencode: { opencodeSessionId: 'ses_A', permissionPolicy: 'ask', cwd: undefined },
        });
    });
});
