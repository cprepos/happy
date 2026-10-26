import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
    machine: null as any,
    isConnected: true,
    alert: vi.fn(),
    confirm: vi.fn(),
    machineRestartSession: vi.fn(),
    refreshSessions: vi.fn(),
    actions: [] as Array<() => Promise<void>>,
}));

vi.mock('react', () => ({
    useMemo: <T,>(factory: () => T) => factory(),
    useCallback: <T,>(callback: T) => callback,
}));
vi.mock('@/hooks/useHappyAction', () => ({
    useHappyAction: (action: () => Promise<void>) => {
        mocks.actions.push(action);
        return [false, () => { void action(); }] as const;
    },
}));
vi.mock('@/hooks/useNavigateToSession', () => ({ useNavigateToSession: () => vi.fn() }));
vi.mock('@/modal', () => ({ Modal: { alert: mocks.alert, confirm: mocks.confirm, show: vi.fn() } }));
vi.mock('@/sync/ops', () => ({
    machineRestartSession: mocks.machineRestartSession,
    machineResumeSession: vi.fn(),
    sessionArchive: vi.fn(),
    sessionKill: vi.fn(),
    sessionSetAgentModes: vi.fn(),
    forkAndSpawn: vi.fn(),
}));
vi.mock('@/hooks/useWorktreeCleanup', () => ({ maybeCleanupWorktree: vi.fn() }));
vi.mock('@/sync/storage', () => ({
    storage: { getState: () => ({ settings: {} }) },
    useLocalSetting: () => false,
    useMachine: () => mocks.machine,
    useSetting: () => false,
    useSession: () => null,
}));
vi.mock('@/sync/sync', () => ({ sync: { refreshSessions: mocks.refreshSessions } }));
vi.mock('@/sync/messageMeta', () => ({
    resolveMessageModeMeta: () => ({ model: null, permissionMode: 'default' }),
    UnsupportedPermissionModeError: class extends Error {},
}));
vi.mock('@/text', () => ({
    t: (key: string, params?: Record<string, unknown>) => (params ? `${key}:${JSON.stringify(params)}` : key),
}));
vi.mock('@/utils/copySessionMetadataToClipboard', () => ({
    copySessionMetadataToClipboard: vi.fn(),
    copySessionMetadataAndLogsToClipboard: vi.fn(),
}));
vi.mock('@/utils/sessionUtils', () => ({ useSessionStatus: () => ({ isConnected: mocks.isConnected }) }));
vi.mock('@/utils/sessionFork', () => ({ getSessionForkSource: () => null }));
vi.mock('expo-router', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('@/components/DuplicateSheet', () => ({ DuplicateSheet: () => null }));
vi.mock('@/sync/rig', () => ({ isRigMetadata: () => false }));

(globalThis as any).__DEV__ = false;

import { useSessionQuickActions } from './useSessionQuickActions';

function session(machineId?: string): any {
    return {
        id: 'session-1',
        active: true,
        metadata: { path: '/project', host: 'devbox', ...(machineId ? { machineId } : {}) },
    };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('useSessionQuickActions restart', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        mocks.actions = [];
        mocks.machine = { id: 'machine-1', active: true, metadata: { host: 'devbox', displayName: 'Work Mac' } };
        mocks.isConnected = true;
        mocks.refreshSessions.mockResolvedValue(undefined);
    });

    it('offers Restart agent in the menu while the session looks online, just above Archive', () => {
        const { actionItems, canShowRestart, canShowResume } = useSessionQuickActions(session('machine-1'));
        expect(canShowResume).toBe(false);
        expect(canShowRestart).toBe(true);
        const ids = actionItems.map((item) => item.id);
        expect(ids).toContain('restart');
        expect(ids.indexOf('restart')).toBe(ids.indexOf('archive') - 1);
        expect(actionItems.find((item) => item.id === 'restart')?.label).toBe('sessionInfo.restartAgent');
    });

    it('offers it for an offline session too', () => {
        mocks.isConnected = false;
        expect(useSessionQuickActions(session('machine-1')).canShowRestart).toBe(true);
    });

    it('does not offer it without a machine', () => {
        const { actionItems, canShowRestart } = useSessionQuickActions(session());
        expect(canShowRestart).toBe(false);
        expect(actionItems.map((item) => item.id)).not.toContain('restart');
    });

    it('restarts only after confirmation, then refreshes and says so', async () => {
        mocks.confirm.mockResolvedValue(true);
        mocks.machineRestartSession.mockResolvedValue({ type: 'success', sessionId: 'session-1', stoppedPids: [1], newPid: 2 });
        useSessionQuickActions(session('machine-1')).restartSession();
        await flush();
        expect(mocks.confirm).toHaveBeenCalledWith(
            'sessionInfo.restartAgentConfirmTitle',
            'sessionInfo.restartAgentConfirmMessage:{"machine":"Work Mac"}',
            expect.objectContaining({ destructive: true }),
        );
        expect(mocks.machineRestartSession).toHaveBeenCalledWith({
            machineId: 'machine-1', sessionId: 'session-1', model: undefined, permissionMode: 'default',
        });
        expect(mocks.refreshSessions).toHaveBeenCalledTimes(1);
        expect(mocks.alert).toHaveBeenCalledWith('sessionInfo.restartAgentSuccess');
    });

    it('does nothing when the confirmation is cancelled', async () => {
        mocks.confirm.mockResolvedValue(false);
        useSessionQuickActions(session('machine-1')).restartSession();
        await flush();
        expect(mocks.machineRestartSession).not.toHaveBeenCalled();
    });

    it('says the machine is offline instead of calling it', async () => {
        mocks.machine = { ...mocks.machine, active: false };
        useSessionQuickActions(session('machine-1')).restartSession();
        await flush();
        expect(mocks.confirm).not.toHaveBeenCalled();
        expect(mocks.machineRestartSession).not.toHaveBeenCalled();
        expect(mocks.alert).toHaveBeenCalledWith('sessionInfo.restartAgent', 'sessionInfo.restartAgentMachineOffline:{"machine":"Work Mac"}');
    });

    it('surfaces the daemon error through the action (no success message)', async () => {
        mocks.confirm.mockResolvedValue(true);
        mocks.machineRestartSession.mockResolvedValue({ type: 'error', errorMessage: 'pid 9 is still alive' });
        useSessionQuickActions(session('machine-1'));
        // useHappyAction call order in the hook: resume, archive, restart, fork.
        // The action throws; useHappyAction is what shows the message.
        expect(mocks.actions).toHaveLength(4);
        await expect(mocks.actions[2]()).rejects.toThrow('pid 9 is still alive');
        expect(mocks.refreshSessions).not.toHaveBeenCalled();
        expect(mocks.alert).not.toHaveBeenCalledWith('sessionInfo.restartAgentSuccess');
    });
});
