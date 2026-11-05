// Per-chat pods through the bridge's HTTP API (app.mjs) and the MCP server's chat router (mcp.mjs),
// with the pod manager and each pod's auto-browser mocked.
import { test, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBridge } from '../lib/app.mjs';
import { LinkStore } from '../lib/store.mjs';
import { chatIdentity, chatKeyOf, createMcpServer } from '../mcp.mjs';

const TOKEN = 'bridge-secret-token-0123456789abcdef';
const PNG = Buffer.from('89504e470d0a1a0a', 'hex');
const KEY_A = 'a'.repeat(32);
const KEY_B = 'b'.repeat(32);

function podClient(sid, calls) {
    const nf = () => Object.assign(new Error('not found'), { status: 404 });
    return {
        async getSession(id) { if (id !== sid) throw nf(); return { id, current_url: `https://example.com/${sid}`, title: sid }; },
        async share(id) { if (id !== sid) throw nf(); return { token: `tok-${sid}`, expires_at: 9e12 }; },
        async observeShared() { calls.observe.push(sid); return { screenshot_url: '/share/x/s.png' }; },
        async fetchFrame() { return { contentType: 'image/png', body: PNG }; },
        async requestTakeover(id) { calls.takeover.push(id); },
        async closeSession(id) { calls.close.push(id); },
    };
}

// A pod manager with the shape of lib/pods.mjs: chats run, sleep and wake on command.
function fakePods(store) {
    const calls = { ensure: [], stop: [], wake: [], touch: [], checkpoint: [], observe: [], takeover: [], close: [] };
    const chats = new Map(); // key -> {sessionId, state, slot, n}
    let n = 0;
    const pods = {
        calls, chats,
        async ensure(key, { source } = {}) {
            calls.ensure.push({ key, source });
            let c = chats.get(key);
            if (!c || c.state !== 'running') {
                c = { sessionId: `s${++n}`, state: 'running', slot: chats.size, source };
                chats.set(key, c);
                c.linkId = store.forChat(key, c.sessionId).id;
            }
            return { chat_key: key, state: 'running', session_id: c.sessionId, link_id: c.linkId, slot: c.slot, api_url: `http://127.0.0.1:${8100 + c.slot}`, mcp_url: `http://127.0.0.1:${8100 + c.slot}/mcp`, novnc_port: 6100 + c.slot };
        },
        async stopChat(key, why) { calls.stop.push({ key, why }); const c = chats.get(key); if (!c) return false; c.state = 'asleep'; return true; },
        checkpointAuth: async (key, o) => { calls.checkpoint.push({ key, ...o }); },
        chatForLink: (id) => { for (const [k, c] of chats) if (c.linkId === id) return { chatKey: k }; return null; },
        chatForSession: (sid) => { for (const [k, c] of chats) if (c.sessionId === sid) return { chatKey: k }; return null; },
        podOf(key) {
            const c = chats.get(key);
            if (!c || c.state !== 'running') return null;
            return { slot: c.slot, client: podClient(c.sessionId, calls), novncPort: 6100 + c.slot, vncPassword: `pw${c.slot}`, sessionId: c.sessionId };
        },
        podState: (key) => chats.get(key)?.state ?? 'none',
        touchViewer: (key) => calls.touch.push(key),
        wake(key) { calls.wake.push(key); pods.ensure(key); return 'starting'; },
        status: () => ({ max_pods: 8, pods: [], chats: [...chats.keys()].map((k) => ({ chat: k.slice(0, 8) })) }),
    };
    return pods;
}

