/**
 * Find and stop the process(es) behind a Happy session without its help.
 *
 * Used by the daemon's `restart-happy-session` RPC (and the app's Resume for
 * OpenCode, which goes through it) and by `happy opencode --resume <id>
 * --restart`. A session that is wedged, untracked (the daemon restarted since
 * it started) or driven by two owners at once still has to be found and
 * stopped, so nothing here asks the session to cooperate.
 *
 * Only exact ids ever select a process:
 * - the daemon's own tracked map;
 * - `~/.happy/sessions.json`: the `hostPid` a session reported for its own id,
 *   accepted only if the record is from this boot, the process still runs a
 *   `happy <flavor>` command line, and it started before the record was saved
 *   (so a recycled pid is never taken for the session);
 * - for OpenCode, the state files in `~/.happy/opencode-tui/` (owner and
 *   `opencode serve` pids), the link file `happy-sessions.json`, and any
 *   `happy opencode … --resume <ses>` process that runs an OpenCode backend
 *   for one of the session's OpenCode ids (an owner whose state file is gone,
 *   for example after a session switch in its TUI, or a second owner).
 * A process is never matched by its name alone.
 *
 * Stopping: SIGUSR2 for OpenCode owners that record it (stop, but leave the
 * session to the new owner), else SIGTERM, to the process group when the
 * process leads one; up to 8 s later SIGKILL; then the OpenCode servers and
 * agent backends the owners had started, then the orphaned-server reaper.
 * The result says which pids are gone and which survived.
 */

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { uptime } from 'node:os';
import { join } from 'node:path';
import type { PersistedSession } from '@/persistence';
import {
    looksLikeOpencodeServe,
    processCommandLine,
    readTuiState,
    reapOrphanedServers,
    type OpencodeTuiState,
} from '@/opencode/tui/opencodeProcesses';

export type RestartableFlavor = 'claude' | 'codex' | 'opencode';

export const RESTARTABLE_FLAVORS: readonly RestartableFlavor[] = ['claude', 'codex', 'opencode'];

export function isRestartableFlavor(flavor: string | null | undefined): flavor is RestartableFlavor {
    return RESTARTABLE_FLAVORS.includes((flavor ?? 'claude') as RestartableFlavor);
}

/** Everything that touches real processes, so tests can supply a fake process table. */
export type ProcessOps = {
    /** Running (a zombie is not running). */
    isAlive: (pid: number) => boolean;
    commandLine: (pid: number) => string | null;
    /** Wall-clock start time of the process, or null if it cannot be read. */
    startTimeMs: (pid: number) => number | null;
    parentPid: (pid: number) => number | null;
    processGroupId: (pid: number) => number | null;
    /** Every pid on the machine, or [] where that cannot be listed. */
    listPids: () => number[];
    kill: (pid: number, signal: NodeJS.Signals) => void;
    now: () => number;
    sleep: (ms: number) => Promise<void>;
    /** This process: never a target, nor are its ancestors. */
    selfPid: number;
    bootTimeMs: () => number;
};

// --- Real process table ------------------------------------------------------

/** Fields of /proc/<pid>/stat after the command name, so index 0 is field 3 (state). */
function procStatFields(pid: number): string[] | null {
    try {
        const raw = readFileSync(`/proc/${pid}/stat`, 'utf8');
        const close = raw.lastIndexOf(')');
        return close === -1 ? null : raw.slice(close + 2).trim().split(/\s+/);
    } catch {
        return null;
    }
}

let cachedClockTicks: number | null = null;
function clockTicksPerSecond(): number {
    if (cachedClockTicks === null) {
        try {
            cachedClockTicks = parseInt(execFileSync('getconf', ['CLK_TCK'], { encoding: 'utf8' }).trim(), 10) || 100;
        } catch {
            cachedClockTicks = 100;
        }
    }
    return cachedClockTicks;
}

function procBootTimeMs(): number | null {
    try {
        const match = readFileSync('/proc/stat', 'utf8').match(/^btime\s+(\d+)/m);
        return match ? parseInt(match[1], 10) * 1000 : null;
    } catch {
        return null;
    }
}

function psField(pid: number, field: string): string | null {
    try {
        return execFileSync('ps', ['-o', `${field}=`, '-p', String(pid)], { encoding: 'utf8' }).trim() || null;
    } catch {
        return null;
    }
}

