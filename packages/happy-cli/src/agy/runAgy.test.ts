import { EventEmitter } from 'node:events';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const {
  mockApiClientCreate,
  mockReadSettings,
  mockNotifyDaemonSessionStarted,
  mockRegisterKillSessionHandler,
  mockSetupOfflineReconnection,
  mockSpawn,
  mockReadAgyConversationId,
  mockCheckAgyConversation,
} = vi.hoisted(() => ({
  mockApiClientCreate: vi.fn(),
  mockReadSettings: vi.fn(),
  mockNotifyDaemonSessionStarted: vi.fn(),
  mockRegisterKillSessionHandler: vi.fn(),
  mockSetupOfflineReconnection: vi.fn(),
  mockSpawn: vi.fn(),
  mockReadAgyConversationId: vi.fn(),
  mockCheckAgyConversation: vi.fn(),
}));

vi.mock('node:child_process', async (importOriginal) => ({
  ...(await importOriginal<typeof import('node:child_process')>()),
  spawn: mockSpawn,
}));

vi.mock('./conversationStore', () => ({
  readAgyConversationId: mockReadAgyConversationId,
}));

// The pre-turn check talks to `agy acp`; conversationCheck.test.ts covers it.
vi.mock('./conversationCheck', () => ({
  checkAgyConversation: mockCheckAgyConversation,
}));

