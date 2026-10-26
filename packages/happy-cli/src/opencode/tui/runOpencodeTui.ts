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
import { encodeBase64 } from '@/api/encryption';
import { mergeAcpSessionConfigIntoMetadata } from '@/agent/acp/sessionConfigMetadata';
import { Credentials, readSettings } from '@/persistence';
import { logger } from '@/ui/logger';
import { createSessionMetadata } from '@/utils/createSessionMetadata';
import { setupOfflineReconnection } from '@/utils/setupOfflineReconnection';
import { connectionState } from '@/utils/serverConnectionErrors';
import { createOpencodeMessageId, OpencodeClient, type OpencodeSessionInfo } from './opencodeClient';
import { OpencodeEventMapper, type OpencodeMirrorAction } from './opencodeEventMapper';
import { OpencodePermissionBridge } from './opencodePermissionBridge';
import {
    attachOpencodeTui,
    classifyTuiExit,
    findLiveOwner,
    reapOrphanedServers,
    removeTuiState,
    startOpencodeServer,
    writeTuiState,
    type OpencodeServerHandle,
    type OpencodeTuiState,
    type ProcessExit,
} from './opencodeProcesses';
import { buildOpencodePickers, opencodePromptOptions } from './opencodeSessionConfig';

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

export async function runOpencodeTui(opts: {
    credentials: Credentials;
    bin: string;
    startedBy?: 'daemon' | 'terminal';
    /** OpenCode session id to continue. */
    resumeSessionId?: string;
}): Promise<void> {
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
    const sessionTag = randomUUID();
    const response = await api.getOrCreateSession({ tag: sessionTag, metadata, state });

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

    session.updateMetadata((current) => ({ ...current, opencodeSessionId: opencodeSession.id }));
    if (resumeNotice) {
        session.sendSessionEvent({ type: 'message', message: resumeNotice });
    }

    let agentNames: string[] = [];
    try {
        const [providers, agents, config] = await Promise.all([client.providers(), client.agents(), client.config()]);
        const pickers = buildOpencodePickers({ providers, agents, config });
        agentNames = pickers.modes?.availableModes.map((mode) => mode.id) ?? [];
        session.updateMetadata((current) => mergeAcpSessionConfigIntoMetadata(current, {
            ...(pickers.models ? { models: pickers.models } : {}),
            ...(pickers.modes ? { modes: pickers.modes } : {}),
        }));
    } catch (error) {
        logger.debug('[OpenCode] Could not read models/agents for the app pickers:', error);
    }

    let thinking = false;
    let tuiAttached = true;
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
    });
    writeTuiState(stateDir, ownerState());

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
                bridge.ask(action);
                break;
            case 'permission-replied':
                bridge.resolveExternally(action.id, action.reply);
                break;
            case 'title':
                session.sendClaudeSessionMessage({ type: 'summary', summary: action.title, leafUuid: randomUUID() });
                break;
            case 'session-changed':
                session.updateMetadata((current) => ({ ...current, opencodeSessionId: action.sessionId }));
                writeTuiState(stateDir, ownerState());
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
        const options = opencodePromptOptions({
            model: message.meta?.model,
            permissionMode: message.meta?.permissionMode,
            agentNames,
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
    const shutdown = async (reason: string, archive: boolean) => {
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
            session.sendSessionDeath();
            await api.deactivateSession(session.sessionId).catch(() => false);
            await session.flush();
            await session.close();
        } catch (error) {
            logger.debug('[OpenCode] Session close failed:', error);
        }
        resolveDone();
    };

    registerKillSessionHandler(session.rpcHandlerManager, () => shutdown('archived from the app', true));
    const onTerminate = () => { void shutdown('terminated', false); };
    process.on('SIGTERM', onTerminate);
    void server.exited.then((exit) => shutdown(`opencode serve exited (code ${exit.code}, signal ${exit.signal})`, false));

    const guard = installHangupGuard(() => {
        tuiAttached = false;
        writeTuiState(stateDir, ownerState());
        sendKeepAlive();
        // With no terminal, Ctrl-C can no longer reach us; SIGINT now means "stop".
        process.on('SIGINT', onTerminate);
    });

    try {
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
            writeTuiState(stateDir, ownerState());
            sendKeepAlive();
            process.on('SIGINT', onTerminate);
        }
        await done;
    } finally {
        guard.dispose();
        process.off('SIGTERM', onTerminate);
        process.off('SIGINT', onTerminate);
    }
}
