// A daemon serving many chats from one MCP process (Happy Agent): each call's chat comes from the
// call id the daemon put in _meta, looked up in the daemon's database, never from tool arguments.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { callChatResolver, chatKeyOf, createMcpServer, NO_CALL_CHAT } from '../mcp.mjs';
import { createAgentChatLookup } from '../lib/agentchat.mjs';

const TOKEN = 'bridge-secret-token-0123456789abcdef';
const KEY_S1 = chatKeyOf({ source: 'happy', id: 'S1' });
const KEY_S2 = chatKeyOf({ source: 'happy', id: 'S2' });
const UP_TOOLS = [
    { name: 'browser.observe', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } },
    { name: 'browser.execute_action', inputSchema: { type: 'object', properties: { session_id: { type: 'string' }, action: { type: 'object' } } } },
    { name: 'browser.get_session', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } },
];

// The daemon's view: call id -> Happy session of the agent that made the call.
const CALLS = { c1: 'S1', c2: 'S2', c3: 'S1' };

function harness({ chat = null, lookup = async (id) => (CALLS[id] ? { source: 'happy', id: CALLS[id] } : null), podsOn = true } = {}) {
    const seen = { bridge: [], calls: [], lookups: [] };
    const podFor = new Map();
    let n = 0;
    const makeUpstream = (url) => ({
        listTools: async () => UP_TOOLS,
        async callTool(name, args) { seen.calls.push({ url, name, args }); return { result: { content: [{ type: 'text', text: 'ok' }] } }; },
    });
    const shared = { listTools: async () => UP_TOOLS, async callTool(name, args) { seen.calls.push({ url: 'shared', name, args }); return { result: { content: [] } }; } };
    const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
    const fetchImpl = async (url, init) => {
        const path = new URL(url).pathname;
        const body = JSON.parse(init.body || '{}');
        seen.bridge.push({ path, body });
        if (!podsOn && (path.startsWith('/api/pod') || path === '/api/tools')) return json(409, { error: 'pods_disabled' });
        if (path === '/api/tools') return json(200, { tools: UP_TOOLS });
        if (path === '/api/pod') {
            if (!body.chat_key) return json(404, { error: 'no_chat' });
            if (!podFor.has(body.chat_key)) podFor.set(body.chat_key, { slot: n, sid: `pod${n++}` });
            const p = podFor.get(body.chat_key);
            return json(200, { chat_key: body.chat_key, session_id: p.sid, mcp_url: `http://127.0.0.1:${8100 + p.slot}/mcp`, api_url: `http://127.0.0.1:${8100 + p.slot}`, link_id: `L${p.slot}`, url: `http://localhost/live/L${p.slot}` });
        }
        if (path === '/api/state') return json(200, { status: 'watching' });
        if (path === '/api/links') return json(200, { id: 'L', url: 'http://localhost/live/L', status: 'watching' });
        return json(404, { error: 'not_found' });
    };
    const out = [];
    const counted = async (id, signal) => { seen.lookups.push(id); return lookup(id, signal); };
    const server = createMcpServer({
        bridgeUrl: 'http://127.0.0.1:1', bridgeToken: TOKEN, write: (m) => out.push(m), fetchImpl, upstream: shared, retryMs: 0,
        chatPods: { chat, makeUpstream }, callChat: callChatResolver(counted),
    });
    let rid = 0;
    const call = async (name, args = {}, meta = undefined) => {
        const id = ++rid;
        await server.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args, ...(meta ? { _meta: meta } : {}) } });
        return out.find((m) => m.id === id);
    };
    const list = async () => { await server.handle({ jsonrpc: '2.0', id: 'l', method: 'tools/list' }); return out.find((m) => m.id === 'l'); };
    const podKeys = () => seen.bridge.filter((b) => b.path === '/api/pod').map((b) => b.body.chat_key);
    return { server, seen, call, list, podKeys };
}
const meta = (id) => ({ 'claudecode/toolUseId': id, progressToken: 7 });

test('call chat: the call id in _meta names the chat; key is sha256("happy:" + Happy session id)', async () => {
    const r = callChatResolver(async (id) => (id === 'c1' ? { source: 'happy', id: 'S1' } : null));
    assert.deepEqual(await r(meta('c1')), { key: KEY_S1, source: 'happy' });
    assert.equal(await r(meta('nope')), NO_CALL_CHAT);
    assert.equal(await r(undefined), NO_CALL_CHAT);
    assert.equal(await r({ progressToken: 1 }), NO_CALL_CHAT);
    assert.equal(await r(meta('bad id; drop')), NO_CALL_CHAT, 'an ill-formed id is not looked up');
    const failing = callChatResolver(async () => { throw new Error('db gone'); });
    assert.equal(await failing(meta('c1')), NO_CALL_CHAT);
});