let server, base, store, pods;
async function start({ withPods = true } = {}) {
    const dir = mkdtempSync(join(tmpdir(), 'chatpods-'));
    store = new LinkStore({ path: join(dir, 'links.json'), idleMs: 3600_000 });
    pods = withPods ? fakePods(store) : null;
    const shared = podClient('shared1', { observe: [], takeover: [], close: [] });
    const bridge = createBridge({
        client: shared, store, log: () => {},
        config: {
            bridgeToken: TOKEN, vncPassword: 'sharedpw', novncUrl: 'http://localhost:6080/vnc.html', pods,
            listTools: async () => [{ name: 'browser.observe', inputSchema: { properties: { session_id: {} } } }],
            onEnd: pods ? async ({ id }) => { const c = pods.chatForLink(id); if (c) await pods.stopChat(c.chatKey, 'user_ended'); } : null,
        },
    });
    server = createServer(bridge.handler);
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${server.address().port}`;
}
afterEach(() => server && new Promise((r) => { server.closeAllConnections?.(); server.close(r); }));

const api = (path, body) => fetch(base + path, { method: 'POST', headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

test('chat identity: Happy session first, then Claude Code, else none; key is sha256 of source:id', () => {
    assert.deepEqual(chatIdentity({ HAPPY_SESSION_ID: 'h1', CLAUDE_CODE_SESSION_ID: 'c1' }), { source: 'happy', id: 'h1' });
    assert.deepEqual(chatIdentity({ CLAUDE_CODE_SESSION_ID: 'c1' }), { source: 'claude', id: 'c1' });
    assert.equal(chatIdentity({}), null);
    const k = chatKeyOf({ source: 'happy', id: 'h1' });
    assert.match(k, /^[0-9a-f]{32}$/);
    assert.notEqual(k, chatKeyOf({ source: 'claude', id: 'h1' }));
});

test('pods off: the pod endpoints answer 409 pods_disabled', async () => {
    await start({ withPods: false });
    const r = await api('/api/pod', { chat_key: KEY_A });
    assert.equal(r.status, 409);
    assert.equal((await r.json()).error, 'pods_disabled');
    assert.equal((await api('/api/tools', {})).status, 409);
    const g = await fetch(base + '/api/pods', { headers: { Authorization: `Bearer ${TOKEN}` } });
    assert.deepEqual(await g.json(), { pods: false });
});

test('/api/pod starts the chat\'s pod; the chat link is found by chat key, each chat its own', async () => {
    await start();
    const a = await (await api('/api/pod', { chat_key: KEY_A, source: 'happy' })).json();
    const b = await (await api('/api/pod', { chat_key: KEY_B, source: 'happy' })).json();
    assert.notEqual(a.session_id, b.session_id);
    assert.notEqual(a.mcp_url, b.mcp_url);
    assert.match(a.url, /\/live\/[A-Za-z0-9_-]+$/);
    assert.equal((await api('/api/pod', { chat_key: 'nothex' })).status, 400);

    const d = await (await fetch(`${base}/live/chat/${KEY_A}`)).json();
    assert.equal(d.id, a.link_id);
    assert.equal(d.live, true);
    assert.equal(d.pod, 'running');
    assert.equal((await fetch(`${base}/live/chat/${'c'.repeat(32)}`)).status, 404);
    // By session too, for a process that only knows the session.
    const s = await (await api('/api/pod', { session_id: b.session_id })).json();
    assert.equal(s.chat_key, KEY_B);

    // /api/links and /api/state by chat key name that chat's link, never another's.
    const l = await (await api('/api/links', { chat_key: KEY_B })).json();
    assert.equal(l.id, b.link_id);
    const st = await (await api('/api/state', { chat_key: KEY_A })).json();
    assert.equal(st.id, a.link_id);
    assert.equal(st.pod, 'running');
});

test('the live page and frames use the chat\'s own pod and noVNC port and password', async () => {
    await start();
    const a = await (await api('/api/pod', { chat_key: KEY_A })).json();
    const b = await (await api('/api/pod', { chat_key: KEY_B })).json();
    assert.equal((await fetch(`${base}/live/${b.link_id}/frame.jpg`)).status, 200);
    assert.deepEqual(pods.calls.observe, [b.session_id]);
    const page = await (await fetch(`${base}/live/${a.link_id}`)).text();
    assert.match(page, /localhost:6100\/vnc\.html#password=pw0/);
    assert.doesNotMatch(page, /sharedpw/);
    const t = await (await fetch(`${base}/live/${b.link_id}/take`, { method: 'POST' })).json();
    assert.equal(t.status, 'user');
    assert.match(t.novnc_url, /:6101\/vnc\.html#password=pw1$/);
    assert.ok(pods.calls.touch.includes(KEY_B));
    // Release keeps the login at once.
    await fetch(`${base}/live/${b.link_id}/release`, { method: 'POST' });
    assert.deepEqual(pods.calls.checkpoint, [{ key: KEY_B, force: true }]);
});

test('asleep: frames 503 without waking, state says asleep, take wakes it (202)', async () => {
    await start();
    const a = await (await api('/api/pod', { chat_key: KEY_A })).json();
    await pods.stopChat(KEY_A, 'idle');
    const f = await fetch(`${base}/live/${a.link_id}/frame.jpg`);
    assert.equal(f.status, 503);
    assert.equal((await f.json()).error, 'asleep');
    const s = await (await fetch(`${base}/live/${a.link_id}/state`)).json();
    assert.equal(s.pod, 'asleep');
    assert.deepEqual(pods.calls.wake, []);
    const d = await (await fetch(`${base}/live/chat/${KEY_A}`)).json();
    assert.equal(d.live, false);
    const t = await fetch(`${base}/live/${a.link_id}/take`, { method: 'POST' });
    assert.equal(t.status, 202);
    assert.equal((await t.json()).pod, 'starting');
    assert.deepEqual(pods.calls.wake, [KEY_A]);
    // Woken (a new session in the same link): take now hands over noVNC.
    const t2 = await fetch(`${base}/live/${a.link_id}/take`, { method: 'POST' });
    assert.equal(t2.status, 200);
    assert.equal((await t2.json()).status, 'user');
});

test('end and close go through the pod stop; the link is done', async () => {
    await start();
    const a = await (await api('/api/pod', { chat_key: KEY_A })).json();
    const e = await fetch(`${base}/live/${a.link_id}/end`, { method: 'POST' });
    assert.equal(e.status, 200);
    assert.deepEqual(pods.calls.stop, [{ key: KEY_A, why: 'user_ended' }]);
    await api('/api/pod', { chat_key: KEY_B });
    const c = await (await api('/api/pod/close', { chat_key: KEY_B })).json();
    assert.equal(c.closed, true);
    const st = await (await api('/api/state', { chat_key: KEY_B })).json();
    assert.equal(st.status, 'done');
    const tools = await (await api('/api/tools', {})).json();
    assert.equal(tools.tools[0].name, 'browser.observe');
});

// ── The MCP server's router ────────────────────────────────────────────────
const UP_TOOLS = [
    { name: 'browser.observe', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } },
    { name: 'browser.execute_action', inputSchema: { type: 'object', properties: { session_id: { type: 'string' }, action: { type: 'string' } } } },
    { name: 'browser.create_session', inputSchema: { type: 'object', properties: { start_url: { type: 'string' } } } },
    { name: 'browser.get_session', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } },
    { name: 'browser.close_session', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } },
    { name: 'browser.fork_session', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } },
];

function mcpHarness({ chat = { key: KEY_A, source: 'happy' }, podsOn = true, refuseOnce = false } = {}) {
    const seen = { bridge: [], calls: [] };
    let n = 0;
    const podFor = new Map();
    let refused = refuseOnce;
    const makeUpstream = (url) => ({
        listTools: async () => UP_TOOLS,
        async callTool(name, args) {
            if (refused) { refused = false; throw new Error('auto-browser MCP unreachable (ECONNREFUSED). Is the browser stack up?'); }
            seen.calls.push({ url, name, args });
            return { result: { content: [{ type: 'text', text: `${name} ok` }] } };
        },
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
            const key = body.chat_key;
            if (!podFor.has(key) || body.verify) podFor.set(key, { slot: n, sid: `pod${n++}` });
            const p = podFor.get(key);
            return json(200, { chat_key: key, session_id: p.sid, mcp_url: `http://127.0.0.1:${8100 + p.slot}/mcp`, api_url: `http://127.0.0.1:${8100 + p.slot}`, link_id: `L${p.slot}`, url: `http://localhost/live/L${p.slot}` });
        }
        if (path === '/api/pod/close') return json(200, { closed: true });
        if (path === '/api/state') return json(200, { status: 'watching' });
        if (path === '/api/links') return json(200, { id: 'L', url: 'http://localhost/live/L', status: 'watching' });
        return json(404, { error: 'not_found' });
    };
    const out = [];
    const server = createMcpServer({ bridgeUrl: 'http://127.0.0.1:1', bridgeToken: TOKEN, write: (m) => out.push(m), fetchImpl, upstream: shared, retryMs: 0, chatPods: { chat, makeUpstream, newKey: () => (n % 2 ? KEY_B : 'd'.repeat(32)) } });
    let id = 0;
    const call = async (name, args = {}) => {
        const rid = ++id;
        await server.handle({ jsonrpc: '2.0', id: rid, method: 'tools/call', params: { name, arguments: args } });
        return out.find((m) => m.id === rid);
    };
    return { server, seen, call, list: async () => { await server.handle({ jsonrpc: '2.0', id: 'l', method: 'tools/list' }); return out.find((m) => m.id === 'l'); } };
}

