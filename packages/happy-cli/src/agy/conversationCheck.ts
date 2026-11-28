/**
 * Asks agy, before a resumed session's first turn, whether the conversation it
 * is about to continue still exists.
 *
 * `agy --print --conversation <id>` does not fail for an unknown id: it warns
 * and starts a new conversation. agy's ACP server lists saved conversations
 * without touching the model, so a short-lived `agy acp` answers the question
 * up front. Anything short of a clear answer (not signed in, an agy without
 * `session/list`, a timeout) is "unknown", and the turn itself checks again.
 */

import { spawn } from 'node:child_process';
import { resolveAgyBin } from './constants';

/** Sends one JSON-RPC request to `agy acp` and resolves with its result. */
export type AcpRequest = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/** Runs `work` against a live `agy acp` process and shuts the process down after. */
export type AcpRunner = <T>(work: (request: AcpRequest) => Promise<T>) => Promise<T>;

export type AgyConversationCheck =
  | { status: 'present'; cwd?: string }
  | { status: 'missing' }
  | { status: 'unknown'; reason: string };

type AcpSessionInfo = { sessionId?: unknown; cwd?: unknown };

/** `session/list` is paged; stop after this many pages and call it unknown. */
const MAX_LIST_PAGES = 50;

export async function checkAgyConversation(
  conversationId: string,
  opts: { runner?: AcpRunner; timeoutMs?: number } = {},
): Promise<AgyConversationCheck> {
  const runner = opts.runner ?? ((work) => runAgyAcp(work, opts.timeoutMs ?? 15_000));
  try {
    return await runner(async (request) => {
      await request('initialize', { protocolVersion: 1, clientCapabilities: {} });
      let cursor: string | undefined;
      for (let page = 0; page < MAX_LIST_PAGES; page++) {
        const result = await request('session/list', cursor ? { cursor } : {}) as {
          sessions?: AcpSessionInfo[];
          nextCursor?: unknown;
        } | null;
        const match = result?.sessions?.find((entry) => entry.sessionId === conversationId);
        if (match) {
          return { status: 'present', cwd: typeof match.cwd === 'string' ? match.cwd : undefined };
        }
        if (typeof result?.nextCursor !== 'string' || !result.nextCursor) {
          return { status: 'missing' };
        }
        cursor = result.nextCursor;
      }
      return { status: 'unknown', reason: 'too many pages of conversations' };
    });
  } catch (error) {
    return { status: 'unknown', reason: error instanceof Error ? error.message : String(error) };
  }
}

/** The default runner: `agy acp` over newline-delimited JSON-RPC on stdio. */
export function runAgyAcp<T>(work: (request: AcpRequest) => Promise<T>, timeoutMs: number): Promise<T> {
  const child = spawn(resolveAgyBin(), ['acp'], {
    env: process.env,
    windowsHide: true,
    stdio: ['pipe', 'pipe', 'ignore'],
  });
  const pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
  let nextId = 1;
  let buffered = '';

  const failAll = (error: Error) => {
    for (const { reject } of pending.values()) reject(error);
    pending.clear();
  };

  child.stdout?.setEncoding('utf8');
  child.stdout?.on('data', (chunk: string) => {
    buffered += chunk;
    let newline: number;
    while ((newline = buffered.indexOf('\n')) >= 0) {
      const line = buffered.slice(0, newline).trim();
      buffered = buffered.slice(newline + 1);
      if (!line) continue;
      let message: { id?: unknown; result?: unknown; error?: { code?: number; message?: string } };
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      // Requests and notifications from the agent carry a method; only
      // responses to our own requests matter here.
      if (typeof message.id !== 'number' || 'method' in message) continue;
      const waiter = pending.get(message.id);
      if (!waiter) continue;
      pending.delete(message.id);
      if (message.error) {
        waiter.reject(new Error(`agy acp error ${message.error.code ?? ''}: ${message.error.message ?? 'unknown'}`.trim()));
      } else {
        waiter.resolve(message.result);
      }
    }
  });
  // A write after agy exits fails with EPIPE; the close below rejects the request.
  child.stdin?.on('error', () => {});
  child.on('error', (error) => failAll(error));
  child.on('close', () => failAll(new Error('agy acp exited')));

  const request: AcpRequest = (method, params) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    child.stdin?.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });

  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`agy acp did not answer within ${timeoutMs}ms`)), timeoutMs);
  });

  return Promise.race([work(request), timeout]).finally(() => {
    clearTimeout(timer);
    child.stdin?.end();
    child.kill('SIGTERM');
  });
}
