import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const {
    mockApiClientCreate,
    mockReadSettings,
    mockNotifyDaemonSessionStarted,
    mockRegisterKillSessionHandler,
    mockSetupOfflineReconnection,
    backendInstances,
} = vi.hoisted(() => ({
    mockApiClientCreate: vi.fn(),
    mockReadSettings: vi.fn(),
    mockNotifyDaemonSessionStarted: vi.fn(),
    mockRegisterKillSessionHandler: vi.fn(),
    mockSetupOfflineReconnection: vi.fn(),
    backendInstances: [] as Array<{ opts: Record<string, any> }>,
}));

vi.mock('@/api/api', () => ({
    ApiClient: {
        create: mockApiClientCreate,
    },
}));

vi.mock('@/persistence', () => ({
    readSettings: mockReadSettings,
}));

vi.mock('@/daemon/run', () => ({
    initialMachineMetadata: {},
}));

vi.mock('@/daemon/controlClient', () => ({
    notifyDaemonSessionStarted: mockNotifyDaemonSessionStarted,
}));

vi.mock('@/claude/registerKillSessionHandler', () => ({
    registerKillSessionHandler: mockRegisterKillSessionHandler,
}));

vi.mock('@/utils/setupOfflineReconnection', () => ({
    setupOfflineReconnection: mockSetupOfflineReconnection,
}));

vi.mock('@/utils/createSessionMetadata', () => ({
    createSessionMetadata: vi.fn(() => ({
        state: {},
        metadata: {
            path: '/work',
            host: 'localhost',
            homeDir: '/home/user',
            happyHomeDir: '/home/user/.happy',
            happyLibDir: '/lib',
            happyToolsDir: '/tools',
            flavor: 'agy',
            machineId: 'machine-1',
        },
    })),
}));

vi.mock('@/ui/logger', () => ({
    logger: {
        debug: vi.fn(),
        getLogPath: vi.fn(() => '/tmp/agy.log'),
    },
}));

vi.mock('@/utils/serverConnectionErrors', () => ({
    connectionState: {
        setBackend: vi.fn(),
    },
}));

vi.mock('./constants', async (importOriginal) => ({
    ...(await importOriginal<typeof import('./constants')>()),
    // Never spawn the real `agy models`.
    discoverAgyModelOptions: vi.fn(async () => null),
}));

vi.mock('./AgyBackend', () => ({
    AgyBackend: class {
        opts: Record<string, any>;
        constructor(opts: Record<string, any>) {
            this.opts = opts;
            backendInstances.push(this);
        }
        onMessage() {}
        offMessage() {}
        setPermissionMode() {}
        setModel() {}
        setEffort() {}
        async startSession() {
            return { sessionId: '/work' };
        }
        async sendPrompt() {}
        async cancel() {}
        async dispose() {}
    },
}));

import { runAgy } from './runAgy';

const RECONNECT_ENV_KEYS = [
    'HAPPY_RECONNECT_SESSION_ID',
    'HAPPY_RECONNECT_ENCRYPTION_KEY',
    'HAPPY_RECONNECT_ENCRYPTION_VARIANT',
    'HAPPY_RECONNECT_SEQ',
    'HAPPY_RECONNECT_METADATA_VERSION',
    'HAPPY_RECONNECT_AGENT_STATE_VERSION',
] as const;

async function startRunAgyHarness(opts: { resumeConversationId?: string } = {}) {
    let metadata: Record<string, unknown> = {};
    const updateMetadata = vi.fn((updater: (current: Record<string, unknown>) => Record<string, unknown>) => {
        metadata = updater(metadata);
    });
    const sessionClient = {
        suppressNextArchiveSignal: vi.fn(),
        skipExistingMessages: vi.fn(),
        updateMetadata,
        onUserMessage: vi.fn(),
        keepAlive: vi.fn(),
        sendSessionEvent: vi.fn(),
        sendSessionProtocolMessage: vi.fn(),
        sendSessionDeath: vi.fn(),
        flush: vi.fn(async () => {}),
        close: vi.fn(async () => {}),
        rpcHandlerManager: { registerHandler: vi.fn() },
    };
    mockSetupOfflineReconnection.mockImplementation((args: { metadata: Record<string, unknown> }) => {
        metadata = { ...args.metadata };
        return { session: sessionClient, reconnectionHandle: null };
    });
    const api = {
        getOrCreateMachine: vi.fn(async () => ({})),
        getOrCreateSession: vi.fn(async () => ({
            id: 'new-session',
            seq: 0,
            metadata: {},
            metadataVersion: 0,
            agentState: {},
            agentStateVersion: 0,
            encryptionKey: new Uint8Array(32),
            encryptionVariant: 'dataKey' as const,
        })),
    };
    mockApiClientCreate.mockResolvedValue(api);

    const runPromise = runAgy({
        credentials: { token: 'token' } as any,
        startedBy: 'daemon',
        ...opts,
    });

    await vi.waitFor(() => {
        expect(mockRegisterKillSessionHandler).toHaveBeenCalled();
    });

    const kill = mockRegisterKillSessionHandler.mock.calls.at(-1)?.[1] as () => Promise<void>;
    const finish = async () => {
        await kill();
        await runPromise;
    };

    return {
        api,
        backend: backendInstances.at(-1)!,
        finish,
        getMetadata: () => metadata,
        sessionClient,
        setupArgs: mockSetupOfflineReconnection.mock.calls.at(-1)?.[0],
    };
}