test('router: every call goes to the chat\'s pod with the chat\'s session, whatever session the agent names', async () => {
    const h = mcpHarness();
    const listed = await h.list();
    assert.ok(listed.result.tools.some((t) => t.name === 'browser_observe'));
    assert.ok(!h.seen.bridge.some((b) => b.path === '/api/pod'), 'listing tools starts no pod');
    await h.call('browser_observe', {});
    await h.call('browser_execute_action', { session_id: 'someone-elses', action: 'click' });
    assert.deepEqual(h.seen.calls.map((c) => [c.url, c.args.session_id]), [['http://127.0.0.1:8100/mcp', 'pod0'], ['http://127.0.0.1:8100/mcp', 'pod0']]);
    // The control check and link name the chat, not a session.
    const states = h.seen.bridge.filter((b) => b.path === '/api/state');
    assert.ok(states.length && states.every((b) => b.body.chat_key === KEY_A && !b.body.session_id));
    assert.equal(h.server.router.apiPortFor({ session_id: 'pod0' }), 8100);
});

test('router: create_session returns the chat\'s session; fork is refused; close stops the pod', async () => {
    const h = mcpHarness();
    const c = await h.call('browser_create_session', { start_url: 'https://example.com/' });
    assert.match(c.result.content[0].text, /pod0/);
    assert.deepEqual(h.seen.calls.map((x) => [x.name, x.args.session_id, x.args.url ?? null]), [['browser.execute_action', 'pod0', 'https://example.com/'], ['browser.get_session', 'pod0', null]]);
    const f = await h.call('browser_fork_session', {});
    assert.equal(f.result.isError, true);
    assert.match(f.result.content[0].text, /one browser/);
    const x = await h.call('browser_close_session', {});
    assert.equal(x.result.isError, false);
    assert.ok(h.seen.bridge.some((b) => b.path === '/api/pod/close' && b.body.chat_key === KEY_A));
    assert.equal(h.seen.calls.filter((y) => y.name === 'browser.close_session').length, 0);
});

