/**
 * `happy opencode` in a terminal: the real OpenCode TUI, mirrored to the app.
 *
 * Happy starts one `opencode serve` (127.0.0.1, random port, per-run
 * password) and runs `opencode attach` against it in the user's terminal.
 * Everything that happens in the OpenCode session, whoever caused it, is
 * read from the server's event stream and mirrored to the Happy session;
 * prompts and permission answers from the app are posted to the same
 * server, so the TUI shows them live.
 *
 * Lifetimes:
 * - Quitting the TUI ends the session (server stopped, session inactive but
 *   resumable from the app, like `happy claude` after Ctrl-C).
 * - Closing the terminal (SIGHUP / logout) only takes the TUI with it. This
 *   process ignores the hangup, the server is in its own process group, and
 *   the session keeps running for the app. `happy opencode --resume <id>`
 *   attaches a new TUI to it.
 * - Archiving from the app (killSession) or SIGTERM ends it from anywhere.
 * - `happy opencode --resume <id>` with no owner running continues the
 *   OpenCode session and the same Happy chat (see opencodeHappySession).
 * - `happy opencode --resume <id> --restart` replaces the owner (and its
 *   server) with one on the installed CLI, detached and headless, keeping
 *   both; in a terminal it then attaches a TUI.
 */

import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { isatty } from 'node:tty';
import { ApiClient } from '@/api/api';
import type { ApiSessionClient } from '@/api/apiSession';
import { configuration } from '@/configuration';
import { registerKillSessionHandler } from '@/claude/registerKillSessionHandler';
import { startHappyServer } from '@/claude/utils/startHappyServer';
import { notifyDaemonSessionStarted } from '@/daemon/controlClient';
import { initialMachineMetadata } from '@/daemon/run';
import { decodeBase64, encodeBase64 } from '@/api/encryption';
import { mergeAcpSessionConfigIntoMetadata } from '@/agent/acp/sessionConfigMetadata';
import { Credentials, readPersistedSessions, readSettings } from '@/persistence';
import type { Session } from '@/api/types';
import { logger } from '@/ui/logger';
import { createSessionMetadata } from '@/utils/createSessionMetadata';
import { setupOfflineReconnection } from '@/utils/setupOfflineReconnection';
import { spawnHappyCLI } from '@/utils/spawnHappyCLI';
import { sanitizeSessionEnvironment } from '@/daemon/sessionEnvironment';
import { connectionState } from '@/utils/serverConnectionErrors';
import { createOpencodeMessageId, OpencodeClient, type OpencodeSessionInfo } from './opencodeClient';
import { OpencodeEventMapper, type OpencodeMirrorAction } from './opencodeEventMapper';
import { OpencodePermissionBridge } from './opencodePermissionBridge';
import { OpencodePermissionRouter } from './opencodePermissionPolicy';
import {
    attachOpencodeTui,
    classifyTuiExit,
    findLiveOwner,
    isProcessAlive,
    looksLikeOpencodeServe,
    processCommandLine,
    readTuiState,
    reapOrphanedServers,
    removeTuiState,
    startOpencodeServer,
    writeTuiState,
    type OpencodeServerHandle,
    type OpencodeTuiState,
    type ProcessExit,
} from './opencodeProcesses';
import {
    fetchServerSessions,
    findReconnectableHappySession,
    linkedHappySessionId,
    rememberHappySession,
} from './opencodeHappySession';
import { buildOpencodePickers, opencodePromptOptions, parseOpencodeMode, type OpencodePermissionPolicy } from './opencodeSessionConfig';

/**
 * Sent by a restart to an owner that records it in its state file: stop
 * like SIGTERM, but leave the Happy session active for the new owner.
 * Older owners do not handle it and get SIGTERM instead.
 */
const RESTART_SIGNAL = 'SIGUSR2';

/** How often streamed text is checked for finished paragraphs to forward. */
const STREAM_FLUSH_MS = 1000;

