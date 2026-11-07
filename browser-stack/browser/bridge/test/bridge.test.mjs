// node:test suite for the bridge, with auto-browser mocked.
import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request as httpRequest } from 'node:http';
import { mkdtempSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBridge, navUrl } from '../lib/app.mjs';
import { LinkStore, ID_PATTERN } from '../lib/store.mjs';
import { createMcpServer } from '../mcp.mjs';
import { fakeNovnc, wsHandshake } from './fake-novnc.mjs';
import { loadConfig } from '../lib/config.mjs';

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
        async navigate(id, action, url) {
            (calls.nav ??= []).push({ id, action, url });
            const s = sessions.get(id);
            if (action === 'goto') Object.assign(s, { current_url: url, title: `T ${url}` });
            return s;
        },
        async closeSession(id) {
            (calls.close ??= []).push(id);
            if (!sessions.has(id)) throw notFound();
            sessions.set(id, { ...sessions.get(id), status: 'closed' });
            return { id, status: 'closed' };
        },
    };
}

let server, base, client, store, clock, logs, dir, bridgeApp;
async function start({ idleMs = 12 * 3600_000, config = {} } = {}) {
    clock = { t: 1_800_000_000_000 };
    const now = () => clock.t;
    dir = mkdtempSync(join(tmpdir(), 'bridge-test-'));
    client = mockClient();
    store = new LinkStore({ path: join(dir, 'links.json'), idleMs, now });
    logs = [];
    const bridge = bridgeApp = createBridge({
        client, store, now, log: (l) => logs.push(l),
        config: { bridgeToken: BRIDGE_TOKEN, vncPassword: VNC_PASSWORD, frameCacheMs: 1000, tunnelCheckMs: 50, ...config },
    });
    server = createServer(bridge.handler);
    server.on('upgrade', bridge.upgrade);
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${server.address().port}`;
}

beforeEach(() => start());
afterEach(() => new Promise((r) => { bridgeApp?.close(); server.closeAllConnections?.(); server.close(r); }));

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
    assert.ok(!html.includes(VNC_PASSWORD), 'the page never carries the VNC password (POST /take does)');
    assert.match(html, />Release control</);
    assert.match(html, /You have control/);
    assert.match(html, /fetch\(base \+ '\/take', \{ method: 'POST' \}\)/);
    assert.match(html, /fetch\(base \+ '\/release', \{ method: 'POST' \}\)/);

    const state = await (await fetch(`${base}/live/${id}/state`)).json();
    assert.deepEqual(state, { status: 'watching', reason: null, url: 'https://news.ycombinator.com/', title: 'Hacker News', last_action: null, approval: null, live: true, live_reason: null });

    const f = await fetch(`${base}/live/${id}/frame.jpg`);
    assert.equal(f.status, 200);
    assert.equal(f.headers.get('content-type'), 'image/png');
    assert.deepEqual(Buffer.from(await f.arrayBuffer()), PNG);
    assert.equal((await fetch(`${base}/live/${id}/frame.jpg`, { method: 'POST' })).status, 405);
    assert.equal((await fetch(`${base}/live/${id}/done`)).status, 405);
    assert.equal((await fetch(`${base}/live/${id}/take`)).status, 405);
    assert.equal((await fetch(`${base}/live/${id}/release`)).status, 405);
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

test("a frame's age counts from when it was asked for, not from when the slow capture ended", async () => {
    const { id } = await link();
    const observe = client.observeShared;
    client.observeShared = async (token) => { clock.t += 700; return observe.call(client, token); };
    try {
        await fetch(`${base}/live/${id}/frame.jpg`).then((r) => r.arrayBuffer());
        assert.equal(client.calls.observe, 1);
        clock.t += 400; // 1.1 s after it was asked for, 0.4 s after it came
        await fetch(`${base}/live/${id}/frame.jpg`).then((r) => r.arrayBuffer());
        assert.equal(client.calls.observe, 2);
    } finally {
        client.observeShared = observe;
    }
});

test('a slow capture: the earlier frame answers after frameWaitMs; a failed one still fails; a stale one waits', async () => {
    bridgeApp.close();
    server.closeAllConnections?.();
    await new Promise((r) => server.close(r));
    await start({ config: { frameWaitMs: 100, frameStaleMs: 15_000 } });
    const { id } = await link();
    const first = Buffer.from('first');
    const frameOf = client.fetchFrame;
    client.fetchFrame = async () => ({ contentType: 'image/png', body: first });
    await fetch(`${base}/live/${id}/frame.jpg`).then((r) => r.arrayBuffer());
    // The next capture is held (a screenshot and scrub under an action), well past frameWaitMs.
    let release;
    const held = new Promise((r) => { release = r; });
    client.fetchFrame = async () => { await held; return { contentType: 'image/png', body: PNG }; };
    try {
        clock.t += 1500;
        const started = Date.now();
        const r = await fetch(`${base}/live/${id}/frame.jpg`);
        assert.equal(r.status, 200);
        assert.deepEqual(Buffer.from(await r.arrayBuffer()), first, 'the earlier frame, not a wait');
        assert.ok(Date.now() - started < 1000, 'answered within about frameWaitMs');
        assert.equal(client.calls.observe, 2);
        release();
        await new Promise((r) => setTimeout(r, 20));
        assert.deepEqual(Buffer.from(await (await fetch(`${base}/live/${id}/frame.jpg`)).arrayBuffer()), PNG, 'then the new one');

        // A capture that fails answers as a failure, earlier frame or not.
        clock.t += 1500;
        client.fetchFrame = async () => { throw Object.assign(new Error('gone'), { status: 404 }); };
        assert.equal((await fetch(`${base}/live/${id}/frame.jpg`)).status, 502);

        // An earlier frame older than frameStaleMs does not stand in: the read waits.
        clock.t += 20_000;
        let release2;
        const held2 = new Promise((r) => { release2 = r; });
        client.fetchFrame = async () => { await held2; return { contentType: 'image/png', body: first }; };
        let answered = false;
        const pending = fetch(`${base}/live/${id}/frame.jpg`).then(async (res) => { answered = true; return Buffer.from(await res.arrayBuffer()); });
        await new Promise((r) => setTimeout(r, 300));
        assert.equal(answered, false, 'a stale frame does not stand in');
        release2();
        assert.deepEqual(await pending, first);
    } finally {
        client.fetchFrame = frameOf;
        release();
    }
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

test('takeover then done (the old alias of release) wakes a waiter', async () => {
    const t = await (await api('/api/takeover', { session_id: 'sess1', reason: 'Log in please' })).json();
    assert.equal(t.status, 'takeover');
    assert.deepEqual(client.calls.takeover, [{ id: 'sess1', reason: 'Log in please' }]);
    const state = await (await fetch(`${base}/live/${t.id}/state`)).json();
    assert.equal(state.status, 'takeover');
    assert.equal(state.reason, 'Log in please');

    const waiting = api('/api/wait', { id: t.id, wait_s: 30 }).then((r) => r.json());
    await new Promise((r) => setTimeout(r, 50));
    const done = await (await fetch(`${base}/live/${t.id}/done`, { method: 'POST' })).json();
    assert.equal(done.status, 'watching');
    assert.equal((await waiting).status, 'watching');
});

const post = (id, sub) => fetch(`${base}/live/${id}/${sub}`, { method: 'POST' });

test('take: watching -> user with the noVNC url; release -> watching', async () => {
    const { id } = await link();
    const r = await post(id, 'take');
    assert.equal(r.status, 200);
    const t = await r.json();
    assert.deepEqual([t.status, t.reason], ['user', 'user_took_control']);
    assert.ok(t.novnc_url.includes(`#password=${VNC_PASSWORD}`));
    assert.equal((await (await fetch(`${base}/live/${id}/state`)).json()).status, 'user');
    assert.equal((await (await post(id, 'take')).json()).status, 'user', 'taking twice is a no-op');
    const rel = await (await post(id, 'release')).json();
    assert.deepEqual([rel.status, rel.reason], ['watching', 'user_released']);
    assert.equal((await (await post(id, 'release')).json()).status, 'watching', 'releasing twice is a no-op');
    store.flush();
    const saved = JSON.parse(readFileSync(join(dir, 'links.json'), 'utf8')).links[0];
    assert.equal(saved.status, 'watching');
});

