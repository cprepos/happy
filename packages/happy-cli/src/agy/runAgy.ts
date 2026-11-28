/**
 * Agy Session Runner
 *
 * Entry point for agy (Antigravity CLI) agent sessions, following the runOpenClaw.ts
 * pattern. The daemon spawns this as:
 *   `node dist/index.mjs agy --happy-starting-mode remote --started-by daemon`
 * and, to resume a session, as `agy --resume <agy conversation id>` with the
 * HAPPY_RECONNECT_* environment of the Happy session it reattaches to.
 *
 * agy is a plain-text streaming CLI (no ACP), so this drives an AgyBackend that
 * spawns `agy --print` per turn, and forwards its AgentMessage stream through the
 * same session pipeline used by the other backends.
 */

import { randomUUID } from 'node:crypto';
import React from 'react';
import { render, type Instance as InkInstance } from 'ink';
import { ApiClient } from '@/api/api';
import type { ApiSessionClient } from '@/api/apiSession';
import { AcpSessionManager } from '@/agent/acp/AcpSessionManager';
import type { SessionEnvelope } from '@slopus/happy-wire';
import { logger } from '@/ui/logger';
import { MessageQueue2 } from '@/utils/MessageQueue2';
import { Credentials, readSettings } from '@/persistence';
import { initialMachineMetadata } from '@/daemon/run';
import { createSessionMetadata } from '@/utils/createSessionMetadata';
import { setupOfflineReconnection } from '@/utils/setupOfflineReconnection';
import { notifyDaemonSessionStarted } from '@/daemon/controlClient';
import { encodeBase64, decodeBase64 } from '@/api/encryption';
import { registerKillSessionHandler } from '@/claude/registerKillSessionHandler';
import { connectionState } from '@/utils/serverConnectionErrors';
import { MessageBuffer } from '@/ui/ink/messageBuffer';
import { AgyDisplay } from '@/ui/ink/AgyDisplay';
import type { AgentMessage } from '@/agent/core';
import { normalizeRemotePermissionMode } from '@/claude/utils/permissionMode';
import { AgyBackend } from './AgyBackend';
import { checkAgyConversation } from './conversationCheck';
import {
  DEFAULT_AGY_EFFORT,
  DEFAULT_AGY_MODEL,
  FALLBACK_AGY_MODEL_OPTIONS,
  discoverAgyModelOptions,
  normalizeAgyEffort,
  normalizeAgyModelAlias,
  pickDefaultAgyModel,
  resolveAgyModelName,
} from './constants';
import type { PermissionMode, Session as ApiSession } from '@/api/types';

export interface RunAgyOptions {
  credentials: Credentials;
  startedBy?: 'daemon' | 'terminal';
  verbose?: boolean;
  model?: string;
  effort?: string;
  permissionMode?: PermissionMode;
  /** agy conversation id to continue (`happy agy --resume <id>`). */
  resumeConversationId?: string;
}