/** How long to wait after the TUI exits for a SIGHUP that explains it. */
const HANGUP_SETTLE_MS = 300;

export function opencodeTuiStateDir(): string {
    return join(configuration.happyHomeDir, 'opencode-tui');
}

/**
 * From the first SIGHUP on, the terminal is gone: stop treating SIGHUP as
 * fatal and make writes to the dead terminal harmless (they fail with EIO).
 */
function installHangupGuard(onHangup: () => void): { hungUp: () => boolean; dispose: () => void } {
    let hungUp = false;
    const ignore = () => { };
    const handler = () => {
        if (hungUp) {
            return;
        }
        hungUp = true;
        process.stdout.on('error', ignore);
        process.stderr.on('error', ignore);
        logger.debug('[OpenCode] Terminal hung up; the session keeps running for the app');
        onHangup();
    };
    process.on('SIGHUP', handler);
    return {
        hungUp: () => hungUp,
        dispose: () => process.off('SIGHUP', handler),
    };
}

async function runTuiUntilExit(opts: {
    bin: string;
    url: string;
    password: string;
    cwd: string;
    sessionId: string;
    hungUp: () => boolean;
    /** Receives a way to close the TUI when the session ends from elsewhere. */
    onStarted?: (close: () => void) => void;
}): Promise<'hangup' | 'quit'> {
    // The TUI owns the terminal while it runs; Ctrl-C belongs to it.
    const ignoreInterrupt = () => { };
    process.on('SIGINT', ignoreInterrupt);
    let exit: ProcessExit;
    try {
        const tui = attachOpencodeTui(opts);
        opts.onStarted?.(() => {
            if (tui.pid !== undefined) {
                try {
                    process.kill(tui.pid, 'SIGTERM');
                } catch {
                    // Already exited.
                }
            }
        });
        exit = await tui.exited;
    } finally {
        process.off('SIGINT', ignoreInterrupt);
    }
    // A closed terminal kills the TUI and signals us at about the same time.
    await new Promise((resolve) => setTimeout(resolve, HANGUP_SETTLE_MS));
    const outcome = classifyTuiExit({
        exit,
        hangupReceived: opts.hungUp(),
        stdinIsTTY: isatty(0),
        stdoutIsTTY: isatty(1),
    });
    logger.debug(`[OpenCode] TUI exited (code ${exit.code}, signal ${exit.signal}): ${outcome}`);
    return outcome;
}

/**
 * `happy opencode --resume <id>` while another `happy opencode` still runs
 * that session (typically after its terminal was closed): open a TUI on the
 * same server. Quitting it ends the session unless the owner still has its
 * own TUI open.
 */
async function attachToRunningSession(bin: string, owner: OpencodeTuiState, stateDir: string): Promise<void> {
    logger.debug(`[OpenCode] Attaching to running session ${owner.opencodeSessionId} (owner ${owner.ownerPid})`);
    const guard = installHangupGuard(() => { });
    try {
        const outcome = await runTuiUntilExit({
            bin,
            url: owner.url,
            password: owner.password,
            cwd: owner.cwd,
            sessionId: owner.opencodeSessionId,
            hungUp: guard.hungUp,
        });
        if (outcome !== 'quit') {
            return;
        }
        // Re-check right before signalling: same owner, still alive, still ours.
        const current = findLiveOwner(stateDir, owner.opencodeSessionId);
        if (current && current.ownerPid === owner.ownerPid && !current.ownerTuiAttached) {
            process.kill(current.ownerPid, 'SIGTERM');
        }
    } finally {
        guard.dispose();
    }
}

/**
 * The Happy session to continue for an OpenCode session: the one the daemon
 * or `happy resume` handed over (HAPPY_RECONNECT_*), else the one linked to
 * it locally. Null means a new Happy session is created.
 */