test('take: the noVNC url goes through the bridge port, with path= and the password in the fragment', async () => {
    const { id } = await link();
    const t = await (await post(id, 'take')).json();
    assert.equal(t.novnc_url, `http://localhost:6090/live/${id}/vnc/vnc.html?autoconnect=true&resize=scale&path=websockify#password=${VNC_PASSWORD}`);
    // As noVNC 1.6 does it: path= against the page's own URL.
    const nv = new URL(t.novnc_url);
    assert.equal(new URL(nv.searchParams.get('path'), nv).pathname, `/live/${id}/vnc/websockify`);
    const u = new URL(t.novnc_url);
    assert.equal(u.port, '6090');
    assert.equal(u.searchParams.get('path'), 'websockify');
    assert.equal(u.hash, `#password=${VNC_PASSWORD}`);
    assert.ok(!u.search.includes(VNC_PASSWORD), 'the password is never in the query');
    // The page's Take control link is the same URL without the password.
    const html = await (await fetch(`${base}/live/${id}`)).text();
    assert.ok(html.includes(`/live/${id}/vnc/vnc.html?autoconnect=true&amp;resize=scale&amp;path=websockify"`));
    assert.ok(!html.includes(VNC_PASSWORD));
});

async function restartWithNovnc(extra = {}) {
    const up = await fakeNovnc('shared');
    bridgeApp.close();
    server.closeAllConnections?.();
    await new Promise((r) => server.close(r));
    await start({ config: { novncUrl: `http://localhost:${up.port}/vnc.html?autoconnect=true&resize=scale`, ...extra } });
    return up;
}