test('call chat: two chats in one process get two pods; each call goes to its own chat\'s pod', async () => {
    const h = harness();
    await h.list();
    await h.call('browser_observe', {}, meta('c1'));
    await h.call('browser_observe', {}, meta('c2'));
    await h.call('browser_execute_action', { action: { action: 'click' } }, meta('c3'));
    assert.deepEqual(h.podKeys(), [KEY_S1, KEY_S2, KEY_S1]);
    assert.ok(h.seen.bridge.filter((b) => b.path === '/api/pod').every((b) => b.body.source === 'happy'));
    assert.deepEqual(h.seen.calls.map((c) => [c.url, c.args.session_id]), [
        ['http://127.0.0.1:8100/mcp', 'pod0'], ['http://127.0.0.1:8101/mcp', 'pod1'], ['http://127.0.0.1:8100/mcp', 'pod0'],
    ]);
});

test('call chat: ids the model puts in the arguments are ignored; another chat\'s session is remapped to its own', async () => {
    const h = harness();
    await h.list();
    await h.call('browser_observe', {}, meta('c2')); // chat S2 gets pod0
    h.seen.bridge.length = 0;
    h.seen.calls.length = 0;
    // Chat S1 names S2's session and every chat-ish field it can think of, including a _meta of its own.
    const args = {
        session_id: 'pod0', chat_key: KEY_S2, chat_id: 'S2', happy_session_id: 'S2', HAPPY_SESSION_ID: 'S2', client_id: 'S2',
        _meta: { 'claudecode/toolUseId': 'c2' },
    };
    await h.call('browser_observe', args, meta('c1'));
    assert.deepEqual(h.podKeys(), [KEY_S1], 'routed by the daemon\'s call id only');
    assert.equal(h.seen.calls.length, 1);
    assert.equal(h.seen.calls[0].url, 'http://127.0.0.1:8101/mcp');
    assert.equal(h.seen.calls[0].args.session_id, 'pod1', 'the session is S1\'s own');
    assert.ok(h.seen.bridge.every((b) => b.body.chat_key === undefined || b.body.chat_key === KEY_S1));
    assert.ok(!h.seen.bridge.some((b) => b.body.session_id === 'pod0'), 'S2\'s session is never asked about');
    assert.deepEqual(h.seen.lookups.slice(-1), ['c1']);
});

test('call chat: a call whose chat cannot be told is refused, not sent to a pod named by its arguments', async () => {
    const h = harness();
    await h.list();
    await h.call('browser_observe', {}, meta('c2'));
    h.seen.bridge.length = 0;
    h.seen.calls.length = 0;
    const r1 = await h.call('browser_observe', { session_id: 'pod0' }, meta('unknown'));
    const r2 = await h.call('browser_execute_action', { session_id: 'pod0', action: { action: 'click' } });
    for (const r of [r1, r2]) {
        assert.equal(r.result.isError, true);
        assert.match(r.result.content[0].text, /could not be matched to its chat/);
    }
    const r3 = await h.call('browser_live_link', { session_id: 'pod0' }, meta('unknown'));
    assert.equal(r3.result.isError, true);
    assert.equal(h.seen.calls.length, 0);
    assert.ok(!h.seen.bridge.some((b) => b.path === '/api/pod' || b.path === '/api/links'), 'no pod or link looked up');
});

test('call chat: own tools name the call\'s chat, whatever session_id they are given', async () => {
    const h = harness();
    await h.list();
    const r = await h.call('browser_live_link', { session_id: 'someone-elses' }, meta('c2'));
    assert.equal(r.result.isError, false);
    assert.ok(h.seen.bridge.some((b) => b.path === '/api/links' && b.body.chat_key === KEY_S2 && !b.body.session_id));
});

test('call chat: a process with its own chat (HAPPY_SESSION_ID) keeps it and never looks calls up', async () => {
    const own = { key: chatKeyOf({ source: 'happy', id: 'ENV' }), source: 'happy' };
    const h = harness({ chat: own });
    await h.list();
    await h.call('browser_observe', {}, meta('c1'));
    assert.deepEqual(h.podKeys(), [own.key]);
    assert.equal(h.seen.lookups.length, 0);
});

