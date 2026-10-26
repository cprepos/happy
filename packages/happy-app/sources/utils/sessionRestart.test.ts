import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('@/text', () => ({
    t: (key: string, params?: Record<string, unknown>) => (params ? `${key}:${JSON.stringify(params)}` : key),
}));

import {
    canShowRestartAgent,
    confirmRestartAgent,
    executeRestartAgent,
    getRestartErrorMessage,
    getRestartPrecheck,
} from './sessionRestart';
import { HappyError } from './errors';

function makeSession(overrides: { machineId?: string; host?: string; active?: boolean } = {}): any {
    return {
        id: 'session-1',
        active: overrides.active ?? true,
        metadata: {
            path: '/project',
            host: overrides.host ?? 'devbox.local',
            ...(overrides.machineId === undefined ? { machineId: 'machine-1' } : overrides.machineId ? { machineId: overrides.machineId } : {}),
        },
    };
}

function makeMachine(active: boolean, displayName?: string): any {
    return { id: 'machine-1', active, metadata: { host: 'devbox', displayName } };
}

describe('canShowRestartAgent', () => {
    it('is shown for a session that looks online — the desync case', () => {
        expect(canShowRestartAgent(makeSession({ active: true }))).toBe(true);
    });

    it('is shown for an offline session', () => {
        expect(canShowRestartAgent(makeSession({ active: false }))).toBe(true);
    });

    it('is hidden when the session has no machine', () => {
        expect(canShowRestartAgent(makeSession({ machineId: '' }))).toBe(false);
        expect(canShowRestartAgent({ id: 'session-1', metadata: null } as any)).toBe(false);
    });

    it('is hidden for the empty stand-in session', () => {
        expect(canShowRestartAgent({ id: '', metadata: null } as any)).toBe(false);
    });
});

describe('getRestartPrecheck', () => {
    it('allows an online machine and names it by display name first', () => {
        expect(getRestartPrecheck(makeSession(), makeMachine(true, 'Work Mac'))).toEqual({
            ok: true, machineId: 'machine-1', machineName: 'Work Mac',
        });
    });

    it('falls back to the machine host for its name', () => {
        expect(getRestartPrecheck(makeSession(), makeMachine(true))).toMatchObject({ ok: true, machineName: 'devbox' });
    });

    it('refuses an offline machine with a machine-offline message', () => {
        expect(getRestartPrecheck(makeSession(), makeMachine(false))).toEqual({
            ok: false, message: 'sessionInfo.restartAgentMachineOffline:{"machine":"devbox"}',
        });
    });

    it('refuses a machine this device does not know, named from the session', () => {
        expect(getRestartPrecheck(makeSession(), undefined)).toEqual({
            ok: false, message: 'sessionInfo.restartAgentMachineUnknown:{"machine":"devbox.local"}',
        });
    });

    it('refuses a session with no machine', () => {
        expect(getRestartPrecheck(makeSession({ machineId: '' }), makeMachine(true))).toEqual({
            ok: false, message: 'sessionInfo.resumeSessionMissingMachine',
        });
    });
});

describe('confirmRestartAgent', () => {
    const alert = vi.fn();
    const confirm = vi.fn();

    beforeEach(() => {
        alert.mockReset();
        confirm.mockReset();
    });

    it('asks with the machine named and a destructive Restart button', async () => {
        confirm.mockResolvedValue(true);
        expect(await confirmRestartAgent(makeSession(), makeMachine(true, 'Work Mac'), { alert, confirm })).toBe(true);
        expect(confirm).toHaveBeenCalledWith(
            'sessionInfo.restartAgentConfirmTitle',
            'sessionInfo.restartAgentConfirmMessage:{"machine":"Work Mac"}',
            { cancelText: 'common.cancel', confirmText: 'sessionInfo.restartAgentConfirmButton', destructive: true },
        );
        expect(alert).not.toHaveBeenCalled();
    });

    it('goes no further when the user cancels', async () => {
        confirm.mockResolvedValue(false);
        expect(await confirmRestartAgent(makeSession(), makeMachine(true), { alert, confirm })).toBe(false);
    });

    it('tells the user the machine is offline instead of asking', async () => {
        expect(await confirmRestartAgent(makeSession(), makeMachine(false), { alert, confirm })).toBe(false);
        expect(confirm).not.toHaveBeenCalled();
        expect(alert).toHaveBeenCalledWith('sessionInfo.restartAgent', 'sessionInfo.restartAgentMachineOffline:{"machine":"devbox"}');
    });
});

describe('executeRestartAgent', () => {
    const restart = vi.fn();
    const refresh = vi.fn();

    beforeEach(() => {
        restart.mockReset();
        refresh.mockReset().mockResolvedValue(undefined);
    });

    it('restarts on the session machine, passes the modes, then refreshes', async () => {
        const success = { type: 'success', sessionId: 'session-1', stoppedPids: [10], newPid: 20 };
        restart.mockResolvedValue(success);
        const result = await executeRestartAgent(makeSession(), makeMachine(true), {
            restart, refresh, modes: { model: 'opus', permissionMode: 'default' },
        });
        expect(result).toEqual(success);
        expect(restart).toHaveBeenCalledWith({ machineId: 'machine-1', sessionId: 'session-1', model: 'opus', permissionMode: 'default' });
        expect(refresh).toHaveBeenCalledTimes(1);
        expect(refresh.mock.invocationCallOrder[0]).toBeGreaterThan(restart.mock.invocationCallOrder[0]);
    });

    it('shows the daemon message on failure and does not refresh', async () => {
        restart.mockResolvedValue({ type: 'error', errorMessage: 'pid 4242 survived SIGKILL', cliTooOld: false });
        const error = await executeRestartAgent(makeSession(), makeMachine(true), { restart, refresh }).catch((e) => e);
        expect(error).toBeInstanceOf(HappyError);
        expect(error.message).toBe('pid 4242 survived SIGKILL');
        expect(refresh).not.toHaveBeenCalled();
    });

    it('turns an unknown RPC method into "update happy on the machine"', async () => {
        restart.mockResolvedValue({ type: 'error', errorMessage: 'RPC method not available', cliTooOld: true });
        await expect(executeRestartAgent(makeSession(), makeMachine(true), { restart, refresh }))
            .rejects.toThrow('sessionInfo.restartAgentCliTooOld');
    });

    it('does not call the machine once it has gone offline', async () => {
        await expect(executeRestartAgent(makeSession(), makeMachine(false), { restart, refresh }))
            .rejects.toThrow('sessionInfo.restartAgentMachineOffline:{"machine":"devbox"}');
        expect(restart).not.toHaveBeenCalled();
    });
});

describe('getRestartErrorMessage', () => {
    it('keeps the daemon wording', () => {
        expect(getRestartErrorMessage({ type: 'error', errorMessage: 'Restart already in progress' })).toBe('Restart already in progress');
    });

    it('maps an old CLI to the update message', () => {
        expect(getRestartErrorMessage({ type: 'error', errorMessage: 'Method not found', cliTooOld: true })).toBe('sessionInfo.restartAgentCliTooOld');
    });
});
