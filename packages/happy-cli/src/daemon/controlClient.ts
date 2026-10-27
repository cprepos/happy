/**
 * HTTP client helpers for daemon communication
 * Used by CLI commands to interact with running daemon
 */

import { logger } from '@/ui/logger';
import { clearDaemonState, readDaemonState } from '@/persistence';
import { Metadata } from '@/api/types';
import { configuration } from '@/configuration';

async function daemonPost(path: string, body?: any, timeoutMs?: number): Promise<{ error?: string } | any> {
  const state = await readDaemonState();
  if (!state?.httpPort) {
    const errorMessage = 'No daemon running, no state file found';
    logger.debug(`[CONTROL CLIENT] ${errorMessage}`);
    return {
      error: errorMessage
    };
  }

  try {
    process.kill(state.pid, 0);
  } catch (error) {
    const errorMessage = 'Daemon is not running, file is stale';
    logger.debug(`[CONTROL CLIENT] ${errorMessage}`);
    return {
      error: errorMessage
    };
  }

  try {
    const timeout = timeoutMs ?? (process.env.HAPPY_DAEMON_HTTP_TIMEOUT ? parseInt(process.env.HAPPY_DAEMON_HTTP_TIMEOUT) : 10_000);
    const response = await fetch(`http://127.0.0.1:${state.httpPort}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {}),
      // Mostly increased for stress test
      signal: AbortSignal.timeout(timeout)
    });
    
    if (!response.ok) {
      const errorMessage = `Request failed: ${path}, HTTP ${response.status}`;
      logger.debug(`[CONTROL CLIENT] ${errorMessage}`);
      return {
        error: errorMessage
      };
    }
    
    return await response.json();
  } catch (error) {
    const errorMessage = `Request failed: ${path}, ${error instanceof Error ? error.message : 'Unknown error'}`;
    logger.debug(`[CONTROL CLIENT] ${errorMessage}`);
    return {
      error: errorMessage
    }
  }
}

const SESSION_STARTED_RETRY_TIMEOUT_MS = 3000;
const SESSION_STARTED_RETRY_INTERVAL_MS = 100;
const DAEMON_WATCH_INTERVAL_MS = 10_000;

type SessionStartedPayload = { sessionId: string; metadata: Metadata; encryption?: unknown };

/**
 * The session this process last announced, and to which daemon instance.
 * A daemon restart (CLI rebuild, crash recovery) starts with no knowledge of
 * running sessions, so the announcement is repeated whenever the daemon state
 * file names a different daemon than the one that accepted it.
 */
const announcement: {
  payload: SessionStartedPayload | null;
  daemon: string | null;
  timer: NodeJS.Timeout | null;
  inFlight: boolean;
} = { payload: null, daemon: null, timer: null, inFlight: false };

async function currentDaemonIdentity(): Promise<string | null> {
  const state = await readDaemonState();
  return state?.pid && state.httpPort ? `${state.pid}:${state.httpPort}` : null;
}

/**
 * Re-send the last session announcement if a different daemon is now
 * running. Runs on an interval once a session has announced itself; exported
 * so tests can drive it.
 */
export async function reannounceSessionIfDaemonChanged(): Promise<boolean> {
  if (!announcement.payload || announcement.inFlight) return false;
  announcement.inFlight = true;
  try {
    const daemon = await currentDaemonIdentity();
    if (!daemon || daemon === announcement.daemon) return false;
    const payload = announcement.payload;
    const result = await daemonPost('/session-started', payload);
    // A newer announcement may have landed while this one was in flight.
    if (result?.error || announcement.payload !== payload) return false;
    announcement.daemon = daemon;
    logger.debug(`[CONTROL CLIENT] Re-announced session ${payload.sessionId} to daemon ${daemon}`);
    return true;
  } finally {
    announcement.inFlight = false;
  }
}

function watchDaemonForReannouncement(): void {
  if (announcement.timer) return;
  const intervalMs = parseInt(process.env.HAPPY_DAEMON_REANNOUNCE_INTERVAL_MS || '', 10) || DAEMON_WATCH_INTERVAL_MS;
  announcement.timer = setInterval(() => {
    reannounceSessionIfDaemonChanged().catch((error) => {
      logger.debug('[CONTROL CLIENT] Session re-announcement failed:', error);
    });
  }, intervalMs);
  // Never keep a finished session process alive just to watch the daemon.
  announcement.timer.unref();
}

/** Forget the announced session and stop watching the daemon. */
export function stopSessionReannouncement(): void {
  if (announcement.timer) clearInterval(announcement.timer);
  announcement.payload = null;
  announcement.daemon = null;
  announcement.timer = null;
}

export async function notifyDaemonSessionStarted(
  sessionId: string,
  metadata: Metadata,
  encryption?: {
    encryptionKey: string;
    encryptionVariant: 'legacy' | 'dataKey';
    seq: number;
    metadataVersion: number;
    agentStateVersion: number;
  }
): Promise<{ error?: string } | any> {
  // Retry briefly — ensureDaemonRunning already waits for readiness, but we may
  // race a daemon that is mid-restart (version upgrade, crash recovery). Without
  // this, the session's encryption data never reaches the daemon and the mobile
  // app's resume-happy-session RPC fails with "not tracked by this daemon".
  const payload = { sessionId, metadata, encryption };
  // From here on, a restarted daemon is told about this session again.
  announcement.payload = payload;
  announcement.daemon = null;
  watchDaemonForReannouncement();
  const deadline = Date.now() + SESSION_STARTED_RETRY_TIMEOUT_MS;
  let result: { error?: string } | any;

  while (true) {
    const daemon = await currentDaemonIdentity();
    result = await daemonPost('/session-started', payload);
    if (!result?.error) {
      if (announcement.payload === payload) announcement.daemon = daemon;
      return result;
    }
    if (Date.now() >= deadline) {
      return result;
    }
    await new Promise(resolve => setTimeout(resolve, SESSION_STARTED_RETRY_INTERVAL_MS));
  }
}

export async function listDaemonSessions(): Promise<any[]> {
  const result = await daemonPost('/list');
  return result.children || [];
}

/** Cloud/RPC readiness, distinct from the local control server's health. */
export type DaemonConnectionStatus = { machineId: string; cliVersion: string; serverUrl: string; connected: boolean };

export async function getDaemonConnectionStatus(timeoutMs = 1000): Promise<DaemonConnectionStatus | null> {
  const result = await daemonPost('/status', undefined, Math.max(1, timeoutMs));
  return typeof result?.machineId === 'string' && typeof result?.connected === 'boolean'
    && typeof result?.cliVersion === 'string' && typeof result?.serverUrl === 'string'
    ? { machineId: result.machineId, cliVersion: result.cliVersion, serverUrl: result.serverUrl, connected: result.connected }
    : null;
}

export async function stopDaemonSession(sessionId: string): Promise<boolean> {
  const result = await daemonPost('/stop-session', { sessionId });
  return result.success || false;
}

export async function spawnDaemonSession(directory: string, sessionId?: string): Promise<any> {
  const result = await daemonPost('/spawn-session', { directory, sessionId });
  return result;
}

export async function stopDaemonHttp(): Promise<void> {
  await daemonPost('/stop');
}

/**
 * The version check is still quite naive.
 * For instance we are not handling the case where we upgraded happy,
 * the daemon is still running, and it recieves a new message to spawn a new session.
 * This is a tough case - we need to somehow figure out to restart ourselves,
 * yet still handle the original request.
 * 
 * Options:
 * 1. Periodically check during the health checks whether our version is the same as CLIs version. If not - restart.
 * 2. Wait for a command from the machine session, or any other signal to
 * check for version & restart.
 *   a. Handle the request first
 *   b. Let the request fail, restart and rely on the client retrying the request
 * 
 * I like option 1 a little better.
 * Maybe we can ... wait for it ... have another daemon to make sure 
 * our daemon is always alive and running the latest version.
 * 
 * That seems like an overkill and yet another process to manage - lets not do this :D
 * 
 * TODO: This function should return a state object with
 * clear state - if it is running / or errored out or something else.
 * Not just a boolean.
 * 
 * We can destructure the response on the caller for richer output.
 * For instance when running `happy daemon status` we can show more information.
 */
export async function checkIfDaemonRunningAndCleanupStaleState(): Promise<boolean> {
  const state = await readDaemonState();
  if (!state) {
    return false;
  }

  // Check if the PID is alive
  try {
    process.kill(state.pid, 0);
  } catch {
    logger.debug('[DAEMON RUN] Daemon PID not running, cleaning up state');
    await cleanupDaemonState();
    return false;
  }

  // PID is alive, but on Windows PIDs get reused after reboot.
  // Verify it's actually our daemon by HTTP pinging its control server.
  if (state.httpPort) {
    try {
      const response = await fetch(`http://127.0.0.1:${state.httpPort}/list`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{}',
        signal: AbortSignal.timeout(5000)
      });
      if (response.ok) {
        return true;
      }
    } catch {
      // HTTP check failed - the PID is not our daemon (likely reused by OS after reboot)
      logger.debug(`[DAEMON RUN] PID ${state.pid} is alive but HTTP health check failed on port ${state.httpPort}, cleaning up stale state`);
      await cleanupDaemonState();
      return false;
    }
  }

  return true;
}