test('router: a refused connection asks the bridge to verify the pod and retries once', async () => {
    const h = mcpHarness({ refuseOnce: true });
    const r = await h.call('browser_observe', {});
    assert.equal(r.result.isError, undefined);
    assert.ok(h.seen.bridge.some((b) => b.path === '/api/pod' && b.body.verify === true));
    assert.equal(h.seen.calls.length, 1);
    assert.equal(h.seen.calls[0].args.session_id, 'pod1');
});

test('router: pods off on the bridge -> the shared controller, as before', async () => {
    const h = mcpHarness({ podsOn: false });
    await h.list();
    await h.call('browser_observe', { session_id: 'x1' });
    assert.deepEqual(h.seen.calls.map((c) => [c.url, c.args.session_id]), [['shared', 'x1']]);
    assert.ok(!h.seen.bridge.some((b) => b.body.chat_key && b.path === '/api/state'));
});

test('router without a chat identity: each created session gets its own pod', async () => {
    const h = mcpHarness({ chat: null });
    await h.call('browser_create_session', {});
    await h.call('browser_create_session', {});
    const keys = h.seen.bridge.filter((b) => b.path === '/api/pod').map((b) => b.body.chat_key);
    assert.equal(new Set(keys).size, 2);
    // A call naming the second session goes to the second pod.
    h.seen.calls.length = 0;
    await h.call('browser_observe', { session_id: 'pod1' });
    assert.equal(h.seen.calls[0].url, 'http://127.0.0.1:8101/mcp');
});

test('live link without a session_id names the chat\'s link', async () => {
    const h = mcpHarness();
    const r = await h.call('browser_live_link', {});
    assert.equal(r.result.isError, false);
    assert.ok(h.seen.bridge.some((b) => b.path === '/api/links' && b.body.chat_key === KEY_A));
});