test('call chat: pods off on the bridge -> the shared controller, as before', async () => {
    const h = harness({ podsOn: false });
    await h.list();
    await h.call('browser_observe', { session_id: 'x1' }, meta('unknown'));
    assert.deepEqual(h.seen.calls.map((c) => [c.url, c.args.session_id]), [['shared', 'x1']]);
});

// The lookup itself, against a database shaped like the daemon's (built with python3's sqlite3).
function fixtureDb() {
    const dir = mkdtempSync(join(tmpdir(), 'agentchat-'));
    const db = join(dir, 'agent.sqlite');
    const ev = (id, agent, type, payload) => [id, agent, type, JSON.stringify(payload)];
    const rows = [
        ev('01a1-0001', 'agentA', 'tool.started', { rigEvent: { type: 'tool_execution_start', toolCall: { id: 'callA1', name: 'mcp__browser__browser_observe', arguments: { session_id: 'x' } } } }),
        ev('01a1-0002', 'agentB', 'tool.started', { rigEvent: { type: 'tool_execution_start', toolCall: { id: 'callB1', name: 'mcp__browser__browser_observe', arguments: {} } } }),
        // A completed event carrying another agent's call id must not count.
        ev('01a1-0003', 'agentB', 'tool.completed', { callId: 'callA2' }),
    ];
    execFileSync('python3', ['-I', '-c', `
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE happy_agent_events (event_id TEXT PRIMARY KEY, agent_id TEXT, occurred_at INTEGER NOT NULL, type TEXT NOT NULL, payload_json TEXT NOT NULL, payload_bytes INTEGER NOT NULL DEFAULT 0)")
c.execute("CREATE TABLE happy_agent_module_history_tool_calls (agent_id TEXT NOT NULL, call_id TEXT NOT NULL, record_id TEXT NOT NULL, PRIMARY KEY (agent_id, call_id))")
c.execute("CREATE TABLE happy_agent_happy_sessions (owner_id TEXT NOT NULL DEFAULT '', agent_id TEXT NOT NULL, session_id TEXT NOT NULL, remote_session_id TEXT, encryption_key_base64 TEXT NOT NULL, updated_at_ms INTEGER NOT NULL, PRIMARY KEY (owner_id, agent_id))")
for r in json.loads(sys.argv[2]):
    c.execute("INSERT INTO happy_agent_events (event_id, agent_id, occurred_at, type, payload_json) VALUES (?, ?, 0, ?, ?)", r)
c.execute("INSERT INTO happy_agent_module_history_tool_calls VALUES ('agentC', 'callC1', 'r1')")
c.execute("INSERT INTO happy_agent_happy_sessions VALUES ('', 'agentA', 'agentA', 'happyA', 'secret-key', 1)")
c.execute("INSERT INTO happy_agent_happy_sessions VALUES ('', 'agentB', 'agentB', NULL, 'secret-key', 1)")
c.commit()
`, db, JSON.stringify(rows)]);
    return db;
}

test('agent chat lookup: call id -> the agent\'s Happy session, else the agent; unknown -> null', async () => {
    const lookup = createAgentChatLookup({ dbPath: fixtureDb(), waitMs: 100 });
    assert.deepEqual(await lookup('callA1'), { source: 'happy', id: 'happyA' });
    assert.deepEqual(await lookup('callB1'), { source: 'agent', id: 'agentB' }, 'no Happy session: the agent id');
    assert.deepEqual(await lookup('callC1'), { source: 'agent', id: 'agentC' }, 'found in the tool-call history too');
    assert.equal(await lookup('callA2'), null, 'only tool.started events name a call\'s agent');
    assert.equal(await lookup('nope'), null);
    assert.equal(await lookup("x' OR 1=1 --"), null, 'an ill-formed id is never run');
});

test('agent chat lookup: a missing database is an error, so the call is refused', async () => {
    const lookup = createAgentChatLookup({ dbPath: join(tmpdir(), 'no-such-dir-agentchat', 'agent.sqlite'), waitMs: 50 });
    await assert.rejects(() => lookup('callA1'), /agent chat lookup/);
    const r = callChatResolver(lookup);
    assert.equal(await r(meta('callA1')), NO_CALL_CHAT);
});
