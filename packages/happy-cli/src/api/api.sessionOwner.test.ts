import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it, vi } from 'vitest';

const { happyHome, MockApiSessionClient } = vi.hoisted(() => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const fs = require('node:fs') as typeof import('node:fs');
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const os = require('node:os') as typeof import('node:os');
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const path = require('node:path') as typeof import('node:path');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'happy-api-owner-'));
    process.env.HAPPY_HOME_DIR = dir;
    return { happyHome: dir, MockApiSessionClient: vi.fn() };
});

vi.mock('./apiSession', () => ({ ApiSessionClient: MockApiSessionClient }));
vi.mock('@/ui/logger', () => ({ logger: { debug: vi.fn() } }));

import { ApiClient } from './api';
import { getProcessStartTime } from '@/utils/processStartTime';

describe('ApiClient.sessionSyncClient ownership', () => {
    it('exits before constructing a client for a session another live process owns', async () => {
        // The parent process (vitest's runner) stands in for the live owner.
        const ownerPid = process.ppid;
        const startTime = getProcessStartTime(ownerPid);
        mkdirSync(join(happyHome, 'sessions'), { recursive: true });
        writeFileSync(join(happyHome, 'sessions', 'owned-session.lock'), JSON.stringify({
            pid: ownerPid,
            startTime: typeof startTime === 'string' ? startTime : null,
            sessionId: 'owned-session',
            acquiredAt: 1,
            cliVersion: 'test',
            startedBy: 'daemon',
        }));
        const exit = vi.spyOn(process, 'exit').mockImplementation(((code?: number) => {
            throw new Error(`exit ${code}`);
        }) as never);
        const error = vi.spyOn(console, 'error').mockImplementation(() => {});

        const api = await ApiClient.create({ token: 't', encryption: { type: 'legacy', secret: new Uint8Array(32) } } as never);
        try {
            expect(() => api.sessionSyncClient({ id: 'owned-session' } as never)).toThrow('exit 0');
            expect(MockApiSessionClient).not.toHaveBeenCalled();
            expect(error).toHaveBeenCalledWith(`Session owned-session is already running (pid ${ownerPid}); not attaching.`);
        } finally {
            exit.mockRestore();
            error.mockRestore();
        }
    });
});