/**
 * Check if the running daemon version matches the current CLI version.
 * This should work from both the daemon itself & a new CLI process.
 * Works via the daemon.state.json file.
 * 
 * @returns true if versions match, false if versions differ or no daemon running
 */
export async function isDaemonRunningCurrentlyInstalledHappyVersion(): Promise<boolean> {
  logger.debug('[DAEMON CONTROL] Checking if daemon is running same version');
  const runningDaemon = await checkIfDaemonRunningAndCleanupStaleState();
  if (!runningDaemon) {
    logger.debug('[DAEMON CONTROL] No daemon running, returning false');
    return false;
  }

  const state = await readDaemonState();
  if (!state) {
    logger.debug('[DAEMON CONTROL] No daemon state found, returning false');
    return false;
  }
  
  // Compare the running daemon's recorded version against THIS CLI invocation's
  // bundled version. Both are read from the same source of truth: the `version`
  // field baked into `dist/` at build time via `import packageJson from '../package.json'`.
  //
  // Previously we read `package.json` fresh from disk on every check, but that
  // produced infinite restart loops (#1107) when `package.json.version` diverged
  // from the bundled version — e.g. when `happy-coder@0.13.1` was published as
  // a deprecation stub that bumped the manifest without rebuilding `dist/`.
  // The daemon would write its bundled version (0.13.0), read 0.13.1 from disk,
  // detect a mismatch, self-restart, and the new daemon would repeat the cycle.
  //
  // Using `configuration.currentCliVersion` instead guarantees the writer and
  // reader agree whenever they're executing the same `dist/` bundle, and still
  // correctly detects real npm upgrades (the new bundle has a new baked version).
  const currentCliVersion = configuration.currentCliVersion;
  logger.debug(`[DAEMON CONTROL] Current CLI version: ${currentCliVersion}, Daemon started with version: ${state.startedWithCliVersion}`);
  return currentCliVersion === state.startedWithCliVersion;
}

