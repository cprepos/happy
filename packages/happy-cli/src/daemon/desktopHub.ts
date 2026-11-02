/**
 * Claude Desktop hub: the daemon's in-memory state for desktop Code sessions.
 *
 * The happyify plugin's hooks run inside the desktop's own Claude process and
 * talk to the daemon over HTTP (see docs/plans/happyify-desktop-sync.md,
 * "Contract"). This module holds everything those routes share:
 *
 * - the adopt registry: one mirror per desktop Claude process, keyed by every
 *   claudeSessionId that process has used. Adopting the same id again returns
 *   the same mirror; a new id from the same pid (resume, /clear, compact)
 *   re-points that mirror, and the old id keeps resolving to it so the attach
 *   process, which only knows the id it was started with, keeps working.
 * - the inbox: phone messages queued by the attach process, handed to the
 *   newest waiting hook only. A newer waiter releases older ones with nothing.
 * - the events log: busy / idle / ended / delivered with a monotonically
 *   increasing seq, long-polled by the attach process.
 * - pending phone spawns: a phone-started session waits here until its
 *   claudeSessionId is adopted and its attach process has reported the Happy
 *   session id.
 *
 * Spawning the attach process is injected, so the hub itself does no I/O.
 * `startDesktopSessionFromPhone` and `runDesktopCommand` implement the
 * phone-started flow with an injectable command runner.
 */

import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { logger } from '@/ui/logger';

/** Longest an inbox or events long-poll may wait. Hooks use a 660 s timeout. */
export const DESKTOP_MAX_WAIT_MS = 600_000;
/** How long a phone-started session waits for its SessionStart adopt. */
export const DESKTOP_PHONE_ADOPT_TIMEOUT_MS = 30_000;
/** Events kept per session; attach polls continuously, so this is plenty. */
const EVENT_LOG_LIMIT = 500;

export type DesktopEventType = 'busy' | 'idle' | 'ended' | 'delivered';
export type DesktopEvent = { type: DesktopEventType; localId?: string };
export type DesktopInboxMessage = { localId: string; text: string };
export type DesktopAdoptRequest = { claudeSessionId: string; transcriptPath: string; cwd: string; pid: number };
export type DesktopAdoptResult = { type: 'success'; happySessionId: string } | { type: 'error'; errorMessage: string };
export type DesktopAttachResult = { type: 'success'; happySessionId: string; attachPid: number } | { type: 'error'; errorMessage: string };

/** Starts the attach process for a newly adopted desktop session. */
export type DesktopAttachSpawner = (session: DesktopAdoptRequest) => Promise<DesktopAttachResult>;

type DesktopEntry = {
    /** Newest claudeSessionId the desktop process reported. */
    claudeSessionId: string;
    /** Every id that resolves to this entry, including the current one. */
    ids: Set<string>;
    pid: number;
    cwd: string;
    transcriptPath: string;
    happySessionId?: string;
    attachPid?: number;
    attaching?: Promise<DesktopAdoptResult>;
    ended: boolean;
    queue: DesktopInboxMessage[];
    inboxWaiter?: (message: DesktopInboxMessage | null) => void;
    events: Array<DesktopEvent & { seq: number }>;
    seq: number;
    eventWaiters: Set<() => void>;
};

export type DesktopSessionSnapshot = {
    claudeSessionId: string;
    happySessionId?: string;
    pid: number;
    cwd: string;
    transcriptPath: string;
    attachPid?: number;
    ended: boolean;
};

export type DesktopHub = ReturnType<typeof createDesktopHub>;