test('vnc files and socket of a shared link: the shared noVNC port; unknown 404, expired 410', async () => {
    const up = await restartWithNovnc();
    try {
        const { id } = await link();
        const f = await fetch(`${base}/live/${id}/vnc/vnc.html`);
        assert.equal(f.status, 200);
        assert.equal(await f.text(), 'vnc:shared:/vnc.html');
        assert.equal((await fetch(`${base}/live/${'0'.repeat(32)}/vnc/vnc.html`)).status, 404);
        const bport = Number(new URL(base).port);
        assert.equal((await wsHandshake(bport, `/live/${id}/vnc/websockify`)).status, 403, 'watching: refused');
        await post(id, 'take');
        const ws = await wsHandshake(bport, `/live/${id}/vnc/websockify`);
        assert.equal(ws.status, 101);
        assert.ok((await ws.read('hello:shared')).includes('hello:shared'));
        assert.ok(!logs.join('\n').includes(VNC_PASSWORD), 'the password is never logged');
        assert.ok(!logs.join('\n').includes(id), 'logs carry only a link-id prefix');
        // Expiry closes the socket and the routes answer 410.
        clock.t += 12 * 3600_000 + 1000;
        assert.ok(await ws.waitClosed(), 'an expired link closes its socket');
        assert.equal((await fetch(`${base}/live/${id}/vnc/vnc.html`)).status, 410);
        assert.equal((await wsHandshake(bport, `/live/${id}/vnc/websockify`)).status, 410);
        assert.equal(up.seen.ws.length, 1);
    } finally { await up.close(); }
});

test('viewer left: control is released after the grace without a noVNC socket, and a reconnect cancels it', async () => {
    const up = await restartWithNovnc({ viewerGraceMs: 150, takeLoadMs: 300 });
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const status = async (id) => (await (await fetch(`${base}/live/${id}/state`)).json());
    try {
        const bport = Number(new URL(base).port);
        const { id } = await link();
        await post(id, 'take');
        const ws = await wsHandshake(bport, `/live/${id}/vnc/websockify`);
        assert.equal(ws.status, 101);
        await sleep(400);
        assert.equal((await status(id)).status, 'user', 'an open socket holds control past the load timeout');
        ws.socket.destroy();
        await sleep(50);
        const again = await wsHandshake(bport, `/live/${id}/vnc/websockify`);
        assert.equal(again.status, 101);
        await sleep(250);
        assert.equal((await status(id)).status, 'user', 'reopening noVNC within the grace keeps control');
        again.socket.destroy();
        await sleep(300);
        const s = await status(id);
        assert.deepEqual([s.status, s.reason], ['watching', 'viewer_left']);

        // /take with no socket ever: released only after the longer load timeout.
        await post(id, 'take');
        await sleep(200);
        assert.equal((await status(id)).status, 'user', 'still loading noVNC: not released at the grace');
        await sleep(250);
        assert.equal((await status(id)).reason, 'viewer_left');
    } finally { await up.close(); }
});

test('shutdown: held links are released, waiters answered, sockets closed, links.json saved', async () => {
    const up = await restartWithNovnc();
    try {
        client.sessions.set('sess2', { id: 'sess2', current_url: 'https://b.example/', title: 'B' });
        client.sessions.set('sess3', { id: 'sess3', current_url: 'https://c.example/', title: 'C' });
        const t = await (await api('/api/takeover', { session_id: 'sess1', reason: 'Sign in' })).json();
        const u = await link('sess2');
        await post(u.id, 'take');
        const w = await link('sess3');
        const waiting = api('/api/wait', { id: t.id, wait_s: 30 }).then((r) => r.json());
        const bport = Number(new URL(base).port);
        const ws = await wsHandshake(bport, `/live/${u.id}/vnc/websockify`);
        assert.equal(ws.status, 101);
        await new Promise((r) => setTimeout(r, 50));

        const released = await bridgeApp.shutdown();
        assert.deepEqual(released.map((r) => r.id).sort(), [t.id.slice(0, 8), u.id.slice(0, 8)].sort());
        const got = await waiting;
        assert.deepEqual([got.status, got.reason], ['watching', 'bridge_restarting'], 'the waiter gets a clean answer');
        assert.ok(await ws.waitClosed(), 'noVNC socket closed');
        const saved = Object.fromEntries(JSON.parse(readFileSync(join(dir, 'links.json'), 'utf8')).links.map((l) => [l.id, l]));
        assert.deepEqual([saved[t.id].status, saved[t.id].reason], ['watching', 'bridge_restarting']);
        assert.deepEqual([saved[u.id].status, saved[u.id].reason], ['watching', 'bridge_restarting']);
        assert.deepEqual([saved[w.id].status, saved[w.id].reason], ['watching', null], 'an unheld link is untouched');
        // The links survive: a new bridge on the same file can take control again.
        const again = new LinkStore({ path: join(dir, 'links.json'), now: () => clock.t });
        assert.equal(again.lookup(t.id).rec.status, 'watching');
        assert.equal((await (await post(u.id, 'take')).json()).status, 'user');
        assert.ok(!logs.join('\n').includes(t.id), 'logs carry only a link-id prefix');
    } finally { await up.close(); }
});

