// node:test suite for the bridge, with auto-browser mocked.
import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBridge } from '../lib/app.mjs';
import { LinkStore, ID_PATTERN } from '../lib/store.mjs';
import { createMcpServer } from '../mcp.mjs';

const BRIDGE_TOKEN = 'bridge-secret-token-0123456789abcdef';
const VNC_PASSWORD = 'Vnc8Pass';
const SHARE_PREFIX = 'share-tok-';
const PNG = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex');

function mockClient() {
    const calls = { share: 0, observe: 0, frame: 0, takeover: [], getSession: 0 };
    const sessions = new Map([['sess1', { id: 'sess1', current_url: 'https://news.ycombinator.com/', title: 'Hacker News' }]]);
    let shareN = 0;
    const notFound = () => Object.assign(new Error('not found'), { status: 404 });
    return {
        calls,
        sessions,
        async getSession(id) { calls.getSession++; if (!sessions.has(id)) throw notFound(); return sessions.get(id); },
        async share(id) {
            calls.share++;
            if (!sessions.has(id)) throw notFound();
            return { token: `${SHARE_PREFIX}${++shareN}`, session_id: id, expires_at: clock.t / 1000 + 86400 };
        },
        async observeShared(token) {
            calls.observe++;
            const s = [...sessions.values()][0];
            if (!s) throw notFound();
            return { session: { id: s.id }, url: s.current_url, title: s.title, screenshot_url: `/share/${token}/screenshots/x.png` };
        },
        async fetchFrame(path) { calls.frame++; assert.ok(path.startsWith('/share/')); return { contentType: 'image/png', body: PNG }; },
        async requestTakeover(id, reason) { if (!sessions.has(id)) throw notFound(); calls.takeover.push({ id, reason }); return {}; },
    };
}

let server, base, client, store, clock, logs, dir;

async function start({ idleMs = 12 * 3600_000 } = {}) {
    clock = { t: 1_800_000_000_000 };
    const now = () => clock.t;
    dir = mkdtempSync(join(tmpdir(), 'bridge-test-'));
    client = mockClient();
    store = new LinkStore({ path: join(dir, 'links.json'), idleMs, now });
    logs = [];
    const bridge = createBridge({
        client, store, now, log: (l) => logs.push(l),
        config: { bridgeToken: BRIDGE_TOKEN, vncPassword: VNC_PASSWORD, frameCacheMs: 1000 },
    });
    server = createServer(bridge.handler);
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${server.address().port}`;
}

beforeEach(() => start());
afterEach(() => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }));

const api = (path, body, token = BRIDGE_TOKEN) => fetch(base + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
});
const link = async (sid = 'sess1') => (await api('/api/links', { session_id: sid })).json();

test('api requires the bridge token', async () => {
    assert.equal((await api('/api/links', { session_id: 'sess1' }, null)).status, 401);
    assert.equal((await api('/api/links', { session_id: 'sess1' }, 'wrong')).status, 401);
    assert.equal((await fetch(base + '/api/links', { headers: { Authorization: `Bearer ${BRIDGE_TOKEN}` } })).status, 405);
});

test('links are 128-bit hex ids, stable per session, and unknown sessions are rejected', async () => {
    const a = await link();
    assert.match(a.id, ID_PATTERN);
    assert.equal(a.url, `http://localhost:6090/live/${a.id}`);
    assert.equal(a.status, 'watching');
    assert.equal((await link()).id, a.id);
    assert.equal((await api('/api/links', { session_id: 'nope' })).status, 404);
    assert.equal((await api('/api/links', { session_id: '../x' })).status, 400);
});

