/**
 * A restarted daemon tracks, lists and can stop the sessions its predecessor
 * left running.
 *
 * The "session" is a real detached process this test spawns (a fake Happy
 * entry point that also starts a grandchild, the way an agent backend runs);
 * only those PIDs are ever signalled.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { encodeBase64 } from '@/api/encryption';

const mocks = vi.hoisted(() => ({
  handlers: null as any,
  children: null as any,
  persisted: {} as Record<string, any>,
  logger: { debug: vi.fn(), debugLargeJson: vi.fn(), warn: vi.fn() },
}));

vi.mock('axios', () => ({ default: { get: vi.fn() } }));
vi.mock('fs/promises', () => ({ default: { access: vi.fn() } }));
vi.mock('@/ui/logger', () => ({ logger: mocks.logger }));
vi.mock('@/configuration', () => ({ configuration: { serverUrl: 'http://test.invalid', happyHomeDir: '/test-only' } }));
vi.mock('@/ui/auth', () => ({ authAndSetupMachineIfNeeded: async () => ({ credentials: { token: 'test-token' }, machineId: 'machine-1' }) }));
vi.mock('@/ui/doctor', () => ({ getEnvironmentInfo: () => ({}) }));
vi.mock('@/utils/caffeinate', () => ({ startCaffeinate: () => false, stopCaffeinate: vi.fn() }));
vi.mock('@/utils/detectCLI', () => ({ detectCLIAvailability: () => ({}) }));
vi.mock('@/utils/spawnHappyCLI', () => ({ spawnHappyCLI: vi.fn() }));
vi.mock('@/utils/tmux', () => ({ isTmuxAvailable: async () => false }));
vi.mock('@/resume/localHappyAgentAuth', () => ({ detectResumeSupport: () => ({}), hasLocalHappyAgentAuth: () => false }));
vi.mock('./happyTerminalBoot', () => ({ startHappyTerminalDaemon: vi.fn() }));
vi.mock('@/persistence', () => ({
  readPersistedSessions: () => mocks.persisted,
  persistSession: vi.fn(), markSessionStopped: vi.fn(), writeDaemonState: vi.fn(), readDaemonState: vi.fn(),
  acquireDaemonLock: async () => ({}), releaseDaemonLock: vi.fn(),
}));
vi.mock('./controlClient', () => ({
  isDaemonRunningCurrentlyInstalledHappyVersion: async () => false,
  stopDaemon: vi.fn(), cleanupDaemonState: vi.fn(),
}));
vi.mock('./controlServer', () => ({ startDaemonControlServer: async (options: any) => {
  mocks.children = options.getChildren;
  return { port: 0, stop: vi.fn() };
} }));
vi.mock('@/api/api', () => ({ ApiClient: { create: async () => ({
  getOrCreateMachine: async () => ({ id: 'machine-1' }),
  machineSyncClient: () => ({
    setRPCHandlers: (handlers: any) => { mocks.handlers = handlers; },
    // Stop boot once the handlers are captured, before heartbeat timers.
    connect: () => { throw new Error('test boot complete'); },
  }),
}) } }));

import { startDaemon } from './run';

const realKill = process.kill.bind(process);

const FAKE_SESSION = `
const { spawn } = require('node:child_process');
const backend = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
console.log(JSON.stringify({ backendPid: backend.pid }));
setInterval(() => {}, 1000);
`;

function isAlive(pid: number): boolean {
  try {
    realKill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(check: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) throw new Error('timed out');
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

describe.runIf(process.platform === 'linux')('daemon restart adopts running sessions', () => {
  let dir: string;
  let owner: ChildProcess | null = null;
  let backendPid = 0;
  const signalled: Array<[number, string | number | undefined]> = [];

  beforeEach(async () => {
    vi.clearAllMocks();
    signalled.length = 0;
    dir = mkdtempSync(join(tmpdir(), 'run-adopt-'));
    mkdirSync(join(dir, 'dist'));
    const entry = join(dir, 'dist', 'index.mjs');
    // The entry point has the name a real session runs from; it loads the CommonJS body.
    writeFileSync(join(dir, 'session.cjs'), FAKE_SESSION);
    writeFileSync(entry, `import { createRequire } from 'node:module';\ncreateRequire(import.meta.url)(${JSON.stringify(join(dir, 'session.cjs'))});\n`);

    owner = spawn(process.execPath, [entry, 'codex', '--started-by', 'daemon'], {
      detached: true,
      stdio: ['ignore', 'pipe', 'ignore'],
      env: { ...process.env, HAPPY_RECONNECT_SESSION_ID: 'live-session' },
    });
    backendPid = await new Promise<number>((resolve) => owner!.stdout!.once('data', (data) => resolve(JSON.parse(String(data)).backendPid)));

    mocks.persisted = {
      'live-session': {
        encryptionKey: encodeBase64(new Uint8Array(32).fill(1)),
        encryptionVariant: 'dataKey', seq: 5, metadataVersion: 2, agentStateVersion: 1,
        metadata: { path: '/project', host: 'h', flavor: 'codex', hostPid: owner.pid },
        savedAt: Date.now() + 1, lastAliveAt: Date.now() + 1,
      },
    };

    vi.spyOn(process, 'on').mockReturnValue(process);
    vi.spyOn(process, 'exit').mockImplementation(() => { throw new Error('test exit'); });
    vi.spyOn(process, 'kill').mockImplementation((pid, signal) => {
      const own = [owner!.pid, backendPid].includes(Math.abs(pid));
      // Probes of other PIDs are harmless; never signal anything but our own fixture.
      if (!own && signal !== 0) throw new Error(`Unexpected signal to PID ${pid}`);
      if (signal !== 0) signalled.push([pid, signal]);
      return realKill(pid, signal);
    });

    await expect(startDaemon()).rejects.toThrow('test exit');
  });

  afterEach(() => {
    vi.restoreAllMocks();
    for (const pid of [owner?.pid, backendPid]) {
      if (pid && isAlive(pid)) realKill(pid, 'SIGKILL');
    }
    rmSync(dir, { recursive: true, force: true });
  });

  it('lists the session it found running', () => {
    expect(mocks.children()).toEqual([
      expect.objectContaining({ happySessionId: 'live-session', pid: owner!.pid, startedBy: 'adopted after daemon restart', ownsProcessGroup: true }),
    ]);
  });

  it('stops the whole process tree of an adopted session', async () => {
    expect(mocks.handlers.stopSession('live-session')).toBe(true);
    expect(signalled).toEqual([[-owner!.pid!, 'SIGTERM']]);
    await waitFor(() => !isAlive(owner!.pid!) && !isAlive(backendPid));
  });

  it('force-restarts an adopted session by stopping its whole process group', async () => {
    // The resume after the stop is not under test here (spawning is mocked);
    // what matters is that the agent backend goes with the owner.
    await mocks.handlers.restartSession('live-session');
    expect(signalled).toContainEqual([-owner!.pid!, 'SIGTERM']);
    await waitFor(() => !isAlive(owner!.pid!) && !isAlive(backendPid));
  });

  it('reports the session as running to resume instead of starting a duplicate', async () => {
    expect(await mocks.handlers.resumeSession('live-session')).toEqual({ type: 'success', sessionId: 'live-session' });
  });
});