async function findHappySessionToReconnect(
    credentials: Credentials,
    stateDir: string,
    opencodeSessionId: string,
    happySessionId: string | undefined,
): Promise<Session | null> {
    const env = process.env;
    if (env.HAPPY_RECONNECT_SESSION_ID && env.HAPPY_RECONNECT_ENCRYPTION_KEY && env.HAPPY_RECONNECT_ENCRYPTION_VARIANT) {
        return {
            id: env.HAPPY_RECONNECT_SESSION_ID,
            seq: parseInt(env.HAPPY_RECONNECT_SEQ || '0', 10),
            encryptionKey: decodeBase64(env.HAPPY_RECONNECT_ENCRYPTION_KEY),
            encryptionVariant: env.HAPPY_RECONNECT_ENCRYPTION_VARIANT as 'legacy' | 'dataKey',
            metadata: {} as Session['metadata'],
            metadataVersion: parseInt(env.HAPPY_RECONNECT_METADATA_VERSION || '0', 10),
            agentState: null,
            agentStateVersion: parseInt(env.HAPPY_RECONNECT_AGENT_STATE_VERSION || '0', 10),
        };
    }
    const found = findReconnectableHappySession({
        opencodeSessionId,
        linkedId: happySessionId ?? linkedHappySessionId(stateDir, opencodeSessionId),
        persisted: readPersistedSessions(),
        serverSessions: await fetchServerSessions(credentials.token),
    });
    if (!found && happySessionId) {
        throw new Error(`Happy session ${happySessionId} is not saved on this machine (${configuration.sessionsFile}), so it cannot be continued`);
    }
    if (!found) {
        logger.debug(`[OpenCode] No saved Happy session for ${opencodeSessionId}; a new one will be created`);
    }
    return found;
}

