/**
 * `happy attach`: mirror a Claude session that the Claude desktop app owns.
 *
 * The desktop runs its own Claude process; Happy never spawns one here. The
 * daemon starts this process from the happy plugin's SessionStart hook
 * (`POST /desktop/adopt`), and it:
 * - creates a Happy session (flavor 'claude', harness 'claude-desktop') and
 *   reports it to the daemon like any other session;
 * - mirrors the desktop's transcript to it with the session scanner, dropping
 *   the rewake echoes of phone messages (see desktopEcho.ts);
 * - hands phone messages to the daemon (`POST /desktop/enqueue`), whose inbox
 *   the plugin's Stop / SessionStart hook delivers into the desktop session;
 * - follows busy / idle from `GET /desktop/events/:claudeSessionId` for the
 *   thinking indicator;
 * - archives the session and exits on `ended`, or when the desktop's Claude
 *   process (`--host-pid`) is gone.
 *
 * It registers no abort / mode switch / permission / goal handlers: the desktop
 * owns the turn, and Happy cannot stop or steer it. Archiving from the phone
 * (killSession) stops the mirror only.
 *
 * The daemon route contract is in docs/plans/happyify-desktop-sync.md.
 */

import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { z } from 'zod';

import { ApiClient } from '@/api/api';
import type { Metadata } from '@/api/types';
import { encodeBase64 } from '@/api/encryption';
import { configuration } from '@/configuration';
import { notifyDaemonSessionStarted } from '@/daemon/controlClient';
import { initialMachineMetadata } from '@/daemon/run';
import { Credentials, readDaemonState, readSettings } from '@/persistence';
import { logger } from '@/ui/logger';
import { connectionState } from '@/utils/serverConnectionErrors';
import { createSessionScanner } from '@/claude/utils/sessionScanner';
import { createDesktopEchoMatcher } from '@/claude/utils/desktopEcho';
import { getProjectPath } from '@/claude/utils/path';
import { registerKillSessionHandler } from './registerKillSessionHandler';
import { projectPath } from '../projectPath';
import packageJson from '../../package.json';

export interface DesktopAttachOptions {
    claudeSessionId: string;
    transcriptPath: string;
    cwd: string;
    /** PID of the desktop's Claude process. */
    hostPid: number;
}

const DesktopEventSchema = z.object({
    type: z.enum(['busy', 'idle', 'ended', 'delivered']),
    localId: z.string().optional(),
    /**
     * Not in the wave 1 contract. When the daemon re-points this mirror to a
     * new Claude session id (/clear, fork) it can say so here; attach then
     * follows the new transcript.
     */
    claudeSessionId: z.string().optional(),
});
export type DesktopEvent = z.infer<typeof DesktopEventSchema>;

const DesktopEventsResponseSchema = z.object({
    seq: z.number(),
    events: z.array(DesktopEventSchema),
});

const EnqueueResponseSchema = z.object({ queued: z.number() });

export type DesktopStatus = {
    /** Drives keepAlive(thinking, 'local'). */
    thinking: boolean;
    ended: boolean;
};

/**
 * Fold daemon events into the mirror's status. `delivered` counts as busy: a
 * rewake turn starts without a UserPromptSubmit, so no `busy` precedes it.
 */
export function reduceDesktopEvents(status: DesktopStatus, events: DesktopEvent[]): DesktopStatus {
    return events.reduce<DesktopStatus>((current, event) => {
        switch (event.type) {
            case 'busy':
            case 'delivered':
                return { ...current, thinking: true };
            case 'idle':
                return { ...current, thinking: false };
            case 'ended':
                return { thinking: false, ended: true };
        }
    }, status);
}

const EVENTS_WAIT_MS = 25_000;
const KEEP_ALIVE_INTERVAL_MS = 2_000;
const HOST_PID_POLL_MS = 2_000;
const DAEMON_RETRY_MS = 3_000;

