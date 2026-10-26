/**
 * AcpBackend agent-exit tests.
 *
 * A real ACP agent (`__fixtures__/resumableAgent.mjs`) runs as a child
 * process. When it goes away without the backend asking it to, the backend
 * must report `stopped` so the runner ends instead of prompting a dead agent.
 */

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { ChildProcess } from 'node:child_process';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { AcpBackend } from './AcpBackend';
import type { AgentMessage } from '@/agent/core';

const FIXTURE = join(__dirname, '__fixtures__', 'resumableAgent.mjs');

describe('AcpBackend agent exit', () => {
  let dir: string;
  const backends: AcpBackend[] = [];

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'acp-exit-'));
  });

  afterEach(async () => {
    for (const backend of backends.splice(0)) {
      await backend.dispose();
    }
    rmSync(dir, { recursive: true, force: true });
  });

  async function start(): Promise<{ backend: AcpBackend; messages: AgentMessage[]; child: ChildProcess }> {
    const backend = new AcpBackend({
      agentName: 'fixture',
      cwd: dir,
      command: process.execPath,
      args: [FIXTURE],
      env: { FIXTURE_CAPABILITIES: 'both', FIXTURE_STORE: join(dir, 'store.json') },
    });
    backends.push(backend);
    const messages: AgentMessage[] = [];
    backend.onMessage((msg) => messages.push(msg));
    await backend.startSession();
    const child = (backend as unknown as { process: ChildProcess }).process;
    return { backend, messages, child };
  }

  const stopped = (messages: AgentMessage[]) => messages.filter(
    (msg) => msg.type === 'status' && msg.status === 'stopped',
  );

  it('reports stopped when the agent is killed by a signal', async () => {
    const { messages, child } = await start();
    const exited = new Promise((resolve) => child.once('exit', resolve));
    child.kill('SIGKILL');
    await exited;
    expect(stopped(messages)).toEqual([{ type: 'status', status: 'stopped', detail: 'Killed by SIGKILL' }]);
  });

  it('reports nothing when the backend itself disposes the agent', async () => {
    const { backend, messages, child } = await start();
    const exited = new Promise((resolve) => child.once('exit', resolve));
    await backend.dispose();
    await exited;
    expect(stopped(messages)).toEqual([]);
  });
});
