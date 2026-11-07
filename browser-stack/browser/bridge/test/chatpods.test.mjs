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
import { chatIdentity, chatKeyOf, createMcpServer, forkParentKey } from '../mcp.mjs';
import { request } from 'node:http';
import { fakeNovnc, wsHandshake } from './fake-novnc.mjs';

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
        novncPortOf: (slot) => 6100 + slot,
        async ensure(key, { source, forkedFrom } = {}) {
            calls.ensure.push({ key, source, ...(forkedFrom ? { forkedFrom } : {}) });
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
            return { slot: c.slot, client: podClient(c.sessionId, calls), novncPort: pods.novncPortOf(c.slot), vncPassword: `pw${c.slot}`, sessionId: c.sessionId };
        },
        podState: (key) => chats.get(key)?.state ?? 'none',
        liveness(key) {
            const st = chats.get(key)?.state ?? 'none';
            if (st === 'running') return { live: true, pod: 'running', reason: null };
            if (st === 'crashed') return { live: false, pod: 'dead', reason: 'crashed' };
            return { live: false, pod: st === 'none' ? 'none' : 'asleep', reason: st === 'none' ? 'no_browser' : 'asleep' };
        },
        sessionSeen: () => {},
        touchViewer: (key) => calls.touch.push(key),
        wake(key) { calls.wake.push(key); pods.ensure(key); return 'starting'; },
        status: () => ({ max_pods: 8, pods: [], chats: [...chats.keys()].map((k) => ({ chat: k.slice(0, 8) })) }),
    };
    return pods;
}