/** One request to the daemon's control server, which listens on 127.0.0.1:httpPort. Throws on failure. */
async function daemonRequest(method: 'GET' | 'POST', path: string, timeoutMs: number, body?: unknown): Promise<{ status: number; json: unknown }> {
    const state = await readDaemonState();
    if (!state?.httpPort) {
        throw new Error('No daemon running, no state file found');
    }
    const response = await fetch(`http://127.0.0.1:${state.httpPort}${path}`, {
        method,
        headers: body === undefined ? undefined : { 'Content-Type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) {
        throw new Error(`${method} ${path}: HTTP ${response.status}`);
    }
    return { status: response.status, json: response.status === 204 ? null : await response.json() };
}

function isPidAlive(pid: number): boolean {
    try {
        process.kill(pid, 0);
        return true;
    } catch (error) {
        // EPERM: the process exists but belongs to someone else.
        return (error as NodeJS.ErrnoException).code === 'EPERM';
    }
}

export async function runClaudeDesktopAttach(credentials: Credentials, options: DesktopAttachOptions): Promise<void> {
    const cwd = resolve(options.cwd);
    logger.debug(`[ATTACH] Mirroring Claude desktop session ${options.claudeSessionId} (cwd ${cwd}, host pid ${options.hostPid})`);

    // The scanner reads <projects>/<project id>/<session id>.jsonl, derived
    // from the cwd. A transcript anywhere else could never be mirrored.
    const projectDir = getProjectPath(cwd);
    if (resolve(dirname(options.transcriptPath)) !== projectDir) {
        throw new Error(`Transcript ${options.transcriptPath} is not in ${projectDir}, the project directory for ${cwd}`);
    }
    if (!isPidAlive(options.hostPid)) {
        throw new Error(`Claude desktop process ${options.hostPid} is not running`);
    }

    connectionState.setBackend('Claude');
    const api = await ApiClient.create(credentials);

    const settings = await readSettings();
    const machineId = settings?.machineId;
    if (!machineId) {
        throw new Error('No machine ID found in settings; run `happy auth` first');
    }
    await api.getOrCreateMachine({ machineId, metadata: initialMachineMetadata });

    const metadata: Metadata = {
        path: cwd,
        host: os.hostname(),
        version: packageJson.version,
        os: os.platform(),
        machineId,
        homeDir: os.homedir(),
        happyHomeDir: configuration.happyHomeDir,
        happyLibDir: projectPath(),
        happyToolsDir: resolve(projectPath(), 'tools', 'unpacked'),
        startedFromDaemon: true,
        // The daemon tracks sessions by the PID that reports them, so this is
        // the attach process, not the desktop's Claude.
        hostPid: process.pid,
        startedBy: 'daemon',
        lifecycleState: 'running',
        lifecycleStateSince: Date.now(),
        flavor: 'claude',
        harness: 'claude-desktop',
        claudeSessionId: options.claudeSessionId,
    };

    const response = await api.getOrCreateSession({ tag: randomUUID(), metadata, state: { controlledByUser: false } });
    if (!response) {
        // No offline mode: without the server there is nothing to mirror to.
        throw new Error('Happy server unreachable, cannot create the mirror session');
    }
    logger.debug(`[ATTACH] Session created: ${response.id}`);

    const reported = await notifyDaemonSessionStarted(response.id, metadata, {
        encryptionKey: encodeBase64(response.encryptionKey),
        encryptionVariant: response.encryptionVariant,
        seq: response.seq,
        metadataVersion: response.metadataVersion,
        agentStateVersion: response.agentStateVersion,
    });
    if (reported?.error) {
        logger.debug('[ATTACH] Failed to report session to daemon:', reported.error);
    }

    const session = api.sessionSyncClient(response);
    session.updateAgentState((current) => ({ ...current, controlledByUser: false }));

    let claudeSessionId = options.claudeSessionId;
    let status: DesktopStatus = { thinking: false, ended: false };
    let stopping = false;

    // Heartbeat, same cadence as a Happy-owned Claude session. Mode is
    // 'local': the turn is driven from the desktop, not from Happy.
    session.keepAlive(status.thinking, 'local');
    const keepAliveInterval = setInterval(() => session.keepAlive(status.thinking, 'local'), KEEP_ALIVE_INTERVAL_MS);

    // Mirror the transcript. The scanner starts with no session and is then
    // pointed at the desktop's, so the existing history is sent to the fresh
    // Happy session as well as everything written from now on.
    const echoes = createDesktopEchoMatcher();
    let sendChain = Promise.resolve();
    const scanner = await createSessionScanner({
        sessionId: null,
        workingDirectory: cwd,
        onMessage: (message) => {
            // Same as the local launcher: Happy generates its own summaries.
            if (message.type === 'summary') return;
            const decision = echoes.classify(message);
            if (decision.kind === 'echo') {
                logger.debug(`[ATTACH] Transcript echo of phone message ${decision.localId}, not forwarded`);
                return;
            }
            const toSend = decision.kind === 'foreign' ? decision.message : message;
            sendChain = sendChain.then(async () => {
                try {
                    await session.sendClaudeSessionMessageFromLocalTranscript(toSend);
                } catch (error) {
                    logger.debug('[ATTACH] Failed to send transcript message', error);
                }
            });
        },
    });
    await scanner.onNewSession(claudeSessionId);

    // Phone → desktop. The daemon queues the message until the plugin's
    // rewake hook takes it; the echo matcher drops it when it comes back.
    session.onUserMessage(async (message) => {
        const localId = message.localKey ?? randomUUID();
        const text = message.content.text;
        echoes.expect(localId, text);
        try {
            const result = await daemonRequest('POST', '/desktop/enqueue', 10_000, { claudeSessionId, localId, text });
            const { queued } = EnqueueResponseSchema.parse(result.json);
            logger.debug(`[ATTACH] Enqueued phone message ${localId} (${queued} queued, desktop ${status.thinking ? 'busy' : 'idle'})`);
        } catch (error) {
            echoes.forget(localId);
            logger.debug('[ATTACH] Failed to enqueue phone message', error);
            session.sendSessionEvent({
                type: 'message',
                message: `Could not hand this message to Claude desktop: ${error instanceof Error ? error.message : String(error)}`,
            });
        }
    });

    let hostPidInterval: ReturnType<typeof setInterval> | null = null;
    const cleanup = async (opts: { archive: boolean; reason: string }) => {
        if (stopping) return;
        stopping = true;
        logger.debug(`[ATTACH] Cleaning up (archive=${opts.archive}): ${opts.reason}`);
        clearInterval(keepAliveInterval);
        if (hostPidInterval) clearInterval(hostPidInterval);
        try {
            if (opts.archive) {
                session.updateMetadata((current) => ({
                    ...current,
                    lifecycleState: 'archived',
                    lifecycleStateSince: Date.now(),
                    archivedBy: 'cli',
                    archiveReason: opts.reason,
                }));
            }
            session.sendSessionDeath();
            try {
                await api.deactivateSession(session.sessionId);
            } catch (error) {
                logger.debug('[ATTACH] deactivateSession during cleanup failed:', error);
            }
            await scanner.cleanup();
            await sendChain;
            await session.flush();
            await session.close();
            logger.debug('[ATTACH] Cleanup complete, exiting');
            process.exit(0);
        } catch (error) {
            logger.debug('[ATTACH] Error during cleanup:', error);
            process.exit(1);
        }
    };

    // Daemon stop / Ctrl-C: leave the session resumable, as runClaude does.
    process.on('SIGTERM', () => { void cleanup({ archive: false, reason: 'SIGTERM' }); });
    process.on('SIGINT', () => { void cleanup({ archive: false, reason: 'SIGINT' }); });
    process.on('uncaughtException', (error) => {
        logger.debug('[ATTACH] Uncaught exception:', error);
        void cleanup({ archive: true, reason: 'Mirror crashed' });
    });
    process.on('unhandledRejection', (reason) => {
        logger.debug('[ATTACH] Unhandled rejection:', reason);
        void cleanup({ archive: true, reason: 'Mirror crashed' });
    });
    session.on('archived', () => { void cleanup({ archive: false, reason: 'Archived from the app' }); });
    // Archive from the app stops the mirror. The desktop session is not touched.
    registerKillSessionHandler(session.rpcHandlerManager, () => cleanup({ archive: true, reason: 'User terminated' }));

    hostPidInterval = setInterval(() => {
        if (!isPidAlive(options.hostPid)) {
            void cleanup({ archive: true, reason: 'Claude desktop process exited' });
        }
    }, HOST_PID_POLL_MS);

    logger.infoDeveloper(`Session: ${response.id}`);
    logger.infoDeveloper(`Logs: ${logger.logFilePath}`);

    // Desktop status from the daemon, long-polled until the session ends.
    let after = 0;
    while (!stopping) {
        try {
            const result = await daemonRequest(
                'GET',
                `/desktop/events/${encodeURIComponent(claudeSessionId)}?after=${after}&wait=${EVENTS_WAIT_MS}`,
                EVENTS_WAIT_MS + 10_000,
            );
            const { seq, events } = DesktopEventsResponseSchema.parse(result.json);
            after = seq;
            for (const event of events) {
                if (event.claudeSessionId && event.claudeSessionId !== claudeSessionId) {
                    logger.debug(`[ATTACH] Claude session id changed: ${claudeSessionId} -> ${event.claudeSessionId}`);
                    claudeSessionId = event.claudeSessionId;
                    session.updateMetadata((current) => ({ ...current, claudeSessionId: event.claudeSessionId }));
                    await scanner.onNewSession(claudeSessionId);
                }
                if (event.type === 'delivered') {
                    logger.debug(`[ATTACH] Phone message ${event.localId ?? '(no localId)'} delivered to the desktop`);
                }
            }
            const next = reduceDesktopEvents(status, events);
            if (next.thinking !== status.thinking) {
                session.keepAlive(next.thinking, 'local');
            }
            status = next;
            if (status.ended) {
                await cleanup({ archive: true, reason: 'Claude desktop session ended' });
            }
        } catch (error) {
            if (stopping) break;
            logger.debug('[ATTACH] Desktop events poll failed, retrying:', error);
            await new Promise((resolveDelay) => setTimeout(resolveDelay, DAEMON_RETRY_MS));
        }
    }
}