/** `ps -o etime` format: [[dd-]hh:]mm:ss */
export function parseElapsed(etime: string): number | null {
    const match = etime.trim().match(/^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$/);
    if (!match) {
        return null;
    }
    const [, days, hours, minutes, seconds] = match;
    return ((parseInt(days ?? '0', 10) * 24 + parseInt(hours ?? '0', 10)) * 60 + parseInt(minutes, 10)) * 60 + parseInt(seconds, 10);
}

const hasProc = existsSync('/proc/self/stat');

export const realProcessOps: ProcessOps = {
    isAlive: (pid) => {
        if (!Number.isSafeInteger(pid) || pid <= 0) {
            return false;
        }
        try {
            process.kill(pid, 0);
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== 'EPERM') {
                return false;
            }
        }
        if (hasProc) {
            const fields = procStatFields(pid);
            if (!fields) {
                // /proc entry gone between the two checks.
                return existsSync(`/proc/${pid}`);
            }
            return fields[0] !== 'Z' && fields[0] !== 'X';
        }
        const state = psField(pid, 'stat');
        return !state || !state.startsWith('Z');
    },
    commandLine: (pid) => processCommandLine(pid),
    startTimeMs: (pid) => {
        if (hasProc) {
            const fields = procStatFields(pid);
            const boot = procBootTimeMs();
            if (!fields || boot === null) {
                return null;
            }
            const ticks = parseInt(fields[19], 10);
            return Number.isFinite(ticks) ? boot + (ticks / clockTicksPerSecond()) * 1000 : null;
        }
        const elapsed = psField(pid, 'etime');
        const seconds = elapsed ? parseElapsed(elapsed) : null;
        return seconds === null ? null : Date.now() - seconds * 1000;
    },
    parentPid: (pid) => {
        const value = hasProc ? procStatFields(pid)?.[1] : psField(pid, 'ppid');
        const parsed = value ? parseInt(value, 10) : NaN;
        return Number.isFinite(parsed) ? parsed : null;
    },
    processGroupId: (pid) => {
        const value = hasProc ? procStatFields(pid)?.[2] : psField(pid, 'pgid');
        const parsed = value ? parseInt(value, 10) : NaN;
        return Number.isFinite(parsed) ? parsed : null;
    },
    listPids: () => {
        try {
            if (hasProc) {
                return readdirSync('/proc').filter((name) => /^\d+$/.test(name)).map((name) => parseInt(name, 10));
            }
            return execFileSync('ps', ['-axo', 'pid='], { encoding: 'utf8' })
                .split('\n').map((line) => parseInt(line.trim(), 10)).filter((pid) => Number.isFinite(pid));
        } catch {
            return [];
        }
    },
    kill: (pid, signal) => { process.kill(pid, signal); },
    now: () => Date.now(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    selfPid: process.pid,
    bootTimeMs: () => procBootTimeMs() ?? Date.now() - uptime() * 1000,
};

// --- Command lines -----------------------------------------------------------

/** Subcommands of `happy` that are not a Claude session (`happy` alone is). */
const NON_CLAUDE_SUBCOMMANDS = new Set([
    'codex', 'opencode', 'gemini', 'agy', 'openclaw', 'acp', 'daemon', 'auth', 'doctor', 'resume',
    'connect', 'notify', 'logout', 'install', 'uninstall', 'server', 'mcp', 'login', 'version',
    'sandbox', 'bye',
]);

function tokens(commandLine: string): string[] {
    return commandLine.split(/\s+/).filter(Boolean);
}

/** The arguments after the Happy entry point (dist/index.mjs, bin/happy.mjs, `happy`). */
function happyArgs(commandLine: string | null): string[] | null {
    if (!commandLine) {
        return null;
    }
    const parts = tokens(commandLine);
    const entry = parts.findIndex((part) => /(^|\/)(happy(\.mjs)?|index\.mjs)$/.test(part)
        && (part.endsWith('index.mjs') ? /happy/.test(part) : true));
    return entry === -1 ? null : parts.slice(entry + 1);
}

