/**
 * AcpBackend resume tests.
 *
 * Each test runs a real ACP agent (`__fixtures__/resumableAgent.mjs`) as a
 * child process: a first backend starts a session and sends a prompt, then a
 * second backend, in a new process, asks to continue that session.
 */

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { AcpBackend, selectAcpResumeMethod, type AcpStartSessionResult } from './AcpBackend';
import type { AgentMessage } from '@/agent/core';

const FIXTURE = join(__dirname, '__fixtures__', 'resumableAgent.mjs');

type Run = {
  backend: AcpBackend;
  messages: AgentMessage[];
  started: AcpStartSessionResult;
};

describe('AcpBackend resume', () => {
  let dir: string;
  const backends: AcpBackend[] = [];

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'acp-resume-'));
  });

  afterEach(async () => {
    for (const backend of backends.splice(0)) {
      await backend.dispose();
    }
    rmSync(dir, { recursive: true, force: true });
  });

  async function start(capabilities: string, resumeSessionId?: string): Promise<Run> {
    const backend = new AcpBackend({
      agentName: 'fixture',
      cwd: dir,
      command: process.execPath,
      args: [FIXTURE],
      env: { FIXTURE_CAPABILITIES: capabilities, FIXTURE_STORE: join(dir, 'store.json') },
      resumeSessionId,
    });
    backends.push(backend);
    const messages: AgentMessage[] = [];
    backend.onMessage((msg) => messages.push(msg));
    const started = await backend.startSession();
    return { backend, messages, started };
  }

  async function prompt(run: Run, text: string): Promise<string> {
    const from = run.messages.length;
    await run.backend.sendPrompt(run.started.sessionId, text);
    return run.messages.slice(from)
      .map((msg) => (msg.type === 'model-output' ? msg.textDelta ?? msg.fullText ?? '' : ''))
      .join('');
  }

  function modelOutput(messages: AgentMessage[]): string[] {
    return messages.flatMap((msg) => (msg.type === 'model-output' ? [msg.textDelta ?? msg.fullText ?? ''] : []));
  }

  it('starts a new session when no resume is asked for', async () => {
    const run = await start('both');
    expect(run.started.opening).toEqual({ kind: 'new' });
    expect(run.started.acpSessionId).toMatch(/^fixture-/);
  });

  it('continues the session with session/resume when the agent advertises it', async () => {
    const first = await start('resume');
    await prompt(first, 'secret PERIWINKLE');
    await first.backend.dispose();

    const second = await start('resume', first.started.acpSessionId);
    expect(second.started.opening).toEqual({ kind: 'resumed', method: 'session/resume' });
    expect(second.started.acpSessionId).toBe(first.started.acpSessionId);
    expect(await prompt(second, 'what was it?')).toBe('remembered:secret PERIWINKLE');
  });

  it('continues with session/load and drops the replayed conversation', async () => {
    const first = await start('load');
    await prompt(first, 'secret PERIWINKLE');
    await first.backend.dispose();

    const second = await start('load', first.started.acpSessionId);
    expect(second.started.opening).toEqual({ kind: 'resumed', method: 'session/load' });
    expect(second.started.acpSessionId).toBe(first.started.acpSessionId);
    // The replay must not surface as new output, but session metadata does.
    expect(modelOutput(second.messages)).toEqual([]);
    expect(second.messages.some((msg) => msg.type === 'event' && msg.name === 'available_commands')).toBe(true);
    expect(await prompt(second, 'what was it?')).toBe('remembered:secret PERIWINKLE');
  });

  it('starts a new session and says why when the agent cannot resume', async () => {
    const first = await start('none');
    await prompt(first, 'secret PERIWINKLE');
    await first.backend.dispose();

    const second = await start('none', first.started.acpSessionId);
    expect(second.started.opening.kind).toBe('resume-failed');
    expect(second.started.opening).toMatchObject({ reason: expect.stringContaining('does not support resuming') });
    expect(second.started.acpSessionId).not.toBe(first.started.acpSessionId);
    expect(await prompt(second, 'what was it?')).toBe('remembered:');
  });

  it('starts a new session when the agent no longer knows the session', async () => {
    const run = await start('both', 'fixture-unknown');
    expect(run.started.opening.kind).toBe('resume-failed');
    expect(run.started.opening).toMatchObject({ reason: expect.stringContaining('session/resume for fixture-unknown failed') });
    expect(run.started.acpSessionId).not.toBe('fixture-unknown');
  });
});

describe('selectAcpResumeMethod', () => {
  it('prefers session/resume, then session/load, else none', () => {
    expect(selectAcpResumeMethod({ loadSession: true, sessionCapabilities: { resume: {} } })).toBe('session/resume');
    expect(selectAcpResumeMethod({ loadSession: true, sessionCapabilities: {} })).toBe('session/load');
    expect(selectAcpResumeMethod({ loadSession: false })).toBeNull();
    expect(selectAcpResumeMethod(undefined)).toBeNull();
  });
});
