/**
 * A minimal ACP agent for AcpBackend resume tests, run as a real child process.
 *
 * FIXTURE_CAPABILITIES picks what it advertises: "resume" (session.resume),
 * "load" (loadSession), "both", or "none". Sessions live in a JSON file
 * (FIXTURE_STORE) so a second process can continue a session the first one
 * created. session/load streams the stored conversation back before it
 * answers, as the protocol asks. A prompt answers with every earlier user
 * message of the session joined by "|", so a test can see what the agent
 * remembers.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Readable, Writable } from 'node:stream';
import { AgentSideConnection, ndJsonStream } from '@agentclientprotocol/sdk';

const capabilities = process.env.FIXTURE_CAPABILITIES ?? 'none';
const storePath = process.env.FIXTURE_STORE;

function readStore() {
  return storePath && existsSync(storePath) ? JSON.parse(readFileSync(storePath, 'utf8')) : {};
}

function writeStore(store) {
  writeFileSync(storePath, JSON.stringify(store));
}

function requireSession(sessionId) {
  const store = readStore();
  if (!store[sessionId]) {
    throw new Error(`Session not found: ${sessionId}`);
  }
  return store[sessionId];
}

const stream = ndJsonStream(Writable.toWeb(process.stdout), Readable.toWeb(process.stdin));
let connection;
connection = new AgentSideConnection(() => ({
  async initialize() {
    return {
      protocolVersion: 1,
      agentCapabilities: {
        loadSession: capabilities === 'load' || capabilities === 'both',
        sessionCapabilities: capabilities === 'resume' || capabilities === 'both' ? { resume: {} } : {},
      },
    };
  },
  async newSession() {
    const sessionId = `fixture-${randomUUID()}`;
    const store = readStore();
    store[sessionId] = { messages: [] };
    writeStore(store);
    return { sessionId };
  },
  async loadSession(params) {
    const stored = requireSession(params.sessionId);
    for (const message of stored.messages) {
      await connection.sessionUpdate({
        sessionId: params.sessionId,
        update: { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: message } },
      });
      await connection.sessionUpdate({
        sessionId: params.sessionId,
        update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: `replayed:${message}` } },
      });
    }
    await connection.sessionUpdate({
      sessionId: params.sessionId,
      update: { sessionUpdate: 'available_commands_update', availableCommands: [{ name: 'fixture', description: 'x' }] },
    });
    return {};
  },
  async unstable_resumeSession(params) {
    requireSession(params.sessionId);
    return {};
  },
  async prompt(params) {
    const store = readStore();
    const stored = store[params.sessionId];
    const text = params.prompt.map((block) => (block.type === 'text' ? block.text : '')).join('');
    const answer = `remembered:${stored.messages.join('|')}`;
    stored.messages.push(text);
    writeStore(store);
    await connection.sessionUpdate({
      sessionId: params.sessionId,
      update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: answer } },
    });
    return { stopReason: 'end_turn' };
  },
  async cancel() {},
  async authenticate() {
    return {};
  },
}), stream);