/** Is this the command line of a `happy <flavor>` session process? */
export function looksLikeHappySession(commandLine: string | null, flavor: RestartableFlavor): boolean {
    const args = happyArgs(commandLine);
    if (!args) {
        return false;
    }
    if (args.includes('--restart')) {
        // `happy opencode --resume <id> --restart` is the restarter, not an owner.
        return false;
    }
    // The subcommand is the first argument (as in index.ts); a flag value
    // such as `--started-by daemon` is not one.
    const subcommand = args[0];
    if (flavor === 'claude') {
        return subcommand === undefined || subcommand === 'claude' || !NON_CLAUDE_SUBCOMMANDS.has(subcommand);
    }
    return subcommand === flavor;
}

/** Does the command line name `id` as an exact argument? */
export function commandLineNames(commandLine: string | null, id: string | undefined): boolean {
    return !!commandLine && !!id && tokens(commandLine).includes(id);
}

/** Agent backends a session starts and that may outlive it when it is SIGKILLed. */
function looksLikeAgentBackend(commandLine: string | null): boolean {
    if (!commandLine) {
        return false;
    }
    if (happyArgs(commandLine)) {
        // Another Happy process (the daemon, a nested session) is never a helper.
        return false;
    }
    return /\bopencode\b.*\b(serve|acp|attach)\b/.test(commandLine) || /\bcodex\b.*\bapp-server\b/.test(commandLine);
}

function looksLikeOpencodeBackend(commandLine: string | null): boolean {
    return !!commandLine && /\bopencode\b.*\b(serve|acp)\b/.test(commandLine) && !happyArgs(commandLine);
}

// --- Discovery ---------------------------------------------------------------

/** A recycled pid started after the session was recorded; allow for clock granularity. */
const START_TIME_SLACK_MS = 5_000;

export type ProcessIdentity = { pid: number; commandLine: string | null; startTimeMs: number | null };

export type SessionProcess = ProcessIdentity & {
    source: 'tracked' | 'sessions.json' | 'opencode-state' | 'command-line';
    /** First signal: SIGUSR2 for OpenCode owners that support it. */
    signal: 'SIGTERM' | 'SIGUSR2';
    /** Signal the whole process group (the pid leads it). */
    group: boolean;
    happySessionId?: string;
    opencodeSessionId?: string;
    /** From the OpenCode state file, when there is one. */
    opencodeState?: OpencodeTuiState;
    /** Started by the owner (OpenCode server, agent backend); stopped after it. */
    helpers: ProcessIdentity[];
};

export type UnverifiedProcess = { pid: number; reason: string };

export type LocateResult = {
    targets: SessionProcess[];
    /** Live pids recorded for the session whose identity could not be confirmed. Never signalled. */
    unverified: UnverifiedProcess[];
    /** Every OpenCode session id tied to this Happy session (requested, linked, recorded). */
    opencodeSessionIds: string[];
};

export type TrackedPid = { pid: number; daemonSpawned: boolean };

export type LocateOptions = {
    flavor: RestartableFlavor;
    /** The Happy session; optional for `happy opencode --restart`, which starts from an OpenCode id. */
    happySessionId?: string;
    /** Provider session id: Claude session, Codex thread, OpenCode session. */
    resumeTarget?: string;
    /** Pids the daemon tracks for this session (authoritative). */
    tracked?: TrackedPid[];
    persisted: Record<string, PersistedSession>;
    /** `~/.happy/opencode-tui`, for OpenCode. */
    opencodeStateDir?: string;
    ops?: ProcessOps;
};

function identity(ops: ProcessOps, pid: number): ProcessIdentity {
    return { pid, commandLine: ops.commandLine(pid), startTimeMs: ops.startTimeMs(pid) };
}

function ancestors(ops: ProcessOps, pid: number): Set<number> {
    const seen = new Set<number>([pid]);
    let current: number | null = pid;
    for (let depth = 0; depth < 64 && current !== null && current > 1; depth++) {
        current = ops.parentPid(current);
        if (current !== null) {
            seen.add(current);
        }
    }
    return seen;
}

type LinkFile = Record<string, { happySessionId?: string }>;

function readLinks(dir: string): LinkFile {
    try {
        const parsed = JSON.parse(readFileSync(join(dir, 'happy-sessions.json'), 'utf8'));
        return parsed && typeof parsed === 'object' ? parsed as LinkFile : {};
    } catch {
        return {};
    }
}