export function createDesktopHub({ spawnAttach }: { spawnAttach: DesktopAttachSpawner }) {
    const entries = new Map<string, DesktopEntry>();
    const pendingAdoptions = new Map<string, Set<(result: DesktopAdoptResult) => void>>();

    const settlePending = (ids: Iterable<string>, result: DesktopAdoptResult): void => {
        for (const id of ids) {
            const waiters = pendingAdoptions.get(id);
            if (!waiters) continue;
            pendingAdoptions.delete(id);
            for (const resolve of waiters) resolve(result);
        }
    };

    const emit = (entry: DesktopEntry, event: DesktopEvent): void => {
        entry.seq += 1;
        entry.events.push({ ...event, seq: entry.seq });
        if (entry.events.length > EVENT_LOG_LIMIT) entry.events.splice(0, entry.events.length - EVENT_LOG_LIMIT);
        const waiters = [...entry.eventWaiters];
        entry.eventWaiters.clear();
        for (const wake of waiters) wake();
    };

    const deliver = (entry: DesktopEntry, message: DesktopInboxMessage): DesktopInboxMessage => {
        emit(entry, { type: 'delivered', localId: message.localId });
        logger.debug(`[DESKTOP HUB] Delivered ${message.localId} to ${entry.claudeSessionId}`);
        return message;
    };

    const findLiveByPid = (pid: number): DesktopEntry | undefined => {
        for (const entry of new Set(entries.values())) {
            if (entry.pid === pid && !entry.ended) return entry;
        }
        return undefined;
    };

    const startAttach = (entry: DesktopEntry, request: DesktopAdoptRequest): Promise<DesktopAdoptResult> => {
        const attaching = spawnAttach(request).then((result): DesktopAdoptResult => {
            entry.attaching = undefined;
            if (result.type === 'error') {
                logger.debug(`[DESKTOP HUB] Attach failed for ${request.claudeSessionId}: ${result.errorMessage}`);
                // Forget the entry so the next SessionStart can try again.
                for (const id of entry.ids) {
                    if (entries.get(id) === entry) entries.delete(id);
                }
                settlePending(entry.ids, result);
                return result;
            }
            entry.happySessionId = result.happySessionId;
            entry.attachPid = result.attachPid;
            logger.debug(`[DESKTOP HUB] ${entry.claudeSessionId} attached as ${result.happySessionId} (attach PID ${result.attachPid})`);
            settlePending(entry.ids, { type: 'success', happySessionId: result.happySessionId });
            return { type: 'success', happySessionId: result.happySessionId };
        });
        entry.attaching = attaching;
        return attaching;
    };

    /** Result for an entry that already exists: its id, or its attach in flight. */
    const existingResult = (entry: DesktopEntry): Promise<DesktopAdoptResult> => entry.attaching
        ?? Promise.resolve({ type: 'success', happySessionId: entry.happySessionId! });

    const adopt = (request: DesktopAdoptRequest): Promise<DesktopAdoptResult> => {
        const known = entries.get(request.claudeSessionId);
        if (known && !known.ended) {
            known.pid = request.pid;
            known.cwd = request.cwd;
            known.transcriptPath = request.transcriptPath;
            return existingResult(known);
        }

        const samePid = findLiveByPid(request.pid);
        if (samePid) {
            logger.debug(`[DESKTOP HUB] Re-pointing ${samePid.claudeSessionId} to ${request.claudeSessionId} (PID ${request.pid})`);
            samePid.claudeSessionId = request.claudeSessionId;
            samePid.ids.add(request.claudeSessionId);
            samePid.cwd = request.cwd;
            samePid.transcriptPath = request.transcriptPath;
            entries.set(request.claudeSessionId, samePid);
            if (samePid.happySessionId) {
                settlePending([request.claudeSessionId], { type: 'success', happySessionId: samePid.happySessionId });
            }
            return existingResult(samePid);
        }

        const entry: DesktopEntry = {
            claudeSessionId: request.claudeSessionId,
            ids: new Set([request.claudeSessionId]),
            pid: request.pid,
            cwd: request.cwd,
            transcriptPath: request.transcriptPath,
            ended: false,
            queue: [],
            events: [],
            seq: 0,
            eventWaiters: new Set(),
        };
        entries.set(request.claudeSessionId, entry);
        logger.debug(`[DESKTOP HUB] Adopting ${request.claudeSessionId} (PID ${request.pid}, cwd ${request.cwd})`);
        return startAttach(entry, request);
    };

    /** Records busy / idle / ended from a hook. False when the id is unknown. */
    const report = (claudeSessionId: string, type: 'busy' | 'idle' | 'ended'): boolean => {
        const entry = entries.get(claudeSessionId);
        if (!entry) return false;
        if (type === 'ended') {
            entry.ended = true;
            entry.inboxWaiter?.(null);
            entry.inboxWaiter = undefined;
        }
        emit(entry, { type });
        return true;
    };

    /**
     * Long-polls the inbox. Resolves with a message, or null on timeout, abort,
     * end, or when a newer waiter replaces this one. Undefined for an unknown id.
     */
    const waitForInbox = (claudeSessionId: string, waitMs: number, signal?: AbortSignal): Promise<DesktopInboxMessage | null> | undefined => {
        const entry = entries.get(claudeSessionId);
        if (!entry) return undefined;

        // Only the newest waiter may receive; release the one before it now.
        entry.inboxWaiter?.(null);
        entry.inboxWaiter = undefined;

        const queued = entry.queue.shift();
        if (queued) return Promise.resolve(deliver(entry, queued));
        if (entry.ended || waitMs <= 0 || signal?.aborted) return Promise.resolve(null);

        return new Promise((resolve) => {
            const finish = (message: DesktopInboxMessage | null): void => {
                clearTimeout(timer);
                signal?.removeEventListener('abort', onAbort);
                if (entry.inboxWaiter === finish) entry.inboxWaiter = undefined;
                resolve(message);
            };
            const onAbort = (): void => finish(null);
            const timer = setTimeout(() => finish(null), Math.min(waitMs, DESKTOP_MAX_WAIT_MS));
            signal?.addEventListener('abort', onAbort, { once: true });
            entry.inboxWaiter = finish;
        });
    };

    /** Queues a phone message, or hands it straight to a waiting hook. */
    const enqueue = (claudeSessionId: string, message: DesktopInboxMessage): number | undefined => {
        const entry = entries.get(claudeSessionId);
        if (!entry) return undefined;
        // A waiter only exists while the queue is empty.
        const waiter = entry.inboxWaiter;
        if (waiter) {
            entry.inboxWaiter = undefined;
            waiter(deliver(entry, message));
            return 0;
        }
        entry.queue.push(message);
        return entry.queue.length;
    };

    /**
     * Events after `after`, waiting up to `waitMs` for the next one when there
     * are none yet. `seq` is the newest seq the caller has now seen.
     */
    const readEvents = async (claudeSessionId: string, after: number, waitMs: number, signal?: AbortSignal): Promise<{ seq: number; events: DesktopEvent[] } | undefined> => {
        const entry = entries.get(claudeSessionId);
        if (!entry) return undefined;

        if (entry.seq <= after && waitMs > 0 && !signal?.aborted) {
            await new Promise<void>((resolve) => {
                const finish = (): void => {
                    clearTimeout(timer);
                    signal?.removeEventListener('abort', finish);
                    entry.eventWaiters.delete(finish);
                    resolve();
                };
                const timer = setTimeout(finish, Math.min(waitMs, DESKTOP_MAX_WAIT_MS));
                signal?.addEventListener('abort', finish, { once: true });
                entry.eventWaiters.add(finish);
            });
        }

        const fresh = entry.events.filter((event) => event.seq > after);
        return {
            seq: entry.seq,
            events: fresh.map(({ type, localId }) => (localId === undefined ? { type } : { type, localId })),
        };
    };

    /**
     * Resolves once `claudeSessionId` is adopted and its attach process has
     * reported a Happy session id, or with an error after `timeoutMs`.
     */
    const waitForAdoption = (claudeSessionId: string, timeoutMs: number): Promise<DesktopAdoptResult> => {
        const entry = entries.get(claudeSessionId);
        if (entry?.happySessionId && !entry.ended) {
            return Promise.resolve({ type: 'success', happySessionId: entry.happySessionId });
        }
        return new Promise((resolve) => {
            const waiters = pendingAdoptions.get(claudeSessionId) ?? new Set();
            pendingAdoptions.set(claudeSessionId, waiters);
            const finish = (result: DesktopAdoptResult): void => {
                clearTimeout(timer);
                waiters.delete(finish);
                if (waiters.size === 0 && pendingAdoptions.get(claudeSessionId) === waiters) pendingAdoptions.delete(claudeSessionId);
                resolve(result);
            };
            const timer = setTimeout(() => finish({
                type: 'error',
                errorMessage: `Claude Desktop did not open session ${claudeSessionId} within ${Math.round(timeoutMs / 1000)} seconds. Check that the desktop app is running and Happy's plugin is installed.`,
            }), timeoutMs);
            waiters.add(finish);
        });
    };

    /** The attach process exited: the next SessionStart must spawn a new one. */
    const attachExited = (attachPid: number): void => {
        for (const entry of new Set(entries.values())) {
            if (entry.attachPid !== attachPid || entry.ended) continue;
            logger.debug(`[DESKTOP HUB] Attach PID ${attachPid} for ${entry.claudeSessionId} exited`);
            entry.ended = true;
            entry.inboxWaiter?.(null);
            entry.inboxWaiter = undefined;
            emit(entry, { type: 'ended' });
        }
    };

    const get = (claudeSessionId: string): DesktopSessionSnapshot | undefined => {
        const entry = entries.get(claudeSessionId);
        if (!entry) return undefined;
        return {
            claudeSessionId: entry.claudeSessionId,
            happySessionId: entry.happySessionId,
            pid: entry.pid,
            cwd: entry.cwd,
            transcriptPath: entry.transcriptPath,
            attachPid: entry.attachPid,
            ended: entry.ended,
        };
    };

    return { adopt, report, waitForInbox, enqueue, readEvents, waitForAdoption, attachExited, get };
}

