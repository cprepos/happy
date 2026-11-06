import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const { happyHome } = vi.hoisted(() => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const fs = require('node:fs') as typeof import('node:fs');
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const os = require('node:os') as typeof import('node:os');
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const path = require('node:path') as typeof import('node:path');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'happy-owner-lock-'));
    process.env.HAPPY_HOME_DIR = dir;
    return { happyHome: dir };
});

import {
    acquireSessionOwnership,
    claimSessionOwnershipOrExit,
    listLiveSessionOwners,
    readLiveSessionOwner,
    releaseAllSessionOwnership,
    type SessionOwnerLockDeps,
} from './sessionOwnerLock';
import { isPidAlive } from './sessionLiveness';
import { configuration } from '@/configuration';

let locksDir: string;

/** A fake process table: pid -> start time. */
function fakeProcesses(table: Record<number, string>) {
    return {
        isPidAlive: (pid: number) => pid in table,
        getStartTime: (pid: number) => (pid in table ? table[pid] : null),
    };
}

function depsFor(pid: number, table: Record<number, string>, extra: Partial<SessionOwnerLockDeps> = {}): Partial<SessionOwnerLockDeps> {
    return {
        locksDir: () => locksDir,
        pid: () => pid,
        now: () => 1_000,
        ...fakeProcesses(table),
        ...extra,
    };
}

function lockFile(id: string) {
    return join(locksDir, `${id}.lock`);
}

function readLock(id: string) {
    return JSON.parse(readFileSync(lockFile(id), 'utf8'));
}

beforeEach(() => {
    locksDir = mkdtempSync(join(tmpdir(), 'happy-owner-locks-'));
});

afterEach(() => {
    rmSync(locksDir, { recursive: true, force: true });
});