function readAllTuiStates(dir: string): OpencodeTuiState[] {
    let names: string[];
    try {
        names = readdirSync(dir).filter((name) => name.endsWith('.json') && name !== 'happy-sessions.json');
    } catch {
        return [];
    }
    const states: OpencodeTuiState[] = [];
    for (const name of names) {
        const state = readTuiState(dir, name.slice(0, -'.json'.length));
        if (state) {
            states.push(state);
        }
    }
    return states;
}

/**
 * Find the processes running a Happy session (and, for OpenCode, every
 * process owning one of its OpenCode sessions). Read-only.
 */
export function locateSessionProcesses(opts: LocateOptions): LocateResult {
    const ops = opts.ops ?? realProcessOps;
    const { flavor } = opts;
    const excluded = ancestors(ops, ops.selfPid);
    const boot = ops.bootTimeMs();
    const targets = new Map<number, SessionProcess>();
    const unverified = new Map<number, string>();

    const add = (pid: number, entry: Omit<SessionProcess, 'pid' | 'commandLine' | 'startTimeMs' | 'group' | 'helpers'> & { group?: boolean }) => {
        if (excluded.has(pid)) {
            return;
        }
        unverified.delete(pid);
        const existing = targets.get(pid);
        if (existing) {
            // A state file knows more (restart signal, server pid) than other sources.
            if (entry.opencodeState && !existing.opencodeState) {
                existing.opencodeState = entry.opencodeState;
                existing.signal = entry.signal;
            }
            existing.group = existing.group || !!entry.group;
            existing.happySessionId ??= entry.happySessionId;
            existing.opencodeSessionId ??= entry.opencodeSessionId;
            return;
        }
        targets.set(pid, { ...identity(ops, pid), group: !!entry.group, helpers: [], ...entry });
    };

    // 1. The daemon's own map.
    for (const tracked of opts.tracked ?? []) {
        if (ops.isAlive(tracked.pid)) {
            add(tracked.pid, { source: 'tracked', signal: 'SIGTERM', group: tracked.daemonSpawned, happySessionId: opts.happySessionId });
        }
    }

    // The ids that belong to this session.
    const happyIds = new Set<string>(opts.happySessionId ? [opts.happySessionId] : []);
    const opencodeIds = new Set<string>(flavor === 'opencode' && opts.resumeTarget ? [opts.resumeTarget] : []);
    const states = flavor === 'opencode' && opts.opencodeStateDir ? readAllTuiStates(opts.opencodeStateDir) : [];
    if (flavor === 'opencode' && opts.opencodeStateDir) {
        const links = readLinks(opts.opencodeStateDir);
        for (const [opencodeId, link] of Object.entries(links)) {
            if (link?.happySessionId && happyIds.has(link.happySessionId)) {
                opencodeIds.add(opencodeId);
            }
        }
        for (const id of [...opencodeIds]) {
            const linked = links[id]?.happySessionId;
            if (linked) {
                happyIds.add(linked);
            }
        }
        for (const state of states) {
            if (happyIds.has(state.happySessionId)) {
                opencodeIds.add(state.opencodeSessionId);
            }
        }
        for (const [id, record] of Object.entries(opts.persisted)) {
            if (happyIds.has(id) && record.metadata?.opencodeSessionId) {
                opencodeIds.add(record.metadata.opencodeSessionId);
            }
        }
    }

    // 2. sessions.json: the pid each session reported for itself.
    for (const [id, record] of Object.entries(opts.persisted)) {
        const pid = record.metadata?.hostPid;
        const recordFlavor = (record.metadata?.flavor ?? 'claude') as string;
        const ours = happyIds.has(id)
            || (flavor === 'opencode' && recordFlavor === 'opencode' && !!record.metadata?.opencodeSessionId && opencodeIds.has(record.metadata.opencodeSessionId));
        if (!ours || !pid || !Number.isSafeInteger(pid) || pid <= 0 || targets.has(pid) || excluded.has(pid)) {
            continue;
        }
        if (record.savedAt < boot) {
            // Saved before this boot: the pid space was reset since.
            continue;
        }
        if (!ops.isAlive(pid)) {
            continue;
        }
        const commandLine = ops.commandLine(pid);
        if (!looksLikeHappySession(commandLine, flavor)) {
            // Recycled by an unrelated program.
            continue;
        }
        const startedAt = ops.startTimeMs(pid);
        const namesSession = commandLineNames(commandLine, id)
            || commandLineNames(commandLine, flavor === 'opencode' ? record.metadata?.opencodeSessionId : opts.resumeTarget);
        if (startedAt !== null && startedAt > record.savedAt + START_TIME_SLACK_MS) {
            // Started after the record was written: another Happy session reusing the pid.
            continue;
        }
        if (startedAt === null && !namesSession) {
            unverified.set(pid, `pid ${pid} is recorded for session ${id} but its start time cannot be read to rule out pid reuse`);
            continue;
        }
        add(pid, { source: 'sessions.json', signal: 'SIGTERM', group: ops.processGroupId(pid) === pid, happySessionId: id, opencodeSessionId: record.metadata?.opencodeSessionId });
    }

    if (flavor === 'opencode') {
        // 3. OpenCode state files: owner and server of each OpenCode session.
        for (const state of states) {
            if (!opencodeIds.has(state.opencodeSessionId) && !happyIds.has(state.happySessionId)) {
                continue;
            }
            const pid = state.ownerPid;
            if (excluded.has(pid) || !ops.isAlive(pid)) {
                continue;
            }
            const commandLine = ops.commandLine(pid);
            if (!looksLikeHappySession(commandLine, 'opencode')) {
                continue;
            }
            const startedAt = ops.startTimeMs(pid);
            if (startedAt !== null && typeof state.startedAt === 'number' && startedAt > state.startedAt + START_TIME_SLACK_MS) {
                continue;
            }
            add(pid, {
                source: 'opencode-state',
                signal: state.restartSignal === 'SIGUSR2' ? 'SIGUSR2' : 'SIGTERM',
                group: ops.processGroupId(pid) === pid,
                happySessionId: state.happySessionId,
                opencodeSessionId: state.opencodeSessionId,
                opencodeState: state,
            });
        }

        // 4. Any `happy opencode … <ses>` that runs an OpenCode backend for
        //    one of these sessions: owners without a state file, second owners.
        if (opencodeIds.size > 0) {
            const all = ops.listPids();
            const children = new Map<number, number[]>();
            for (const pid of all) {
                const parent = ops.parentPid(pid);
                if (parent !== null) {
                    children.set(parent, [...(children.get(parent) ?? []), pid]);
                }
            }
            for (const pid of all) {
                if (targets.has(pid) || excluded.has(pid)) {
                    continue;
                }
                const commandLine = ops.commandLine(pid);
                if (!looksLikeHappySession(commandLine, 'opencode')) {
                    continue;
                }
                const named = [...opencodeIds].find((id) => commandLineNames(commandLine, id));
                if (!named) {
                    continue;
                }
                // A TUI attached to someone else's server runs `opencode attach`
                // only; an owner runs the server (or `opencode acp`) itself.
                const runsBackend = (children.get(pid) ?? []).some((child) => looksLikeOpencodeBackend(ops.commandLine(child)));
                if (!runsBackend || !ops.isAlive(pid)) {
                    continue;
                }
                add(pid, { source: 'command-line', signal: 'SIGTERM', group: ops.processGroupId(pid) === pid, opencodeSessionId: named });
            }
        }
    }

    // Helpers: backends the owners started, which can outlive a SIGKILL.
    const all = targets.size > 0 ? ops.listPids() : [];
    for (const target of targets.values()) {
        const helpers = new Map<number, ProcessIdentity>();
        const serverPid = target.opencodeState?.serverPid;
        if (serverPid && !targets.has(serverPid) && !excluded.has(serverPid) && ops.isAlive(serverPid)
            && looksLikeOpencodeServe(ops.commandLine(serverPid))) {
            helpers.set(serverPid, identity(ops, serverPid));
        }
        const descendants = new Set<number>([target.pid]);
        let grew = true;
        while (grew) {
            grew = false;
            for (const pid of all) {
                const parent = ops.parentPid(pid);
                if (parent !== null && descendants.has(parent) && !descendants.has(pid)) {
                    descendants.add(pid);
                    grew = true;
                }
            }
        }
        descendants.delete(target.pid);
        for (const pid of descendants) {
            if (!targets.has(pid) && !excluded.has(pid) && looksLikeAgentBackend(ops.commandLine(pid))) {
                helpers.set(pid, identity(ops, pid));
            }
        }
        target.helpers = [...helpers.values()];
    }

    return {
        targets: [...targets.values()],
        unverified: [...unverified.entries()].map(([pid, reason]) => ({ pid, reason })),
        opencodeSessionIds: [...opencodeIds],
    };
}

