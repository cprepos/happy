/**
 * Agy AgentBackend Implementation
 *
 * Custom AgentBackend that drives the agy (Antigravity) CLI. This backend spawns
 * one `agy --print "<prompt>" --output-format stream-json` process per turn and
 * maps:
 *
 *   spawn            → { type: 'status', status: 'running' }
 *   result event     → { type: 'model-output', textDelta: result.response }
 *   exit code 0      → { type: 'status', status: 'idle' }
 *   exit code != 0   → { type: 'status', status: 'error', detail }
 *
 * The result event also names the conversation agy used, which the backend pins
 * so later turns (and a resumed session) continue it.
 *
 * There are no tool-call or permission events: print mode is one-shot and governed
 * by the CLI flags (see cliArgs.ts) plus agy's own settings.json.
 */

import { spawn, type ChildProcess } from 'node:child_process';
import type { PermissionMode } from '@/api/types';
import type {
  AgentBackend,
  AgentMessage,
  AgentMessageHandler,
  SessionId,
  StartSessionResult,
} from '@/agent/core/AgentBackend';
import { resolveAgyBin, AGY_PRINT_TIMEOUT, resolveAgyModelName } from './constants';
import { buildAgyArgs } from './cliArgs';
import { readAgyConversationId } from './conversationStore';

/** Signature of node's `spawn`, injectable so tests can supply a fake process. */
export type SpawnFn = typeof spawn;

const MAX_AGY_ERROR_DETAIL_CHARS = 2_000;

/** What agy prints to stderr, before starting a new conversation, for an unknown `--conversation` id. */
const CONVERSATION_NOT_FOUND = /warning: conversation "([^"]+)" not found/;