test('shutdown: SIGTERM to a real bridge process releases held links and exits cleanly', async () => {
    const { spawn } = await import('node:child_process');
    const { writeFileSync, mkdirSync } = await import('node:fs');
    const { fileURLToPath } = await import('node:url');
    const home = mkdtempSync(join(tmpdir(), 'bridge-sig-'));
    mkdirSync(join(home, 'secrets'));
    for (const [f, v] of [['api-token', 'api-tok'], ['vnc-password', VNC_PASSWORD], ['bridge-token', BRIDGE_TOKEN]]) writeFileSync(join(home, 'secrets', f), v, { mode: 0o600 });
    mkdirSync(join(home, 'bridge'));
    const id = 'c'.repeat(32);
    const t0 = Date.now();
    writeFileSync(join(home, 'bridge/links.json'), JSON.stringify({ links: [{ id, sessionId: 's', createdAt: t0, lastSeenAt: t0, status: 'takeover', reason: 'Sign in', url: null, title: 'T' }], expired: [] }));
    const port = 20000 + Math.floor(Math.random() * 20000);
    const child = spawn(process.execPath, [fileURLToPath(new URL('../server.mjs', import.meta.url))], {
        env: { ...process.env, HAPPY_BROWSER_HOME: home, BRIDGE_PORT: String(port), BRIDGE_PODS: '0', AUTO_BROWSER_URL: 'http://127.0.0.1:1' }, stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    try {
        for (let i = 0; i < 50 && !out.includes('listening'); i++) await new Promise((r) => setTimeout(r, 100));
        const waiting = fetch(`http://127.0.0.1:${port}/api/wait`, { method: 'POST', headers: { Authorization: `Bearer ${BRIDGE_TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ id, wait_s: 30 }) }).then((r) => r.json());
        await new Promise((r) => setTimeout(r, 200));
        const exited = new Promise((r) => child.on('exit', (code) => r(code)));
        child.kill('SIGTERM');
        const got = await waiting;
        assert.deepEqual([got.status, got.reason], ['watching', 'bridge_restarting']);
        assert.equal(await exited, 0);
        assert.ok(Date.now() - t0 < 8000, 'well inside docker\'s stop timeout');
        const saved = JSON.parse(readFileSync(join(home, 'bridge/links.json'), 'utf8')).links[0];
        assert.deepEqual([saved.status, saved.reason], ['watching', 'bridge_restarting']);
        assert.ok(!out.includes(VNC_PASSWORD) && !out.includes(BRIDGE_TOKEN) && !out.includes(id));
    } finally { child.kill('SIGKILL'); }
});

test('mcp: browser_wait_for_human returns released when the bridge shuts down mid-wait', async () => {
    const { call } = mcpHarness();
    const wait = call(9, 'browser_wait_for_human', { session_id: 'sess1', reason: 'Sign in', timeout_s: 30 });
    await new Promise((r) => setTimeout(r, 100));
    await bridgeApp.shutdown();
    const r = await wait;
    assert.equal(r.result.structuredContent.status, 'released');
    assert.match(r.result.structuredContent.note, /bridge restarting/);
});

test('vnc socket: a Host the bridge does not answer to is refused', async () => {
    const up = await restartWithNovnc({ allowedHosts: ['localhost:6090'] });
    try {
        const bport = Number(new URL(base).port);
        assert.equal((await wsHandshake(bport, `/live/${'0'.repeat(32)}/vnc/websockify`)).status, 421);
        assert.equal(up.seen.ws.length, 0);
    } finally { await up.close(); }
});

test('user status survives a restart through the store file', async () => {
    const { id } = await link();
    await post(id, 'take');
    store.flush();
    const again = new LinkStore({ path: join(dir, 'links.json'), now: () => clock.t });
    assert.equal(again.lookup(id).rec.status, 'user');
});

test('take during a takeover changes nothing; release ends it and wakes the waiter', async () => {
    const t = await (await api('/api/takeover', { session_id: 'sess1', reason: 'CAPTCHA' })).json();
    const waiting = api('/api/wait', { id: t.id, wait_s: 30 }).then((r) => r.json());
    const took = await (await post(t.id, 'take')).json();
    assert.deepEqual([took.status, took.reason], ['takeover', 'CAPTCHA']);
    await new Promise((r) => setTimeout(r, 50));
    const rel = await (await post(t.id, 'release')).json();
    assert.equal(rel.status, 'watching');
    assert.equal((await waiting).status, 'watching');
});

test('take on an ended session is refused', async () => {
    const { id } = await link();
    client.sessions.get('sess1').status = 'interrupted';
    clock.t += 6000;
    await fetch(`${base}/live/${id}/state`);
    assert.equal((await post(id, 'take')).status, 409);
});

test('a waiter stays blocked while the user has control, and wakes on release', async () => {
    const { id } = await link();
    await post(id, 'take');
    const started = Date.now();
    const w = await (await api('/api/wait', { id, wait_s: 1 })).json();
    assert.equal(w.status, 'user');
    assert.ok(Date.now() - started >= 900, 'user status does not wake the waiter');
    const waiting = api('/api/wait', { id, wait_s: 30 }).then((r) => r.json());
    await new Promise((r) => setTimeout(r, 50));
    await post(id, 'release');
    assert.equal((await waiting).status, 'watching');
    // /api/release is for unanswered takeovers: it leaves a user's control alone.
    await post(id, 'take');
    assert.equal((await (await api('/api/release', { id, reason: 'timeout' })).json()).status, 'user');
});

test('/api/state: by session, held link without one, and last_action recorded only when nobody holds it', async () => {
    assert.deepEqual(await (await api('/api/state', { session_id: 'sess1' })).json(), { status: null });
    const { id } = await link();
    const s1 = await (await api('/api/state', { session_id: 'sess1', action: { kind: 'click', target: 'Sign\nin' } })).json();
    assert.equal(s1.status, 'watching');
    assert.deepEqual(s1.last_action, { kind: 'click', target: 'Sign in', at: clock.t });
    const st = await (await fetch(`${base}/live/${id}/state`)).json();
    assert.deepEqual(st.last_action, { kind: 'click', target: 'Sign in', at: clock.t });
    assert.deepEqual(await (await api('/api/state', {})).json(), { status: null }, 'no held link');
    await post(id, 'take');
    assert.equal((await (await api('/api/state', {})).json()).status, 'user');
    clock.t += 10;
    const s2 = await (await api('/api/state', { session_id: 'sess1', action: { kind: 'type' } })).json();
    assert.equal(s2.status, 'user');
    assert.equal(s2.last_action.kind, 'click', 'a refused action is not recorded');
    await post(id, 'release');
    const s3 = await (await api('/api/state', { session_id: 'sess1', action: { kind: 'bogus' } })).json();
    assert.equal(s3.last_action.kind, 'click', 'unknown kinds are ignored');
    assert.equal((await api('/api/state', { session_id: '../x' })).status, 400);
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

for (const status of ['interrupted', 'failed', 'closed', 'ended']) {
    test(`a session auto-browser reports ${status} turns the link done/session_closed in /state`, async () => {
        const { id } = await link();
        assert.equal((await (await fetch(`${base}/live/${id}/state`)).json()).status, 'watching');
        client.sessions.get('sess1').status = status;
        clock.t += 6000; // past the 5 s status re-check
        const s = await (await fetch(`${base}/live/${id}/state`)).json();
        assert.deepEqual([s.status, s.reason], ['done', 'session_closed']);
        assert.equal((await api('/api/links', { session_id: 'sess1' })).status, 404, 'no new link for an ended session');
    });
}

test('a 404 from shared observe marks the link done without waiting on getSession', async () => {
    const { id } = await link();
    // As after a controller restart: the record still reads as interrupted, observe 404s.
    client.observeShared = async () => { throw Object.assign(new Error('Unknown session'), { status: 404 }); };
    client.getSession = async () => new Promise(() => {}); // never answers
    const f = await fetch(`${base}/live/${id}/frame.jpg`);
    assert.equal(f.status, 404);
    assert.deepEqual(await f.json(), { error: 'session_closed' });
    const rec = store.lookup(id).rec;
    assert.deepEqual([rec.status, rec.reason], ['done', 'session_closed']);
});

test('a pruned frame file on a live session is a 502, and the link stays watching', async () => {
    const { id } = await link();
    client.fetchFrame = async () => { throw Object.assign(new Error('Not found'), { status: 404 }); };
    const f = await fetch(`${base}/live/${id}/frame.jpg`);
    assert.equal(f.status, 502);
    assert.equal(store.lookup(id).rec.status, 'watching');
});

test('defaults: a 1920x1200 desktop frame, and noVNC takeover scaled to fit', () => {
    const cfg = loadConfig({ HAPPY_BROWSER_HOME: '/nonexistent' });
    assert.equal(cfg.frameWidth, 1920);
    assert.equal(cfg.frameHeight, 1200);
    const u = new URL(cfg.novncUrl);
    assert.equal(u.searchParams.get('resize'), 'scale');
    assert.equal(u.searchParams.get('view_clip'), null);
    const env = loadConfig({ HAPPY_BROWSER_HOME: '/nonexistent', BRIDGE_FRAME_WIDTH: '1280', BRIDGE_FRAME_HEIGHT: '800' });
    assert.deepEqual([env.frameWidth, env.frameHeight], [1280, 800]);
});

test('page fits a 320-430 px phone: viewport meta, no fixed widths, frame box sized to the screen', async () => {
    const { id } = await link();
    const html = await (await fetch(`${base}/live/${id}`)).text();
    const viewport = html.match(/<meta name="viewport" content="([^"]+)">/)?.[1] ?? '';
    for (const part of ['width=device-width', 'initial-scale=1', 'viewport-fit=cover']) assert.ok(viewport.includes(part), part);
    const css = html.match(/<style[^>]*>([\s\S]*?)<\/style>/)[1];
    assert.match(css, /box-sizing: border-box/);
    assert.match(css, /safe-area-inset-left/);
    assert.match(css, /safe-area-inset-right/);
    assert.match(css, /object-fit: contain/);
    assert.match(css, /aspect-ratio: var\(--frame-ar\)/);
    assert.match(css, /--frame-ar: 1920 \/ 1200/);
    assert.match(css, /overflow-wrap: anywhere/);
    // width / min-width / flex-basis in px above the narrowest phone would push the page wider.
    for (const [, prop, px] of css.matchAll(/(?<![-\w])((?:min-)?width|flex-basis)\s*:\s*(\d+)px/g)) {
        assert.ok(Number(px) <= 320, `${prop}: ${px}px is wider than a 320 px phone`);
    }
    // The placeholder sits inside the frame box, not beside it.
    assert.match(html, /<div id="box"[^>]*>\s*<img id="frame"[^>]*>\s*<div id="note"[^>]*>Loading the live view…<\/div>\s*<div id="spin"[^>]*><\/div>\s*<\/div>/);
    // A spinner while it waits for a frame: shown at first, over the last frame once one is slow.
    assert.match(css, /#spin::after \{[^}]*animation: spin/);
    assert.match(html, /const SPIN_MS = \d+/);
    assert.match(html, /if \(!haveFrame\) spin\(true\)/);
    // Between refreshes the last frame stays up with no spinner: it spins only once frame reads
    // have gone as long as the app's inline player allows (4 s) without a frame, counted from the
    // first of them (test/pagespin.test.mjs runs it), each read given up on after 8 s, and a new
    // frame is decoded off screen before it replaces the one shown.
    assert.match(html, /const SPIN_MS = 4000/);
    assert.match(html, /const READ_MS = 8000/);
    assert.match(html, /waitingSince \+ SPIN_MS - Date\.now\(\)/);
    assert.match(html, /await next\.decode\(\)/);
    // The page script handles an ended session and repeated frame failures.
    assert.match(html, /This live browser has ended/);
    assert.match(html, /f\.status === 404\) return finish\(\)/);
    assert.match(html, /MAX_FAILS = \d+/);
});

test('links survive a restart through the store file', async () => {
    const { id } = await link();
    store.flush();
    const again = new LinkStore({ path: join(dir, 'links.json'), now: () => clock.t });
    assert.equal(again.lookup(id).rec.sessionId, 'sess1');
});

test('end: closes the session, marks the link user_ended, wakes a waiter, and refuses take', async () => {
    const t = await (await api('/api/takeover', { session_id: 'sess1', reason: 'Log in' })).json();
    const waiting = api('/api/wait', { id: t.id, wait_s: 30 }).then((r) => r.json());
    await new Promise((r) => setTimeout(r, 50));
    const r = await post(t.id, 'end');
    assert.equal(r.status, 200);
    const ended = await r.json();
    assert.equal(ended.status, 'done');
    assert.equal(ended.reason, 'user_ended');
    assert.deepEqual(client.calls.close, ['sess1']);
    const woke = await waiting;
    assert.equal(woke.status, 'done');
    assert.equal(woke.reason, 'user_ended');

    assert.equal((await post(t.id, 'take')).status, 409);
    clock.t += 10_000; // past the state route's session re-check
    const state = await (await fetch(`${base}/live/${t.id}/state`)).json();
    assert.equal(state.reason, 'user_ended', 'the closed session does not turn it into session_closed');
    assert.equal((await post(t.id, 'end')).status, 200, 'ending twice is fine');
    assert.deepEqual(client.calls.close, ['sess1'], 'and closes nothing more');
    assert.equal((await api('/api/links', { session_id: 'sess1' })).status, 404, 'a closed session gets no new link');
    assert.equal((await fetch(`${base}/live/${t.id}/end`)).status, 405);
});

test('end: the hook runs first, and a failing hook or close still ends the link', async () => {
    const seen = [];
    const store2 = new LinkStore({ path: join(dir, 'links2.json'), idleMs: 3600_000, now: () => clock.t });
    const failing = { ...client, async closeSession(id) { seen.push(['close', id]); throw Object.assign(new Error('boom'), { status: 502 }); } };
    const b = createBridge({
        client: failing, store: store2, now: () => clock.t, log: (l) => seen.push(['log', l]),
        config: { bridgeToken: BRIDGE_TOKEN, onEnd: async (rec) => { seen.push(['hook', rec.sessionId]); throw new Error('no pod'); } },
    });
    const srv = createServer(b.handler);
    await new Promise((r) => srv.listen(0, '127.0.0.1', r));
    try {
        const b2 = `http://127.0.0.1:${srv.address().port}`;
        const l = await (await fetch(b2 + '/api/links', { method: 'POST', headers: { Authorization: `Bearer ${BRIDGE_TOKEN}` }, body: '{"session_id":"sess1"}' })).json();
        const r = await (await fetch(`${b2}/live/${l.id}/end`, { method: 'POST' })).json();
        assert.equal(r.reason, 'user_ended');
        assert.deepEqual(seen.filter((x) => x[0] !== 'log' || /hook|closing/.test(x[1])).map((x) => x[0]), ['hook', 'log', 'close', 'log']);
    } finally {
        srv.closeAllConnections?.();
        await new Promise((r) => srv.close(r));
    }
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

test('mcp: browser_wait_for_human when the user already has control keeps it theirs until Release', async () => {
    const { call, out } = mcpHarness();
    const { id } = await link();
    await post(id, 'take');
    const pending = call(8, 'browser_wait_for_human', { session_id: 'sess1', reason: 'Waiting', timeout_s: 30 }, { progressToken: 'p2' });
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(client.calls.takeover.length, 0, 'no takeover request');
    const st = await (await fetch(`${base}/live/${id}/state`)).json();
    assert.deepEqual([st.status, st.reason], ['user', 'user_took_control']);
    assert.match(out.find((m) => m.method === 'notifications/progress').params.message, /has control/);
    await post(id, 'release');
    const r = await pending;
    assert.equal(r.result.structuredContent.status, 'done');
});

test('mcp: a timed-out wait leaves the user in control', async () => {
    const { call } = mcpHarness(1);
    const { id } = await link();
    await post(id, 'take');
    const r = await call(9, 'browser_wait_for_human', { session_id: 'sess1', reason: 'x', timeout_s: 5 });
    assert.equal(r.result.structuredContent.status, 'timeout');
    assert.equal((await (await fetch(`${base}/live/${id}/state`)).json()).status, 'user');
});

test('mcp: browser_wait_for_human times out and releases the takeover', async () => {
    const { call } = mcpHarness(1);
    const r = await call(6, 'browser_wait_for_human', { session_id: 'sess1', reason: 'Sign in', timeout_s: 5 });
    assert.equal(r.result.structuredContent.status, 'timeout');
    const id = r.result.structuredContent.link.split('/').pop();
    const s = await (await fetch(`${base}/live/${id}/state`)).json();
    assert.equal(s.status, 'watching');
});

test('mcp: a wait the user ends returns ended, and later calls on that session say so', async () => {
    const { call, out } = mcpHarness();
    const pending = call(20, 'browser_wait_for_human', { session_id: 'sess1', reason: 'Sign in', timeout_s: 30 }, { progressToken: 'p9' });
    await new Promise((r) => setTimeout(r, 100));
    const id = out.find((m) => m.method === 'notifications/progress').params.message.match(/live\/([0-9a-f]{32})/)[1];
    await post(id, 'end');
    const r = await pending;
    assert.equal(r.result.structuredContent.status, 'ended');
    assert.match(r.result.structuredContent.note, /The user ended this browser/);
    const again = await call(21, 'browser_live_link', { session_id: 'sess1' });
    assert.equal(again.result.isError, true);
    assert.match(again.result.content[0].text, /The user ended this browser\. Start a new one only if the task still needs it\./);
});

test('nav: goto an allowed url, a refused scheme, and only while the user holds control', async () => {
    const { id } = await link();
    const nav = (body) => fetch(`${base}/live/${id}/nav`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const notHeld = await nav({ action: 'goto', url: 'https://example.com/' });
    assert.equal(notHeld.status, 409);
    assert.equal((await notHeld.json()).error, 'not_in_control');
    await post(id, 'take');
    const ok = await nav({ action: 'goto', url: 'example.com/a?b=1' });
    assert.equal(ok.status, 200);
    assert.deepEqual(await ok.json(), { ok: true, url: 'https://example.com/a?b=1', title: 'T https://example.com/a?b=1', can_go_back: null, can_go_forward: null });
    assert.equal((await (await fetch(`${base}/live/${id}/state`)).json()).url, 'https://example.com/a?b=1');
    for (const url of ['javascript:alert(1)', 'file:///etc/passwd', 'data:text/html,x', 'chrome://settings', 'view-source:https://a.b/', 'about:config', 'x'.repeat(2049)]) {
        assert.equal((await nav({ action: 'goto', url })).status, 400, url.slice(0, 20));
    }
    assert.equal((await nav({ action: 'back' })).status, 200);
    assert.equal((await nav({ action: 'open' })).status, 400);
    assert.deepEqual(client.calls.nav.map((n) => n.action), ['goto', 'back']);
    assert.equal(navUrl('about:blank'), 'about:blank');
    assert.equal(navUrl('localhost:3000/x'), 'https://localhost:3000/x');
    assert.equal((await fetch(`${base}/live/${'0'.repeat(32)}/nav`, { method: 'POST' })).status, 404);
});

// ── The LAN listener (BRIDGE_LAN_BIND) ─────────────────────────────────────
// A request with any Host header (fetch will not set one).
function rawGet(port, path, { host, method = 'GET', headers = {} } = {}) {
    return new Promise((resolve, reject) => {
        const req = httpRequest({ host: '127.0.0.1', port, path, method, headers: { Host: host, ...headers } }, (res) => {
            let body = '';
            res.setEncoding('utf8');
            res.on('data', (d) => { body += d; });
            res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
        });
        req.on('error', reject);
        req.end();
    });
}
const LAN_HOST = '192.168.2.72:6090';
const LAN_BASE = `http://${LAN_HOST}`;
async function lanServer(opts) {
    const lan = bridgeApp.listener({ allowedHosts: [LAN_HOST], publicBase: LAN_BASE, api: false, ...opts });
    const srv = createServer(lan.handler);
    srv.on('upgrade', lan.upgrade);
    await new Promise((r) => srv.listen(0, '127.0.0.1', r));
    return { lan, port: srv.address().port, close: () => new Promise((r) => { srv.closeAllConnections?.(); srv.close(r); }) };
}

test('LAN listener: an allowlisted client gets the live routes with LAN URLs; other Hosts 421, /api 404', async () => {
    const up = await restartWithNovnc();
    const l = await lanServer({ allowFrom: ['127.0.0.1'] });
    // A loopback listener as server.mjs makes it: its own Hosts only.
    const lo = await lanServer({ allowedHosts: ['localhost:6090', '127.0.0.1:6090'], allowFrom: null, publicBase: 'http://localhost:6090', api: true });
    try {
        const { id, url } = await link();
        assert.equal(url, `http://localhost:6090/live/${id}`, 'the MCP server still gets the loopback link');
        assert.equal((await rawGet(l.port, '/healthz', { host: LAN_HOST })).status, 200);
        assert.equal((await rawGet(l.port, '/healthz', { host: 'localhost:6090' })).status, 421);
        assert.equal((await rawGet(l.port, '/healthz', { host: '127.0.0.1:6090' })).status, 421);
        assert.equal((await rawGet(l.port, '/healthz', { host: '192.168.2.72' })).status, 421);
        assert.equal((await rawGet(l.port, '/api/links', { host: LAN_HOST, method: 'POST', headers: { Authorization: `Bearer ${BRIDGE_TOKEN}` } })).status, 404, 'no private routes on the LAN');
        assert.equal((await rawGet(l.port, '/api/pods', { host: LAN_HOST, headers: { Authorization: `Bearer ${BRIDGE_TOKEN}` } })).status, 404);

        const page = await rawGet(l.port, `/live/${id}`, { host: LAN_HOST });
        assert.equal(page.status, 200);
        assert.ok(page.body.includes(`${LAN_BASE}/live/${id}/vnc/vnc.html?`), 'Take control points at the LAN base');
        assert.ok(!page.body.includes('http://localhost:6090'));
        assert.equal((await rawGet(l.port, `/live/${id}/state`, { host: LAN_HOST })).status, 200);
        assert.equal((await rawGet(l.port, `/live/${id}/frame.jpg`, { host: LAN_HOST })).status, 200);
        assert.equal((await rawGet(l.port, `/live/${id}/vnc/vnc.html`, { host: LAN_HOST })).body, 'vnc:shared:/vnc.html');

        const take = await rawGet(l.port, `/live/${id}/take`, { host: LAN_HOST, method: 'POST' });
        assert.equal(take.status, 200);
        assert.ok(JSON.parse(take.body).novnc_url.startsWith(`${LAN_BASE}/live/${id}/vnc/vnc.html?`));
        // The same take over loopback still answers with the loopback base.
        assert.ok((await (await post(id, 'take')).json()).novnc_url.startsWith(`http://localhost:6090/live/${id}/vnc/`));

        assert.equal((await wsHandshake(l.port, `/live/${id}/vnc/websockify`, { host: 'localhost:6090' })).status, 421);
        const ws = await wsHandshake(l.port, `/live/${id}/vnc/websockify`, { host: LAN_HOST });
        assert.equal(ws.status, 101);
        assert.ok((await ws.read('hello:shared')).includes('hello:shared'));
        ws.socket.destroy();

        // And the loopback listener does not answer to the LAN Host.
        assert.equal((await rawGet(lo.port, '/healthz', { host: LAN_HOST })).status, 421);
        assert.equal((await rawGet(lo.port, '/healthz', { host: 'localhost:6090' })).status, 200);
    } finally { await lo.close(); await l.close(); await up.close(); }
});

test('LAN listener: a client not in the allowlist is refused before any routing', async () => {
    const up = await restartWithNovnc();
    const l = await lanServer({ allowFrom: ['192.168.2.55', '192.168.2.56'] });
    try {
        const { id } = await link();
        await post(id, 'take');
        for (const path of ['/healthz', `/live/${id}`, `/live/${id}/state`, `/live/${id}/frame.jpg`, `/live/${id}/vnc/vnc.html`, '/api/links', '/nope']) {
            const r = await rawGet(l.port, path, { host: LAN_HOST });
            assert.equal(r.status, 403, path);
            assert.equal(r.body, '{"error":"forbidden"}');
        }
        assert.equal((await wsHandshake(l.port, `/live/${id}/vnc/websockify`, { host: LAN_HOST })).status, 403);
        assert.equal(up.seen.http.length, 0, 'nothing reached noVNC');
        assert.equal(up.seen.ws.length, 0);
        assert.ok(logs.some((x) => x.includes('lan-refused')));
        assert.ok(l.lan.allows('192.168.2.55'));
        assert.ok(l.lan.allows('::ffff:192.168.2.56'), 'an IPv4-mapped address is its IPv4');
        assert.ok(!l.lan.allows('127.0.0.1'));
        assert.ok(!l.lan.allows('192.168.2.5'));
        assert.ok(!l.lan.allows(''));
    } finally { await l.close(); await up.close(); }
});

test('lanConfig: off when unset; refuses wildcard, loopback, an empty or malformed allowlist', async () => {
    const { lanConfig } = await import('../lib/config.mjs');
    assert.equal(lanConfig({}, 6090), null);
    assert.equal(loadConfig({}).lan, null);
    assert.deepEqual(lanConfig({ BRIDGE_LAN_BIND: '192.168.2.72', BRIDGE_LAN_ALLOW: '192.168.2.55, 192.168.2.56' }, 6090),
        { bind: '192.168.2.72', port: 6090, allow: ['192.168.2.55', '192.168.2.56'], allowedHosts: ['192.168.2.72:6090'], publicBase: 'http://192.168.2.72:6090' });
    assert.equal(lanConfig({ BRIDGE_LAN_BIND: '192.168.2.72', BRIDGE_LAN_ALLOW: '192.168.2.55', BRIDGE_LAN_PUBLIC_BASE: 'http://ml.lan:6090/' }, 6090).publicBase, 'http://ml.lan:6090');
    for (const bind of ['0.0.0.0', '127.0.0.1', '::', '192.168.2.300', 'prep-ml', '192.168.2.72:6090']) {
        assert.throws(() => lanConfig({ BRIDGE_LAN_BIND: bind, BRIDGE_LAN_ALLOW: '192.168.2.55' }, 6090), /BRIDGE_LAN_BIND/, bind);
    }
    assert.throws(() => lanConfig({ BRIDGE_LAN_BIND: '192.168.2.72' }, 6090), /BRIDGE_LAN_ALLOW is empty/);
    for (const allow of ['0.0.0.0', '192.168.2.0/24', '*', 'prep-pro']) {
        assert.throws(() => lanConfig({ BRIDGE_LAN_BIND: '192.168.2.72', BRIDGE_LAN_ALLOW: allow }, 6090), /BRIDGE_LAN_ALLOW/, allow);
    }
});
