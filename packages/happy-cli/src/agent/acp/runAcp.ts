import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { ApiClient } from '@/api/api';
import type { ApiSessionClient } from '@/api/apiSession';
import type { AgentMessage } from '@/agent/core';
import { AcpBackend, type AcpPermissionHandler } from './AcpBackend';
import { DefaultTransport } from '@/agent/transport';
import { AcpSessionManager } from './AcpSessionManager';
import type { SessionEnvelope } from '@slopus/happy-wire';
import { logger } from '@/ui/logger';
import { MessageQueue2 } from '@/utils/MessageQueue2';
import { hashObject } from '@/utils/deterministicJson';
import { Credentials, readSettings } from '@/persistence';
import { initialMachineMetadata } from '@/daemon/run';
import { createSessionMetadata } from '@/utils/createSessionMetadata';
import { setupOfflineReconnection } from '@/utils/setupOfflineReconnection';
import { notifyDaemonSessionStarted } from '@/daemon/controlClient';
import { decodeBase64, encodeBase64 } from '@/api/encryption';
import type { Metadata, Session as ApiSession } from '@/api/types';
import { opencodeModeAgent, withOpencodePermissionModes, type OpencodePermissionPolicy } from '@/opencode/acpPermissionModes';
import { parseOpencodeMode } from '@/opencode/tui/opencodeSessionConfig';
import { registerKillSessionHandler } from '@/claude/registerKillSessionHandler';
import { startHappyServer } from '@/claude/utils/startHappyServer';
import { projectPath } from '@/projectPath';
import { BasePermissionHandler, type PermissionResult } from '@/utils/BasePermissionHandler';
import { connectionState } from '@/utils/serverConnectionErrors';
import {
  extractConfigOptionsFromPayload,
  extractCurrentModeIdFromPayload,
  extractModeStateFromPayload,
  extractModelStateFromPayload,
  mergeAcpSessionConfigIntoMetadata,
} from './sessionConfigMetadata';
import type { SessionConfigOption, SessionModeState, SessionModelState } from '@agentclientprotocol/sdk';

const TURN_TIMEOUT_MS = 5 * 60 * 1000;
const ACP_EVENT_PREVIEW_CHARS = 240;
const ACP_RAW_PREVIEW_CHARS = 2000;
const ACP_COLOR_RESET = '\u001b[0m';
const ACP_LOG_COLORS = {
  muted: '\u001b[90m',
  error: '\u001b[31m',
  incoming: '\u001b[32m',
  outgoing: '\u001b[34m',
  tool: '\u001b[38;5;208m',
} as const;

type AcpLogKind = keyof typeof ACP_LOG_COLORS;
type AcpFormattedLog = {
  kind: AcpLogKind;
  text: string;
};

function shouldUseColoredAcpLogs(): boolean {
  if (process.env.FORCE_COLOR === '0') {
    return false;
  }
  if (process.env.FORCE_COLOR !== undefined) {
    return true;
  }
  return process.stdout.isTTY === true || process.stderr.isTTY === true;
}

function formatAcpTime(date: Date = new Date()): string {
  const hours = String(date.getHours()).padStart(2, '0');
  const minutes = String(date.getMinutes()).padStart(2, '0');
  return `${hours}:${minutes}`;
}

function colorizeAcpLine(kind: AcpLogKind, line: string): string {
  if (!shouldUseColoredAcpLogs()) {
    return line;
  }
  return `${ACP_LOG_COLORS[kind]}${line}${ACP_COLOR_RESET}`;
}

function logAcp(kind: AcpLogKind, message: string): void {
  const line = `[${formatAcpTime()}] ${message}`;
  console.log(colorizeAcpLine(kind, line));
}

function toSingleLine(text: string): string {
  return text.replace(/\s+/g, ' ').trim();
}

function truncateForConsole(text: string, limit: number): string {
  if (text.length <= limit) {
    return text;
  }
  return `${text.slice(0, limit)}...`;
}

function formatUnknownForConsole(value: unknown, limit: number): string {
  let serialized = '';
  if (typeof value === 'string') {
    serialized = value;
  } else {
    try {
      serialized = JSON.stringify(value);
    } catch {
      serialized = String(value);
    }
  }
  return truncateForConsole(toSingleLine(serialized), limit);
}

function formatTextForConsole(text: string): string {
  return JSON.stringify(truncateForConsole(toSingleLine(text), ACP_EVENT_PREVIEW_CHARS));
}

function formatOptionalDetail(text: string | null | undefined, limit = ACP_EVENT_PREVIEW_CHARS): string {
  if (!text) {
    return '';
  }
  return ` - ${truncateForConsole(toSingleLine(text), limit)}`;
}

function extractThinkingText(payload: unknown): string {
  if (typeof payload === 'string') {
    return payload;
  }
  if (payload && typeof payload === 'object' && typeof (payload as { text?: unknown }).text === 'string') {
    return (payload as { text: string }).text;
  }
  return '';
}

