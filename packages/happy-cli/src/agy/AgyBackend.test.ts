import { EventEmitter } from 'node:events';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { AgyBackend, type SpawnFn } from './AgyBackend';
import type { AgentMessage } from '@/agent/core/AgentBackend';

/** Minimal fake of a spawned child process for driving AgyBackend in tests. */
function makeFakeChild() {
  const stdout = new EventEmitter() as EventEmitter & { setEncoding: (e: string) => void };
  const stderr = new EventEmitter() as EventEmitter & { setEncoding: (e: string) => void };
  stdout.setEncoding = () => {};
  stderr.setEncoding = () => {};
  const child = new EventEmitter() as EventEmitter & {
    stdout: typeof stdout;
    stderr: typeof stderr;
    kill: (signal?: string) => boolean;
  };
  child.stdout = stdout;
  child.stderr = stderr;
  child.kill = vi.fn(() => true);
  return { child, stdout, stderr };
}

/**
 * The last stdout line of `agy -p ... --output-format stream-json` (agy 1.5.18),
 * with the usage object trimmed.
 */
function resultLine(conversationId: string, extra: Record<string, unknown> = {}) {
  return `${JSON.stringify({
    event: 'result',
    result: {
      conversation_id: conversationId,
      status: 'SUCCESS',
      response: 'OK\n',
      duration_seconds: 3.43,
      num_turns: 1,
      ...extra,
    },
  })}\n`;
}

