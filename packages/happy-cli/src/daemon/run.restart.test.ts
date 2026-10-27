import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { encodeBase64 } from '@/api/encryption';
import { FakeProcessTable } from '@/session/fakeProcessTable.testkit';

const mocks = vi.hoisted(() => ({
  handlers: null as any,
  webhook: null as any,
  children: null as any,
  table: null as any,
  persisted: {} as Record<string, any>,
  get: vi.fn(),
  spawn: vi.fn(),
  access: vi.fn(),
  persistSession: vi.fn(),
  logger: { debug: vi.fn(), debugLargeJson: vi.fn(), warn: vi.fn() },
}));

vi.mock('axios', () => ({ default: { get: mocks.get } }));
vi.mock('os', async (importOriginal) => {
  const original = await importOriginal<typeof import('os')>();
  return { ...original, default: { ...original, homedir: () => process.env.HAPPY_HOME_DIR! } };
});
vi.mock('fs/promises', () => ({ default: { access: mocks.access } }));
vi.mock('@/ui/logger', () => ({ logger: mocks.logger }));
vi.mock('@/configuration', () => ({ configuration: { serverUrl: 'http://test.invalid', happyHomeDir: '/test-only' } }));
vi.mock('@/ui/auth', () => ({ authAndSetupMachineIfNeeded: async () => ({ credentials: { token: 'test-token' }, machineId: 'machine-1' }) }));
vi.mock('@/ui/doctor', () => ({ getEnvironmentInfo: () => ({}) }));
vi.mock('@/utils/caffeinate', () => ({ startCaffeinate: () => false, stopCaffeinate: vi.fn() }));
vi.mock('@/utils/detectCLI', () => ({ detectCLIAvailability: () => ({}) }));
vi.mock('@/utils/spawnHappyCLI', () => ({ spawnHappyCLI: mocks.spawn }));
vi.mock('@/utils/tmux', () => ({ isTmuxAvailable: async () => false }));
vi.mock('@/resume/localHappyAgentAuth', () => ({ detectResumeSupport: () => ({}), hasLocalHappyAgentAuth: () => false }));
vi.mock('./happyTerminalBoot', () => ({ startHappyTerminalDaemon: vi.fn() }));
vi.mock('@/persistence', () => ({
  readPersistedSessions: () => mocks.persisted,
  persistSession: mocks.persistSession, markSessionStopped: vi.fn(), writeDaemonState: vi.fn(), readDaemonState: vi.fn(),
  acquireDaemonLock: async () => ({}), releaseDaemonLock: vi.fn(),
}));
vi.mock('./controlClient', () => ({
  isDaemonRunningCurrentlyInstalledHappyVersion: async () => false,
  stopDaemon: vi.fn(), cleanupDaemonState: vi.fn(),
}));
vi.mock('./controlServer', () => ({ startDaemonControlServer: async (options: any) => {
  mocks.webhook = options.onHappySessionWebhook;
  mocks.children = options.getChildren;
  return { port: 0, stop: vi.fn() };
} }));
vi.mock('@/api/api', () => ({ ApiClient: { create: async () => ({
  getOrCreateMachine: async () => ({ id: 'machine-1' }),
  machineSyncClient: () => ({
    setRPCHandlers: (handlers: any) => { mocks.handlers = handlers; },
    connect: () => { throw new Error('test boot complete'); },
  }),
}) } }));
// The daemon's restarter, on the fake process table: no real pid is ever inspected or signalled.
vi.mock('./restartSession', async (importOriginal) => {
  const original = await importOriginal<typeof import('./restartSession')>();
  return {
    ...original,
    createSessionRestarter: (deps: Parameters<typeof original.createSessionRestarter>[0]) =>
      original.createSessionRestarter({ ...deps, ops: mocks.table.ops(), graceMs: 1_000 }),
  };
});

import { startDaemon } from './run';

// Above the kernel's pid_max: never a real process.
const PID = 5_200_000;
const HAPPY = 'node /opt/happy/dist/index.mjs';
const dataKey = new Uint8Array(32).fill(1);
const claudeMetadata = { path: '/project', machineId: 'machine-1', flavor: 'claude', claudeSessionId: 'claude-old' };
const opencodeMetadata = { path: '/project', machineId: 'machine-1', flavor: 'opencode', opencodeSessionId: 'ses_A' };
const keys = { metadataVersion: 3, agentStateVersion: 4, seq: 12, encryptionKey: encodeBase64(dataKey), encryptionVariant: 'dataKey' };
const fallbackFor = (metadata: Record<string, unknown>) => ({ metadata, ...keys });