describe('sessionOwnerLock', () => {
    it('uses <happy home>/sessions for locks', () => {
        expect(configuration.sessionLocksDir).toBe(join(happyHome, 'sessions'));
    });

    it('acquires a fresh lock and records the owner', () => {
        const table = { 100: 'start-100' };
        const result = acquireSessionOwnership('s1', depsFor(100, table));
        expect(result.acquired).toBe(true);
        expect(readLock('s1')).toMatchObject({ pid: 100, startTime: 'start-100', sessionId: 's1' });
        expect(readLiveSessionOwner('s1', depsFor(1, table))?.pid).toBe(100);
        expect(listLiveSessionOwners(depsFor(1, table)).map((o) => o.sessionId)).toEqual(['s1']);
    });

    it('is re-entrant for the same process', () => {
        const table = { 100: 'start-100' };
        expect(acquireSessionOwnership('s1', depsFor(100, table)).acquired).toBe(true);
        expect(acquireSessionOwnership('s1', depsFor(100, table)).acquired).toBe(true);
    });

    it('refuses while another live process owns the session', () => {
        const table = { 100: 'start-100', 200: 'start-200' };
        acquireSessionOwnership('s1', depsFor(100, table));
        const second = acquireSessionOwnership('s1', depsFor(200, table));
        expect(second).toMatchObject({ acquired: false, owner: { pid: 100 } });
        expect(readLock('s1').pid).toBe(100);
    });

    it('takes over the lock of a dead owner', () => {
        acquireSessionOwnership('s1', depsFor(100, { 100: 'start-100' }));
        const result = acquireSessionOwnership('s1', depsFor(200, { 200: 'start-200' }));
        expect(result.acquired).toBe(true);
        expect(readLock('s1').pid).toBe(200);
    });

    it('takes over when the recorded pid was reused by another process', () => {
        acquireSessionOwnership('s1', depsFor(100, { 100: 'old-start' }));
        const table = { 100: 'new-start', 200: 'start-200' };
        expect(readLiveSessionOwner('s1', depsFor(1, table))).toBeNull();
        const result = acquireSessionOwnership('s1', depsFor(200, table));
        expect(result.acquired).toBe(true);
        expect(readLock('s1').pid).toBe(200);
    });

    it('counts an owner it may not signal (EPERM) as alive', () => {
        acquireSessionOwnership('s1', depsFor(100, { 100: 'start-100' }));
        const eperm = () => { throw Object.assign(new Error('not permitted'), { code: 'EPERM' }); };
        const result = acquireSessionOwnership('s1', depsFor(200, {}, {
            isPidAlive: (pid) => isPidAlive(pid, eperm),
            getStartTime: () => undefined,
        }));
        expect(result).toMatchObject({ acquired: false, owner: { pid: 100 } });
    });

    it('takes over a corrupt or empty lock file', () => {
        writeFileSync(lockFile('s1'), '{not json');
        expect(acquireSessionOwnership('s1', depsFor(200, { 200: 's' })).acquired).toBe(true);
        writeFileSync(lockFile('s2'), '');
        expect(acquireSessionOwnership('s2', depsFor(200, { 200: 's' })).acquired).toBe(true);
        expect(readLock('s2').pid).toBe(200);
    });

    it('release does not delete a lock another process now holds', () => {
        const first = acquireSessionOwnership('s1', depsFor(100, { 100: 'a' }));
        // Process 100 is considered dead; 200 takes over.
        acquireSessionOwnership('s1', depsFor(200, { 200: 'b' }));
        if (first.acquired) first.release();
        expect(readLock('s1').pid).toBe(200);
        const second = acquireSessionOwnership('s1', depsFor(200, { 200: 'b' }));
        if (second.acquired) second.release();
        expect(existsSync(lockFile('s1'))).toBe(false);
    });

    it('lets exactly one of two racing stale takeovers win', () => {
        acquireSessionOwnership('s1', depsFor(100, { 100: 'dead-owner' }));
        const table: Record<number, string> = { 200: 'b', 300: 'c' };
        const results: Array<{ pid: number; acquired: boolean }> = [];

        // B reads the stale lock, then A runs its whole takeover before B
        // reaches the guard.
        let raced = false;
        const bDeps = depsFor(300, table, {
            isPidAlive: (pid) => {
                if (pid === 100 && !raced) {
                    raced = true;
                    const a = acquireSessionOwnership('s1', depsFor(200, table));
                    results.push({ pid: 200, acquired: a.acquired });
                }
                return pid in table;
            },
        });
        const b = acquireSessionOwnership('s1', bDeps);
        results.push({ pid: 300, acquired: b.acquired });

        expect(results.filter((r) => r.acquired)).toEqual([{ pid: 200, acquired: true }]);
        expect(readLock('s1').pid).toBe(200);
    });

    it('a takeover that finds the guard held does not win', () => {
        acquireSessionOwnership('s1', depsFor(100, { 100: 'dead-owner' }));
        const table: Record<number, string> = { 200: 'b', 300: 'c' };
        let inner: boolean | undefined;
        const a = acquireSessionOwnership('s1', depsFor(200, table, {
            onTakeoverGuardHeld: () => {
                inner = acquireSessionOwnership('s1', depsFor(300, table)).acquired;
            },
        }));
        expect(a.acquired).toBe(true);
        expect(inner).toBe(false);
        expect(readLock('s1').pid).toBe(200);
    }, 15_000);

    it('rejects session ids that are not plain identifiers', () => {
        expect(() => acquireSessionOwnership('../etc', depsFor(1, {}))).toThrow();
        expect(readLiveSessionOwner('../etc')).toBeNull();
    });

    it('exits instead of claiming a session owned elsewhere', () => {
        const table = { 100: 'a', 200: 'b' };
        acquireSessionOwnership('s1', depsFor(100, table));
        const exit = vi.spyOn(process, 'exit').mockImplementation((() => undefined) as never);
        const error = vi.spyOn(console, 'error').mockImplementation(() => {});
        try {
            expect(() => claimSessionOwnershipOrExit('s1', depsFor(200, table))).toThrow();
            expect(exit).toHaveBeenCalledWith(0);
            expect(error).toHaveBeenCalledWith('Session s1 is already running (pid 100); not attaching.');
        } finally {
            exit.mockRestore();
            error.mockRestore();
            releaseAllSessionOwnership();
        }
    });
});