// --- Stopping ----------------------------------------------------------------

export const DEFAULT_STOP_GRACE_MS = 8_000;
const KILL_WAIT_MS = 3_000;
const HELPER_GRACE_MS = 2_000;
const POLL_MS = 100;

export type StopResult = {
    /** Pids that were running and are gone now (owners first, then helpers). */
    stoppedPids: number[];
    /** Pids that would not die even after SIGKILL. */
    survivors: number[];
    /** Owners that ignored the first signal and were SIGKILLed. */
    killed: number[];
    /** Orphaned OpenCode servers the reaper stopped. */
    reaped: number[];
};

export type StopOptions = {
    ops?: ProcessOps;
    graceMs?: number;
    /** Run after the owners are gone; defaults to the OpenCode orphan reaper on `opencodeStateDir`. */
    reapOrphans?: () => number[];
    opencodeStateDir?: string;
    log?: (message: string) => void;
};

/** Still the same process we identified (not exited and recycled meanwhile). */
function sameProcess(ops: ProcessOps, process: ProcessIdentity): boolean {
    if (!ops.isAlive(process.pid)) {
        return false;
    }
    if (process.startTimeMs !== null) {
        const now = ops.startTimeMs(process.pid);
        if (now !== null && Math.abs(now - process.startTimeMs) > 1_000) {
            return false;
        }
    }
    return process.commandLine === null || ops.commandLine(process.pid) === process.commandLine;
}