export async function runAgy(opts: RunAgyOptions): Promise<void> {
  const verbose = opts.verbose === true;
  const sessionTag = randomUUID();
  connectionState.setBackend('agy');

  const log = (msg: string) => {
    logger.debug(`[agy] ${msg}`);
    if (verbose) {
      console.log(`[agy] ${msg}`);
    }
  };

  const api = await ApiClient.create(opts.credentials);
  const settings = await readSettings();
  if (!settings?.machineId) {
    throw new Error('No machine ID found in settings');
  }

  await api.getOrCreateMachine({
    machineId: settings.machineId,
    metadata: initialMachineMetadata,
  });

  let selectedModel = opts.model ? normalizeAgyModelAlias(opts.model) : DEFAULT_AGY_MODEL;
  let selectedEffort = opts.effort ? normalizeAgyEffort(opts.effort) : DEFAULT_AGY_EFFORT;
  let displayedModel = resolveAgyModelName(selectedModel, selectedEffort);
  // Started now, answered after the session is up: `agy models` can take seconds.
  const modelDiscovery = discoverAgyModelOptions();
  let availableModels = [...FALLBACK_AGY_MODEL_OPTIONS];

  const { state, metadata } = createSessionMetadata({
    flavor: 'agy',
    machineId: settings.machineId,
    startedBy: opts.startedBy,
  });
  metadata.models = availableModels;
  metadata.currentModelCode = selectedModel;
  // A resumed session records the conversation it continues from the start:
  // the backend only reports conversations it pins itself, so without this the
  // id would be lost after one resume.
  if (opts.resumeConversationId) {
    metadata.agyConversationId = opts.resumeConversationId;
  }

  // Check for session reconnection env vars (set by the daemon and `happy resume`)
  const reconnectSessionId = process.env.HAPPY_RECONNECT_SESSION_ID;
  const reconnectKeyBase64 = process.env.HAPPY_RECONNECT_ENCRYPTION_KEY;
  const reconnectVariant = process.env.HAPPY_RECONNECT_ENCRYPTION_VARIANT as 'legacy' | 'dataKey' | undefined;
  const reconnectSeq = process.env.HAPPY_RECONNECT_SEQ;
  const reconnectMetadataVersion = process.env.HAPPY_RECONNECT_METADATA_VERSION;
  const reconnectAgentStateVersion = process.env.HAPPY_RECONNECT_AGENT_STATE_VERSION;

  // Reattach only with the full environment; anything less starts a new session.
  const isReconnect = Boolean(reconnectSessionId && reconnectKeyBase64 && reconnectVariant);

  let response: ApiSession | null;
  if (isReconnect && reconnectSessionId && reconnectKeyBase64 && reconnectVariant) {
    log(`Reconnecting to existing session ${reconnectSessionId}`);
    response = {
      id: reconnectSessionId,
      seq: parseInt(reconnectSeq || '0', 10),
      encryptionKey: decodeBase64(reconnectKeyBase64),
      encryptionVariant: reconnectVariant,
      metadata,
      metadataVersion: parseInt(reconnectMetadataVersion || '0', 10),
      agentState: state,
      agentStateVersion: parseInt(reconnectAgentStateVersion || '0', 10),
    };
  } else {
    response = await api.getOrCreateSession({ tag: sessionTag, metadata, state });
  }
  if (response) {
    log(`Happy Session ID: ${response.id}`);
  }

  let session: ApiSessionClient;
  const { session: initialSession, reconnectionHandle } = setupOfflineReconnection({
    api,
    sessionTag,
    metadata,
    state,
    response,
    onSessionSwap: (newSession) => {
      session = newSession;
    },
  });
  session = initialSession;

  // On reconnect, un-archive the session and skip replaying old messages.
  if (isReconnect) {
    session.suppressNextArchiveSignal();
    session.skipExistingMessages();
    session.updateMetadata((meta) => ({
      ...meta,
      lifecycleState: 'running',
      archivedBy: undefined,
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
      logger.debug('[agy] Failed to report session to daemon:', error);
    }
  }

  const sessionManager = new AcpSessionManager();
  const messageQueue = new MessageQueue2<Record<string, never>>(() => '');
  let shouldExit = false;
  let abortController = new AbortController();
  let thinking = false;
  let errorReportedForCurrentTurn = false;

  const backend = new AgyBackend({
    cwd: process.cwd(),
    permissionMode: opts.permissionMode ?? 'default',
    model: selectedModel,
    effort: selectedEffort,
    log,
    conversationId: opts.resumeConversationId,
    // Persist the conversation so the session can be resumed after a restart.
    onConversationId: (conversationId, previousConversationId) => {
      try {
        session.updateMetadata((curr) => ({
          ...curr,
          agyConversationId: conversationId,
        }));
      } catch (error) {
        logger.debug('[agy] Failed to record the agy conversation id:', error);
      }
      if (previousConversationId) {
        const notice = `Antigravity conversation ${previousConversationId} could not be resumed, so agy started a new one (${conversationId}). The earlier context is not available to the agent.`;
        messageBuffer.addMessage(notice, 'status');
        session.sendSessionEvent({ type: 'message', message: notice });
      }
    },
  });

  // Terminal UI (only with a real TTY; the daemon runs headless).
  const messageBuffer = new MessageBuffer();
  const hasTTY = Boolean(process.stdout.isTTY && process.stdin.isTTY);
  let inkInstance: InkInstance | null = null;

  const sendEnvelopes = (envelopes: SessionEnvelope[]) => {
    for (const envelope of envelopes) {
      session.sendSessionProtocolMessage(envelope);
    }
  };

  const onBackendMessage = (msg: AgentMessage) => {
    if (verbose) {
      log(`Backend message: ${JSON.stringify(msg).slice(0, 200)}`);
    }

    if (msg.type === 'model-output' && msg.textDelta) {
      messageBuffer.addMessage(msg.textDelta, 'assistant');
    } else if (msg.type === 'status') {
      const nextThinking = msg.status === 'running';
      if (thinking !== nextThinking) {
        thinking = nextThinking;
        session.keepAlive(thinking, 'remote');
      }
      if (msg.status === 'error' && msg.detail) {
        messageBuffer.addMessage(`Error: ${msg.detail}`, 'status');
      }
    }

    const envelopes = sessionManager.mapMessage(msg);
    sendEnvelopes(envelopes);
    if (msg.type === 'status' && msg.status === 'error' && envelopes.length === 0) {
      session.sendSessionEvent({
        type: 'message',
        message: `Antigravity error: ${msg.detail?.trim() || 'The agent stopped because of an unknown error.'}`,
      });
    }
    if (msg.type === 'status' && msg.status === 'error') {
      errorReportedForCurrentTurn = true;
    }
  };

  backend.onMessage(onBackendMessage);

  let availableModelCodes = availableModels.map((item) => item.code);
  let lastRemoteModel: string | undefined = undefined;
  let lastRemoteEffort: string | null | undefined = undefined;

  const publishModelMetadata = () => {
    try {
      session.updateMetadata((curr) => ({
        ...curr,
        models: availableModels,
        currentModelCode: selectedModel,
      }));
    } catch {
      // Ignore metadata update race before first flush.
    }
  };

  const syncDisplayedModel = (nextModel: string, nextEffort?: string) => {
    selectedModel = normalizeAgyModelAlias(nextModel);
    if (nextEffort !== undefined) {
      selectedEffort = normalizeAgyEffort(nextEffort);
      backend.setEffort(selectedEffort);
    }
    backend.setModel(selectedModel);
    displayedModel = resolveAgyModelName(selectedModel, selectedEffort);
    if (hasTTY) {
      messageBuffer.addMessage(`[MODEL:${displayedModel}]`, 'system');
    }
    publishModelMetadata();
  };

  const DisplayComponent = () =>
    React.createElement(AgyDisplay, {
      messageBuffer,
      logPath: process.env.DEBUG ? logger.getLogPath() : undefined,
      currentModel: displayedModel,
      availableModels: availableModelCodes,
      onSelectModel: (chosen: string) => {
        syncDisplayedModel(chosen);
        messageBuffer.addMessage(`Switched model to ${displayedModel}`, 'status');
      },
      onExit: async () => {
        logger.debug('[agy] Exiting agent via Ctrl-C');
        shouldExit = true;
        await handleAbort();
      },
    });

  if (hasTTY) {
    inkInstance = render(React.createElement(DisplayComponent), {
      exitOnCtrlC: false,
      patchConsole: false,
    });
    messageBuffer.addMessage(`[MODEL:${displayedModel}]`, 'system');

    process.stdin.resume();
    if (process.stdin.isTTY) {
      process.stdin.setRawMode(true);
    }
    process.stdin.setEncoding('utf8');
  }

  // The default model is swapped when the account doesn't list it, even when
  // an app sent it: the app's own default is the same model, picked before
  // this list reached it. Only `--model` is left alone.
  const modelsReady = modelDiscovery.then((discovered) => {
    if (!discovered) return;
    availableModels = discovered;
    availableModelCodes = discovered.map((item) => item.code);
    const fallback = pickDefaultAgyModel(availableModelCodes);
    if (!opts.model && selectedModel === DEFAULT_AGY_MODEL && fallback !== selectedModel) {
      log(`${selectedModel} is not in agy models; defaulting to ${fallback}`);
      syncDisplayedModel(fallback);
    } else {
      publishModelMetadata();
    }
    inkInstance?.rerender(React.createElement(DisplayComponent));
  }).catch((error) => {
    logger.debug('[agy] Applying agy models failed:', error);
  });

  session.onUserMessage((message) => {
    if (!message.content.text) return;

    if (message.meta?.permissionMode) {
      const mode = normalizeRemotePermissionMode(message.meta.permissionMode);
      if (mode) {
        backend.setPermissionMode(mode);
      }
    }

    const incomingModel = message.meta?.hasOwnProperty('model') ? message.meta.model : undefined;
    const incomingEffort = message.meta?.hasOwnProperty('effort') ? message.meta.effort : undefined;
    const remoteModelChanged = incomingModel && incomingModel !== lastRemoteModel;
    const remoteEffortChanged = incomingEffort !== undefined && incomingEffort !== lastRemoteEffort;

    if (incomingModel !== undefined) {
      lastRemoteModel = incomingModel ?? undefined;
    }
    if (incomingEffort !== undefined) {
      lastRemoteEffort = incomingEffort;
    }

    if (remoteModelChanged || remoteEffortChanged) {
      const nextModel = incomingModel ? normalizeAgyModelAlias(incomingModel) : selectedModel;
      const nextEffort = incomingEffort !== undefined ? normalizeAgyEffort(incomingEffort) : selectedEffort;
      syncDisplayedModel(nextModel, nextEffort);
    }

    const trimmedText = message.content.text.trim();
    if (/^\/models$/i.test(trimmedText)) {
      const listText = availableModelCodes
        .map((code, idx) => `${idx + 1}. ${code}${code === selectedModel ? ` ✓ (current: ${displayedModel})` : ''}`)
        .join('\n');
      const reply = `Available Antigravity models:\n${listText}\n\nUse \`/model <number or name>\` (e.g. \`/model argon high\` or \`/model 1\`) or the model picker to switch.`;
      messageBuffer.addMessage(reply, 'status');
      session.sendSessionEvent({ type: 'message', message: reply });
      session.sendSessionEvent({ type: 'ready' });
      return;
    }

    const slashModelMatch = /^\/model\s+(.+)$/i.exec(trimmedText);
    if (slashModelMatch) {
      const rawArg = slashModelMatch[1].trim();
      const numericIndex = /^\d+$/.test(rawArg) ? Number(rawArg) - 1 : -1;
      if (numericIndex >= 0 && numericIndex < availableModelCodes.length) {
        syncDisplayedModel(availableModelCodes[numericIndex]);
      } else {
        const parts = rawArg.split(/\s+/);
        const maybeEffort = parts.length > 1 ? parts[parts.length - 1].toLowerCase() : '';
        if (['low', 'medium', 'high', 'xhigh'].includes(maybeEffort)) {
          syncDisplayedModel(parts.slice(0, -1).join(' '), maybeEffort);
        } else {
          syncDisplayedModel(rawArg);
        }
      }
      const confirmMsg = `Switched Antigravity model to: ${displayedModel}`;
      messageBuffer.addMessage(confirmMsg, 'status');
      session.sendSessionEvent({ type: 'message', message: confirmMsg });
      session.sendSessionEvent({ type: 'ready' });
      return;
    }

    messageBuffer.addMessage(message.content.text, 'user');
    messageQueue.push(message.content.text, {});
  });
  session.keepAlive(thinking, 'remote');

  const keepAliveInterval = setInterval(() => {
    session.keepAlive(thinking, 'remote');
  }, 2000);

  /**
   * Before the first turn, ask agy whether the conversation still exists, and
   * fail like a Codex resume does when it is gone. An unclear answer resumes
   * anyway: the turn itself reports a missing conversation.
   */
  async function announceResumedConversation(conversationId: string) {
    const check = await checkAgyConversation(conversationId);
    if (check.status === 'missing') {
      const message = `Antigravity conversation ${conversationId} no longer exists, so it cannot be resumed.`;
      messageBuffer.addMessage(message, 'status');
      session.sendSessionEvent({ type: 'message', message });
      throw new Error(message);
    }
    if (check.status === 'unknown') {
      log(`Could not check conversation ${conversationId} before resuming: ${check.reason}`);
    } else if (check.cwd && check.cwd !== process.cwd()) {
      const notice = `Conversation ${conversationId} was started in ${check.cwd}, resuming it in ${process.cwd()}`;
      log(notice);
      messageBuffer.addMessage(notice, 'status');
    }
    messageBuffer.addMessage(`Resumed conversation ${conversationId}`, 'status');
    session.sendSessionEvent({
      type: 'message',
      message: `Resumed Antigravity conversation ${conversationId}`,
    });
  }

  async function handleAbort() {
    log('Abort requested');
    try {
      await backend.cancel();
    } catch (error) {
      logger.debug('[agy] Abort failed:', error);
    }
    thinking = false;
    session.keepAlive(false, 'remote');
    abortController.abort();
    abortController = new AbortController();
  }

  session.rpcHandlerManager.registerHandler('abort', handleAbort);
  registerKillSessionHandler(session.rpcHandlerManager, async () => {
    shouldExit = true;
    messageQueue.close();
    await handleAbort();
  });

  try {
    await backend.startSession();
    log('Backend ready');

    if (opts.resumeConversationId) {
      await announceResumedConversation(opts.resumeConversationId);
    }

    while (!shouldExit) {
      const waitSignal = abortController.signal;
      const batch = await messageQueue.waitForMessagesAndGetAsString(waitSignal);
      if (!batch) {
        if (shouldExit) break;
        if (waitSignal.aborted) continue;
        break;
      }

      log(`Incoming prompt: ${batch.message.slice(0, 200)}`);
      errorReportedForCurrentTurn = false;
      // The first turn waits (at most agy models' timeout) so a default the
      // account lacks is swapped before it fails.
      await modelsReady;
      sendEnvelopes(sessionManager.startTurn());
      try {
        await backend.sendPrompt(process.cwd(), batch.message);
        sendEnvelopes(sessionManager.endTurn('completed'));
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        if (!errorReportedForCurrentTurn) {
          session.sendSessionEvent({ type: 'message', message: `Antigravity error: ${msg}` });
          errorReportedForCurrentTurn = true;
        }
        log(`Turn ended: ${msg}`);
        sendEnvelopes(sessionManager.endTurn('failed'));
      }
      thinking = false;
      session.keepAlive(false, 'remote');
      session.sendSessionEvent({ type: 'ready' });
    }
  } finally {
    clearInterval(keepAliveInterval);
    reconnectionHandle?.cancel();

    backend.offMessage(onBackendMessage);
    await backend.dispose();
    inkInstance?.unmount();

    try {
      session.updateMetadata((currentMetadata) => ({
        ...currentMetadata,
        lifecycleState: 'archived',
        lifecycleStateSince: Date.now(),
        archivedBy: 'cli',
        archiveReason: 'Session ended',
      }));
      session.sendSessionDeath();
      await session.flush();
      await session.close();
    } catch (error) {
      logger.debug('[agy] Session close failed:', error);
    }
  }
}
