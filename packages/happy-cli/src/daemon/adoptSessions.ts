/**
 * Re-adopting live sessions after a daemon restart.
 *
 * A daemon restart (a CLI rebuild trips "version mismatch, restarting") used
 * to leave the new daemon tracking nothing: sessions spawned by the old daemon
 * run detached and survive it, but stop, restart and the session list could no
 * longer reach them. `sessions.json` still names each one's host PID, so the
 * new daemon re-adopts those that are provably the same process:
 *
 * - the record was written during this boot (PIDs are reused across boots);
 * - the PID is alive;
 * - the process started before the record was written (a process that started
 *   later merely inherited a reused PID);
 * - its command line is a Happy session of the recorded flavor, not some other
 *   process and not the daemon or a one-shot command;
 * - any session id it was launched for (`--happy-session`, or
 *   `HAPPY_RECONNECT_SESSION_ID` in its environment) is the recorded session.
 *
 * Anything that cannot be verified is left alone: a saved PID is never
 * authority to signal a process. Such sessions still re-register themselves
 * once they notice the new daemon (see `controlClient.ts`).
 */

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { decodeBase64 } from '@/api/encryption';
import type { PersistedSession } from '@/persistence';
import { logger } from '@/ui/logger';
import { isPidAlive } from './sessionLiveness';
import type { TrackedSession } from './types';

export const ADOPTED_SESSION_STARTED_BY = 'adopted after daemon restart';

/** Clock granularity (/proc ticks, `ps` whole seconds) plus clock-skew allowance. */
const START_TIME_SLACK_MS = 2_000;

/** Entry points a Happy session process runs from. */
const HAPPY_ENTRY_PATTERN = /(?:^|[\\/])(?:dist[\\/]index\.mjs|bin[\\/]happy\.mjs|happy)$/;

export type ProcessInfo = {
    argv: string[];
    /** Wall-clock start time, or null when it cannot be read. */
    startTimeMs: number | null;
    /** The process environment, or null when it cannot be read. */
    env: Record<string, string> | null;
    /** The process group id, or null when it cannot be read. */
    processGroupId: number | null;
};

export type AdoptionDeps = {
    isAlive: (pid: number) => boolean;
    readProcess: (pid: number) => ProcessInfo | null;
};

let clockTicksPerSecond: number | null = null;

function linuxClockTicks(): number {
    if (clockTicksPerSecond === null) {
        try {
            const ticks = parseInt(execFileSync('getconf', ['CLK_TCK'], { encoding: 'utf-8', timeout: 2_000 }).trim(), 10);
            clockTicksPerSecond = ticks > 0 ? ticks : 100;
        } catch {
            clockTicksPerSecond = 100;
        }
    }
    return clockTicksPerSecond;
}

function readLinuxProcess(pid: number): ProcessInfo | null {
    let argv: string[];
    try {
        argv = readFileSync(`/proc/${pid}/cmdline`, 'utf-8').split('\0').filter((part) => part.length > 0);
    } catch {
        return null;
    }

    let startTimeMs: number | null = null;
    let processGroupId: number | null = null;
    try {
        const stat = readFileSync(`/proc/${pid}/stat`, 'utf-8');
        // The command name (field 2) may contain spaces and parentheses, so
        // count fields from the last ')'. Field 3 is fields[0] below.
        const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
        const startTicks = Number(fields[19]);
        const bootLine = readFileSync('/proc/stat', 'utf-8').split('\n').find((line) => line.startsWith('btime '));
        const bootSeconds = bootLine ? Number(bootLine.slice(6)) : NaN;
        if (Number.isFinite(startTicks) && Number.isFinite(bootSeconds)) {
            startTimeMs = bootSeconds * 1000 + (startTicks / linuxClockTicks()) * 1000;
        }
        const pgrp = Number(fields[2]);
        processGroupId = Number.isSafeInteger(pgrp) && pgrp > 0 ? pgrp : null;
    } catch {
        // Leave start time unknown: adoption then refuses the process.
    }

    let env: Record<string, string> | null = null;
    try {
        env = {};
        for (const entry of readFileSync(`/proc/${pid}/environ`, 'utf-8').split('\0')) {
            const eq = entry.indexOf('=');
            if (eq > 0) env[entry.slice(0, eq)] = entry.slice(eq + 1);
        }
    } catch {
        env = null;
    }

    return { argv, startTimeMs, env, processGroupId };
}