async function boot() {
  await expect(startDaemon()).rejects.toThrow('test exit');
}

describe('daemon restart-happy-session', () => {
  let table: FakeProcessTable;
  let nextPid: number;

  beforeEach(() => {
    vi.clearAllMocks();
    mocks.persisted = {};
    mocks.access.mockResolvedValue(undefined);
    table = new FakeProcessTable();
    table.selfPid = PID;
    table.add({ pid: PID, commandLine: `${HAPPY} daemon start-sync`, startTimeMs: table.boot });
    mocks.table = table;
    nextPid = PID + 100;
    vi.spyOn(process, 'on').mockReturnValue(process);
    vi.spyOn(process, 'exit').mockImplementation(() => { throw new Error('test exit'); });
    // Liveness checks in the daemon see the fake table too.
    vi.spyOn(process, 'kill').mockImplementation((pid) => {
      if (!table.processes.has(Math.abs(pid))) throw Object.assign(new Error('kill ESRCH'), { code: 'ESRCH' });
      return true;
    });
    mocks.spawn.mockImplementation((args: string[], options: any) => {
      const pid = nextPid++;
      table.add({ pid, commandLine: `${HAPPY} ${args.join(' ')}`, startTimeMs: table.clock });
      const metadata = args[0] === 'opencode' ? opencodeMetadata : claudeMetadata;
      queueMicrotask(() => mocks.webhook(options.env.HAPPY_RECONNECT_SESSION_ID, { ...metadata, hostPid: pid }));
      return { pid, on: vi.fn() };
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('is registered with the machine RPC handlers', async () => {
    await boot();
    expect(mocks.handlers.restartSession).toBeTypeOf('function');
  });

  it('stops the tracked process and resumes the same session, forwarding model and permission mode', async () => {
    await boot();
    expect(await mocks.handlers.resumeSession('old-session', { fallback: fallbackFor(claudeMetadata) })).toEqual({ type: 'success', sessionId: 'old-session' });
    const first = PID + 100;
    const result = await mocks.handlers.restartSession('old-session', { fallback: fallbackFor(claudeMetadata), model: 'opus', permissionMode: 'acceptEdits' });
    expect(result).toEqual({ type: 'success', sessionId: 'old-session', stoppedPids: [first], newPid: PID + 101 });
    expect(table.processes.has(first)).toBe(false);
    expect(table.signals[0]).toEqual({ pid: first, signal: 'SIGTERM' });
    const [args, options] = mocks.spawn.mock.calls[1];
    expect(args).toEqual(expect.arrayContaining(['--resume', 'claude-old', '--model', 'opus', '--permission-mode', 'acceptEdits']));
    expect(options.env.HAPPY_RECONNECT_SESSION_ID).toBe('old-session');
    expect(mocks.children().map((child: any) => child.pid)).toEqual([PID + 101]);
  });

  it('SIGKILLs a tracked process that ignores SIGTERM', async () => {
    await boot();
    await mocks.handlers.resumeSession('old-session', { fallback: fallbackFor(claudeMetadata) });
    table.processes.get(PID + 100)!.onSignal = (signal, fake, pid) => FakeProcessTable.ignoresSoftSignals(signal, fake, pid);
    const result = await mocks.handlers.restartSession('old-session', { fallback: fallbackFor(claudeMetadata) });
    expect(result).toMatchObject({ type: 'success', stoppedPids: [PID + 100], newPid: PID + 101 });
    expect(table.signals.some((entry) => entry.pid === PID + 100 && entry.signal === 'SIGKILL')).toBe(true);
  });

  it('stops an untracked session found through sessions.json after a daemon restart', async () => {
    const old = PID + 50;
    table.add({ pid: old, commandLine: `${HAPPY} --happy-starting-mode remote --started-by daemon --resume claude-old`, startTimeMs: table.clock - 60_000 });
    mocks.persisted = { 'old-session': { ...keys, metadata: { ...claudeMetadata, hostPid: old }, savedAt: table.clock - 59_000 } };
    await boot();
    const result = await mocks.handlers.restartSession('old-session', { fallback: fallbackFor(claudeMetadata) });
    expect(result).toEqual({ type: 'success', sessionId: 'old-session', stoppedPids: [old], newPid: PID + 100 });
    expect(mocks.spawn).toHaveBeenCalledTimes(1);
  });

  it('runs one restart for a double tap', async () => {
    await boot();
    await mocks.handlers.resumeSession('old-session', { fallback: fallbackFor(claudeMetadata) });
    const results = await Promise.all([
      mocks.handlers.restartSession('old-session', { fallback: fallbackFor(claudeMetadata) }),
      mocks.handlers.restartSession('old-session', { fallback: fallbackFor(claudeMetadata) }),
      mocks.handlers.resumeSession('old-session', { fallback: fallbackFor(claudeMetadata) }),
    ]);
    expect(results[0]).toMatchObject({ type: 'success', newPid: PID + 101 });
    expect(results[1]).toEqual(results[0]);
    expect(results[2]).toEqual({ type: 'success', sessionId: 'old-session' });
    expect(mocks.spawn).toHaveBeenCalledTimes(2);
  });

  it('restarts a session it has never seen from the fallback key and metadata', async () => {
    await boot();
    const result = await mocks.handlers.restartSession('old-session', { fallback: fallbackFor(claudeMetadata), fallbackReason: 'untracked' });
    expect(result).toEqual({ type: 'success', sessionId: 'old-session', stoppedPids: [], newPid: PID + 100 });
    expect(mocks.spawn.mock.calls[0][1].env).toMatchObject({
      HAPPY_RECONNECT_SESSION_ID: 'old-session', HAPPY_RECONNECT_ENCRYPTION_KEY: keys.encryptionKey, HAPPY_RECONNECT_SEQ: '12',
    });
  });

  it('refuses a session it knows nothing about', async () => {
    await boot();
    expect(await mocks.handlers.restartSession('old-session')).toMatchObject({ type: 'error', errorMessage: expect.stringContaining('not known on this machine') });
    expect(mocks.spawn).not.toHaveBeenCalled();
  });

  it('refuses flavors it cannot restart', async () => {
    await boot();
    const result = await mocks.handlers.restartSession('old-session', { fallback: fallbackFor({ path: '/project', machineId: 'machine-1', flavor: 'gemini' }) });
    expect(result).toMatchObject({ type: 'error', errorMessage: expect.stringContaining('not supported for gemini') });
    expect(mocks.spawn).not.toHaveBeenCalled();
  });

  it('restarts OpenCode as the headless TUI-style owner', async () => {
    await boot();
    const result = await mocks.handlers.restartSession('old-session', { fallback: fallbackFor(opencodeMetadata), model: 'ignored', permissionMode: 'default' });
    expect(result).toMatchObject({ type: 'success', stoppedPids: [], newPid: PID + 100 });
    const [args, options] = mocks.spawn.mock.calls[0];
    expect(args).toEqual(['opencode', '--resume', 'ses_A', '--headless', '--permission-mode', 'ask', '--happy-session', 'old-session', '--started-by', 'daemon']);
    expect(options.env.HAPPY_OPENCODE_MODE).toBe('tui');
    expect(options.cwd).toBe('/project');
  });

  it('resumes OpenCode through the restart, so a live owner is stopped first and never doubled', async () => {
    await boot();
    // An owner started from a terminal that the daemon does not track.
    const terminalOwner = PID + 60;
    table.add({ pid: terminalOwner, commandLine: `${HAPPY} opencode --resume ses_A`, startTimeMs: table.clock - 30_000 });
    table.add({ pid: PID + 61, ppid: terminalOwner, pgid: PID + 61, commandLine: 'opencode serve --port 4096', startTimeMs: table.clock - 29_000 });
    const result = await mocks.handlers.resumeSession('old-session', { fallback: fallbackFor(opencodeMetadata) });
    expect(result).toEqual({ type: 'success', sessionId: 'old-session' });
    expect(table.processes.has(terminalOwner)).toBe(false);
    expect(table.processes.has(PID + 61)).toBe(false);
    expect(mocks.spawn).toHaveBeenCalledTimes(1);
    expect(mocks.spawn.mock.calls[0][0]).toEqual(['opencode', '--resume', 'ses_A', '--headless', '--permission-mode', 'auto', '--happy-session', 'old-session', '--started-by', 'daemon']);
    expect(mocks.spawn.mock.calls[0][1].env.HAPPY_OPENCODE_MODE).toBe('tui');
  });

  it('still resumes Claude without stopping a live owner', async () => {
    await boot();
    await mocks.handlers.resumeSession('old-session', { fallback: fallbackFor(claudeMetadata) });
    expect(await mocks.handlers.resumeSession('old-session', { fallback: fallbackFor(claudeMetadata) })).toEqual({ type: 'success', sessionId: 'old-session' });
    expect(table.signals).toEqual([]);
    expect(mocks.spawn).toHaveBeenCalledTimes(1);
  });
});
