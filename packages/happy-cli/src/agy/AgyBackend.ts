/**
 * Agy AgentBackend Implementation
 *
 * Custom AgentBackend that drives the agy (Antigravity) CLI. Unlike the ACP-based
 * backends, agy has no streaming-event protocol — its only non-interactive surface
 * is `agy --print "<prompt>"`, which streams the final answer as plain text and
 * exits. So this backend spawns one `agy --print` process per turn and maps:
 *
 *   spawn            → { type: 'status', status: 'running' }
 *   stdout chunk     → { type: 'model-output', textDelta }
 *   exit code 0      → { type: 'status', status: 'idle' }
 *   exit code != 0   → { type: 'status', status: 'error', detail }
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

/**
 * What an unauthenticated agy prints to stderr in print mode. It then waits 60s
 * for an OAuth code on stdin, which a headless turn can never supply.
 */
const AGY_AUTH_REQUIRED_PATTERN = /Authentication required\. Please visit the URL to log in|You are not logged into Antigravity/;

/** Error shown instead of the OAuth URL when agy has no stored login. */
export const AGY_LOGIN_REQUIRED_DETAIL =
  'Antigravity is not signed in on this machine. Run `agy` once in a terminal on this machine and complete the Google sign-in, then send the message again.';

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
  /** Optional override for resolving the resume conversation id (tests). */
  resolveConversationId?: (cwd: string) => string | null;
  /** agy conversation to continue from the first turn (`happy agy --resume <id>`). */
  conversationId?: string | null;
  /** Called once the backend knows which agy conversation this session uses. */
  onConversationId?: (conversationId: string) => void;
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
  private readonly onConversationId: (conversationId: string) => void;

  private permissionMode: PermissionMode;
  private model?: string;
  private effort?: string;
  private conversationId: string | null = null;
  private child: ChildProcess | null = null;

  constructor(opts: AgyBackendOptions) {
    this.cwd = opts.cwd;
    this.permissionMode = opts.permissionMode;
    this.model = opts.model;
    this.effort = opts.effort;
    this.printTimeout = opts.printTimeout ?? AGY_PRINT_TIMEOUT;
    this.log = opts.log ?? (() => {});
    this.spawnFn = opts.spawnFn ?? spawn;
    this.resolveConversationId = opts.resolveConversationId ?? readAgyConversationId;
    this.onConversationId = opts.onConversationId ?? (() => {});
    this.conversationId = opts.conversationId ?? null;
  }

  /** The agy conversation this session continues, once known. */
  getConversationId(): string | null {
    return this.conversationId;
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
    // a resumed one is handed its own id explicitly (options.conversationId).
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

    // Until we have pinned our own conversation, snapshot the cwd cache so we can
    // tell after the turn whether the entry is ours (changed → our turn wrote it)
    // or a leftover from another session (unchanged → not ours to adopt).
    const preTurnCacheId =
      this.conversationId === null ? this.resolveConversationId(this.cwd) : null;

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
      let authRequired = false;
      const watchdog = setTimeout(() => {
        this.log(`agy turn exceeded ${this.printTimeout}; killing process`);
        child.kill('SIGKILL');
      }, parsePrintTimeoutMs(this.printTimeout) + 30_000);
      const cleanup = () => {
        clearTimeout(watchdog);
        if (this.child === child) {
          this.child = null;
        }
      };

      child.stdout?.setEncoding('utf8');
      child.stdout?.on('data', (chunk: string) => {
        if (chunk) {
          this.emit({ type: 'model-output', textDelta: chunk });
        }
      });

      child.stderr?.setEncoding('utf8');
      child.stderr?.on('data', (chunk: string) => {
        const text = chunk.trimEnd();
        if (text) {
          this.log(`stderr: ${text}`);
        }
        stderrTail = `${stderrTail}${chunk}`.slice(-MAX_AGY_ERROR_DETAIL_CHARS * 2);
        if (!authRequired && AGY_AUTH_REQUIRED_PATTERN.test(stderrTail)) {
          // Without a login agy waits a minute for a code nobody can type here.
          authRequired = true;
          this.log('agy is not signed in; stopping the turn');
          child.kill('SIGTERM');
        }
      });

      child.on('error', (err: Error) => {
        if (settled) return;
        settled = true;
        cleanup();
        const detail = (err as NodeJS.ErrnoException).code === 'ENOENT'
          ? `agy executable not found. Install the Antigravity CLI (curl -fsSL https://antigravity.google/cli/install.sh | bash), or set HAPPY_AGY_PATH to its absolute path (tried 'agy' on PATH and ~/.local/bin/agy).`
          : err.message;
        this.emit({ type: 'status', status: 'error', detail });
        reject(err);
      });

      child.on('close', (code: number | null) => {
        if (settled) return;
        settled = true;
        cleanup();
        // Pin the conversation our first turn created so later turns resume it.
        // Once pinned, never re-read the cache: another session in the same cwd
        // may have updated it since, and adopting that id would cross-resume.
        // Best effort while unpinned: any concurrent same-cwd write that differs
        // from the pre-turn snapshot (another session's turn, or bare interactive
        // agy) would be adopted just the same — agy doesn't echo the id it
        // created, so we cannot attribute the cache entry more precisely.
        // Deliberately runs on failed turns too: agy may have created the
        // conversation before the turn errored, and resuming it keeps context.
        if (this.conversationId === null) {
          const cid = this.resolveConversationId(this.cwd);
          if (cid && cid !== preTurnCacheId) {
            this.conversationId = cid;
            this.log(`pinned agy conversation ${cid}`);
            this.onConversationId(cid);
          } else {
            this.log('agy conversation cache unchanged after turn; not adopting (will retry next turn)');
          }
        }

        if (authRequired) {
          this.emit({ type: 'status', status: 'error', detail: AGY_LOGIN_REQUIRED_DETAIL });
          reject(new Error(AGY_LOGIN_REQUIRED_DETAIL));
        } else if (code === 0) {
          this.emit({ type: 'status', status: 'idle' });
          resolve();
        } else {
          const stderrDetail = cleanAgyErrorOutput(stderrTail);
          const detail = stderrDetail
            ? `agy exited with code ${code ?? 'null'}: ${stderrDetail}`
            : `agy exited with code ${code ?? 'null'}`;
          this.emit({ type: 'status', status: 'error', detail });
          reject(new Error(detail));
        }
      });
    });
  }

  async cancel(_sessionId?: SessionId): Promise<void> {
    if (this.child) {
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
