/**
 * Processes behind `happy opencode` in terminal mode.
 *
 * - `opencode serve`: the session engine. Started in its own process group
 *   and session (`detached`), so closing the terminal does not hang it up.
 *   Bound to 127.0.0.1 on a random port and protected by a per-run password.
 * - `opencode attach`: the real OpenCode TUI, in the user's terminal,
 *   talking to that server. It dies with the terminal; nothing else does.
 *
 * A small state file per OpenCode session (`~/.happy/opencode-tui/<id>.json`,
 * mode 0600) records who owns the running server, so `happy opencode
 * --resume <id>` can attach a new TUI to it, and so a server left behind by
 * a crashed owner can be stopped later. Only processes recorded there, and
 * only after checking they are still what we started, are ever signalled.
 */

import { spawn, execFileSync, type ChildProcess } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { logger } from '@/ui/logger';

export type ProcessExit = { code: number | null; signal: NodeJS.Signals | null };

export type OpencodeServerHandle = {
    pid: number;
    url: string;
    password: string;
    /** Resolves when the server process exits, for whatever reason. */
    exited: Promise<ProcessExit>;
    /** SIGTERM, then SIGKILL after `graceMs`. Resolves once the process is gone. */
    stop: (graceMs?: number) => Promise<void>;
};

const LISTENING = /listening on (https?:\/\/[^\s]+)/;

export function generateServerPassword(): string {
    return randomBytes(24).toString('base64url');
}

function waitForExit(child: ChildProcess): Promise<ProcessExit> {
    if (child.exitCode !== null || child.signalCode !== null) {
        return Promise.resolve({ code: child.exitCode, signal: child.signalCode });
    }
    return new Promise((resolve) => {
        child.once('exit', (code, signal) => resolve({ code, signal }));
    });
}

async function terminate(child: ChildProcess, exited: Promise<ProcessExit>, graceMs: number): Promise<void> {
    if (child.exitCode !== null || child.signalCode !== null) {
        return;
    }
    child.kill('SIGTERM');
    const timer = setTimeout(() => {
        if (child.exitCode === null && child.signalCode === null) {
            child.kill('SIGKILL');
        }
    }, graceMs);
    await exited;
    clearTimeout(timer);
}

/**
 * Start `opencode serve` and wait until it reports its URL.
 *
 * `configContent` is passed as OPENCODE_CONFIG_CONTENT, which OpenCode
 * merges over the user's own configuration (used to add Happy's MCP server).
 */
export async function startOpencodeServer(opts: {
    bin: string;
    cwd: string;
    /** Defaults to `serve --hostname 127.0.0.1 --port 0`. */
    args?: string[];
    env?: NodeJS.ProcessEnv;
    configContent?: string;
    password?: string;
    startTimeoutMs?: number;
}): Promise<OpencodeServerHandle> {
    const password = opts.password ?? generateServerPassword();
    const child = spawn(opts.bin, opts.args ?? ['serve', '--hostname', '127.0.0.1', '--port', '0'], {
        cwd: opts.cwd,
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
        env: {
            ...(opts.env ?? process.env),
            OPENCODE_SERVER_PASSWORD: password,
            ...(opts.configContent ? { OPENCODE_CONFIG_CONTENT: opts.configContent } : {}),
        },
    });
    const exited = waitForExit(child);
    const stop = (graceMs: number = 5_000) => terminate(child, exited, graceMs);

    let output = '';
    const url = await new Promise<string>((resolve, reject) => {
        const timer = setTimeout(() => {
            reject(new Error(`opencode serve did not report its address within ${opts.startTimeoutMs ?? 30_000}ms`));
        }, opts.startTimeoutMs ?? 30_000);
        const onData = (chunk: Buffer) => {
            output += chunk.toString();
            const match = output.match(LISTENING);
            if (match) {
                clearTimeout(timer);
                resolve(match[1]);
            }
        };
        child.stdout!.on('data', onData);
        child.stderr!.on('data', onData);
        child.once('error', (error) => {
            clearTimeout(timer);
            reject(error);
        });
        exited.then((exit) => {
            clearTimeout(timer);
            reject(new Error(`opencode serve exited (code ${exit.code}, signal ${exit.signal}) before it was ready: ${output.trim().slice(-500)}`));
        });
    }).catch(async (error) => {
        await stop(1_000);
        throw error;
    });

    // Keep draining the pipes so the server never blocks on a full buffer.
    child.stdout!.removeAllListeners('data');
    child.stderr!.removeAllListeners('data');
    child.stdout!.on('data', (chunk: Buffer) => logger.debug(`[opencode serve] ${chunk.toString().trimEnd()}`));
    child.stderr!.on('data', (chunk: Buffer) => logger.debug(`[opencode serve] ${chunk.toString().trimEnd()}`));

    return { pid: child.pid!, url, password, exited, stop };
}

/**
 * Run the OpenCode TUI attached to `url`, in this terminal. The password is
 * passed in the environment so it never shows up in the process list.
 */
export function attachOpencodeTui(opts: {
    bin: string;
    url: string;
    password: string;
    cwd: string;
    sessionId: string;
    /** Defaults to `attach <url> --dir <cwd> --session <id>`. */
    args?: string[];
    env?: NodeJS.ProcessEnv;
}): { pid: number | undefined; exited: Promise<ProcessExit> } {
    const child = spawn(opts.bin, opts.args ?? ['attach', opts.url, '--dir', opts.cwd, '--session', opts.sessionId], {
        cwd: opts.cwd,
        stdio: 'inherit',
        env: { ...(opts.env ?? process.env), OPENCODE_SERVER_PASSWORD: opts.password },
    });
    const exited = new Promise<ProcessExit>((resolve) => {
        child.once('exit', (code, signal) => resolve({ code, signal }));
        child.once('error', (error) => {
            logger.debug('[opencode attach] failed to start:', error);
            resolve({ code: 127, signal: null });
        });
    });
    return { pid: child.pid, exited };
}

