import { EventEmitter } from 'node:events';
import { afterEach, describe, expect, it, vi } from 'vitest';

const { mockSpawn } = vi.hoisted(() => ({ mockSpawn: vi.fn() }));

vi.mock('node:child_process', async (importOriginal) => ({
  ...(await importOriginal<typeof import('node:child_process')>()),
  spawn: mockSpawn,
}));

vi.mock('./constants', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./constants')>()),
  resolveAgyBin: () => 'agy',
}));

import { checkAgyConversation, runAgyAcp, type AcpRunner } from './conversationCheck';

const REAL_ID = '62cbe556-f8a3-411b-b752-345289e34067';

/** `session/list` from agy 1.5.18: global, with each conversation's cwd. */
const LIST_RESULT = {
  sessions: [{ sessionId: REAL_ID, cwd: '/abs/dir', title: 'Reply with just OK', updatedAt: '2026-11-28T07:42:51Z' }],
};

/** A runner that answers each method from `answers`, recording what was asked. */
function fakeRunner(answers: Record<string, (params: Record<string, unknown>) => unknown>) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const runner: AcpRunner = (work) => work(async (method, params) => {
    calls.push([method, params]);
    const answer = answers[method];
    if (!answer) throw new Error(`agy acp error -32601: Method not found: ${method}`);
    return answer(params);
  });
  return { runner, calls };
}

describe('checkAgyConversation', () => {
  it('finds a listed conversation and reports where it was started', async () => {
    const { runner, calls } = fakeRunner({ initialize: () => ({}), 'session/list': () => LIST_RESULT });

    await expect(checkAgyConversation(REAL_ID, { runner })).resolves.toEqual({ status: 'present', cwd: '/abs/dir' });
    expect(calls).toEqual([
      ['initialize', { protocolVersion: 1, clientCapabilities: {} }],
      ['session/list', {}],
    ]);
  });

  it('reports a conversation agy does not list as missing', async () => {
    const { runner } = fakeRunner({ initialize: () => ({}), 'session/list': () => LIST_RESULT });

    await expect(checkAgyConversation('00000000-dead-beef-0000-000000000000', { runner }))
      .resolves.toEqual({ status: 'missing' });
  });

  it('follows the list onto later pages', async () => {
    const { runner, calls } = fakeRunner({
      initialize: () => ({}),
      'session/list': (params) => (params.cursor === 'page-2'
        ? LIST_RESULT
        : { sessions: [{ sessionId: 'other', cwd: '/x' }], nextCursor: 'page-2' }),
    });

    await expect(checkAgyConversation(REAL_ID, { runner })).resolves.toMatchObject({ status: 'present' });
    expect(calls.at(-1)).toEqual(['session/list', { cursor: 'page-2' }]);
  });

  it('cannot tell when agy is not signed in', async () => {
    const { runner } = fakeRunner({
      initialize: () => ({}),
      'session/list': () => { throw new Error('agy acp error -32000: Authentication required'); },
    });

    await expect(checkAgyConversation(REAL_ID, { runner })).resolves.toEqual({
      status: 'unknown',
      reason: 'agy acp error -32000: Authentication required',
    });
  });

  it('cannot tell with an agy that has no session/list', async () => {
    const { runner } = fakeRunner({ initialize: () => ({}) });

    await expect(checkAgyConversation(REAL_ID, { runner })).resolves.toMatchObject({ status: 'unknown' });
  });
});

describe('runAgyAcp', () => {
  afterEach(() => {
    vi.useRealTimers();
    mockSpawn.mockReset();
  });

  /** A fake `agy acp`: records request lines and lets the test answer them. */
  function fakeAcp() {
    const stdout = Object.assign(new EventEmitter(), { setEncoding: () => {} });
    const written: Array<{ id: number; method: string }> = [];
    const stdin = Object.assign(new EventEmitter(), {
      write: (line: string) => {
        written.push(JSON.parse(line));
        return true;
      },
      end: vi.fn(),
    });
    const child = Object.assign(new EventEmitter(), { stdout, stdin, kill: vi.fn(() => true) });
    mockSpawn.mockReturnValue(child);
    const reply = (message: unknown) => stdout.emit('data', `${JSON.stringify(message)}\n`);
    return { child, written, reply };
  }

  it('matches responses to requests, skips the agent\'s own messages, and stops agy after', async () => {
    const acp = fakeAcp();

    const result = runAgyAcp((request) => request('session/list', {}), 5_000);
    expect(mockSpawn).toHaveBeenCalledWith('agy', ['acp'], expect.anything());
    expect(acp.written).toEqual([{ jsonrpc: '2.0', id: 1, method: 'session/list', params: {} }]);
    acp.reply({ jsonrpc: '2.0', method: 'session/update', params: {} });
    acp.reply({ jsonrpc: '2.0', id: 1, result: LIST_RESULT });

    await expect(result).resolves.toEqual(LIST_RESULT);
    expect(acp.child.kill).toHaveBeenCalledWith('SIGTERM');
  });

  it('turns a JSON-RPC error into a rejection', async () => {
    const acp = fakeAcp();

    const result = runAgyAcp((request) => request('session/list', {}), 5_000);
    acp.reply({ jsonrpc: '2.0', id: 1, error: { code: -32000, message: 'Authentication required' } });

    await expect(result).rejects.toThrow('agy acp error -32000: Authentication required');
  });

  it('gives up and stops agy when it does not answer in time', async () => {
    vi.useFakeTimers();
    const acp = fakeAcp();

    const result = runAgyAcp((request) => request('initialize', { protocolVersion: 1 }), 2_000);
    const settled = expect(result).rejects.toThrow('agy acp did not answer within 2000ms');
    await vi.advanceTimersByTimeAsync(2_000);

    await settled;
    expect(acp.child.kill).toHaveBeenCalledWith('SIGTERM');
  });

  it('fails a pending request when agy exits', async () => {
    const acp = fakeAcp();

    const result = runAgyAcp((request) => request('initialize', { protocolVersion: 1 }), 5_000);
    acp.child.emit('close', 1);

    await expect(result).rejects.toThrow('agy acp exited');
  });
});