function formatAcpMessageForFrontend(agentName: string, msg: AgentMessage, detailed: boolean): AcpFormattedLog | null {
  switch (msg.type) {
    case 'status':
      return null;
    case 'model-output': {
      const text = msg.textDelta ?? msg.fullText ?? '';
      return {
        kind: 'outgoing',
        text: `Outgoing message: ${formatTextForConsole(text)}`,
      };
    }
    case 'tool-call':
      return {
        kind: 'tool',
        text: `Tool: ${msg.toolName} started (callId=${msg.callId})`,
      };
    case 'tool-result':
      return {
        kind: 'tool',
        text: `Tool: ${msg.toolName} completed (callId=${msg.callId})`,
      };
    case 'permission-request':
      if (!detailed) {
        return null;
      }
      return {
        kind: 'muted',
        text: `Outgoing permission request from ${agentName}: id=${msg.id} reason=${msg.reason}`,
      };
    case 'permission-response':
      if (!detailed) {
        return null;
      }
      return {
        kind: 'muted',
        text: `Outgoing permission response from ${agentName}: id=${msg.id} approved=${msg.approved}`,
      };
    case 'fs-edit':
      if (!detailed) {
        return null;
      }
      return {
        kind: 'muted',
        text: `Outgoing fs edit from ${agentName}: description=${formatTextForConsole(msg.description)}`,
      };
    case 'terminal-output':
      if (!detailed) {
        return null;
      }
      return {
        kind: 'muted',
        text: `Outgoing terminal output from ${agentName}: text=${formatTextForConsole(msg.data)}`,
      };
    case 'event': {
      if (msg.name === 'thinking') {
        const thinkingText = extractThinkingText(msg.payload);
        return {
          kind: 'muted',
          text: `Thinking: ${formatTextForConsole(thinkingText)}`,
        };
      }
      if (!detailed) {
        return null;
      }
      return {
        kind: 'muted',
        text: `Outgoing event from ${agentName}: name=${msg.name} payload=${formatUnknownForConsole(msg.payload, ACP_EVENT_PREVIEW_CHARS)}`,
      };
    }
    case 'token-count':
      if (!detailed) {
        return null;
      }
      return {
        kind: 'muted',
        text: `Outgoing token count from ${agentName}: data=${formatUnknownForConsole(msg, ACP_EVENT_PREVIEW_CHARS)}`,
      };
    case 'exec-approval-request':
      if (!detailed) {
        return null;
      }
      return {
        kind: 'muted',
        text: `Outgoing exec approval request from ${agentName}: callId=${msg.call_id}`,
      };
    case 'patch-apply-begin':
      if (!detailed) {
        return null;
      }
      return {
        kind: 'muted',
        text: `Outgoing patch apply begin from ${agentName}: callId=${msg.call_id} autoApproved=${msg.auto_approved === true}`,
      };
    case 'patch-apply-end':
      if (!detailed) {
        return null;
      }
      return {
        kind: 'muted',
        text: `Outgoing patch apply end from ${agentName}: callId=${msg.call_id} success=${msg.success}`,
      };
    default:
      return null;
  }
}

function formatEnvelopeForServerLog(agentName: string, envelope: SessionEnvelope): AcpFormattedLog {
  if (envelope.ev.t === 'text') {
    const thinkingPrefix = envelope.ev.thinking ? 'thinking' : 'text';
    return {
      kind: 'incoming',
      text: `Incoming ${thinkingPrefix} prompt for ${agentName}: ${formatUnknownForConsole(envelope.ev.text, ACP_EVENT_PREVIEW_CHARS)}`,
    };
  }
  if (envelope.ev.t === 'tool-call-start') {
    return {
      kind: 'tool',
      text: `Tool start sent to server from ${agentName}: tool=${envelope.ev.name} callId=${envelope.ev.call} args=${formatUnknownForConsole(envelope.ev.args, ACP_EVENT_PREVIEW_CHARS)}`,
    };
  }
  if (envelope.ev.t === 'tool-call-end') {
    return {
      kind: 'tool',
      text: `Tool end sent to server from ${agentName}: callId=${envelope.ev.call}`,
    };
  }
  if (envelope.ev.t === 'turn-start') {
    return {
      kind: 'incoming',
      text: `Incoming turn start for ${agentName}`,
    };
  }
  if (envelope.ev.t === 'turn-end') {
    return {
      kind: 'incoming',
      text: `Incoming turn end for ${agentName}: status=${envelope.ev.status}`,
    };
  }
  return {
    kind: 'incoming',
    text: `Incoming ${envelope.ev.t} for ${agentName}: ${formatUnknownForConsole(envelope.ev, ACP_EVENT_PREVIEW_CHARS)}`,
  };
}

type AcpSwitchMode = {
  permissionMode?: string;
  model?: string | null;
};

type AcpSelectableOption = {
  code: string;
  value: string;
};

type AcpConfigSelector = {
  configId: string;
  currentCode: string;
  options: AcpSelectableOption[];
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === 'object';
}