test('page, state and frame routes', async () => {
    const { id } = await link();
    const page = await fetch(`${base}/live/${id}`);
    assert.equal(page.status, 200);
    assert.match(page.headers.get('content-type'), /text\/html/);
    assert.match(page.headers.get('content-security-policy'), /script-src 'nonce-/);
    const html = await page.text();
    assert.match(html, /name="viewport"/);
    assert.match(html, /prefers-color-scheme: dark/);
    assert.match(html, /Take control/);
    assert.ok(html.includes(`#password=${VNC_PASSWORD}`), 'Take control link carries the VNC password');

    const state = await (await fetch(`${base}/live/${id}/state`)).json();
    assert.deepEqual(state, { status: 'watching', reason: null, url: 'https://news.ycombinator.com/', title: 'Hacker News' });

    const f = await fetch(`${base}/live/${id}/frame.jpg`);
    assert.equal(f.status, 200);
    assert.equal(f.headers.get('content-type'), 'image/png');
    assert.deepEqual(Buffer.from(await f.arrayBuffer()), PNG);
    assert.equal((await fetch(`${base}/live/${id}/frame.jpg`, { method: 'POST' })).status, 405);
    assert.equal((await fetch(`${base}/live/${id}/done`)).status, 405);
});

test('frames are cached for about a second and concurrent fetches coalesce', async () => {
    const { id } = await link();
    await Promise.all([1, 2, 3].map(() => fetch(`${base}/live/${id}/frame.jpg`).then((r) => r.arrayBuffer())));
    assert.equal(client.calls.observe, 1);
    await fetch(`${base}/live/${id}/frame.jpg`).then((r) => r.arrayBuffer());
    assert.equal(client.calls.observe, 1);
    clock.t += 1500;
    await fetch(`${base}/live/${id}/frame.jpg`).then((r) => r.arrayBuffer());
    assert.equal(client.calls.observe, 2);
    assert.equal(client.calls.share, 1, 'share token reused');
});

test('unknown id is 404, expired id is 410', async () => {
    assert.equal((await fetch(`${base}/live/${'0'.repeat(32)}`)).status, 404);
    assert.equal((await fetch(`${base}/live/not-an-id/state`)).status, 404);
    const { id } = await link();
    clock.t += 11 * 3600_000;
    assert.equal((await fetch(`${base}/live/${id}/state`)).status, 200, 'viewing resets the idle clock');
    clock.t += 12 * 3600_000 + 1000;
    for (const sub of ['', '/state', '/frame.jpg']) assert.equal((await fetch(`${base}/live/${id}${sub}`)).status, 410, sub);
    assert.equal((await fetch(`${base}/live/${id}/done`, { method: 'POST' })).status, 410);
    assert.equal((await api('/api/wait', { id, wait_s: 0 })).status, 410);
    const fresh = await link();
    assert.notEqual(fresh.id, id, 'a new link replaces the expired one');
});

test('takeover then done wakes a waiter', async () => {
    const t = await (await api('/api/takeover', { session_id: 'sess1', reason: 'Log in please' })).json();
    assert.equal(t.status, 'takeover');
    assert.deepEqual(client.calls.takeover, [{ id: 'sess1', reason: 'Log in please' }]);
    const state = await (await fetch(`${base}/live/${t.id}/state`)).json();
    assert.equal(state.status, 'takeover');
    assert.equal(state.reason, 'Log in please');

    const waiting = api('/api/wait', { id: t.id, wait_s: 30 }).then((r) => r.json());
    await new Promise((r) => setTimeout(r, 50));
    const done = await (await fetch(`${base}/live/${t.id}/done`, { method: 'POST' })).json();
    assert.equal(done.status, 'done');
    assert.equal((await waiting).status, 'done');
});

test('wait times out while still in takeover; release returns it to watching', async () => {
    const t = await (await api('/api/takeover', { session_id: 'sess1', reason: 'CAPTCHA' })).json();
    const started = Date.now();
    const w = await (await api('/api/wait', { id: t.id, wait_s: 1 })).json();
    assert.equal(w.status, 'takeover');
    assert.ok(Date.now() - started >= 900);
    const r = await (await api('/api/release', { id: t.id, reason: 'timeout' })).json();
    assert.equal(r.status, 'watching');
});

test('a closed session reports done/session_closed', async () => {
    const { id } = await link();
    client.sessions.clear();
    assert.equal((await fetch(`${base}/live/${id}/frame.jpg`)).status, 404);
    await new Promise((r) => setTimeout(r, 20));
    const s = await (await fetch(`${base}/live/${id}/state`)).json();
    assert.equal(s.status, 'done');
    assert.equal(s.reason, 'session_closed');
});

test('no secrets in state, logs or the store file', async () => {
    const t = await (await api('/api/takeover', { session_id: 'sess1', reason: 'x' })).json();
    await fetch(`${base}/live/${t.id}/frame.jpg`).then((r) => r.arrayBuffer());
    const stateText = await (await fetch(`${base}/live/${t.id}/state`)).text();
    store.flush();
    const file = join(dir, 'links.json');
    assert.equal(statSync(file).mode & 0o777, 0o600);
    for (const text of [stateText, logs.join('\n'), readFileSync(file, 'utf8')]) {
        assert.ok(!text.includes(BRIDGE_TOKEN));
        assert.ok(!text.includes(VNC_PASSWORD));
        assert.ok(!text.includes(SHARE_PREFIX));
    }
    assert.ok(!logs.join('\n').includes(t.id), 'logs carry only a link-id prefix');
});

test('a deleted session (status closed) is refused and reported closed', async () => {
    const { id } = await link();
    client.sessions.get('sess1').status = 'closed';
    assert.equal((await api('/api/links', { session_id: 'sess1' })).status, 404);
    assert.equal((await api('/api/takeover', { session_id: 'sess1', reason: 'x' })).status, 404);
    // The share route 404s for a closed session; the bridge confirms via getSession.
    const observe = client.observeShared;
    client.observeShared = async () => { throw Object.assign(new Error('gone'), { status: 404 }); };
    assert.equal((await fetch(`${base}/live/${id}/frame.jpg`)).status, 404);
    client.observeShared = observe;
    await new Promise((r) => setTimeout(r, 20));
    const s = await (await fetch(`${base}/live/${id}/state`)).json();
    assert.deepEqual([s.status, s.reason], ['done', 'session_closed']);
});

test('links survive a restart through the store file', async () => {
    const { id } = await link();
    store.flush();
    const again = new LinkStore({ path: join(dir, 'links.json'), now: () => clock.t });
    assert.equal(again.lookup(id).rec.sessionId, 'sess1');
});

// ── MCP server over the bridge ───────────────────────────────────────────
function mcpHarness(pollS = 1) {
    const out = [];
    const server = createMcpServer({ bridgeUrl: base, bridgeToken: BRIDGE_TOKEN, write: (m) => out.push(m), pollS });
    const call = async (id, name, args, meta) => {
        await server.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args, ...(meta ? { _meta: meta } : {}) } });
        return out.find((m) => m.id === id);
    };
    return { server, out, call };
}