function send(ops: ProcessOps, pid: number, signal: NodeJS.Signals, group: boolean, log: (message: string) => void): void {
    if (group && process.platform !== 'win32') {
        try {
            ops.kill(-pid, signal);
        } catch (error) {
            log(`${signal} to process group ${pid} failed: ${error instanceof Error ? error.message : error}`);
        }
    }
    try {
        ops.kill(pid, signal);
    } catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        if (code !== 'ESRCH') {
            log(`${signal} to ${pid} failed: ${error instanceof Error ? error.message : error}`);
        }
    }
}

async function waitUntilGone(ops: ProcessOps, processes: ProcessIdentity[], timeoutMs: number): Promise<ProcessIdentity[]> {
    const deadline = ops.now() + timeoutMs;
    let alive = processes.filter((process) => sameProcess(ops, process));
    while (alive.length > 0 && ops.now() < deadline) {
        await ops.sleep(POLL_MS);
        alive = alive.filter((process) => sameProcess(ops, process));
    }
    return alive;
}

/**
 * Stop the located processes: first signal, up to `graceMs` later SIGKILL,
 * then their helpers (SIGTERM, then SIGKILL), then the orphan reaper.
 */
export async function stopSessionProcesses(targets: SessionProcess[], opts: StopOptions = {}): Promise<StopResult> {
    const ops = opts.ops ?? realProcessOps;
    const log = opts.log ?? (() => { });
    const graceMs = opts.graceMs ?? DEFAULT_STOP_GRACE_MS;
    const owners = targets.filter((target) => sameProcess(ops, target));
    const helpers = new Map<number, ProcessIdentity>();
    for (const target of targets) {
        for (const helper of target.helpers) {
            if (!targets.some((other) => other.pid === helper.pid)) {
                helpers.set(helper.pid, helper);
            }
        }
    }
    const helperList = [...helpers.values()].filter((helper) => sameProcess(ops, helper));

    for (const owner of owners) {
        // SIGUSR2 is handled by the owner itself; its TUI must not get it.
        const group = owner.signal === 'SIGTERM' && owner.group;
        log(`Sending ${owner.signal} to ${owner.pid}${group ? ' (process group)' : ''}`);
        send(ops, owner.pid, owner.signal, group, log);
    }
    let alive = await waitUntilGone(ops, owners, graceMs);
    const killed: number[] = [];
    for (const owner of alive) {
        const target = owner as SessionProcess;
        log(`${target.pid} did not stop within ${graceMs} ms, sending SIGKILL`);
        killed.push(target.pid);
        send(ops, target.pid, 'SIGKILL', target.group, log);
    }
    if (alive.length > 0) {
        alive = await waitUntilGone(ops, alive, KILL_WAIT_MS);
    }

    let helpersAlive = helperList.filter((helper) => sameProcess(ops, helper));
    for (const helper of helpersAlive) {
        log(`Stopping ${helper.pid} (${helper.commandLine ?? 'helper'}) left by the session`);
        send(ops, helper.pid, 'SIGTERM', false, log);
    }
    helpersAlive = await waitUntilGone(ops, helpersAlive, HELPER_GRACE_MS);
    for (const helper of helpersAlive) {
        send(ops, helper.pid, 'SIGKILL', false, log);
    }
    helpersAlive = await waitUntilGone(ops, helpersAlive, KILL_WAIT_MS);

    let reaped: number[] = [];
    try {
        reaped = opts.reapOrphans
            ? opts.reapOrphans()
            : (opts.opencodeStateDir ? reapOrphanedServers(opts.opencodeStateDir) : []);
    } catch (error) {
        log(`Orphan reaper failed: ${error instanceof Error ? error.message : error}`);
    }

    const survivors = [...alive, ...helpersAlive].map((process) => process.pid);
    const stoppedPids = [...owners, ...helperList]
        .map((process) => process.pid)
        .filter((pid) => !survivors.includes(pid));
    return { stoppedPids, survivors, killed, reaped };
}