function isSelectValue(value: unknown): value is { value: string; name: string } {
  return isRecord(value) && typeof value.value === 'string' && typeof value.name === 'string';
}

function isSelectGroup(value: unknown): value is { options: unknown[] } {
  return isRecord(value) && Array.isArray(value.options);
}

function flattenSelectOptions(options: unknown): AcpSelectableOption[] {
  if (!Array.isArray(options)) {
    return [];
  }

  const flattened: AcpSelectableOption[] = [];

  for (const entry of options) {
    if (isSelectValue(entry)) {
      flattened.push({ code: entry.value, value: entry.name });
      continue;
    }
    if (isSelectGroup(entry)) {
      for (const grouped of entry.options) {
        if (!isSelectValue(grouped)) {
          continue;
        }
        flattened.push({ code: grouped.value, value: grouped.name });
      }
    }
  }

  return flattened;
}

/**
 * Find the select option that controls the agent's mode or model.
 *
 * An option whose declared category matches always wins. Only when no option
 * declares the category do id/name heuristics apply, and the mode heuristic
 * skips anything that looks like a model: OpenCode lists its `model` option
 * before `mode`, and "model" contains "mode".
 */
export function extractConfigSelector(
  configOptions: SessionConfigOption[],
  category: 'mode' | 'model',
): AcpConfigSelector | null {
  const looksLikeCategory = (option: SessionConfigOption): boolean => {
    const id = normalizeComparable(option.id);
    const name = normalizeComparable(option.name);
    const looksLikeModel = id.includes('model') || name.includes('model');
    if (category === 'model') {
      return looksLikeModel;
    }
    return !looksLikeModel
      && (id.includes('mode') || id.includes('permission') || name.includes('mode') || name.includes('permission'));
  };

  const selects = configOptions.filter((option) => option.type === 'select');
  const option = selects.find((candidate) => candidate.category === category)
    ?? selects.find(looksLikeCategory);
  if (!option || option.type !== 'select') {
    return null;
  }
  return {
    configId: option.id,
    currentCode: option.currentValue,
    options: flattenSelectOptions(option.options),
  };
}

function normalizeComparable(value: string): string {
  return value.trim().toLowerCase();
}

function resolveRequestedCode(options: AcpSelectableOption[], requested: string): string | null {
  for (const option of options) {
    if (option.code === requested || option.value === requested) {
      return option.code;
    }
  }

  const normalizedRequested = normalizeComparable(requested);
  for (const option of options) {
    if (normalizeComparable(option.code) === normalizedRequested || normalizeComparable(option.value) === normalizedRequested) {
      return option.code;
    }
  }

  return null;
}

function resolveRequestedLegacyModeCode(modes: SessionModeState, requested: string): string | null {
  for (const mode of modes.availableModes) {
    if (mode.id === requested || mode.name === requested) {
      return mode.id;
    }
  }

  const normalizedRequested = normalizeComparable(requested);
  for (const mode of modes.availableModes) {
    if (normalizeComparable(mode.id) === normalizedRequested || normalizeComparable(mode.name) === normalizedRequested) {
      return mode.id;
    }
  }

  return null;
}

function resolveRequestedLegacyModelCode(models: SessionModelState, requested: string): string | null {
  for (const model of models.availableModels) {
    if (model.modelId === requested || model.name === requested) {
      return model.modelId;
    }
  }

  const normalizedRequested = normalizeComparable(requested);
  for (const model of models.availableModels) {
    if (normalizeComparable(model.modelId) === normalizedRequested || normalizeComparable(model.name) === normalizedRequested) {
      return model.modelId;
    }
  }

  return null;
}

class GenericAcpPermissionHandler extends BasePermissionHandler implements AcpPermissionHandler {
  private readonly logPrefix: string;

  /**
   * @param autoApprove When it returns true, a request is approved once
   * without asking (OpenCode's auto mode); otherwise it goes to the app.
   */
  constructor(session: ApiSessionClient, agentName: string, private readonly autoApprove: () => boolean = () => false) {
    super(session);
    this.logPrefix = `[${agentName}]`;
  }

  protected getLogPrefix(): string {
    return this.logPrefix;
  }

  async handleToolCall(toolCallId: string, toolName: string, input: unknown): Promise<PermissionResult> {
    if (this.autoApprove()) {
      logger.debug(`${this.logPrefix} Auto-approving tool ${toolName} (${toolCallId})`);
      this.session.updateAgentState((currentState) => ({
        ...currentState,
        completedRequests: {
          ...currentState.completedRequests,
          [toolCallId]: {
            tool: toolName,
            arguments: input,
            createdAt: Date.now(),
            completedAt: Date.now(),
            status: 'approved',
            decision: 'approved',
          },
        },
      }));
      return { decision: 'approved' };
    }
    return new Promise<PermissionResult>((resolve, reject) => {
      this.pendingRequests.set(toolCallId, {
        resolve,
        reject,
        toolName,
        input,
      });
      this.addPendingRequestToState(toolCallId, toolName, input);
      logger.debug(`${this.logPrefix} Permission request sent for tool: ${toolName} (${toolCallId})`);
    });
  }
}