describe('runAgy resume', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        backendInstances.length = 0;
        mockReadSettings.mockResolvedValue({ machineId: 'machine-1' });
        mockNotifyDaemonSessionStarted.mockResolvedValue({});
        for (const key of RECONNECT_ENV_KEYS) {
            delete process.env[key];
        }
    });

    afterEach(() => {
        for (const key of RECONNECT_ENV_KEYS) {
            delete process.env[key];
        }
    });

    it('starts a fresh session with no conversation and records the one the backend pins', async () => {
        const harness = await startRunAgyHarness();

        expect(harness.api.getOrCreateSession).toHaveBeenCalledTimes(1);
        const created = harness.api.getOrCreateSession.mock.calls[0][0] as { metadata: Record<string, unknown> };
        expect(created.metadata.agyConversationId).toBeUndefined();
        expect(harness.backend.opts.conversationId).toBeUndefined();

        harness.backend.opts.onConversationId('pinned-cid');
        expect(harness.getMetadata().agyConversationId).toBe('pinned-cid');

        await harness.finish();
    });

    it('records the resumed conversation in the metadata it creates the session with', async () => {
        const harness = await startRunAgyHarness({ resumeConversationId: 'resumed-cid' });

        const created = harness.api.getOrCreateSession.mock.calls[0][0] as { metadata: Record<string, unknown> };
        expect(created.metadata.agyConversationId).toBe('resumed-cid');
        expect(harness.backend.opts.conversationId).toBe('resumed-cid');

        await harness.finish();
    });

    it('reattaches to the resumed session from the reconnect environment instead of creating one', async () => {
        process.env.HAPPY_RECONNECT_SESSION_ID = 'old-session';
        process.env.HAPPY_RECONNECT_ENCRYPTION_KEY = Buffer.from(new Uint8Array(32).fill(1)).toString('base64');
        process.env.HAPPY_RECONNECT_ENCRYPTION_VARIANT = 'dataKey';
        process.env.HAPPY_RECONNECT_SEQ = '12';
        process.env.HAPPY_RECONNECT_METADATA_VERSION = '3';
        process.env.HAPPY_RECONNECT_AGENT_STATE_VERSION = '4';

        const harness = await startRunAgyHarness({ resumeConversationId: 'resumed-cid' });

        expect(harness.api.getOrCreateSession).not.toHaveBeenCalled();
        expect(harness.setupArgs.response).toMatchObject({
            id: 'old-session',
            seq: 12,
            encryptionVariant: 'dataKey',
            metadataVersion: 3,
            agentStateVersion: 4,
        });
        expect(harness.setupArgs.response.encryptionKey).toEqual(new Uint8Array(32).fill(1));
        expect(harness.sessionClient.suppressNextArchiveSignal).toHaveBeenCalled();
        expect(harness.sessionClient.skipExistingMessages).toHaveBeenCalled();
        expect(harness.getMetadata()).toMatchObject({
            lifecycleState: 'running',
            agyConversationId: 'resumed-cid',
        });
        expect(mockNotifyDaemonSessionStarted).toHaveBeenCalledWith(
            'old-session',
            expect.objectContaining({ agyConversationId: 'resumed-cid' }),
            expect.anything(),
        );

        await harness.finish();
    });

    it('keeps the conversation id through a second resume: the resumed run pins nothing itself', async () => {
        process.env.HAPPY_RECONNECT_SESSION_ID = 'old-session';
        process.env.HAPPY_RECONNECT_ENCRYPTION_KEY = Buffer.from(new Uint8Array(32)).toString('base64');
        process.env.HAPPY_RECONNECT_ENCRYPTION_VARIANT = 'dataKey';

        const harness = await startRunAgyHarness({ resumeConversationId: 'resumed-cid' });
        await harness.finish();

        // The archive on exit keeps the id, so the next resume finds it again.
        expect(harness.getMetadata()).toMatchObject({
            lifecycleState: 'archived',
            agyConversationId: 'resumed-cid',
        });
    });

    it('does not reattach without the full reconnect environment', async () => {
        process.env.HAPPY_RECONNECT_SESSION_ID = 'old-session';

        const harness = await startRunAgyHarness();

        expect(harness.api.getOrCreateSession).toHaveBeenCalledTimes(1);
        expect(harness.sessionClient.suppressNextArchiveSignal).not.toHaveBeenCalled();
        expect(harness.sessionClient.skipExistingMessages).not.toHaveBeenCalled();

        await harness.finish();
    });

    it('does not fail a turn when recording the pinned conversation throws', async () => {
        const harness = await startRunAgyHarness();
        harness.sessionClient.updateMetadata.mockImplementationOnce(() => {
            throw new Error('metadata not ready');
        });

        expect(() => harness.backend.opts.onConversationId('pinned-cid')).not.toThrow();

        await harness.finish();
    });
});