function readPsProcess(pid: number): ProcessInfo | null {
    try {
        const header = execFileSync('ps', ['-o', 'pgid=', '-o', 'lstart=', '-p', String(pid)], { encoding: 'utf-8', timeout: 2_000 }).trim();
        const command = execFileSync('ps', ['-ww', '-o', 'command=', '-p', String(pid)], { encoding: 'utf-8', timeout: 2_000 }).trim();
        if (!header || !command) return null;
        const match = /^(\d+)\s+(.+)$/.exec(header);
        const startTimeMs = match ? Date.parse(match[2]) : NaN;
        return {
            argv: command.split(/\s+/),
            startTimeMs: Number.isFinite(startTimeMs) ? startTimeMs : null,
            env: null,
            processGroupId: match ? Number(match[1]) : null,
        };
    } catch {
        return null;
    }
}

/** What the OS says about a running process, or null when it is unknown or unreadable. */
export function readProcessInfo(pid: number): ProcessInfo | null {
    if (process.platform === 'linux') return readLinuxProcess(pid);
    if (process.platform === 'darwin') return readPsProcess(pid);
    return null;
}

/**
 * Why this process cannot be the recorded session's owner, or null when it is.
 * Exported for tests.
 */
export function processMismatch(sessionId: string, session: PersistedSession, info: ProcessInfo): string | null {
    if (info.startTimeMs === null) return 'process start time unknown';
    if (info.startTimeMs > session.savedAt + START_TIME_SLACK_MS) return 'process started after the record was written (PID reused)';

    const entryIndex = info.argv.findIndex((arg) => HAPPY_ENTRY_PATTERN.test(arg));
    if (entryIndex < 0) return 'not a Happy process';
    const subcommand = info.argv[entryIndex + 1] as string | undefined;

    const flavor = session.metadata?.flavor ?? 'claude';
    const flavorMatches = flavor === 'claude'
        ? subcommand === undefined || subcommand === 'claude' || subcommand.startsWith('-')
        : subcommand === flavor || subcommand === 'acp';
    if (!flavorMatches) return `command '${subcommand ?? ''}' is not a ${flavor} session`;

    const flagIndex = info.argv.indexOf('--happy-session', entryIndex);
    if (flagIndex >= 0 && info.argv[flagIndex + 1] !== sessionId) return 'launched for a different session';
    const reconnectId = info.env?.HAPPY_RECONNECT_SESSION_ID;
    if (reconnectId && reconnectId !== sessionId) return 'reconnected to a different session';

    return null;
}

/**
 * Sessions from `sessions.json` whose host process is verifiably still
 * running, ready to be tracked by a freshly started daemon. When several
 * records name the same live PID, the most recently written one wins.
 */
export function adoptLiveSessions(
    persisted: Record<string, PersistedSession>,
    bootTimeMs: number,
    deps: AdoptionDeps = { isAlive: (pid) => isPidAlive(pid), readProcess: readProcessInfo },
): TrackedSession[] {
    const byPid = new Map<number, { session: PersistedSession; tracked: TrackedSession }>();

    for (const [sessionId, session] of Object.entries(persisted)) {
        const pid = session.metadata?.hostPid;
        if (!Number.isSafeInteger(pid) || pid! <= 0 || pid === process.pid) continue;
        if (session.savedAt < bootTimeMs) continue;
        if (!deps.isAlive(pid!)) continue;

        const info = deps.readProcess(pid!);
        const reason = info ? processMismatch(sessionId, session, info) : 'process unreadable';
        if (reason) {
            logger.debug(`[DAEMON RUN] Not adopting session ${sessionId} (PID ${pid}): ${reason}`);
            continue;
        }

        const previous = byPid.get(pid!);
        if (previous && previous.session.savedAt >= session.savedAt) continue;

        byPid.set(pid!, {
            session,
            tracked: {
                startedBy: ADOPTED_SESSION_STARTED_BY,
                happySessionId: sessionId,
                happySessionMetadataFromLocalWebhook: session.metadata,
                encryption: {
                    encryptionKey: decodeBase64(session.encryptionKey),
                    encryptionVariant: session.encryptionVariant,
                    seq: session.seq,
                    metadataVersion: session.metadataVersion,
                    agentStateVersion: session.agentStateVersion,
                },
                pid: pid!,
                ownsProcessGroup: info!.processGroupId === pid,
            },
        });
    }

    const adopted = Array.from(byPid.values(), (entry) => entry.tracked);
    for (const session of adopted) {
        logger.debug(`[DAEMON RUN] Adopted live session ${session.happySessionId} (PID ${session.pid})`);
    }
    return adopted;
}