let server, base, store, pods, bridgeApp;
async function start({ withPods = true, novncUrl = 'http://localhost:6080/vnc.html' } = {}) {
    const dir = mkdtempSync(join(tmpdir(), 'chatpods-'));
    store = new LinkStore({ path: join(dir, 'links.json'), idleMs: 3600_000 });
    pods = withPods ? fakePods(store) : null;
    const shared = podClient('shared1', { observe: [], takeover: [], close: [] });
    const bridge = bridgeApp = createBridge({
        client: shared, store, log: () => {},
        config: {
            bridgeToken: TOKEN, vncPassword: 'sharedpw', novncUrl, pods, tunnelCheckMs: 50,
            listTools: async () => [{ name: 'browser.observe', inputSchema: { properties: { session_id: {} } } }],
            onEnd: pods ? async ({ id }) => { const c = pods.chatForLink(id); if (c) await pods.stopChat(c.chatKey, 'user_ended'); } : null,
        },
    });
    server = createServer(bridge.handler);
    server.on('upgrade', bridge.upgrade);
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${server.address().port}`;
}
afterEach(() => server && new Promise((r) => { bridgeApp?.close(); server.closeAllConnections?.(); server.close(r); }));

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
    assert.ok(page.includes(`http://localhost:6090/live/${a.link_id}/vnc/vnc.html?path=websockify"`));
    assert.ok(!page.includes('pw0'), 'the page never carries the pod password; POST /take does');
    assert.doesNotMatch(page, /sharedpw/);
    const t = await (await fetch(`${base}/live/${b.link_id}/take`, { method: 'POST' })).json();
    assert.equal(t.status, 'user');
    // Through the bridge's own port: the link's path, noVNC's socket path, the pod's password.
    assert.equal(t.novnc_url, `http://localhost:6090/live/${b.link_id}/vnc/vnc.html?path=websockify#password=pw1`);
    assert.doesNotMatch(t.novnc_url, /:610\d/);
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

test('sleep: POST only; stops the pod with why slept and leaves the link watching on its page', async () => {
    await start();
    const a = await (await api('/api/pod', { chat_key: KEY_A })).json();
    assert.equal((await fetch(`${base}/live/${a.link_id}/sleep`)).status, 405);
    const r = await fetch(`${base}/live/${a.link_id}/sleep`, { method: 'POST' });
    assert.equal(r.status, 200);
    const body = await r.json();
    assert.equal(body.status, 'watching');
    assert.equal(body.pod, 'asleep');
    assert.deepEqual(pods.calls.stop, [{ key: KEY_A, why: 'slept' }]);
    // Asleep already: nothing changes.
    const again = await fetch(`${base}/live/${a.link_id}/sleep`, { method: 'POST' });
    assert.equal(again.status, 200);
    assert.equal(pods.calls.stop.length, 1);
    // The next take wakes it.
    assert.equal((await fetch(`${base}/live/${a.link_id}/take`, { method: 'POST' })).status, 202);
});

test('sleep: a held link is released first (user_slept), a done link is refused', async () => {
    await start();
    const a = await (await api('/api/pod', { chat_key: KEY_A })).json();
    assert.equal((await (await fetch(`${base}/live/${a.link_id}/take`, { method: 'POST' })).json()).status, 'user');
    const r = await (await fetch(`${base}/live/${a.link_id}/sleep`, { method: 'POST' })).json();
    assert.deepEqual([r.status, r.reason, r.pod], ['watching', 'user_slept', 'asleep']);
    await api('/api/pod', { chat_key: KEY_A });
    await fetch(`${base}/live/${a.link_id}/end`, { method: 'POST' });
    const d = await fetch(`${base}/live/${a.link_id}/sleep`, { method: 'POST' });
    assert.equal(d.status, 409);
    assert.equal((await d.json()).error, 'user_ended');
});

test('sleep: without pods it answers 409 pods_disabled', async () => {
    await start({ withPods: false });
    const l = await (await api('/api/links', { session_id: 'shared1' })).json();
    const r = await fetch(`${base}/live/${l.id}/sleep`, { method: 'POST' });
    assert.equal(r.status, 409);
    assert.equal((await r.json()).error, 'pods_disabled');
});

// ── noVNC through the bridge ───────────────────────────────────────────────
// A raw GET: fetch() would normalise `..` before it is sent.
const rawGet = (path, headers = {}) => new Promise((resolve, reject) => {
    const u = new URL(base);
    const req = request({ host: u.hostname, port: u.port, path, headers }, (res) => {
        let body = '';
        res.on('data', (d) => { body += d; });
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on('error', reject);
    req.end();
});
const bridgePort = () => Number(new URL(base).port);

async function twoPods() {
    const upA = await fakeNovnc('A');
    const upB = await fakeNovnc('B');
    await start();
    pods.novncPortOf = (slot) => [upA.port, upB.port][slot];
    const a = await (await api('/api/pod', { chat_key: KEY_A })).json();
    const b = await (await api('/api/pod', { chat_key: KEY_B })).json();
    return { upA, upB, a, b };
}

test('vnc files: served from the link\'s own pod port, cookies and auth stripped both ways', async () => {
    const { upA, upB, a, b } = await twoPods();
    try {
        const ra = await rawGet(`/live/${a.link_id}/vnc/vnc.html`, { Cookie: 'c=1', Authorization: 'Bearer x', Accept: 'text/html' });
        assert.equal(ra.status, 200);
        assert.equal(ra.body, 'vnc:A:/vnc.html');
        for (const h of ['set-cookie', 'www-authenticate', 'location']) assert.equal(ra.headers[h], undefined, h);
        assert.equal(ra.headers['content-type'], 'text/html');
        const rb = await rawGet(`/live/${b.link_id}/vnc/app/ui.js?x=1`);
        assert.equal(rb.body, 'vnc:B:/app/ui.js', 'chat B reads its own pod, without the query');
        assert.deepEqual(upA.seen.http.map((r) => r.url), ['/vnc.html']);
        assert.deepEqual(upB.seen.http.map((r) => r.url), ['/app/ui.js']);
        const sent = upA.seen.http[0].headers;
        assert.equal(sent.cookie, undefined);
        assert.equal(sent.authorization, undefined);
        assert.equal(sent.host, `127.0.0.1:${upA.port}`);
        assert.equal(sent.accept, 'text/html');
        assert.ok(pods.calls.touch.includes(KEY_A));
        // Asleep: 503, not woken, nothing forwarded.
        await pods.stopChat(KEY_A, 'idle');
        assert.equal((await rawGet(`/live/${a.link_id}/vnc/vnc.html`)).status, 503);
        assert.deepEqual(pods.calls.wake, []);
        assert.equal(upA.seen.http.length, 1);
    } finally { await upA.close(); await upB.close(); }
});

test('vnc files: traversal, encoded dots and odd paths are refused before any upstream', async () => {
    const { upA, upB, a } = await twoPods();
    try {
        const id = a.link_id;
        for (const p of [`/live/${id}/vnc/../../api/pods`, `/live/${id}/vnc/app/../../x`, `/live/${id}/vnc/%2e%2e/x`, `/live/${id}/vnc/%2E%2E%2Fx`,
            `/live/${id}/vnc/.hidden`, `/live/${id}/vnc//etc/passwd`, `/live/${id}/vnc/a\\b`, `/live/${id}/vnc/`, `/live/${id}/vnc`,
            `/live/${id}/x/../vnc/vnc.html`, `/live/${id}/vnc/app/`, `/live/${id}/vnc/a%00b`]) {
            const r = await rawGet(p);
            assert.ok([400, 404].includes(r.status), `${p} -> ${r.status}`);
        }
        assert.equal(upA.seen.http.length + upB.seen.http.length, 0);
        // No open proxy: a port in the request goes nowhere.
        assert.equal((await rawGet(`/live/${id}/vnc/vnc.html`, { Host: `127.0.0.1:${upB.port}` })).body, 'vnc:A:/vnc.html');
        assert.equal(upB.seen.http.length, 0);
        // websockify without an upgrade is not proxied as a file.
        assert.equal((await rawGet(`/live/${id}/vnc/websockify`)).status, 426);
        assert.equal((await rawGet(`/live/${'0'.repeat(32)}/vnc/vnc.html`)).status, 404);
    } finally { await upA.close(); await upB.close(); }
});

test('vnc socket: only while the user holds the link, piped to that chat\'s pod, closed on release and on pod stop', async () => {
    const { upA, upB, a, b } = await twoPods();
    try {
        const path = (id) => `/live/${id}/vnc/websockify`;
        const watching = await wsHandshake(bridgePort(), path(a.link_id));
        assert.equal(watching.status, 403, 'watching: refused');
        assert.equal(upA.seen.ws.length, 0);

        await fetch(`${base}/live/${a.link_id}/take`, { method: 'POST' });
        const ws = await wsHandshake(bridgePort(), path(a.link_id));
        assert.equal(ws.status, 101);
        assert.equal(ws.headers['set-cookie'], undefined);
        assert.ok(ws.headers['sec-websocket-accept']);
        assert.ok((await ws.read('hello:A')).includes('hello:A'));
        ws.socket.write('ping-1');
        assert.ok((await ws.read('ping-1')).includes('ping-1'), 'bytes go both ways');
        assert.equal(upA.seen.ws.length, 1);
        assert.equal(upB.seen.ws.length, 0, 'never another chat\'s pod');
        assert.equal(upA.seen.ws[0].url, '/websockify');
        assert.equal(upA.seen.ws[0].headers.cookie, undefined);
        assert.equal(upA.seen.ws[0].headers.authorization, undefined);

        // B is not held: refused, though A is.
        assert.equal((await wsHandshake(bridgePort(), path(b.link_id))).status, 403);

        await fetch(`${base}/live/${a.link_id}/release`, { method: 'POST' });
        assert.ok(await ws.waitClosed(), 'release closes the socket');

        // A takeover is held too; its pod stopping closes the socket.
        await api('/api/takeover', { chat_key: KEY_B, reason: 'sign in' });
        const wb = await wsHandshake(bridgePort(), path(b.link_id));
        assert.equal(wb.status, 101);
        assert.ok((await wb.read('hello:B')).includes('hello:B'));
        await pods.stopChat(KEY_B, 'idle');
        assert.ok(await wb.waitClosed(), 'the pod stopping closes the socket');
        assert.equal((await wsHandshake(bridgePort(), path(b.link_id))).status, 503, 'asleep: refused');
    } finally { await upA.close(); await upB.close(); }
});

test('vnc socket: end closes it; unknown links and other upgrades are refused', async () => {
    const { upA, upB, a } = await twoPods();
    try {
        await fetch(`${base}/live/${a.link_id}/take`, { method: 'POST' });
        const ws = await wsHandshake(bridgePort(), `/live/${a.link_id}/vnc/websockify`);
        assert.equal(ws.status, 101);
        await fetch(`${base}/live/${a.link_id}/end`, { method: 'POST' });
        assert.ok(await ws.waitClosed(), 'end closes the socket');
        assert.equal((await wsHandshake(bridgePort(), `/live/${'0'.repeat(32)}/vnc/websockify`)).status, 404);
        for (const p of ['/api/pods', `/live/${a.link_id}`, `/live/${a.link_id}/vnc/vnc.html`, '/websockify', `/live/${a.link_id}/vnc/../vnc/websockify`]) {
            assert.equal((await wsHandshake(bridgePort(), p)).status, 404, p);
        }
        assert.equal(upA.seen.ws.length + upB.seen.ws.length, 1);
    } finally { await upA.close(); await upB.close(); }
});

test('shutdown: a held pod link is released, its socket closed and its login saved; the pod keeps running', async () => {
    const { upA, upB, a, b } = await twoPods();
    try {
        await fetch(`${base}/live/${a.link_id}/take`, { method: 'POST' });
        const ws = await wsHandshake(bridgePort(), `/live/${a.link_id}/vnc/websockify`);
        assert.equal(ws.status, 101);
        const released = await bridgeApp.shutdown();
        assert.deepEqual(released.map((r) => r.id), [a.link_id.slice(0, 8)]);
        assert.ok(await ws.waitClosed());
        assert.deepEqual(pods.calls.checkpoint, [{ key: KEY_A, force: true }]);
        assert.deepEqual(pods.calls.stop, [], 'no pod is stopped');
        const st = await (await api('/api/state', { chat_key: KEY_A })).json();
        assert.deepEqual([st.status, st.reason, st.pod], ['watching', 'bridge_restarting', 'running']);
        assert.equal((await (await api('/api/state', { chat_key: KEY_B })).json()).reason, null);
        void b;
    } finally { await upA.close(); await upB.close(); }
});

test('vnc: a link with no pod uses the shared noVNC port', async () => {
    const shared = await fakeNovnc('shared');
    const upA = await fakeNovnc('A');
    try {
        await start({ novncUrl: `http://localhost:${shared.port}/vnc.html?autoconnect=true&resize=scale` });
        pods.novncPortOf = () => upA.port;
        const l = await (await api('/api/links', { session_id: 'shared1' })).json();
        assert.equal((await rawGet(`/live/${l.id}/vnc/vnc.html`)).body, 'vnc:shared:/vnc.html');
        const t = await (await fetch(`${base}/live/${l.id}/take`, { method: 'POST' })).json();
        assert.equal(t.novnc_url, `http://localhost:6090/live/${l.id}/vnc/vnc.html?autoconnect=true&resize=scale&path=websockify#password=sharedpw`);
        const ws = await wsHandshake(bridgePort(), `/live/${l.id}/vnc/websockify`);
        assert.equal(ws.status, 101);
        assert.ok((await ws.read('hello:shared')).includes('hello:shared'));
        assert.equal(upA.seen.ws.length + upA.seen.http.length, 0);
    } finally { await shared.close(); await upA.close(); }
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

function mcpHarness({ chat = { key: KEY_A, source: 'happy' }, podsOn = true, refuseOnce = false, recoverOnce = null, capped = false, shared: sharedMode = 'ok' } = {}) {
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
    const shared = {
        listTools: async () => UP_TOOLS,
        async callTool(name, args) {
            if (sharedMode === 'down') throw new Error('auto-browser MCP unreachable (ECONNREFUSED). Is the browser stack up?');
            seen.calls.push({ url: 'shared', name, args });
            if (sharedMode === 'gone' && name === 'browser.get_session') return { result: { isError: true, content: [{ type: 'text', text: 'No session with id x1 (unknown_session)' }] } };
            return { result: { content: [] } };
        },
    };
    const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
    const fetchImpl = async (url, init) => {
        const path = new URL(url).pathname;
        const body = JSON.parse(init.body || '{}');
        seen.bridge.push({ path, body });
        if (!podsOn && (path.startsWith('/api/pod') || path === '/api/tools')) return json(409, { error: 'pods_disabled' });
        if (path === '/api/tools') return json(200, { tools: UP_TOOLS });
        if (path === '/api/pod') {
            const key = body.chat_key;
            if (capped && body.check) return json(503, { error: "this chat's browser died 2 times in 5 minutes; not restarting it again yet", code: 'recovery_limit' });
            if (!podFor.has(key) || body.verify) podFor.set(key, { slot: n, sid: `pod${n++}` });
            const p = podFor.get(key);
            let recovered;
            if (recoverOnce && body.check) { recovered = recoverOnce; recoverOnce = null; p.sid = `pod${n++}`; }
            if (recovered) return json(200, { chat_key: key, session_id: p.sid, recovered, mcp_url: `http://127.0.0.1:${8100 + p.slot}/mcp`, api_url: `http://127.0.0.1:${8100 + p.slot}`, link_id: `L${p.slot}`, url: `http://localhost/live/L${p.slot}` });
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
    assert.deepEqual(h.seen.calls.map((x) => [x.name, x.args.session_id, x.args.action?.url ?? null]), [['browser.execute_action', 'pod0', 'https://example.com/'], ['browser.get_session', 'pod0', null]]);
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
    // The preflight asks for the session first.
    assert.deepEqual(h.seen.calls.map((c) => [c.url, c.name, c.args.session_id]), [['shared', 'browser.get_session', 'x1'], ['shared', 'browser.observe', 'x1']]);
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

test('fork parent: only from HAPPY_FORKED_FROM_SESSION_ID, for a Happy chat, checked first', () => {
    const parent = chatKeyOf({ source: 'happy', id: 'parent-1' });
    assert.equal(forkParentKey({ HAPPY_SESSION_ID: 'child-1', HAPPY_FORKED_FROM_SESSION_ID: 'parent-1' }), parent);
    assert.equal(forkParentKey({ HAPPY_SESSION_ID: 'child-1' }), null, 'not a fork');
    assert.equal(forkParentKey({ HAPPY_SESSION_ID: 'child-1', HAPPY_FORKED_FROM_SESSION_ID: '' }), null);
    assert.equal(forkParentKey({ HAPPY_SESSION_ID: 'child-1', HAPPY_FORKED_FROM_SESSION_ID: 'child-1' }), null, 'never itself');
    assert.equal(forkParentKey({ HAPPY_SESSION_ID: 'child-1', HAPPY_FORKED_FROM_SESSION_ID: '../x' }), null, 'bad id refused');
    assert.equal(forkParentKey({ HAPPY_SESSION_ID: 'child-1', HAPPY_FORKED_FROM_SESSION_ID: 'p'.repeat(129) }), null);
    assert.equal(forkParentKey({ CLAUDE_CODE_SESSION_ID: 'c1', HAPPY_FORKED_FROM_SESSION_ID: 'parent-1' }), null, 'only a Happy chat');
    assert.equal(forkParentKey({ HAPPY_FORKED_FROM_SESSION_ID: 'parent-1' }), null);
});

test('/api/pod passes a valid forked_from to the pod manager and refuses a bad one', async () => {
    await start();
    const r = await api('/api/pod', { chat_key: KEY_A, source: 'happy', forked_from: KEY_B });
    assert.equal(r.status, 200);
    assert.deepEqual(pods.calls.ensure.at(-1), { key: KEY_A, source: 'happy', forkedFrom: KEY_B });
    await api('/api/pod', { chat_key: KEY_B, source: 'happy' });
    assert.deepEqual(pods.calls.ensure.at(-1), { key: KEY_B, source: 'happy' }, 'no fork, no forkedFrom');
    const n = pods.calls.ensure.length;
    for (const bad of ['nothex', 'A'.repeat(32), KEY_A, 42, { k: 1 }]) {
        const b = await api('/api/pod', { chat_key: KEY_A, forked_from: bad });
        assert.equal(b.status, 400, JSON.stringify(bad));
    }
    assert.equal(pods.calls.ensure.length, n, 'a refused forked_from starts nothing');
});

test('router: a forked chat names its parent on every pod request; no tool argument can', async () => {
    const PARENT = 'e'.repeat(32);
    const h = mcpHarness({ chat: { key: KEY_A, source: 'happy', forkedFrom: PARENT } });
    await h.call('browser_observe', { forked_from: 'f'.repeat(32) });
    await h.call('browser_create_session', {});
    const reqs = h.seen.bridge.filter((b) => b.path === '/api/pod');
    assert.ok(reqs.length >= 1);
    assert.ok(reqs.every((b) => b.body.chat_key === KEY_A && b.body.forked_from === PARENT), JSON.stringify(reqs));

    const plain = mcpHarness();
    await plain.call('browser_observe', { forked_from: 'f'.repeat(32) });
    const preqs = plain.seen.bridge.filter((b) => b.path === '/api/pod');
    assert.ok(preqs.length >= 1 && preqs.every((b) => !('forked_from' in b.body)), 'a non-fork never sends one');
});

test('preflight: every pod call asks the bridge to check the session; an alive one goes on as before', async () => {
    const h = mcpHarness();
    const r = await h.call('browser_execute_action', { action: 'click' });
    assert.equal(r.result.isError, undefined);
    assert.ok(h.seen.bridge.filter((b) => b.path === '/api/pod').every((b) => b.body.check === true && b.body.chat_key === KEY_A));
});

test('preflight: a recovered browser answers a read-only call with a note, and refuses one that changes the page', async () => {
    const recovered = { reason: 'session_ended', previous_session_id: 'pod0' };
    const ro = mcpHarness({ recoverOnce: recovered });
    const o = await ro.call('browser_observe', {});
    assert.equal(o.result.isError, undefined);
    assert.match(o.result.content.map((c) => c.text).join('\n'), /restarted \(its session ended\).*pod0 is gone.*now session pod1/);
    assert.equal(ro.seen.calls[0].args.session_id, 'pod1');

    const mu = mcpHarness({ recoverOnce: recovered });
    const x = await mu.call('browser_execute_action', { action: 'click' });
    assert.equal(x.result.isError, true);
    assert.match(x.result.content[0].text, /observe the page again/);
    assert.equal(mu.seen.calls.length, 0, 'nothing reached the pod');
    // The next call is against the recovered browser as usual.
    assert.equal((await mu.call('browser_execute_action', { action: 'click' })).result.isError, undefined);
});

test('preflight: the loop cap comes back as a clear error', async () => {
    const h = mcpHarness({ capped: true });
    const r = await h.call('browser_observe', {});
    assert.equal(r.result.isError, true);
    assert.match(r.result.content[0].text, /died 2 times in 5 minutes/);
    assert.equal(h.seen.calls.length, 0);
});

test('preflight: shared browser (no pods) is never recovered: a gone session or a down browser is a clear error', async () => {
    const gone = mcpHarness({ podsOn: false, shared: 'gone' });
    await gone.list();
    const g = await gone.call('browser_execute_action', { session_id: 'x1', action: 'click' });
    assert.equal(g.result.isError, true);
    assert.match(g.result.content[0].text, /Session x1 is gone \(unknown session\).*browser_create_session/);
    assert.ok(!gone.seen.calls.some((c) => c.name === 'browser.execute_action'));
    assert.ok(!gone.seen.bridge.some((b) => b.path === '/api/pod' && b.body.check), 'nothing asks for a pod');
    const down = mcpHarness({ podsOn: false, shared: 'down' });
    const d = await down.call('browser_observe', { session_id: 'x1' });
    assert.equal(d.result.isError, true);
});

test('phantoms: live is false with pod and live_reason once the browser is gone, everywhere the app looks; a held link is released', async () => {
    await start();
    const a = await (await api('/api/pod', { chat_key: KEY_A })).json();
    const t = await fetch(`${base}/live/${a.link_id}/take`, { method: 'POST' });
    assert.equal((await t.json()).live, true);
    // The pod goes away under the held link (reaped, crashed).
    pods.chats.get(KEY_A).state = 'crashed';
    const d = await (await fetch(`${base}/live/chat/${KEY_A}`)).json();
    assert.deepEqual([d.live, d.pod, d.live_reason], [false, 'dead', 'crashed']);
    const s = await (await fetch(`${base}/live/${a.link_id}/state`)).json();
    assert.deepEqual([s.live, s.pod], [false, 'dead']);
    const st = await (await api('/api/state', { chat_key: KEY_A })).json();
    assert.equal(st.live, false);
    assert.equal(bridgeApp.sweepLinks(), 1);
    const after = await (await fetch(`${base}/live/${a.link_id}/state`)).json();
    assert.deepEqual([after.status, after.reason], ['watching', 'browser_asleep']);
    // Ended by the user: done, never live.
    await fetch(`${base}/live/${a.link_id}/end`, { method: 'POST' });
    const e = await (await fetch(`${base}/live/chat/${KEY_A}`)).json();
    assert.deepEqual([e.live, e.live_reason], [false, 'user_ended']);
});