test('mcp: initialize and tools/list', async () => {
    const { server, out } = mcpHarness();
    await server.handle({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26' } });
    await server.handle({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
    assert.equal(out[0].result.protocolVersion, '2025-03-26');
    const names = out[1].result.tools.map((t) => t.name);
    assert.deepEqual(names, ['browser_live_link', 'browser_wait_for_human']);
    for (const t of out[1].result.tools) assert.ok(!('client_id' in t.inputSchema.properties));
    assert.match(out[1].result.tools[0].description, /post/i);
});

test('mcp: browser_live_link returns the link', async () => {
    const { call } = mcpHarness();
    const r = await call(3, 'browser_live_link', { session_id: 'sess1' });
    assert.match(r.result.structuredContent.link, /^http:\/\/localhost:6090\/live\/[0-9a-f]{32}$/);
    const bad = await call(4, 'browser_live_link', { session_id: 'missing' });
    assert.equal(bad.result.isError, true);
});

test('mcp: browser_wait_for_human returns done when the user taps Done', async () => {
    const { call, out } = mcpHarness();
    const pending = call(5, 'browser_wait_for_human', { session_id: 'sess1', reason: 'Sign in', timeout_s: 30 }, { progressToken: 'p1' });
    await new Promise((r) => setTimeout(r, 100));
    const prog = out.find((m) => m.method === 'notifications/progress');
    assert.equal(prog.params.progressToken, 'p1');
    const linkUrl = prog.params.message.match(/http:\/\/localhost:6090\/live\/([0-9a-f]{32})/);
    assert.ok(linkUrl, 'progress carries the link');
    await fetch(`${base}/live/${linkUrl[1]}/done`, { method: 'POST' });
    const r = await pending;
    assert.equal(r.result.structuredContent.status, 'done');
});

test('mcp: browser_wait_for_human times out and releases the takeover', async () => {
    const { call } = mcpHarness(1);
    const r = await call(6, 'browser_wait_for_human', { session_id: 'sess1', reason: 'Sign in', timeout_s: 5 });
    assert.equal(r.result.structuredContent.status, 'timeout');
    const id = r.result.structuredContent.link.split('/').pop();
    const s = await (await fetch(`${base}/live/${id}/state`)).json();
    assert.equal(s.status, 'watching');
});
