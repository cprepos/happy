/**
 * Running sessions re-announce themselves to a restarted daemon.
 *
 * The daemon state file is mocked to name one daemon or another; the daemon
 * HTTP endpoint is a stubbed fetch that records what each daemon was told.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const { daemonState } = vi.hoisted(() => ({
    daemonState: { current: null as null | { pid: number; httpPort: number } },
}));

vi.mock('@/persistence', () => ({
    readDaemonState: vi.fn(async () => daemonState.current),
    clearDaemonState: vi.fn(),
}));

import { notifyDaemonSessionStarted, reannounceSessionIfDaemonChanged, stopSessionReannouncement } from './controlClient';
import type { Metadata } from '@/api/types';

const metadata = { path: '/w', host: 'h', hostPid: 123, flavor: 'opencode' } as unknown as Metadata;
const encryption = { encryptionKey: 'a2V5', encryptionVariant: 'dataKey' as const, seq: 1, metadataVersion: 1, agentStateVersion: 1 };

describe('session re-announcement after a daemon restart', () => {
    let posts: Array<{ port: string; body: { sessionId: string } }>;
    let failingPorts: Set<string>;

    beforeEach(() => {
        posts = [];
        failingPorts = new Set();
        // Both "daemons" use this test's own pid so the liveness probe passes.
        daemonState.current = { pid: process.pid, httpPort: 1111 };
        vi.stubGlobal('fetch', vi.fn(async (url: string, init: { body: string }) => {
            const port = new URL(url).port;
            if (failingPorts.has(port)) throw new Error('connection refused');
            posts.push({ port, body: JSON.parse(init.body) });
            return { ok: true, json: async () => ({ ok: true }) };
        }));
    });

    afterEach(() => {
        stopSessionReannouncement();
        vi.unstubAllGlobals();
    });

    it('does nothing while the same daemon is running', async () => {
        await notifyDaemonSessionStarted('s1', metadata, encryption);
        expect(await reannounceSessionIfDaemonChanged()).toBe(false);
        expect(posts.map((p) => p.port)).toEqual(['1111']);
    });

    it('tells a new daemon about the session, once', async () => {
        await notifyDaemonSessionStarted('s1', metadata, encryption);
        daemonState.current = { pid: process.pid, httpPort: 2222 };

        expect(await reannounceSessionIfDaemonChanged()).toBe(true);
        expect(await reannounceSessionIfDaemonChanged()).toBe(false);

        expect(posts.map((p) => p.port)).toEqual(['1111', '2222']);
        expect(posts[1].body).toEqual({ sessionId: 's1', metadata, encryption });
    });

    it('waits while no daemon is running, then announces to the next one', async () => {
        await notifyDaemonSessionStarted('s1', metadata, encryption);
        daemonState.current = null;
        expect(await reannounceSessionIfDaemonChanged()).toBe(false);

        daemonState.current = { pid: process.pid, httpPort: 3333 };
        expect(await reannounceSessionIfDaemonChanged()).toBe(true);
        expect(posts.map((p) => p.port)).toEqual(['1111', '3333']);
    });

    it('keeps trying a new daemon that is not answering yet', async () => {
        await notifyDaemonSessionStarted('s1', metadata, encryption);
        daemonState.current = { pid: process.pid, httpPort: 4444 };
        failingPorts.add('4444');

        expect(await reannounceSessionIfDaemonChanged()).toBe(false);
        failingPorts.clear();
        expect(await reannounceSessionIfDaemonChanged()).toBe(true);
        expect(posts.map((p) => p.port)).toEqual(['1111', '4444']);
    });

    it('announces a session whose first announcement found no daemon', async () => {
        vi.useFakeTimers();
        try {
            daemonState.current = null;
            const first = notifyDaemonSessionStarted('s1', metadata, encryption);
            await vi.advanceTimersByTimeAsync(5_000);
            expect((await first).error).toBeTruthy();
        } finally {
            vi.useRealTimers();
        }

        daemonState.current = { pid: process.pid, httpPort: 5555 };
        expect(await reannounceSessionIfDaemonChanged()).toBe(true);
        expect(posts.map((p) => p.port)).toEqual(['5555']);
    });

    it('re-announces the latest session when a process switches sessions', async () => {
        await notifyDaemonSessionStarted('s1', metadata, encryption);
        await notifyDaemonSessionStarted('s2', metadata, encryption);
        daemonState.current = { pid: process.pid, httpPort: 6666 };

        await reannounceSessionIfDaemonChanged();
        expect(posts.at(-1)).toMatchObject({ port: '6666', body: { sessionId: 's2' } });
    });

    it('does nothing before any session was announced or after it is forgotten', async () => {
        expect(await reannounceSessionIfDaemonChanged()).toBe(false);
        await notifyDaemonSessionStarted('s1', metadata, encryption);
        stopSessionReannouncement();
        daemonState.current = { pid: process.pid, httpPort: 7777 };
        expect(await reannounceSessionIfDaemonChanged()).toBe(false);
    });

    it('re-announces on its own interval', async () => {
        vi.useFakeTimers();
        try {
            await notifyDaemonSessionStarted('s1', metadata, encryption);
            daemonState.current = { pid: process.pid, httpPort: 8888 };
            await vi.advanceTimersByTimeAsync(10_000);
            expect(posts.map((p) => p.port)).toEqual(['1111', '8888']);
        } finally {
            vi.useRealTimers();
        }
    });
});