describe('AgyBackend', () => {
  it('maps the logical Gemini model and effort to the agy model display name', async () => {
    const { child } = makeFakeChild();
    const spawnFn = vi.fn(() => child) as unknown as SpawnFn;
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      model: 'Gemini 3.8 Flash',
      effort: 'medium',
      spawnFn,
      resolveConversationId: () => null,
    });

    backend.setEffort('high');
    const turn = backend.sendPrompt('/work', 'hi');
    child.emit('close', 0);
    await turn;

    const args = (spawnFn as unknown as ReturnType<typeof vi.fn>).mock.calls[0][1] as string[];
    const modelIndex = args.indexOf('--model');
    expect(args[modelIndex + 1]).toBe('Gemini 3.8 Flash (High)');
  });

  it('maps a successful turn: running → model-output(s) → idle', async () => {
    const { child, stdout } = makeFakeChild();
    const spawnFn = vi.fn(() => child) as unknown as SpawnFn;

    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => null,
    });

    const messages: AgentMessage[] = [];
    backend.onMessage((m) => messages.push(m));

    await backend.startSession();
    const turn = backend.sendPrompt('/work', 'hi');

    // Events arrive as NDJSON, split anywhere; only the result carries text.
    const line = resultLine('62cbe556-f8a3-411b-b752-345289e34067');
    stdout.emit('data', '{"event":"init"}\n' + line.slice(0, 30));
    stdout.emit('data', line.slice(30));
    child.emit('close', 0);

    await expect(turn).resolves.toBeUndefined();

    const types = messages.map((m) => m.type);
    expect(types[0]).toBe('status');
    expect(messages[0]).toMatchObject({ type: 'status', status: 'running' });
    // agy --print hangs unless stdin is closed: spawn must give the child an
    // empty stdin (immediate EOF), not an open pipe.
    const spawnOpts = (spawnFn as unknown as ReturnType<typeof vi.fn>).mock.calls[0][2];
    expect(spawnOpts.stdio).toEqual(['ignore', 'pipe', 'pipe']);

    expect(messages.filter((m) => m.type === 'model-output')).toEqual([
      { type: 'model-output', textDelta: 'OK\n' },
    ]);
    expect(messages.at(-1)).toMatchObject({ type: 'status', status: 'idle' });
  });

  it('passes plain text through from an agy that prints no events', async () => {
    const { child, stdout } = makeFakeChild();
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn: vi.fn(() => child) as unknown as SpawnFn,
      resolveConversationId: () => null,
    });
    const messages: AgentMessage[] = [];
    backend.onMessage((m) => messages.push(m));

    const turn = backend.sendPrompt('/work', 'hi');
    stdout.emit('data', 'Hello\nwor');
    stdout.emit('data', 'ld');
    child.emit('close', 0);
    await turn;

    expect(messages.filter((m) => m.type === 'model-output')).toEqual([
      { type: 'model-output', textDelta: 'Hello\n' },
      { type: 'model-output', textDelta: 'world\n' },
    ]);
  });

  it('reports the error agy\'s result names, and still pins the conversation', async () => {
    const { child, stdout, stderr } = makeFakeChild();
    const pinned: string[] = [];
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn: vi.fn(() => child) as unknown as SpawnFn,
      resolveConversationId: () => null,
      onConversationId: (id) => pinned.push(id),
    });

    const turn = backend.sendPrompt('/work', 'hi');
    stderr.emit('data', 'some progress noise\n');
    stdout.emit('data', resultLine('new-cid', { status: 'ERROR', response: '', error: 'quota exhausted', finished_reason: 'error' }));
    child.emit('close', 3);

    await expect(turn).rejects.toThrow('agy exited with code 3: quota exhausted');
    expect(pinned).toEqual(['new-cid']);
  });

  it('emits an error status and rejects on non-zero exit', async () => {
    const { child, stderr } = makeFakeChild();
    const spawnFn = vi.fn(() => child) as unknown as SpawnFn;

    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => null,
    });
    const messages: AgentMessage[] = [];
    backend.onMessage((m) => messages.push(m));

    await backend.startSession();
    const turn = backend.sendPrompt('/work', 'hi');
    stderr.emit('data', '\u001b[31mUnknown model Gemini 3.8 Flash\u001b[0m\n');
    child.emit('close', 1);

    await expect(turn).rejects.toThrow(/exited with code 1: Unknown model Gemini 3\.8 Flash/);
    expect(messages.at(-1)).toMatchObject({
      type: 'status',
      status: 'error',
      detail: 'agy exited with code 1: Unknown model Gemini 3.8 Flash',
    });
  });

  it('resumes the captured conversation id on the next turn', async () => {
    const spawnCalls: string[][] = [];
    let current = makeFakeChild();
    const spawnFn = vi.fn((_bin: string, args: string[]) => {
      spawnCalls.push(args);
      return current.child;
    }) as unknown as SpawnFn;

    // No conversation at start; agy records one after the first turn.
    let recorded: string | null = null;
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => recorded,
    });

    await backend.startSession();

    // First turn: fresh (no --conversation), then a conversation id appears.
    const t1 = backend.sendPrompt('/work', 'first');
    recorded = 'cid-xyz';
    current.child.emit('close', 0);
    await t1;

    expect(spawnCalls[0]).not.toContain('--conversation');

    // Second turn: resumes the captured id.
    current = makeFakeChild();
    const t2 = backend.sendPrompt('/work', 'second');
    current.child.emit('close', 0);
    await t2;

    const idx = spawnCalls[1].indexOf('--conversation');
    expect(idx).toBeGreaterThanOrEqual(0);
    expect(spawnCalls[1][idx + 1]).toBe('cid-xyz');
  });

  it('starts fresh instead of resuming a pre-existing cwd conversation (cross-resume guard)', async () => {
    const spawnCalls: string[][] = [];
    let current = makeFakeChild();
    const spawnFn = vi.fn((_bin: string, args: string[]) => {
      spawnCalls.push(args);
      return current.child;
    }) as unknown as SpawnFn;

    // The cwd cache already holds a conversation from another (possibly live) session.
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => 'other-sessions-conversation',
    });

    await backend.startSession();

    const t1 = backend.sendPrompt('/work', 'first');
    current.child.emit('close', 0);
    await t1;
    expect(spawnCalls[0]).not.toContain('--conversation');

    // The cache entry never changed, so it was not ours to adopt.
    current = makeFakeChild();
    const t2 = backend.sendPrompt('/work', 'second');
    current.child.emit('close', 0);
    await t2;
    expect(spawnCalls[1]).not.toContain('--conversation');
  });

  it('adopts the id recorded during the first turn even when a stale entry existed', async () => {
    const spawnCalls: string[][] = [];
    let current = makeFakeChild();
    const spawnFn = vi.fn((_bin: string, args: string[]) => {
      spawnCalls.push(args);
      return current.child;
    }) as unknown as SpawnFn;

    let recorded: string | null = 'stale-old';
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => recorded,
    });

    await backend.startSession();

    const t1 = backend.sendPrompt('/work', 'first');
    recorded = 'fresh-1'; // our turn created a new conversation
    current.child.emit('close', 0);
    await t1;
    expect(spawnCalls[0]).not.toContain('--conversation');

    current = makeFakeChild();
    const t2 = backend.sendPrompt('/work', 'second');
    current.child.emit('close', 0);
    await t2;
    const idx = spawnCalls[1].indexOf('--conversation');
    expect(idx).toBeGreaterThanOrEqual(0);
    expect(spawnCalls[1][idx + 1]).toBe('fresh-1');
  });

  it('re-snapshots the cache every turn while unpinned: a foreign write between turns is not adopted', async () => {
    const spawnCalls: string[][] = [];
    let current = makeFakeChild();
    const spawnFn = vi.fn((_bin: string, args: string[]) => {
      spawnCalls.push(args);
      return current.child;
    }) as unknown as SpawnFn;

    let recorded: string | null = 'stale-S';
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => recorded,
    });

    await backend.startSession();

    // Turn 1: cache stays at the stale value → nothing to adopt.
    const t1 = backend.sendPrompt('/work', 'first');
    current.child.emit('close', 0);
    await t1;

    // While idle, a foreign session writes a new id. If the backend kept using
    // turn 1's snapshot ('stale-S'), turn 2's close would mis-adopt 'foreign-F'.
    recorded = 'foreign-F';

    current = makeFakeChild();
    const t2 = backend.sendPrompt('/work', 'second');
    current.child.emit('close', 0);
    await t2;

    current = makeFakeChild();
    const t3 = backend.sendPrompt('/work', 'third');
    current.child.emit('close', 0);
    await t3;

    for (const call of spawnCalls) {
      expect(call).not.toContain('--conversation');
    }
  });

  it('keeps the pinned conversation when another session updates the cache', async () => {
    const spawnCalls: string[][] = [];
    let current = makeFakeChild();
    const spawnFn = vi.fn((_bin: string, args: string[]) => {
      spawnCalls.push(args);
      return current.child;
    }) as unknown as SpawnFn;

    let recorded: string | null = null;
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => recorded,
    });

    await backend.startSession();

    const t1 = backend.sendPrompt('/work', 'first');
    recorded = 'mine';
    current.child.emit('close', 0);
    await t1;

    // A second agy session in the same cwd finishes a turn: cache now points elsewhere.
    recorded = 'theirs';

    current = makeFakeChild();
    const t2 = backend.sendPrompt('/work', 'second');
    current.child.emit('close', 0);
    await t2;

    current = makeFakeChild();
    const t3 = backend.sendPrompt('/work', 'third');
    current.child.emit('close', 0);
    await t3;

    for (const call of [spawnCalls[1], spawnCalls[2]]) {
      const idx = call.indexOf('--conversation');
      expect(idx).toBeGreaterThanOrEqual(0);
      expect(call[idx + 1]).toBe('mine');
    }
  });

  it('continues a resumed conversation from the first turn and never reads the cache for it', async () => {
    const spawnCalls: string[][] = [];
    let current = makeFakeChild();
    const spawnFn = vi.fn((_bin: string, args: string[]) => {
      spawnCalls.push(args);
      return current.child;
    }) as unknown as SpawnFn;

    // The cwd cache names another session's conversation; it must not matter.
    const resolveConversationId = vi.fn(() => 'other-session-cid');
    const pinned: string[] = [];
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      conversationId: 'resumed-cid',
      resolveConversationId,
      onConversationId: (id) => pinned.push(id),
    });

    await backend.startSession();

    for (const prompt of ['first', 'second']) {
      current = makeFakeChild();
      const turn = backend.sendPrompt('/work', prompt);
      current.stdout.emit('data', resultLine('resumed-cid'));
      current.child.emit('close', 0);
      await turn;
    }

    for (const args of spawnCalls) {
      const idx = args.indexOf('--conversation');
      expect(idx).toBeGreaterThanOrEqual(0);
      expect(args[idx + 1]).toBe('resumed-cid');
    }
    expect(pinned).toEqual([]);
    expect(resolveConversationId).not.toHaveBeenCalled();
  });

  it('reports a freshly pinned conversation once, so it can be persisted', async () => {
    let current = makeFakeChild();
    const spawnFn = vi.fn(() => current.child) as unknown as SpawnFn;

    let recorded: string | null = 'stale-cid';
    const pinned: string[] = [];
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => recorded,
      onConversationId: (id) => pinned.push(id),
    });

    const t1 = backend.sendPrompt('/work', 'first');
    recorded = 'new-cid';
    current.child.emit('close', 0);
    await t1;

    current = makeFakeChild();
    const t2 = backend.sendPrompt('/work', 'second');
    recorded = 'someone-else-cid';
    current.child.emit('close', 0);
    await t2;

    expect(pinned).toEqual(['new-cid']);
  });

  it('does not report the stale cwd entry it refused to adopt', async () => {
    const { child } = makeFakeChild();
    const spawnFn = vi.fn(() => child) as unknown as SpawnFn;
    const pinned: string[] = [];
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => 'stale-cid',
      onConversationId: (id) => pinned.push(id),
    });

    const turn = backend.sendPrompt('/work', 'first');
    child.emit('close', 0);
    await turn;

    expect(pinned).toEqual([]);
  });

  it('pins the conversation agy used instead of the one it was asked for, and names the lost one', async () => {
    const spawnCalls: string[][] = [];
    let current = makeFakeChild();
    const spawnFn = vi.fn((_bin: string, args: string[]) => {
      spawnCalls.push(args);
      return current.child;
    }) as unknown as SpawnFn;

    const pinned: Array<[string, string | undefined]> = [];
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      conversationId: 'resumed-cid',
      resolveConversationId: () => null,
      onConversationId: (id, previous) => pinned.push([id, previous]),
    });

    const t1 = backend.sendPrompt('/work', 'first');
    current.stdout.emit('data', resultLine('replacement-cid'));
    current.child.emit('close', 0);
    await t1;

    current = makeFakeChild();
    const t2 = backend.sendPrompt('/work', 'second');
    current.stdout.emit('data', resultLine('replacement-cid'));
    current.child.emit('close', 0);
    await t2;

    expect(pinned).toEqual([['replacement-cid', 'resumed-cid']]);
    expect(spawnCalls[1][spawnCalls[1].indexOf('--conversation') + 1]).toBe('replacement-cid');
  });

  it('corrects a foreign conversation the cache fallback adopted once the result names ours', async () => {
    const { child, stdout } = makeFakeChild();
    let recorded: string | null = null;
    const pinned: Array<[string, string | undefined]> = [];
    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn: vi.fn(() => child) as unknown as SpawnFn,
      resolveConversationId: () => recorded,
      onConversationId: (id, previous) => pinned.push([id, previous]),
      cachePollMs: 10,
    });

    vi.useFakeTimers();
    try {
      const turn = backend.sendPrompt('/work', 'first');
      // Another agy in the same cwd writes the cache while our turn runs.
      recorded = 'concurrent-cid';
      await vi.advanceTimersByTimeAsync(10);
      stdout.emit('data', resultLine('our-cid'));
      child.emit('close', 0);
      await turn;
    } finally {
      vi.useRealTimers();
    }

    expect(pinned).toEqual([['concurrent-cid', undefined], ['our-cid', undefined]]);
  });

  describe('when agy reports that the resumed conversation is gone', () => {
    // Captured from agy 1.5.18: `agy -p ... --conversation <unknown id>` prints
    // this to stderr before anything else, then starts a new conversation.
    const DEAD_ID = '00000000-dead-beef-0000-000000000000';
    const NOT_FOUND = `warning: conversation "${DEAD_ID}" not found\n`;

    function resumedBackend(recorded: { id: string | null }) {
      const spawnCalls: string[][] = [];
      const children: ReturnType<typeof makeFakeChild>[] = [];
      const spawnFn = vi.fn((_bin: string, args: string[]) => {
        spawnCalls.push(args);
        const next = makeFakeChild();
        children.push(next);
        return next.child;
      }) as unknown as SpawnFn;
      const pinned: Array<[string, string | undefined]> = [];
      const messages: AgentMessage[] = [];
      const backend = new AgyBackend({
        cwd: '/work',
        permissionMode: 'default',
        spawnFn,
        conversationId: DEAD_ID,
        resolveConversationId: () => recorded.id,
        onConversationId: (id, previous) => pinned.push([id, previous]),
      });
      backend.onMessage((m) => messages.push(m));
      return { backend, spawnCalls, children, pinned, messages };
    }

    it('stops the turn and says the conversation no longer exists', async () => {
      const recorded = { id: 'other-session-cid' as string | null };
      const { backend, spawnCalls, children, pinned, messages } = resumedBackend(recorded);

      const t1 = backend.sendPrompt('/work', 'first');
      expect(spawnCalls[0][spawnCalls[0].indexOf('--conversation') + 1]).toBe(DEAD_ID);
      children[0].stderr.emit('data', NOT_FOUND);
      expect(children[0].child.kill).toHaveBeenCalledWith('SIGTERM');
      // The conversation agy starts instead must not be adopted for this turn.
      recorded.id = 'replacement-cid';
      children[0].child.emit('close', null);

      await expect(t1).rejects.toThrow(`Antigravity conversation ${DEAD_ID} no longer exists`);
      expect(messages.filter((m) => m.type === 'status' && m.status === 'error')).toEqual([
        {
          type: 'status',
          status: 'error',
          detail: `Antigravity conversation ${DEAD_ID} no longer exists, so its earlier context is not available. Your next message starts a new conversation.`,
        },
      ]);
      expect(pinned).toEqual([]);
    });

    it('starts and pins a new conversation on the next message', async () => {
      const recorded = { id: 'other-session-cid' as string | null };
      const { backend, spawnCalls, children, pinned } = resumedBackend(recorded);

      const t1 = backend.sendPrompt('/work', 'first');
      children[0].stderr.emit('data', NOT_FOUND);
      recorded.id = 'replacement-cid';
      children[0].child.emit('close', null);
      await expect(t1).rejects.toThrow();

      const t2 = backend.sendPrompt('/work', 'second');
      expect(spawnCalls[1]).not.toContain('--conversation');
      recorded.id = 'new-cid';
      children[1].child.emit('close', 0);
      await t2;

      expect(pinned).toEqual([['new-cid', undefined]]);
      const t3 = backend.sendPrompt('/work', 'third');
      expect(spawnCalls[2][spawnCalls[2].indexOf('--conversation') + 1]).toBe('new-cid');
      children[2].child.emit('close', 0);
      await t3;
    });

    it('spots the warning when stderr splits it across chunks', async () => {
      const { backend, children } = resumedBackend({ id: null });

      const t1 = backend.sendPrompt('/work', 'first');
      children[0].stderr.emit('data', NOT_FOUND.slice(0, 20));
      expect(children[0].child.kill).not.toHaveBeenCalled();
      children[0].stderr.emit('data', NOT_FOUND.slice(20));
      expect(children[0].child.kill).toHaveBeenCalledWith('SIGTERM');
      children[0].child.emit('close', null);
      await expect(t1).rejects.toThrow('no longer exists');
    });

    it('ignores the warning for a conversation it did not ask for', async () => {
      const { backend, children } = resumedBackend({ id: null });

      const t1 = backend.sendPrompt('/work', 'first');
      children[0].stderr.emit('data', 'warning: conversation "some-other-id" not found\n');
      children[0].child.emit('close', 0);
      await expect(t1).resolves.toBeUndefined();
      expect(children[0].child.kill).not.toHaveBeenCalled();
    });
  });

  describe('while the first turn runs', () => {
    afterEach(() => {
      vi.useRealTimers();
    });

    it('pins the conversation as soon as the cache changes, before the turn ends', async () => {
      vi.useFakeTimers();
      const { child } = makeFakeChild();
      const spawnFn = vi.fn(() => child) as unknown as SpawnFn;

      let recorded: string | null = 'stale-cid';
      const pinned: string[] = [];
      const backend = new AgyBackend({
        cwd: '/work',
        permissionMode: 'default',
        spawnFn,
        cachePollMs: 50,
        resolveConversationId: () => recorded,
        onConversationId: (id) => pinned.push(id),
      });

      const turn = backend.sendPrompt('/work', 'first');
      await vi.advanceTimersByTimeAsync(50);
      expect(pinned).toEqual([]);

      recorded = 'new-cid';
      await vi.advanceTimersByTimeAsync(50);
      expect(pinned).toEqual(['new-cid']);

      // Once pinned, the poll and the close never re-pin.
      recorded = 'someone-else-cid';
      await vi.advanceTimersByTimeAsync(200);
      child.emit('close', 0);
      await turn;
      expect(pinned).toEqual(['new-cid']);
    });

    it('pins the conversation when the turn is stopped before the poll sees it', async () => {
      const { child } = makeFakeChild();
      const spawnFn = vi.fn(() => child) as unknown as SpawnFn;

      let recorded: string | null = null;
      const pinned: string[] = [];
      const backend = new AgyBackend({
        cwd: '/work',
        permissionMode: 'default',
        spawnFn,
        cachePollMs: 60_000,
        resolveConversationId: () => recorded,
        onConversationId: (id) => pinned.push(id),
      });

      const turn = backend.sendPrompt('/work', 'first');
      recorded = 'new-cid';
      await backend.cancel();
      expect(pinned).toEqual(['new-cid']);
      expect(child.kill).toHaveBeenCalledWith('SIGTERM');

      child.emit('close', null);
      await expect(turn).rejects.toThrow();
      expect(pinned).toEqual(['new-cid']);
    });

    it('stops polling once the turn ends', async () => {
      vi.useFakeTimers();
      const { child } = makeFakeChild();
      const spawnFn = vi.fn(() => child) as unknown as SpawnFn;

      let reads = 0;
      const backend = new AgyBackend({
        cwd: '/work',
        permissionMode: 'default',
        spawnFn,
        cachePollMs: 50,
        resolveConversationId: () => {
          reads++;
          return null;
        },
      });

      const turn = backend.sendPrompt('/work', 'first');
      child.emit('close', 0);
      await turn;
      const readsAtClose = reads;
      await vi.advanceTimersByTimeAsync(500);
      expect(reads).toBe(readsAtClose);
    });
  });

  it('emits only one error when error is followed by close (no double-emit)', async () => {
    const { child } = makeFakeChild();
    const spawnFn = vi.fn(() => child) as unknown as SpawnFn;

    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => null,
    });
    const messages: AgentMessage[] = [];
    backend.onMessage((m) => messages.push(m));

    await backend.startSession();
    const turn = backend.sendPrompt('/work', 'hi');

    // Node fires both 'error' and 'close' on spawn failure.
    child.emit('error', new Error('spawn ENOENT'));
    child.emit('close', null);

    await expect(turn).rejects.toThrow(/ENOENT/);
    expect(messages.filter((m) => m.type === 'status' && m.status === 'error')).toHaveLength(1);
  });

  it('cancel() kills the running child', async () => {
    const { child } = makeFakeChild();
    const spawnFn = vi.fn(() => child) as unknown as SpawnFn;

    const backend = new AgyBackend({
      cwd: '/work',
      permissionMode: 'default',
      spawnFn,
      resolveConversationId: () => null,
    });

    await backend.startSession();
    const turn = backend.sendPrompt('/work', 'hi');
    await backend.cancel();
    expect(child.kill).toHaveBeenCalled();

    // The kill surfaces as a non-zero close, which rejects the turn.
    child.emit('close', null);
    await expect(turn).rejects.toThrow();
  });
});