/**
 * Did the TUI exit because the terminal went away, or because the user quit?
 *
 * A hangup is signalled to us (SIGHUP) and to the TUI, and leaves our stdio
 * without a terminal. Any of those means the user did not choose to end the
 * session, so it keeps running for the app.
 */
export function classifyTuiExit(opts: {
    exit: ProcessExit;
    hangupReceived: boolean;
    stdinIsTTY: boolean;
    stdoutIsTTY: boolean;
}): 'hangup' | 'quit' {
    if (opts.hangupReceived || opts.exit.signal === 'SIGHUP' || (!opts.stdinIsTTY && !opts.stdoutIsTTY)) {
        return 'hangup';
    }
    return 'quit';
}

// --- State files -----------------------------------------------------------

export type OpencodeTuiState = {
    /** The `happy opencode` process that owns the server and mirrors the session. */
    ownerPid: number;
    serverPid: number;
    url: string;
    password: string;
    cwd: string;
    opencodeSessionId: string;
    happySessionId: string;
    startedAt: number;
    /** Whether the owner's own TUI is still open (false once its terminal is gone). */
    ownerTuiAttached: boolean;
    /** Launch permission policy, reused by a restart. Absent in older files. */
    permissionPolicy?: 'auto' | 'ask';
    /** Signal that stops this owner for a restart; absent in older files (use SIGTERM). */
    restartSignal?: 'SIGUSR2';
};

function stateFile(dir: string, opencodeSessionId: string): string {
    return join(dir, `${opencodeSessionId.replace(/[^A-Za-z0-9_-]/g, '_')}.json`);
}

export function writeTuiState(dir: string, state: OpencodeTuiState): string {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const file = stateFile(dir, state.opencodeSessionId);
    writeFileSync(file, JSON.stringify(state, null, 2), { mode: 0o600 });
    chmodSync(file, 0o600);
    return file;
}

export function readTuiState(dir: string, opencodeSessionId: string): OpencodeTuiState | null {
    const file = stateFile(dir, opencodeSessionId);
    try {
        const state = JSON.parse(readFileSync(file, 'utf8')) as OpencodeTuiState;
        return typeof state.ownerPid === 'number' && typeof state.serverPid === 'number' && typeof state.url === 'string'
            ? state
            : null;
    } catch {
        return null;
    }
}

/** Remove the state file, but only if it still belongs to `ownerPid`. */
export function removeTuiState(dir: string, opencodeSessionId: string, ownerPid: number): void {
    const state = readTuiState(dir, opencodeSessionId);
    if (state && state.ownerPid !== ownerPid) {
        return;
    }
    try {
        unlinkSync(stateFile(dir, opencodeSessionId));
    } catch {
        // Already gone.
    }
}

export function isProcessAlive(pid: number): boolean {
    try {
        process.kill(pid, 0);
        return true;
    } catch (error) {
        return (error as NodeJS.ErrnoException).code === 'EPERM';
    }
}

/** Command line of a running process, or null if it is gone. */
export function processCommandLine(pid: number): string | null {
    try {
        if (existsSync(`/proc/${pid}/cmdline`)) {
            return readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').join(' ').trim() || null;
        }
        return execFileSync('ps', ['-o', 'args=', '-p', String(pid)], { encoding: 'utf8' }).trim() || null;
    } catch {
        return null;
    }
}

export function looksLikeOpencodeServe(commandLine: string | null): boolean {
    return !!commandLine && /opencode/.test(commandLine) && /\bserve\b/.test(commandLine);
}

export function looksLikeHappyOpencode(commandLine: string | null): boolean {
    return !!commandLine && /happy|index\.mjs/.test(commandLine) && /\bopencode\b/.test(commandLine);
}

/**
 * A live owner for an OpenCode session: its state file, its owner still
 * running (and still a `happy opencode`), its server still running.
 */
export function findLiveOwner(dir: string, opencodeSessionId: string): OpencodeTuiState | null {
    const state = readTuiState(dir, opencodeSessionId);
    if (!state) {
        return null;
    }
    const ownerAlive = isProcessAlive(state.ownerPid) && looksLikeHappyOpencode(processCommandLine(state.ownerPid));
    const serverAlive = isProcessAlive(state.serverPid) && looksLikeOpencodeServe(processCommandLine(state.serverPid));
    return ownerAlive && serverAlive ? state : null;
}

/**
 * Stop servers whose owner is gone (it crashed or was SIGKILLed) and drop
 * their state files. A server is only signalled if its pid still runs
 * `opencode serve`, so a recycled pid is never touched.
 */
export function reapOrphanedServers(dir: string): number[] {
    let entries: string[];
    try {
        entries = readdirSync(dir).filter((name) => name.endsWith('.json'));
    } catch {
        return [];
    }
    const reaped: number[] = [];
    for (const name of entries) {
        const state = readTuiState(dir, name.slice(0, -'.json'.length));
        if (!state || (isProcessAlive(state.ownerPid) && looksLikeHappyOpencode(processCommandLine(state.ownerPid)))) {
            continue;
        }
        if (isProcessAlive(state.serverPid) && looksLikeOpencodeServe(processCommandLine(state.serverPid))) {
            try {
                process.kill(state.serverPid, 'SIGTERM');
                reaped.push(state.serverPid);
            } catch (error) {
                logger.debug(`[OpenCode] Could not stop orphaned server ${state.serverPid}:`, error);
            }
        }
        removeTuiState(dir, state.opencodeSessionId, state.ownerPid);
    }
    return reaped;
}