vi.mock('./constants', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./constants')>()),
  resolveAgyBin: () => 'agy',
  // Never spawn the real `agy models`.
  discoverAgyModelOptions: vi.fn(async () => null),
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

import { runAgy } from './runAgy';

const RECONNECT_ENV_KEYS = [
  'HAPPY_RECONNECT_SESSION_ID',
  'HAPPY_RECONNECT_ENCRYPTION_KEY',
  'HAPPY_RECONNECT_ENCRYPTION_VARIANT',
  'HAPPY_RECONNECT_SEQ',
  'HAPPY_RECONNECT_METADATA_VERSION',
  'HAPPY_RECONNECT_AGENT_STATE_VERSION',
] as const;

type Metadata = Record<string, unknown>;

/** A fake `agy --print` child: the test decides when it writes the cache and exits. */
function makeFakeChild() {
  const stdout = Object.assign(new EventEmitter(), { setEncoding: () => {} });
  const stderr = Object.assign(new EventEmitter(), { setEncoding: () => {} });
  const child = Object.assign(new EventEmitter(), {
    stdout,
    stderr,
    kill: vi.fn(() => {
      queueMicrotask(() => child.emit('close', null));
      return true;
    }),
  });
  return child;
}

function setReconnectEnv() {
  process.env.HAPPY_RECONNECT_SESSION_ID = 'old-session';
  process.env.HAPPY_RECONNECT_ENCRYPTION_KEY = Buffer.from(new Uint8Array(32).fill(1)).toString('base64');
  process.env.HAPPY_RECONNECT_ENCRYPTION_VARIANT = 'dataKey';
  process.env.HAPPY_RECONNECT_SEQ = '12';
  process.env.HAPPY_RECONNECT_METADATA_VERSION = '3';
  process.env.HAPPY_RECONNECT_AGENT_STATE_VERSION = '4';
}

async function startRunAgyHarness(opts: { resumeConversationId?: string } = {}) {
  let metadata: Metadata = {};
  const children: Array<ReturnType<typeof makeFakeChild>> = [];
  mockSpawn.mockImplementation(() => {
    const child = makeFakeChild();
    children.push(child);
    return child;
  });

  const sessionClient = {
    suppressNextArchiveSignal: vi.fn(),
    skipExistingMessages: vi.fn(),
    updateMetadata: vi.fn((updater: (current: Metadata) => Metadata) => {
      metadata = updater(metadata);
    }),
    onUserMessage: vi.fn(),
    keepAlive: vi.fn(),
    sendSessionEvent: vi.fn(),
    sendSessionProtocolMessage: vi.fn(),
    sendSessionDeath: vi.fn(),
    flush: vi.fn(async () => {}),
    close: vi.fn(async () => {}),
    rpcHandlerManager: { registerHandler: vi.fn() },
  };
  mockSetupOfflineReconnection.mockImplementation((args: { metadata: Metadata }) => {
    metadata = { ...args.metadata };
    return { session: sessionClient, reconnectionHandle: null };
  });
  const api = {
    getOrCreateMachine: vi.fn(async () => ({})),
    getOrCreateSession: vi.fn(async (_opts: { metadata: Metadata }) => ({
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
  // A failed resume rejects before a test awaits it; tests assert on runPromise.
  runPromise.catch(() => {});

  await vi.waitFor(() => {
    expect(mockRegisterKillSessionHandler).toHaveBeenCalled();
  });
  const kill = mockRegisterKillSessionHandler.mock.calls.at(-1)?.[1] as () => Promise<void>;
  const onUserMessage = sessionClient.onUserMessage.mock.calls[0][0] as (message: unknown) => void;

  /** Send a prompt and wait for its `agy --print` child to spawn. */
  const startTurn = async (text: string) => {
    const spawned = children.length;
    onUserMessage({ content: { type: 'text', text }, meta: {} });
    await vi.waitFor(() => {
      expect(children.length).toBe(spawned + 1);
    });
    return children[spawned];
  };

  const readyEvents = () => sessionClient.sendSessionEvent.mock.calls
    .filter(([event]) => event.type === 'ready').length;

  /** Exit the turn's child and wait until the runner is ready for the next prompt. */
  const endTurn = async (child: ReturnType<typeof makeFakeChild>, code = 0) => {
    const ready = readyEvents();
    child.emit('close', code);
    await vi.waitFor(() => {
      expect(readyEvents()).toBe(ready + 1);
    });
  };

  /** Print agy's stream-json result line for the turn (agy 1.5.18). */
  const respond = (child: ReturnType<typeof makeFakeChild>, conversationId: string) => {
    child.stdout.emit('data', `${JSON.stringify({
      event: 'result',
      result: { conversation_id: conversationId, status: 'SUCCESS', response: 'OK\n', duration_seconds: 3.43, num_turns: 1 },
    })}\n`);
  };

  const spawnArgs = (turn: number) => mockSpawn.mock.calls[turn][1] as string[];
  const protocolText = () => JSON.stringify(sessionClient.sendSessionProtocolMessage.mock.calls);
  const sessionMessages = () => sessionClient.sendSessionEvent.mock.calls
    .filter(([event]) => event.type === 'message')
    .map(([event]) => event.message as string);

  return {
    api,
    endTurn,
    finish: async () => {
      await kill();
      await runPromise;
    },
    getMetadata: () => metadata,
    protocolText,
    respond,
    runPromise,
    sessionClient,
    sessionMessages,
    setupArgs: mockSetupOfflineReconnection.mock.calls.at(-1)?.[0],
    spawnArgs,
    startTurn,
  };
}

function conversationArg(args: string[]): string | undefined {
  const idx = args.indexOf('--conversation');
  return idx >= 0 ? args[idx + 1] : undefined;
}

describe('runAgy resume', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockReadSettings.mockResolvedValue({ machineId: 'machine-1' });
    mockNotifyDaemonSessionStarted.mockResolvedValue({});
    mockReadAgyConversationId.mockReturnValue(null);
    mockCheckAgyConversation.mockResolvedValue({ status: 'present', cwd: process.cwd() });
    for (const key of RECONNECT_ENV_KEYS) {
      delete process.env[key];
    }
  });

  afterEach(() => {
    for (const key of RECONNECT_ENV_KEYS) {
      delete process.env[key];
    }
  });

  it('persists the conversation the first turn creates and continues it on the next turn', async () => {
    mockReadAgyConversationId.mockReturnValue('another-sessions-cid');
    const harness = await startRunAgyHarness();

    expect(harness.api.getOrCreateSession.mock.calls[0][0].metadata.agyConversationId).toBeUndefined();

    const first = await harness.startTurn('hello');
    expect(conversationArg(harness.spawnArgs(0))).toBeUndefined();
    harness.respond(first, 'new-cid');
    await harness.endTurn(first);

    expect(harness.getMetadata().agyConversationId).toBe('new-cid');

    const second = await harness.startTurn('again');
    expect(conversationArg(harness.spawnArgs(1))).toBe('new-cid');
    await harness.endTurn(second);

    await harness.finish();
  });

  it('persists the conversation when the session is stopped during its first turn', async () => {
    const harness = await startRunAgyHarness();

    await harness.startTurn('hello');
    mockReadAgyConversationId.mockReturnValue('new-cid');
    await harness.finish();

    expect(harness.getMetadata()).toMatchObject({
      agyConversationId: 'new-cid',
      lifecycleState: 'archived',
    });
  });

  it('records the resumed conversation in the session metadata and continues it from the first turn', async () => {
    const harness = await startRunAgyHarness({ resumeConversationId: 'resumed-cid' });

    expect(harness.api.getOrCreateSession.mock.calls[0][0].metadata.agyConversationId).toBe('resumed-cid');
    await vi.waitFor(() => {
      expect(harness.sessionMessages()).toContain('Resumed Antigravity conversation resumed-cid');
    });
    expect(mockCheckAgyConversation).toHaveBeenCalledWith('resumed-cid');

    const turn = await harness.startTurn('hello');
    expect(conversationArg(harness.spawnArgs(0))).toBe('resumed-cid');
    harness.respond(turn, 'resumed-cid');
    await harness.endTurn(turn);

    await harness.finish();
    expect(harness.getMetadata().agyConversationId).toBe('resumed-cid');
  });

  it('fails the resume before any turn when agy no longer has the conversation', async () => {
    mockCheckAgyConversation.mockResolvedValue({ status: 'missing' });
    const harness = await startRunAgyHarness({ resumeConversationId: 'gone-cid' });

    await expect(harness.runPromise).rejects.toThrow(
      'Antigravity conversation gone-cid no longer exists, so it cannot be resumed.',
    );
    expect(harness.sessionMessages()).toContain(
      'Antigravity conversation gone-cid no longer exists, so it cannot be resumed.',
    );
    expect(harness.sessionMessages()).not.toContain('Resumed Antigravity conversation gone-cid');
    expect(mockSpawn).not.toHaveBeenCalled();
    expect(harness.getMetadata().lifecycleState).toBe('archived');
  });

  it('resumes anyway when agy cannot say whether the conversation exists', async () => {
    mockCheckAgyConversation.mockResolvedValue({ status: 'unknown', reason: 'agy acp error -32000: Authentication required' });
    const harness = await startRunAgyHarness({ resumeConversationId: 'resumed-cid' });

    await vi.waitFor(() => {
      expect(harness.sessionMessages()).toContain('Resumed Antigravity conversation resumed-cid');
    });
    const turn = await harness.startTurn('hello');
    expect(conversationArg(harness.spawnArgs(0))).toBe('resumed-cid');
    harness.respond(turn, 'resumed-cid');
    await harness.endTurn(turn);

    await harness.finish();
  });

  it('stops the turn and tells the user when agy reports the resumed conversation missing', async () => {
    const harness = await startRunAgyHarness({ resumeConversationId: 'resumed-cid' });

    const turn = await harness.startTurn('hello');
    const ready = harness.sessionClient.sendSessionEvent.mock.calls.length;
    // Captured from agy 1.5.18 for an unknown --conversation id.
    turn.stderr.emit('data', 'warning: conversation "resumed-cid" not found\n');
    await vi.waitFor(() => {
      expect(harness.sessionClient.sendSessionEvent.mock.calls.slice(ready)
        .some(([event]) => event.type === 'ready')).toBe(true);
    });

    expect(harness.protocolText()).toContain(
      'Error: Antigravity conversation resumed-cid no longer exists, so its earlier context is not available. Your next message starts a new conversation.',
    );

    const next = await harness.startTurn('again');
    expect(conversationArg(harness.spawnArgs(1))).toBeUndefined();
    harness.respond(next, 'new-cid');
    await harness.endTurn(next);

    await harness.finish();
    expect(harness.getMetadata().agyConversationId).toBe('new-cid');
  });

  it('pins the conversation agy used instead and says the earlier context is gone', async () => {
    const harness = await startRunAgyHarness({ resumeConversationId: 'resumed-cid' });

    const turn = await harness.startTurn('hello');
    harness.respond(turn, 'replacement-cid');
    await harness.endTurn(turn);

    expect(harness.getMetadata().agyConversationId).toBe('replacement-cid');
    expect(harness.sessionMessages()).toContainEqual(expect.stringContaining(
      'Antigravity conversation resumed-cid could not be resumed',
    ));

    const next = await harness.startTurn('again');
    expect(conversationArg(harness.spawnArgs(1))).toBe('replacement-cid');
    await harness.endTurn(next);

    await harness.finish();
  });

  it('reattaches to the resumed session from the reconnect environment instead of creating one', async () => {
    setReconnectEnv();

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

  it('does not reattach or un-archive without the full reconnect environment', async () => {
    process.env.HAPPY_RECONNECT_SESSION_ID = 'old-session';

    const harness = await startRunAgyHarness();

    expect(harness.api.getOrCreateSession).toHaveBeenCalledTimes(1);
    expect(harness.sessionClient.suppressNextArchiveSignal).not.toHaveBeenCalled();
    expect(harness.sessionClient.skipExistingMessages).not.toHaveBeenCalled();
    expect(harness.getMetadata().lifecycleState).toBeUndefined();

    await harness.finish();
  });

  it('finishes the turn when recording the pinned conversation fails', async () => {
    const harness = await startRunAgyHarness();
    harness.sessionClient.updateMetadata.mockImplementationOnce(() => {
      throw new Error('metadata not ready');
    });

    const turn = await harness.startTurn('hello');
    mockReadAgyConversationId.mockReturnValue('new-cid');
    await harness.endTurn(turn);

    expect(harness.sessionMessages()).not.toContainEqual(expect.stringContaining('Antigravity error'));

    await harness.finish();
  });
});