function cleanAgyErrorOutput(value: string): string {
  return value
    .replace(/\u001B\[[0-?]*[ -/]*[@-~]/g, '')
    .trim()
    .slice(-MAX_AGY_ERROR_DETAIL_CHARS);
}

export interface AgyBackendOptions {
  /** Working directory the agy process runs in (and the conversation cache key). */
  cwd: string;
  /** Initial permission mode; updated per turn from message meta. */
  permissionMode: PermissionMode;
  /** Initial model display name; updated per turn from message meta. */
  model?: string;
  /** Initial Happy effort key; used to resolve models with agy-specific variants. */
  effort?: string;
  /** Value for `--print-timeout`. Defaults to AGY_PRINT_TIMEOUT. */
  printTimeout?: string;
  /** Optional logger. */
  log?: (msg: string) => void;
  /** Injectable spawn (defaults to node's child_process.spawn). */
  spawnFn?: SpawnFn;
  /**
   * Reads the conversation agy last used in a cwd (its cache). Only a fallback,
   * for a first turn stopped before agy's result names the conversation.
   */
  resolveConversationId?: (cwd: string) => string | null;
  /**
   * agy conversation to continue from the first turn (a resumed session).
   * It comes from this session's own metadata, never from the cwd cache.
   */
  conversationId?: string;
  /**
   * Called when the backend pins a conversation: the one a fresh session's
   * first turn created, or the one agy used instead of the conversation the
   * turn asked for (`previousConversationId`), whose context is then lost.
   */
  onConversationId?: (conversationId: string, previousConversationId?: string) => void;
  /** How often the cache is read while a fresh session's first turn runs. Defaults to 1s. */
  cachePollMs?: number;
}

/** Parse an agy duration string ("10m", "30s", "1h") to milliseconds; defaults to 10m. */
function parsePrintTimeoutMs(value: string): number {
  const m = /^(\d+)\s*(s|m|h)$/.exec(value.trim());
  if (!m) return 10 * 60_000;
  const n = Number(m[1]);
  return m[2] === 'h' ? n * 3_600_000 : m[2] === 'm' ? n * 60_000 : n * 1_000;
}

export class AgyBackend implements AgentBackend {
  private readonly handlers = new Set<AgentMessageHandler>();
  private readonly cwd: string;
  private readonly printTimeout: string;
  private readonly log: (msg: string) => void;
  private readonly spawnFn: SpawnFn;
  private readonly resolveConversationId: (cwd: string) => string | null;
  private readonly onConversationId?: (conversationId: string, previousConversationId?: string) => void;
  private readonly cachePollMs: number;

  private permissionMode: PermissionMode;
  private model?: string;
  private effort?: string;
  private conversationId: string | null = null;
  private child: ChildProcess | null = null;
  /** Reads the cache for the turn in flight, so a stop can pin before the kill. */
  private checkTurnCache: (() => void) | null = null;

  constructor(opts: AgyBackendOptions) {
    this.cwd = opts.cwd;
    this.permissionMode = opts.permissionMode;
    this.model = opts.model;
    this.effort = opts.effort;
    this.printTimeout = opts.printTimeout ?? AGY_PRINT_TIMEOUT;
    this.log = opts.log ?? (() => {});
    this.spawnFn = opts.spawnFn ?? spawn;
    this.resolveConversationId = opts.resolveConversationId ?? readAgyConversationId;
    this.onConversationId = opts.onConversationId;
    this.cachePollMs = opts.cachePollMs ?? 1_000;
    this.conversationId = opts.conversationId ?? null;
  }

  /** Update the permission mode applied to subsequent turns. */
  setPermissionMode(mode: PermissionMode): void {
    this.permissionMode = mode;
  }

  /** Update the model applied to subsequent turns. */
  setModel(model: string | undefined): void {
    this.model = model;
  }

  /** Update the effort applied to subsequent turns. */
  setEffort(effort: string | undefined): void {
    this.effort = effort;
  }

  async startSession(): Promise<StartSessionResult> {
    // agy spawns lazily per prompt; there is nothing long-lived to start.
    // Deliberately do NOT seed from the cwd conversation cache: it holds whatever
    // conversation last ran in this cwd — possibly another live session's — so
    // seeding would cross-resume it. A fresh session starts a fresh conversation;
    // a resumed one continues the id it was given (`conversationId`), which comes
    // from its own persisted metadata.
    return { sessionId: this.cwd };
  }

  async sendPrompt(_sessionId: SessionId, prompt: string): Promise<void> {
    const args = buildAgyArgs({
      prompt,
      model: this.model ? resolveAgyModelName(this.model, this.effort) : undefined,
      conversationId: this.conversationId,
      permissionMode: this.permissionMode,
      addDirs: [this.cwd],
      printTimeout: this.printTimeout,
    });

    this.emit({ type: 'status', status: 'running' });

    const requestedConversationId = this.conversationId;
    // Set when agy reports that the conversation we asked for is gone.
    let lostConversationId: string | null = null;
    // The conversation agy's result event says this turn used.
    let resultConversationId: string | null = null;
    let resultError: string | null = null;

    const pin = (cid: string) => {
      if (cid === this.conversationId) return;
      this.conversationId = cid;
      // Asking for one conversation and getting another means agy started a
      // new one: the earlier context is gone, and the caller should say so.
      const lost = requestedConversationId !== null && cid !== requestedConversationId
        ? requestedConversationId
        : undefined;
      this.log(lost
        ? `agy used conversation ${cid} instead of ${lost}; pinned the new one`
        : `pinned agy conversation ${cid}`);
      this.onConversationId?.(cid, lost);
    };

    // Fallback for a fresh session's first turn: agy writes the cwd cache when
    // the conversation starts, so a stop or restart before the result event
    // still pins it. Only a change seen while our child runs is attributed to
    // it. Best effort: a concurrent same-cwd agy writing in that window is
    // adopted just the same, until this turn's result corrects it.
    const watchCache = requestedConversationId === null;
    const preTurnCacheId = watchCache ? this.resolveConversationId(this.cwd) : null;
    const checkCache = () => {
      if (this.conversationId !== null || resultConversationId) return;
      const cid = this.resolveConversationId(this.cwd);
      if (cid && cid !== preTurnCacheId) pin(cid);
    };

    await new Promise<void>((resolve, reject) => {
      const child = this.spawnFn(resolveAgyBin(), args, {
        cwd: this.cwd,
        env: process.env,
        windowsHide: true,
        // agy --print blocks until stdin reaches EOF. We never write stdin, so
        // give the child an empty stdin (immediate EOF) instead of an open pipe;
        // otherwise it hangs forever and the turn never completes.
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      this.child = child;

      // Node can fire both 'error' and 'close' on spawn failure; act on the first only.
      let settled = false;
      let stderrTail = '';
      let stdoutBuffer = '';
      const watchdog = setTimeout(() => {
        this.log(`agy turn exceeded ${this.printTimeout}; killing process`);
        child.kill('SIGKILL');
      }, parsePrintTimeoutMs(this.printTimeout) + 30_000);
      const cachePoll = watchCache ? setInterval(checkCache, this.cachePollMs) : null;
      this.checkTurnCache = watchCache ? checkCache : null;
      const cleanup = () => {
        clearTimeout(watchdog);
        if (cachePoll) clearInterval(cachePoll);
        if (this.child === child) {
          this.child = null;
          this.checkTurnCache = null;
        }
      };

      const handleLine = (line: string) => {
        if (!line.trim()) return;
        let event: { event?: unknown; result?: Record<string, unknown> };
        try {
          event = JSON.parse(line);
        } catch {
          // Not an event: an agy without stream-json prints the answer as text.
          this.emit({ type: 'model-output', textDelta: `${line}\n` });
          return;
        }
        if (event?.event !== 'result' || !event.result) return;
        const { response, conversation_id: cid, error } = event.result;
        if (typeof response === 'string' && response) {
          this.emit({ type: 'model-output', textDelta: response });
        }
        if (typeof cid === 'string' && cid) resultConversationId = cid;
        if (typeof error === 'string' && error) resultError = error;
      };

      child.stdout?.setEncoding('utf8');
      child.stdout?.on('data', (chunk: string) => {
        stdoutBuffer += chunk;
        let newline: number;
        while ((newline = stdoutBuffer.indexOf('\n')) >= 0) {
          handleLine(stdoutBuffer.slice(0, newline));
          stdoutBuffer = stdoutBuffer.slice(newline + 1);
        }
      });

      child.stderr?.setEncoding('utf8');
      child.stderr?.on('data', (chunk: string) => {
        const text = chunk.trimEnd();
        if (text) {
          this.log(`stderr: ${text}`);
        }
        stderrTail = `${stderrTail}${chunk}`.slice(-MAX_AGY_ERROR_DETAIL_CHARS * 2);
        // agy answers a missing conversation by quietly starting a new one. Stop
        // the turn instead, so the prompt never runs without the context the
        // user expects, and say so.
        const missing = requestedConversationId && !lostConversationId
          ? CONVERSATION_NOT_FOUND.exec(stderrTail)?.[1]
          : undefined;
        if (missing && missing === requestedConversationId) {
          lostConversationId = missing;
          this.log(`agy conversation ${missing} not found; stopping the turn`);
          child.kill('SIGTERM');
        }
      });

      child.on('error', (err: Error) => {
        if (settled) return;
        settled = true;
        cleanup();
        const detail = (err as NodeJS.ErrnoException).code === 'ENOENT'
          ? `agy executable not found. Install the Antigravity CLI, or set HAPPY_AGY_PATH to its absolute path (tried 'agy' on PATH and ~/.local/bin/agy).`
          : err.message;
        this.emit({ type: 'status', status: 'error', detail });
        reject(err);
      });

      child.on('close', (code: number | null) => {
        if (settled) return;
        settled = true;
        cleanup();
        handleLine(stdoutBuffer);
        stdoutBuffer = '';

        if (lostConversationId) {
          // Forget the dead id: the next turn starts a new conversation and pins
          // it like a fresh session's first turn.
          this.conversationId = null;
          const detail = `Antigravity conversation ${lostConversationId} no longer exists, so its earlier context is not available. Your next message starts a new conversation.`;
          this.emit({ type: 'status', status: 'error', detail });
          reject(new Error(detail));
          return;
        }

        // Pin the conversation agy says it used, on failed turns too: agy may
        // have created it before the turn errored, and resuming it keeps context.
        if (resultConversationId) {
          pin(resultConversationId);
        } else if (watchCache) {
          checkCache();
          if (this.conversationId === null) {
            this.log('agy named no conversation and the cache is unchanged; not pinning (will retry next turn)');
          }
        }

        if (code === 0) {
          this.emit({ type: 'status', status: 'idle' });
          resolve();
        } else {
          const errorDetail = resultError ?? cleanAgyErrorOutput(stderrTail);
          const detail = errorDetail
            ? `agy exited with code ${code ?? 'null'}: ${errorDetail}`
            : `agy exited with code ${code ?? 'null'}`;
          this.emit({ type: 'status', status: 'error', detail });
          reject(new Error(detail));
        }
      });
    });
  }

  async cancel(_sessionId?: SessionId): Promise<void> {
    if (this.child) {
      // Pin before the kill, so a stopped first turn stays resumable.
      this.checkTurnCache?.();
      this.child.kill('SIGTERM');
      this.child = null;
    }
  }

  onMessage(handler: AgentMessageHandler): void {
    this.handlers.add(handler);
  }

  offMessage(handler: AgentMessageHandler): void {
    this.handlers.delete(handler);
  }

  async dispose(): Promise<void> {
    await this.cancel();
    this.handlers.clear();
  }

  private emit(msg: AgentMessage): void {
    for (const handler of this.handlers) {
      handler(msg);
    }
  }
}