type PendingTurn = {
  resolve: () => void;
  reject: (err: Error) => void;
  timeout: NodeJS.Timeout;
};

function resolveSessionFlavor(agentName: string): 'gemini' | 'opencode' | 'acp' {
  if (agentName === 'gemini') {
    return 'gemini';
  }
  if (agentName === 'opencode') {
    return 'opencode';
  }
  return 'acp';
}

export async function runAcp(opts: {
  credentials: Credentials;
  agentName: string;
  command: string;
  args: string[];
  startedBy?: 'daemon' | 'terminal';
  verbose?: boolean;
  /** The agent's ACP session id to continue (`happy opencode --resume <id>`). */
  resumeSessionId?: string;
  /**
   * OpenCode only: `auto` (default) approves permission requests once without
   * asking, like `opencode --auto`; `ask` shows them in the app. Messages from
   * the app can switch it per message through their mode.
   */
  permissionPolicy?: OpencodePermissionPolicy;
}): Promise<void> {
  const verbose = opts.verbose === true;
  const sessionTag = randomUUID();
  connectionState.setBackend(opts.agentName);

  const api = await ApiClient.create(opts.credentials);
  const settings = await readSettings();
  if (!settings?.machineId) {
    throw new Error('No machine ID found in settings');
  }

  await api.getOrCreateMachine({
    machineId: settings.machineId,
    metadata: initialMachineMetadata,
  });

  const flavor = resolveSessionFlavor(opts.agentName);
  const { state, metadata } = createSessionMetadata({
    flavor,
    machineId: settings.machineId,
    startedBy: opts.startedBy,
    sandbox: settings.sandboxConfig,
  });
  if (flavor === 'opencode' && opts.resumeSessionId) {
    metadata.opencodeSessionId = opts.resumeSessionId;
  }
  const launchPolicy: OpencodePermissionPolicy = opts.permissionPolicy ?? 'auto';
  let permissionPolicy: OpencodePermissionPolicy = launchPolicy;
  // OpenCode's mode list is shown as <Agent>-auto / <Agent>-ask (see acpPermissionModes).
  const withSessionConfig = (current: Metadata, snapshot: Parameters<typeof mergeAcpSessionConfigIntoMetadata>[1]): Metadata => {
    const merged = mergeAcpSessionConfigIntoMetadata(current, snapshot);
    return flavor === 'opencode' ? withOpencodePermissionModes(merged, permissionPolicy) : merged;
  };

  // The daemon sets these to resume a Happy session in place.
  const reconnectSessionId = process.env.HAPPY_RECONNECT_SESSION_ID;
  const reconnectKeyBase64 = process.env.HAPPY_RECONNECT_ENCRYPTION_KEY;
  const reconnectVariant = process.env.HAPPY_RECONNECT_ENCRYPTION_VARIANT as 'legacy' | 'dataKey' | undefined;
  let response: ApiSession | null;
  if (reconnectSessionId && reconnectKeyBase64 && reconnectVariant) {
    logger.debug(`[${opts.agentName}] Reconnecting to existing session ${reconnectSessionId}`);
    response = {
      id: reconnectSessionId,
      seq: parseInt(process.env.HAPPY_RECONNECT_SEQ || '0', 10),
      encryptionKey: decodeBase64(reconnectKeyBase64),
      encryptionVariant: reconnectVariant,
      metadata,
      metadataVersion: parseInt(process.env.HAPPY_RECONNECT_METADATA_VERSION || '0', 10),
      agentState: state,
      agentStateVersion: parseInt(process.env.HAPPY_RECONNECT_AGENT_STATE_VERSION || '0', 10),
    };
  } else {
    response = await api.getOrCreateSession({ tag: sessionTag, metadata, state });
  }
  if (response) {
    logAcp('muted', `Happy Session ID: ${response.id}`);
  }

  let session: ApiSessionClient;
  let permissionHandler: GenericAcpPermissionHandler;
  const { session: initialSession, reconnectionHandle } = setupOfflineReconnection({
    api,
    sessionTag,
    metadata,
    state,
    response,
    onSessionSwap: (newSession) => {
      session = newSession;
      if (permissionHandler) {
        permissionHandler.updateSession(newSession);
      }
    },
  });
  session = initialSession;

  // On reconnect, un-archive the session and skip replaying old messages.
  if (reconnectSessionId) {
    session.suppressNextArchiveSignal();
    session.skipExistingMessages();
    session.updateMetadata((currentMetadata) => ({
      ...currentMetadata,
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
      logger.debug('[acp] Failed to report session to daemon:', error);
    }
  }

  permissionHandler = new GenericAcpPermissionHandler(
    session,
    opts.agentName,
    () => flavor === 'opencode' && permissionPolicy === 'auto',
  );
  // Drop any permission requests left in agent state from a previous CLI
  // process that died while a tool prompt was open — see the matching
  // call in claudeRemoteLauncher for the full rationale.
  permissionHandler.reset('Previous CLI process exited before responding');
  const sessionManager = new AcpSessionManager();
  const messageQueue = new MessageQueue2<AcpSwitchMode>((mode) => hashObject(mode));
  let currentPermissionMode: string | undefined;
  let currentModel: string | null | undefined;
  let modeSelector: AcpConfigSelector | null = null;
  let modelSelector: AcpConfigSelector | null = null;
  let legacyModes: SessionModeState | null = null;
  let legacyModels: SessionModelState | null = null;
  let sawSlashCommands = false;
  let sawModes = false;
  let sawModels = false;

  const happyServer = await startHappyServer(session);
  const mcpServers = {
    happy: {
      command: join(projectPath(), 'bin', 'happy-mcp.mjs'),
      args: ['--url', happyServer.url],
    },
  };

  const backend = new AcpBackend({
    agentName: opts.agentName,
    cwd: process.cwd(),
    command: opts.command,
    args: opts.args,
    mcpServers,
    permissionHandler,
    transportHandler: new DefaultTransport(opts.agentName),
    verbose,
    resumeSessionId: opts.resumeSessionId,
  });

  let thinking = false;
  let acpSessionId: string | null = null;
  let shouldExit = false;
  let abortController = new AbortController();
  let pendingTurn: PendingTurn | null = null;
  let errorReportedForCurrentTurn = false;
  // Stop in the app (`abort`) cancels the current turn only. While the
  // backend's cancel call runs, the 'stopped' status it reports means "turn
  // cancelled", not "agent gone"; and a turn the user cancelled ends quietly
  // instead of taking the whole runner down with it.
  let cancelInFlight = false;
  let currentTurnCancelled = false;

  const clearPendingTurn = (error?: Error) => {
    if (!pendingTurn) {
      return;
    }
    clearTimeout(pendingTurn.timeout);
    const current = pendingTurn;
    pendingTurn = null;
    if (error) {
      current.reject(error);
      return;
    }
    current.resolve();
  };

  const waitForTurnEnd = () => new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingTurn = null;
      reject(new Error(`Timed out waiting for ${opts.agentName} to finish the turn`));
    }, TURN_TIMEOUT_MS);
    pendingTurn = { resolve, reject, timeout };
  });

  const stopRunnerFromBackendStatus = (status: 'error' | 'stopped', detail?: string) => {
    const reason = detail
      ? `${opts.agentName} backend ${status}: ${detail}`
      : `${opts.agentName} backend ${status}`;
    logger.debug(`[${opts.agentName}] ${reason}; stopping ACP runner`);
    shouldExit = true;
    messageQueue.close();
    clearPendingTurn(new Error(reason));
  };

  const sendEnvelopes = (envelopes: SessionEnvelope[]) => {
    for (const envelope of envelopes) {
      if (verbose) {
        const formatted = formatEnvelopeForServerLog(opts.agentName, envelope);
        logAcp('muted', formatted.text);
      }
      session.sendSessionProtocolMessage(envelope);
      if (verbose) {
        logAcp('muted', `Incoming raw envelope for ${opts.agentName}: ${formatUnknownForConsole(envelope, ACP_RAW_PREVIEW_CHARS)}`);
      }
    }
  };

  const switchPermissionModeIfRequested = async (requestedMode: string): Promise<void> => {
    if (!requestedMode) {
      return;
    }

    if (modeSelector) {
      const resolved = resolveRequestedCode(modeSelector.options, requestedMode);
      if (!resolved) {
        logger.debug(`[${opts.agentName}] Ignoring unknown ACP permission mode request: ${requestedMode}`);
        return;
      }
      if (resolved === modeSelector.currentCode) {
        return;
      }
      const switched = await backend.setSessionConfigOption(modeSelector.configId, resolved);
      if (switched) {
        modeSelector.currentCode = resolved;
        return;
      }
    }

    if (!legacyModes) {
      return;
    }

    const resolvedLegacyMode = resolveRequestedLegacyModeCode(legacyModes, requestedMode);
    if (!resolvedLegacyMode) {
      logger.debug(`[${opts.agentName}] Ignoring unknown ACP legacy mode request: ${requestedMode}`);
      return;
    }
    if (resolvedLegacyMode === legacyModes.currentModeId) {
      return;
    }

    const switched = await backend.setSessionMode(resolvedLegacyMode);
    if (switched) {
      legacyModes = {
        ...legacyModes,
        currentModeId: resolvedLegacyMode,
      };
    }
  };

  /**
   * An OpenCode mode key picks an agent and/or a permission policy
   * (`build:ask`, `plan`, `bypassPermissions`, ...). The policy applies from
   * this message on; the agent is switched through ACP as before.
   */
  const applyOpencodeMode = async (requestedMode: string): Promise<void> => {
    const agentNames = [
      ...(modeSelector?.options.map((option) => option.code) ?? []),
      ...(legacyModes?.availableModes.map((mode) => mode.id) ?? []),
    ].map(opencodeModeAgent);
    const parsed = parseOpencodeMode(requestedMode, agentNames, launchPolicy);
    // Before the agent list is known, `<agent>:<policy>` still sets the policy.
    const suffix = requestedMode.slice(opencodeModeAgent(requestedMode).length + 1);
    const policy = parsed.policy ?? (suffix === 'auto' || suffix === 'ask' ? suffix : undefined);
    const agent = parsed.agent;
    if (policy && policy !== permissionPolicy) {
      logger.debug(`[${opts.agentName}] Permission policy: ${policy}`);
      permissionPolicy = policy;
    }
    if (agent) {
      await switchPermissionModeIfRequested(agent);
    } else if (!policy) {
      // Not an OpenCode mode key: match it against the agent's modes as before.
      await switchPermissionModeIfRequested(requestedMode);
    }
    const currentModeId = modeSelector?.currentCode ?? legacyModes?.currentModeId;
    session.updateMetadata((currentMetadata) => withSessionConfig(currentMetadata, currentModeId ? { currentModeId } : {}));
  };

  const switchModelIfRequested = async (requestedModel: string): Promise<void> => {
    if (!requestedModel) {
      return;
    }

    if (modelSelector) {
      const resolved = resolveRequestedCode(modelSelector.options, requestedModel);
      if (!resolved) {
        logger.debug(`[${opts.agentName}] Ignoring unknown ACP model request: ${requestedModel}`);
        return;
      }
      if (resolved === modelSelector.currentCode) {
        return;
      }
      const switched = await backend.setSessionConfigOption(modelSelector.configId, resolved);
      if (switched) {
        modelSelector.currentCode = resolved;
        return;
      }
    }

    if (!legacyModels) {
      return;
    }

    const resolvedLegacyModel = resolveRequestedLegacyModelCode(legacyModels, requestedModel);
    if (!resolvedLegacyModel) {
      logger.debug(`[${opts.agentName}] Ignoring unknown ACP legacy model request: ${requestedModel}`);
      return;
    }
    if (resolvedLegacyModel === legacyModels.currentModelId) {
      return;
    }

    const switched = await backend.setSessionModel(resolvedLegacyModel);
    if (switched) {
      legacyModels = {
        ...legacyModels,
        currentModelId: resolvedLegacyModel,
      };
    }
  };

  const onBackendMessage = (msg: AgentMessage) => {
    if (verbose) {
      logAcp('muted', `Outgoing raw backend message from ${opts.agentName}: ${formatUnknownForConsole(msg, ACP_RAW_PREVIEW_CHARS)}`);
    }

    if (msg.type === 'event' && msg.name === 'available_commands') {
      const commands = msg.payload as { name: string; description?: string }[];
      const commandNames = commands.map((c) => c.name);
      sawSlashCommands = commands.length > 0;
      if (verbose) {
        logAcp('muted', `Outgoing slash commands from ${opts.agentName} (${commands.length}):`);
        for (const command of commands) {
          logAcp('muted', `  /${command.name}${formatOptionalDetail(command.description, 160)}`);
        }
      }
      session.updateMetadata((currentMetadata) => ({
        ...currentMetadata,
        slashCommands: commandNames,
      }));
    }

    if (msg.type === 'event' && msg.name === 'config_options_update') {
      const configOptions = extractConfigOptionsFromPayload(msg.payload);
      if (configOptions) {
        if (verbose) {
          logAcp('muted', `Outgoing config options from ${opts.agentName} (${configOptions.length}):`);
          for (const option of configOptions) {
            if (option.type === 'select') {
              const optionValues = flattenSelectOptions(option.options);
              logAcp('muted', `  config=${option.id} category=${option.category ?? 'unknown'} current=${option.currentValue} options=${optionValues.length}`);
            } else {
              logAcp('muted', `  config=${option.id} type=${option.type} category=${option.category ?? 'unknown'}`);
            }
          }
        }

        modeSelector = extractConfigSelector(configOptions, 'mode');
        modelSelector = extractConfigSelector(configOptions, 'model');
        if (verbose) {
          if (modeSelector) {
            sawModes = true;
            logAcp('muted', `Outgoing mode options from ${opts.agentName} (${modeSelector.options.length}), current=${modeSelector.currentCode}:`);
            for (const option of modeSelector.options) {
              logAcp('muted', `  mode=${option.code} label=${option.value}`);
            }
          } else {
            logAcp('muted', `Outgoing mode options from ${opts.agentName}: not reported in config options`);
          }
          if (modelSelector) {
            sawModels = true;
            logAcp('muted', `Outgoing model options from ${opts.agentName} (${modelSelector.options.length}), current=${modelSelector.currentCode}:`);
            for (const option of modelSelector.options) {
              logAcp('muted', `  model=${option.code} label=${option.value}`);
            }
          } else {
            logAcp('muted', `Outgoing model options from ${opts.agentName}: not reported in config options`);
          }
        }
        session.updateMetadata((currentMetadata) =>
          withSessionConfig(currentMetadata, { configOptions }),
        );
      }
    }

    if (msg.type === 'event' && msg.name === 'modes_update') {
      const modes = extractModeStateFromPayload(msg.payload);
      if (modes) {
        legacyModes = modes;
        sawModes = true;
        if (verbose) {
          logAcp('muted', `Outgoing modes from ${opts.agentName} (${modes.availableModes.length}), current=${modes.currentModeId}:`);
          for (const mode of modes.availableModes) {
            logAcp('muted', `  mode=${mode.id} name=${mode.name}${formatOptionalDetail(mode.description, 160)}`);
          }
        }
        session.updateMetadata((currentMetadata) =>
          withSessionConfig(currentMetadata, { modes }),
        );
      }
    }

    if (msg.type === 'event' && msg.name === 'models_update') {
      const models = extractModelStateFromPayload(msg.payload);
      if (models) {
        legacyModels = models;
        sawModels = true;
        if (verbose) {
          logAcp('muted', `Outgoing models from ${opts.agentName} (${models.availableModels.length}), current=${models.currentModelId}:`);
          for (const model of models.availableModels) {
            logAcp('muted', `  model=${model.modelId} name=${model.name}`);
          }
        }
        session.updateMetadata((currentMetadata) =>
          withSessionConfig(currentMetadata, { models }),
        );
      }
    }

    if (msg.type === 'event' && msg.name === 'current_mode_update') {
      const currentModeId = extractCurrentModeIdFromPayload(msg.payload);
      if (currentModeId) {
        if (modeSelector) {
          modeSelector = {
            ...modeSelector,
            currentCode: currentModeId,
          };
        }
        if (legacyModes) {
          legacyModes = {
            ...legacyModes,
            currentModeId,
          };
        }
        session.updateMetadata((currentMetadata) =>
          withSessionConfig(currentMetadata, { currentModeId }),
        );
      }
    }

    if (msg.type === 'status') {
      const suffix = msg.detail ? `: ${msg.detail}` : '';
      const statusLine = `Status: ${msg.status}${suffix}`;
      logAcp('muted', statusLine);
      const nextThinking = msg.status === 'running';
      if (thinking !== nextThinking) {
        thinking = nextThinking;
        session.keepAlive(thinking, 'remote');
      }
      if (msg.status === 'idle') {
        clearPendingTurn();
      }
      if (msg.status === 'stopped' && cancelInFlight) {
        logger.debug(`[${opts.agentName}] Turn cancelled by user; runner keeps running`);
        clearPendingTurn();
      } else if (msg.status === 'error' && currentTurnCancelled) {
        // The prompt the user just cancelled failed on its way out.
        logger.debug(`[${opts.agentName}] Cancelled turn ended with: ${msg.detail ?? 'error'}`);
        clearPendingTurn();
      } else if (msg.status === 'error' || msg.status === 'stopped') {
        stopRunnerFromBackendStatus(msg.status, msg.detail);
      }
    }

    const frontendMessage = formatAcpMessageForFrontend(opts.agentName, msg, verbose);
    if (frontendMessage) {
      logAcp(frontendMessage.kind, frontendMessage.text);
    }

    const envelopes = sessionManager.mapMessage(msg);
    sendEnvelopes(envelopes);
    if (msg.type === 'status' && msg.status === 'error' && envelopes.length === 0 && !currentTurnCancelled) {
      session.sendSessionEvent({
        type: 'message',
        message: `${opts.agentName} error: ${msg.detail?.trim() || 'The agent stopped because of an unknown error.'}`,
      });
    }
    if (msg.type === 'status' && msg.status === 'error') {
      errorReportedForCurrentTurn = true;
    }
  };

  backend.onMessage(onBackendMessage);

  session.onUserMessage((message) => {
    if (!message.content.text) {
      return;
    }

    if (typeof message.meta?.permissionMode === 'string') {
      currentPermissionMode = message.meta.permissionMode;
      logger.debug(`[${opts.agentName}] Requested ACP permission mode: ${currentPermissionMode}`);
    }

    if (message.meta && Object.prototype.hasOwnProperty.call(message.meta, 'model')) {
      currentModel = message.meta.model ?? null;
      logger.debug(`[${opts.agentName}] Requested ACP model: ${currentModel ?? 'null'}`);
    }

    messageQueue.push(message.content.text, {
      permissionMode: currentPermissionMode,
      model: currentModel,
    });
  });
  session.keepAlive(thinking, 'remote');

  const keepAliveInterval = setInterval(() => {
    session.keepAlive(thinking, 'remote');
  }, 2000);
  // Forward finished paragraphs of long streamed text while the turn runs,
  // instead of only when the text ends.
  const streamFlushInterval = setInterval(() => {
    sendEnvelopes(sessionManager.flushCompleteParagraphs());
  }, 1000);

  async function handleAbort() {
    try {
      if (acpSessionId) {
        if (pendingTurn) {
          currentTurnCancelled = true;
        }
        cancelInFlight = true;
        try {
          await backend.cancel(acpSessionId);
        } finally {
          cancelInFlight = false;
        }
        // The turn is over for the user even if the agent never says so.
        clearPendingTurn();
      }
      permissionHandler.reset();
      abortController.abort();
    } catch (error) {
      logger.debug(`[${opts.agentName}] Abort failed:`, error);
    } finally {
      abortController = new AbortController();
    }
  }

  session.rpcHandlerManager.registerHandler('abort', handleAbort);
  registerKillSessionHandler(session.rpcHandlerManager, async () => {
    shouldExit = true;
    messageQueue.close();
    clearPendingTurn(new Error('Session terminated'));
    await handleAbort();
  });

  try {
    const started = await backend.startSession();
    acpSessionId = started.sessionId;
    if (flavor === 'opencode') {
      // Recorded so the session can be resumed later (app Resume, `happy resume`).
      session.updateMetadata((currentMetadata) => ({
        ...currentMetadata,
        opencodeSessionId: started.acpSessionId,
      }));
    }
    if (started.opening.kind === 'resumed') {
      logAcp('muted', `Resumed ${opts.agentName} session ${started.acpSessionId} (${started.opening.method})`);
    }
    if (started.opening.kind === 'resume-failed') {
      const notice = `Could not resume the previous ${opts.agentName} session, so a new one was started and ${opts.agentName} will not remember the earlier conversation. ${started.opening.reason}`;
      logAcp('error', notice);
      session.sendSessionEvent({ type: 'message', message: notice });
    }
    if (verbose) {
      if (!sawSlashCommands) {
        logAcp('muted', `Outgoing slash commands from ${opts.agentName}: not reported yet`);
      }
      if (!sawModes) {
        logAcp('muted', `Outgoing modes from ${opts.agentName}: not reported yet`);
      }
      if (!sawModels) {
        logAcp('muted', `Outgoing models from ${opts.agentName}: not reported yet`);
      }
    }

    while (!shouldExit) {
      const waitSignal = abortController.signal;
      const batch = await messageQueue.waitForMessagesAndGetAsString(waitSignal);
      if (!batch) {
        if (shouldExit) {
          break;
        }
        if (waitSignal.aborted) {
          continue;
        }
        break;
      }

      if (!acpSessionId) {
        throw new Error('ACP session is not started');
      }

      logAcp('incoming', `Incoming prompt: ${formatUnknownForConsole(batch.message, ACP_EVENT_PREVIEW_CHARS)}`);
      errorReportedForCurrentTurn = false;
      currentTurnCancelled = false;
      sendEnvelopes(sessionManager.startTurn());
      const turnEnded = waitForTurnEnd();
      try {
        if (typeof batch.mode.permissionMode === 'string' && batch.mode.permissionMode.length > 0) {
          if (flavor === 'opencode') {
            await applyOpencodeMode(batch.mode.permissionMode);
          } else {
            await switchPermissionModeIfRequested(batch.mode.permissionMode);
          }
        }
        if (typeof batch.mode.model === 'string' && batch.mode.model.length > 0) {
          await switchModelIfRequested(batch.mode.model);
        }
        await backend.sendPrompt(acpSessionId, batch.message);
        await turnEnded;
        sendEnvelopes(sessionManager.endTurn(currentTurnCancelled ? 'cancelled' : 'completed'));
        currentTurnCancelled = false;
        session.sendSessionEvent({ type: 'ready' });
        if (verbose) {
          logAcp('muted', `Outgoing prompt completion from ${opts.agentName}`);
        }
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        if (currentTurnCancelled && !shouldExit) {
          logger.debug(`[${opts.agentName}] Cancelled prompt ended with: ${detail}`);
          clearPendingTurn();
          await turnEnded.catch(() => {});
          sendEnvelopes(sessionManager.endTurn('cancelled'));
          currentTurnCancelled = false;
          session.sendSessionEvent({ type: 'ready' });
          continue;
        }
        if (!errorReportedForCurrentTurn) {
          session.sendSessionEvent({
            type: 'message',
            message: `${opts.agentName} error: ${detail}`,
          });
          errorReportedForCurrentTurn = true;
        }
        sendEnvelopes(sessionManager.endTurn('failed'));
        session.sendSessionEvent({ type: 'ready' });
        logAcp('error', `Prompt error from ${opts.agentName}: ${detail}`);
        clearPendingTurn(error instanceof Error ? error : new Error(String(error)));
        await turnEnded.catch(() => {});
        throw error;
      }
    }
  } finally {
    clearInterval(keepAliveInterval);
    clearInterval(streamFlushInterval);
    reconnectionHandle?.cancel();
    clearPendingTurn(new Error('ACP runner shutting down'));

    try {
      permissionHandler.reset();
    } catch (error) {
      logger.debug(`[${opts.agentName}] Failed to reset permission handler:`, error);
    }

    backend.offMessage?.(onBackendMessage);
    await backend.dispose();

    try {
      happyServer.stop();
    } catch (error) {
      logger.debug(`[${opts.agentName}] Failed to stop Happy MCP server:`, error);
    }

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
      logger.debug(`[${opts.agentName}] Session close failed:`, error);
    }
  }
}