export async function runOpencodeTui(opts: {
    credentials: Credentials;
    bin: string;
    startedBy?: 'daemon' | 'terminal';
    /** OpenCode session id to continue. */
    resumeSessionId?: string;
    /** `auto` (default) approves permission requests itself; `ask` shows them in the app. */
    permissionPolicy?: OpencodePermissionPolicy;
    /** Run without a TUI of its own; `happy opencode --resume <id>` attaches one. */
    headless?: boolean;
    /** Happy session (chat) to continue on resume, instead of the one linked to it. */
    happySessionId?: string;
}): Promise<void> {
    const launchPolicy: OpencodePermissionPolicy = opts.permissionPolicy ?? 'auto';
    const stateDir = opencodeTuiStateDir();
    const reaped = reapOrphanedServers(stateDir);
    if (reaped.length > 0) {
        logger.debug(`[OpenCode] Stopped orphaned servers: ${reaped.join(', ')}`);
    }

    if (opts.resumeSessionId) {
        const owner = findLiveOwner(stateDir, opts.resumeSessionId);
        if (owner) {
            await attachToRunningSession(opts.bin, owner, stateDir);
            return;
        }
    }

    connectionState.setBackend('opencode');
    const cwd = process.cwd();
    const api = await ApiClient.create(opts.credentials);
    const settings = await readSettings();
    if (!settings?.machineId) {
        throw new Error('No machine ID found in settings');
    }
    await api.getOrCreateMachine({ machineId: settings.machineId, metadata: initialMachineMetadata });

    const { state, metadata } = createSessionMetadata({
        flavor: 'opencode',
        machineId: settings.machineId,
        startedBy: opts.startedBy,
        sandbox: settings.sandboxConfig,
    });
    if (opts.resumeSessionId) {
        metadata.opencodeSessionId = opts.resumeSessionId;
    }
    const sessionTag = randomUUID();
    // Resuming continues the same Happy chat when its key is saved here.
    const existing = opts.resumeSessionId
        ? await findHappySessionToReconnect(opts.credentials, stateDir, opts.resumeSessionId, opts.happySessionId)
        : null;
    const response = existing
        ? { ...existing, metadata: { ...existing.metadata, ...metadata }, agentState: existing.agentState ?? state }
        : await api.getOrCreateSession({ tag: sessionTag, metadata, state });

    let session: ApiSessionClient;
    let permissions: OpencodePermissionBridge | null = null;
    const { session: initialSession, reconnectionHandle } = setupOfflineReconnection({
        api,
        sessionTag,
        metadata,
        state,
        response,
        onSessionSwap: (newSession) => {
            session = newSession;
            permissions?.updateSession(newSession);
        },
    });
    session = initialSession;

    if (existing) {
        logger.debug(`[OpenCode] Reconnected to Happy session ${existing.id}`);
        // Same as the daemon's resume in place: un-archive, and do not replay
        // the chat's old messages as new prompts.
        session.suppressNextArchiveSignal();
        session.skipExistingMessages();
        session.updateMetadata((current) => ({
            ...current,
            ...metadata,
            lifecycleState: 'running',
            lifecycleStateSince: Date.now(),
            archivedBy: undefined,
            archiveReason: undefined,
        }));
    }

    if (response) {
        try {
            await notifyDaemonSessionStarted(response.id, metadata, {
                encryptionKey: encodeBase64(response.encryptionKey),
                encryptionVariant: response.encryptionVariant,
                seq: response.seq,
                metadataVersion: response.metadataVersion,
                agentStateVersion: response.agentStateVersion,
            });
        } catch (error) {
            logger.debug('[OpenCode] Failed to report session to daemon:', error);
        }
    }

    const happyServer = await startHappyServer(session);
    let server: OpencodeServerHandle;
    try {
        server = await startOpencodeServer({
            bin: opts.bin,
            cwd,
            configContent: JSON.stringify({ mcp: { happy: { type: 'remote', url: happyServer.url, enabled: true } } }),
        });
    } catch (error) {
        happyServer.stop();
        reconnectionHandle?.cancel();
        session.sendSessionDeath();
        await session.flush();
        await session.close();
        throw error;
    }
    const client = new OpencodeClient({ url: server.url, password: server.password, directory: cwd });

    // The OpenCode session: the requested one if the server knows it, else a new one.
    let opencodeSession: OpencodeSessionInfo;
    let resumeNotice: string | null = null;
    if (opts.resumeSessionId) {
        try {
            opencodeSession = await client.getSession(opts.resumeSessionId);
        } catch (error) {
            logger.debug(`[OpenCode] Could not resume ${opts.resumeSessionId}:`, error);
            resumeNotice = `Could not resume OpenCode session ${opts.resumeSessionId}, so a new one was started and OpenCode will not remember the earlier conversation.`;
            opencodeSession = await client.createSession();
        }
    } else {
        opencodeSession = await client.createSession();
    }

    const mapper = new OpencodeEventMapper(opencodeSession.id);
    permissions = new OpencodePermissionBridge(session, (id, reply) => client.replyPermission(id, reply));
    permissions.reset('Previous CLI process exited before responding');
    const bridge = permissions;
    const router = new OpencodePermissionRouter(launchPolicy, {
        ask: (request) => bridge.ask(request),
        reply: (id, reply) => client.replyPermission(id, reply),
    });

    session.updateMetadata((current) => ({ ...current, opencodeSessionId: opencodeSession.id }));
    if (resumeNotice) {
        session.sendSessionEvent({ type: 'message', message: resumeNotice });
    }

    let agentNames: string[] = [];
    try {
        const [providers, agents, config] = await Promise.all([client.providers(), client.agents(), client.config()]);
        const pickers = buildOpencodePickers({ providers, agents, config, launchPolicy });
        agentNames = (pickers.modes?.availableModes ?? []).map((mode) => mode.id).filter((id) => !id.includes(':'));
        session.updateMetadata((current) => mergeAcpSessionConfigIntoMetadata(current, {
            ...(pickers.models ? { models: pickers.models } : {}),
            ...(pickers.modes ? { modes: pickers.modes } : {}),
        }));
    } catch (error) {
        logger.debug('[OpenCode] Could not read models/agents for the app pickers:', error);
    }

    let thinking = false;
    let tuiAttached = !opts.headless;
    let closeTui: () => void = () => { };
    const ownerState = (): OpencodeTuiState => ({
        ownerPid: process.pid,
        serverPid: server.pid,
        url: server.url,
        password: server.password,
        cwd,
        opencodeSessionId: mapper.sessionId,
        happySessionId: session.sessionId,
        startedAt: Date.now(),
        ownerTuiAttached: tuiAttached,
        permissionPolicy: launchPolicy,
        restartSignal: RESTART_SIGNAL,
    });
    const saveOwnerState = () => {
        writeTuiState(stateDir, ownerState());
        rememberHappySession(stateDir, mapper.sessionId, session.sessionId);
    };
    saveOwnerState();

    const sendKeepAlive = () => session.keepAlive(thinking, tuiAttached ? 'local' : 'remote');

    const apply = (action: OpencodeMirrorAction) => {
        switch (action.type) {
            case 'envelopes':
                for (const envelope of action.envelopes) {
                    session.sendSessionProtocolMessage(envelope);
                }
                break;
            case 'busy':
                thinking = true;
                sendKeepAlive();
                break;
            case 'idle':
                thinking = false;
                sendKeepAlive();
                session.sendSessionEvent({ type: 'ready' });
                break;
            case 'permission-asked':
                router.handleAsked(action);
                break;
            case 'permission-replied':
                bridge.resolveExternally(action.id, action.reply);
                break;
            case 'title':
                session.sendClaudeSessionMessage({ type: 'summary', summary: action.title, leafUuid: randomUUID() });
                break;
            case 'session-changed':
                session.updateMetadata((current) => ({ ...current, opencodeSessionId: action.sessionId }));
                saveOwnerState();
                break;
        }
    };

    // Pick up requests raised while the event stream was down.
    const syncPermissions = async () => {
        try {
            const pending = await client.listPermissions();
            for (const request of pending) {
                for (const action of mapper.handle({ type: 'permission.asked', properties: request })) {
                    apply(action);
                }
            }
        } catch (error) {
            logger.debug('[OpenCode] Could not list pending permissions:', error);
        }
    };

    const events = new AbortController();
    const streaming = client.streamEvents({
        signal: events.signal,
        onConnected: () => { void syncPermissions(); },
        onEvent: (event) => {
            const before = mapper.sessionId;
            for (const action of mapper.handle(event)) {
                apply(action);
            }
            if (mapper.sessionId !== before) {
                removeTuiState(stateDir, before, process.pid);
            }
        },
        onError: (error) => logger.debug('[OpenCode] Event stream dropped, reconnecting:', error),
    });

    session.onUserMessage((message) => {
        const text = message.content.text;
        if (!text) {
            return;
        }
        const messageId = createOpencodeMessageId();
        mapper.markOwnMessage(messageId);
        const { policy } = parseOpencodeMode(message.meta?.permissionMode, agentNames, launchPolicy);
        if (policy) {
            router.setPolicy(policy);
        }
        const options = opencodePromptOptions({
            model: message.meta?.model,
            permissionMode: message.meta?.permissionMode,
            agentNames,
            launchPolicy,
        });
        client.promptAsync(mapper.sessionId, { text, messageId, ...options }).catch((error) => {
            logger.debug('[OpenCode] Failed to send prompt:', error);
            session.sendSessionEvent({ type: 'message', message: `OpenCode error: ${error instanceof Error ? error.message : String(error)}` });
        });
    });

    session.rpcHandlerManager.registerHandler('abort', async () => {
        bridge.abortAll();
        await client.abort(mapper.sessionId).catch((error) => logger.debug('[OpenCode] Abort failed:', error));
    });

    sendKeepAlive();
    const keepAliveInterval = setInterval(sendKeepAlive, 2000);
    const streamFlushInterval = setInterval(() => {
        for (const action of mapper.flushStreamingText()) {
            apply(action);
        }
    }, STREAM_FLUSH_MS);

    // --- Shutdown ---------------------------------------------------------
    let resolveDone!: () => void;
    const done = new Promise<void>((resolve) => { resolveDone = resolve; });
    let shuttingDown = false;
    /** `handover`: a restart takes the session over, so leave it active in the app. */
    const shutdown = async (reason: string, archive: boolean, handover = false) => {
        if (shuttingDown) {
            return;
        }
        shuttingDown = true;
        logger.debug(`[OpenCode] Ending session: ${reason} (archive=${archive})`);
        closeTui();
        clearInterval(keepAliveInterval);
        clearInterval(streamFlushInterval);
        reconnectionHandle?.cancel();
        events.abort();
        try {
            for (const envelope of mapper.closeTurn('cancelled')) {
                session.sendSessionProtocolMessage(envelope);
            }
            bridge.reset(reason);
        } catch (error) {
            logger.debug('[OpenCode] Failed to close the turn:', error);
        }
        await server.stop().catch((error) => logger.debug('[OpenCode] Failed to stop opencode serve:', error));
        await streaming.catch(() => { });
        try {
            happyServer.stop();
        } catch (error) {
            logger.debug('[OpenCode] Failed to stop Happy MCP server:', error);
        }
        removeTuiState(stateDir, mapper.sessionId, process.pid);
        try {
            if (archive) {
                session.updateMetadata((current) => ({
                    ...current,
                    lifecycleState: 'archived',
                    lifecycleStateSince: Date.now(),
                    archivedBy: 'cli',
                    archiveReason: 'User terminated',
                }));
            }
            if (!handover) {
                session.sendSessionDeath();
                await api.deactivateSession(session.sessionId).catch(() => false);
            }
            await session.flush();
            await session.close();
        } catch (error) {
            logger.debug('[OpenCode] Session close failed:', error);
        }
        resolveDone();
    };

    registerKillSessionHandler(session.rpcHandlerManager, () => shutdown('archived from the app', true));
    const onTerminate = () => { void shutdown('terminated', false); };
    const onHandover = () => { void shutdown('restarting', false, true); };
    process.on('SIGTERM', onTerminate);
    process.on(RESTART_SIGNAL, onHandover);
    void server.exited.then((exit) => shutdown(`opencode serve exited (code ${exit.code}, signal ${exit.signal})`, false));

    const guard = installHangupGuard(() => {
        tuiAttached = false;
        saveOwnerState();
        sendKeepAlive();
        // With no terminal, Ctrl-C can no longer reach us; SIGINT now means "stop".
        process.on('SIGINT', onTerminate);
    });

    try {
        if (opts.headless) {
            // No TUI of its own (a restart, or no terminal): run for the app
            // until stopped. SIGINT stops it like SIGTERM.
            process.on('SIGINT', onTerminate);
            await done;
            return;
        }
        const outcome = await runTuiUntilExit({
            bin: opts.bin,
            url: server.url,
            password: server.password,
            cwd,
            sessionId: mapper.sessionId,
            hungUp: guard.hungUp,
            onStarted: (close) => { closeTui = close; },
        });
        closeTui = () => { };
        if (outcome === 'quit') {
            await shutdown('TUI closed', false);
        } else if (!guard.hungUp()) {
            // The terminal went away without a SIGHUP reaching us.
            tuiAttached = false;
            saveOwnerState();
            sendKeepAlive();
            process.on('SIGINT', onTerminate);
        }
        await done;
    } finally {
        guard.dispose();
        process.off('SIGTERM', onTerminate);
        process.off('SIGINT', onTerminate);
        process.off(RESTART_SIGNAL, onHandover);
    }
}

