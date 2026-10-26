import { beforeEach, describe, expect, it, vi } from 'vitest';

const { machineRPC, getSessionDataKey, state } = vi.hoisted(() => ({
    machineRPC: vi.fn(),
    getSessionDataKey: vi.fn(),
    state: { sessions: {} as Record<string, any> },
}));

vi.mock('./apiSocket', () => ({ apiSocket: { machineRPC } }));
vi.mock('./sync', () => ({ sync: { encryption: { getSessionDataKey } } }));
vi.mock('./storage', () => ({ storage: { getState: () => state } }));

import { isUnknownRpcMethodError, machineRestartSession } from './ops';

describe('machineRestartSession', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        state.sessions = {
            'session-1': {
                metadata: { path: '/project', machineId: 'machine-1', opencodeSessionId: 'ses_1' },
                metadataVersion: 3, agentStateVersion: 4, seq: 12,
            },
        };
        getSessionDataKey.mockReturnValue(new Uint8Array(32).fill(1));
        machineRPC.mockResolvedValue({ type: 'success', sessionId: 'session-1', stoppedPids: [11, 12], newPid: 13 });
    });

    it('calls restart-happy-session on the owning machine with the resume fallback', async () => {
        const result = await machineRestartSession({ machineId: 'machine-1', sessionId: 'session-1', permissionMode: 'default' });
        expect(result).toEqual({ type: 'success', sessionId: 'session-1', stoppedPids: [11, 12], newPid: 13 });
        expect(machineRPC).toHaveBeenCalledTimes(1);
        expect(machineRPC).toHaveBeenCalledWith('machine-1', 'restart-happy-session', {
            sessionId: 'session-1',
            model: undefined,
            permissionMode: 'default',
            fallbackReason: 'ok',
            fallback: {
                ...state.sessions['session-1'],
                encryptionVariant: 'dataKey',
                encryptionKey: Buffer.alloc(32, 1).toString('base64'),
            },
        });
    });

    it('withholds the data key from a machine that does not own the session', async () => {
        state.sessions['session-1'].metadata.machineId = 'machine-2';
        await machineRestartSession({ machineId: 'machine-1', sessionId: 'session-1' });
        expect(getSessionDataKey).not.toHaveBeenCalled();
        expect(machineRPC.mock.calls[0][2]).toMatchObject({ fallback: undefined, fallbackReason: 'client-session-machine-mismatch' });
    });

    it('passes the daemon error message through unchanged', async () => {
        machineRPC.mockResolvedValue({ type: 'error', errorMessage: 'Could not stop pid 4242' });
        expect(await machineRestartSession({ machineId: 'machine-1', sessionId: 'session-1' })).toEqual({
            type: 'error', errorMessage: 'Could not stop pid 4242', cliTooOld: false,
        });
    });

    it('accepts the bare {error} shape daemon handlers also use', async () => {
        machineRPC.mockResolvedValue({ error: 'Restart already in progress' });
        expect(await machineRestartSession({ machineId: 'machine-1', sessionId: 'session-1' })).toEqual({
            type: 'error', errorMessage: 'Restart already in progress', cliTooOld: false,
        });
    });

    it('marks an unregistered RPC method as a CLI that is too old', async () => {
        machineRPC.mockRejectedValue(new Error('RPC method not available'));
        expect(await machineRestartSession({ machineId: 'machine-1', sessionId: 'session-1' })).toEqual({
            type: 'error', errorMessage: 'RPC method not available', cliTooOld: true,
        });
    });

    it('marks a daemon that answers "Method not found" as too old', async () => {
        machineRPC.mockResolvedValue({ error: 'Method not found' });
        const result = await machineRestartSession({ machineId: 'machine-1', sessionId: 'session-1' });
        expect(result).toMatchObject({ type: 'error', cliTooOld: true });
    });

    it('reports transport failures as errors, not as an old CLI', async () => {
        machineRPC.mockRejectedValue(new Error('Socket not connected'));
        expect(await machineRestartSession({ machineId: 'machine-1', sessionId: 'session-1' })).toEqual({
            type: 'error', errorMessage: 'Socket not connected', cliTooOld: false,
        });
    });

    it('treats an empty or unrecognised response as an error', async () => {
        machineRPC.mockResolvedValue(undefined);
        expect((await machineRestartSession({ machineId: 'machine-1', sessionId: 'session-1' })).type).toBe('error');
        machineRPC.mockResolvedValue({ ok: true });
        expect((await machineRestartSession({ machineId: 'machine-1', sessionId: 'session-1' })).type).toBe('error');
    });
});

describe('isUnknownRpcMethodError', () => {
    it.each([
        ['RPC method not available', true],
        ['Method not found', true],
        ['rpc method NOT available', true],
        ['Restart failed: pid 1 still alive', false],
        ['', false],
        [undefined, false],
    ])('%s -> %s', (message, expected) => {
        expect(isUnknownRpcMethodError(message as string | undefined)).toBe(expected);
    });
});