export type DesktopCommandResult = { exitCode: number | null; output: string };
/** Runs a command to completion. Injected so tests can use real fake scripts. */
export type DesktopCommandRunner = (command: string, args: string[], options: { cwd: string; env: NodeJS.ProcessEnv }) => Promise<DesktopCommandResult>;

/** Default runner: spawns the command and collects the tail of its output. */
export const runDesktopCommand: DesktopCommandRunner = (command, args, { cwd, env }) => new Promise((resolve) => {
    let output = '';
    const child = spawn(command, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    const collect = (chunk: Buffer): void => {
        output = (output + chunk.toString()).slice(-4000);
    };
    child.stdout.on('data', collect);
    child.stderr.on('data', collect);
    child.on('error', (error) => resolve({ exitCode: null, output: `${output}${error.message}` }));
    child.on('close', (code) => resolve({ exitCode: code, output }));
});

/**
 * Phone-started desktop session (contract "Phone-started session"): seed a
 * session file with `/cost` (no model call), open it in Claude Desktop with
 * `--desktop --resume`, then wait for the desktop's SessionStart to adopt it.
 *
 * `claudeCommand` is the argv prefix that runs Claude Code (the daemon uses
 * the same launcher as local mode). `ttyWrapper` is the argv prefix that gives
 * `--desktop` the TTY it insists on (`script -q /dev/null` on macOS).
 */
export async function startDesktopSessionFromPhone({
    hub,
    directory,
    claudeCommand,
    ttyWrapper,
    env,
    runCommand,
    adoptTimeoutMs = DESKTOP_PHONE_ADOPT_TIMEOUT_MS,
}: {
    hub: DesktopHub;
    directory: string;
    claudeCommand: string[];
    ttyWrapper: string[];
    env: NodeJS.ProcessEnv;
    runCommand: DesktopCommandRunner;
    adoptTimeoutMs?: number;
}): Promise<DesktopAdoptResult> {
    const claudeSessionId = randomUUID();
    logger.debug(`[DESKTOP HUB] Phone-started desktop session ${claudeSessionId} in ${directory}`);

    // The seed is a Claude that Happy spawns, so it carries HAPPY_MANAGED and
    // the plugin ignores it.
    const [claudeBin, ...claudePrefix] = claudeCommand;
    const seed = await runCommand(claudeBin, [...claudePrefix, '-p', '--session-id', claudeSessionId, '/cost'], {
        cwd: directory,
        env: { ...env, HAPPY_MANAGED: '1' },
    });
    if (seed.exitCode !== 0) {
        return { type: 'error', errorMessage: `Could not create the Claude session (exit ${seed.exitCode}): ${seed.output.trim()}` };
    }

    // Register before launching so a fast SessionStart cannot be missed.
    const adopted = hub.waitForAdoption(claudeSessionId, adoptTimeoutMs);

    // The desktop runs its own Claude for this, which must NOT be marked as
    // Happy-managed, or the plugin would refuse to adopt it.
    const { HAPPY_MANAGED: _managed, ...desktopEnv } = env;
    const [launchBin, ...launchArgs] = [...ttyWrapper, ...claudeCommand, '--desktop', '--resume', claudeSessionId];
    const launchFailed = runCommand(launchBin, launchArgs, { cwd: directory, env: desktopEnv })
        .then((launch): DesktopAdoptResult | Promise<never> => {
            // A clean exit only means the desktop was asked; keep waiting for adopt.
            if (launch.exitCode === 0) return new Promise<never>(() => {});
            return { type: 'error', errorMessage: `Could not open the session in Claude Desktop (exit ${launch.exitCode}): ${launch.output.trim()}` };
        });

    return Promise.race([adopted, launchFailed]);
}