/** How long a restart waits for the old owner to stop, and for the new one to come up. */
const RESTART_STOP_TIMEOUT_MS = 30_000;
const RESTART_START_TIMEOUT_MS = 60_000;

async function waitFor(check: () => boolean, timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (!check()) {
        if (Date.now() >= deadline) {
            return false;
        }
        await new Promise((resolve) => setTimeout(resolve, 250));
    }
    return true;
}

/**
 * `happy opencode --resume <id> --restart`: move a session onto the CLI that
 * is installed now, keeping OpenCode's context and the same Happy chat.
 *
 * The running owner (if any) is stopped with SIGTERM, after checking its
 * recorded pid is still a `happy opencode`; it stops its own `opencode
 * serve`, so the new owner starts a fresh one with the current config
 * (permission policy, Happy MCP server). The new owner runs detached and
 * headless, so it outlives this terminal; from a terminal a TUI is attached
 * to it right away.
 */
export async function restartOpencodeSession(opts: {
    bin: string;
    opencodeSessionId: string;
    /** Defaults to the policy the running owner was started with, else `auto`. */
    permissionPolicy?: OpencodePermissionPolicy;
    happySessionId?: string;
}): Promise<void> {
    const stateDir = opencodeTuiStateDir();
    const id = opts.opencodeSessionId;
    const recorded = readTuiState(stateDir, id);
    const owner = findLiveOwner(stateDir, id);
    const policy = opts.permissionPolicy ?? owner?.permissionPolicy ?? 'auto';
    const cwd = owner?.cwd ?? recorded?.cwd ?? process.cwd();

    if (owner) {
        console.log(`Stopping the running session (pid ${owner.ownerPid})...`);
        process.kill(owner.ownerPid, owner.restartSignal === RESTART_SIGNAL ? RESTART_SIGNAL : 'SIGTERM');
        const ownerStopped = await waitFor(() => !isProcessAlive(owner.ownerPid), RESTART_STOP_TIMEOUT_MS);
        if (!ownerStopped) {
            throw new Error(`The running session (pid ${owner.ownerPid}) did not stop within ${RESTART_STOP_TIMEOUT_MS / 1000}s; nothing was restarted`);
        }
        const serverStopped = await waitFor(
            () => !(isProcessAlive(owner.serverPid) && looksLikeOpencodeServe(processCommandLine(owner.serverPid))),
            5_000,
        );
        if (!serverStopped) {
            reapOrphanedServers(stateDir);
        }
    }

    const args = ['opencode', '--resume', id, '--headless', '--permission-mode', policy];
    if (opts.happySessionId) {
        args.push('--happy-session', opts.happySessionId);
    }
    const child = spawnHappyCLI(args, {
        cwd,
        detached: true,
        stdio: 'ignore',
        env: sanitizeSessionEnvironment(process.env),
    });
    child.unref();
    const childPid = child.pid;
    if (childPid === undefined) {
        throw new Error('Could not start the new session process');
    }
    let exitedEarly = false;
    child.once('exit', () => { exitedEarly = true; });

    let next: OpencodeTuiState | null = null;
    const started = await waitFor(() => {
        next = findLiveOwner(stateDir, id);
        return exitedEarly || next?.ownerPid === childPid;
    }, RESTART_START_TIMEOUT_MS);
    const ready = next as OpencodeTuiState | null;
    if (!started || exitedEarly || !ready) {
        throw new Error(`The new session process (pid ${childPid}) did not come up; see the logs in ${configuration.logsDir}`);
    }
    console.log(`Session ${id} restarted on the installed CLI (pid ${ready.ownerPid}), same Happy session ${ready.happySessionId}.`);

    if (isatty(0) && isatty(1)) {
        await attachToRunningSession(opts.bin, ready, stateDir);
        return;
    }
    console.log(`It runs in the background for the app. Open its TUI with: happy opencode --resume ${id}`);
}