// --- Starting the OpenCode owner again ----------------------------------------

export type OpencodePermissionPolicyName = 'auto' | 'ask';

/** Map an app permission mode to the policy a headless OpenCode owner takes. */
export function opencodePolicyFromPermissionMode(mode: string | undefined): OpencodePermissionPolicyName | undefined {
    if (mode === 'ask' || mode === 'default') {
        return 'ask';
    }
    if (mode === 'auto' || mode === 'yolo' || mode === 'bypassPermissions') {
        return 'auto';
    }
    return undefined;
}

/**
 * Arguments for the TUI-style headless OpenCode owner, the one
 * `happy opencode --restart` starts: it serves the app (questions,
 * permissions) and a TUI can be attached to it later.
 */
export function opencodeOwnerArgs(opts: {
    opencodeSessionId: string;
    happySessionId?: string;
    permissionPolicy: OpencodePermissionPolicyName;
    startedBy?: 'daemon' | 'terminal';
}): string[] {
    const args = ['opencode', '--resume', opts.opencodeSessionId, '--headless', '--permission-mode', opts.permissionPolicy];
    if (opts.happySessionId) {
        args.push('--happy-session', opts.happySessionId);
    }
    if (opts.startedBy) {
        args.push('--started-by', opts.startedBy);
    }
    return args;
}

/**
 * Pick the OpenCode session and launch settings to continue from what was
 * found: the live owner of this Happy session knows its current OpenCode
 * session (it may have switched in its TUI since the metadata was written).
 */
export function opencodeRestartPlan(located: LocateResult, opts: {
    happySessionId?: string;
    opencodeSessionId?: string;
}): { opencodeSessionId?: string; happySessionId?: string; cwd?: string; permissionPolicy?: OpencodePermissionPolicyName } {
    const withState = located.targets.filter((target) => target.opencodeState);
    const own = withState.find((target) => opts.happySessionId && target.opencodeState!.happySessionId === opts.happySessionId)
        ?? withState.find((target) => opts.opencodeSessionId && target.opencodeState!.opencodeSessionId === opts.opencodeSessionId)
        ?? withState[0];
    const state = own?.opencodeState;
    return {
        opencodeSessionId: state?.opencodeSessionId ?? opts.opencodeSessionId,
        happySessionId: opts.happySessionId ?? state?.happySessionId
            ?? located.targets.find((target) => target.happySessionId)?.happySessionId,
        cwd: state?.cwd,
        permissionPolicy: state?.permissionPolicy,
    };
}