export async function cleanupDaemonState(): Promise<void> {
  try {
    await clearDaemonState();
    logger.debug('[DAEMON RUN] Daemon state file removed');
  } catch (error) {
    logger.debug('[DAEMON RUN] Error cleaning up daemon metadata', error);
  }
}

export async function stopDaemon() {
  try {
    const state = await readDaemonState();
    if (!state) {
      logger.debug('No daemon state found');
      return;
    }

    logger.debug(`Stopping daemon with PID ${state.pid}`);

    // Try HTTP graceful stop
    try {
      await stopDaemonHttp();

      // Wait for daemon to die
      await waitForProcessDeath(state.pid, 2000);
      logger.debug('Daemon stopped gracefully via HTTP');
      return;
    } catch (error) {
      logger.debug('HTTP stop failed, will force kill', error);
    }

    // Force kill
    try {
      process.kill(state.pid, 'SIGKILL');
      logger.debug('Force killed daemon');
    } catch (error) {
      logger.debug('Daemon already dead');
    }
  } catch (error) {
    logger.debug('Error stopping daemon', error);
  }
}

async function waitForProcessDeath(pid: number, timeout: number): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      process.kill(pid, 0);
      await new Promise(resolve => setTimeout(resolve, 100));
    } catch {
      return; // Process is dead
    }
  }
  throw new Error('Process did not die within timeout');
}