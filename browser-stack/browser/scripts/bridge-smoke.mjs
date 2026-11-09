#!/usr/bin/env node
// End-to-end smoke test of the live bridge against the running stack
// (make browser-up). Creates a throwaway auto-browser session, walks the
// bridge's routes and the MCP server (its own tools and the auto-browser
// tools it passes through, and noVNC through the bridge on its own link), then deletes the session.
// With per-chat pods the MCP part runs as a throwaway chat and closes that chat's pod at the end.
// Secrets are read from their files and never printed.
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { connect } from 'node:net';
import { createHash, randomBytes } from 'node:crypto';

const home = process.env.HAPPY_BROWSER_HOME || join(process.env.HOME, '.local/share/happy-browser');
const API = process.env.BROWSER_API || 'http://127.0.0.1:8010';
const BRIDGE = process.env.BROWSER_BRIDGE || 'http://127.0.0.1:6090';
const NODE_CONTAINER = process.env.BROWSER_NODE_CONTAINER || 'happy-browser-browser-node-1';
const START_URL = process.env.SMOKE_URL || 'https://news.ycombinator.com/';
const secret = (n) => readFileSync(join(home, 'secrets', n), 'utf8').trim();
const apiToken = secret('api-token');
const bridgeToken = secret('bridge-token');
const vncPassword = secret('vnc-password');

let failures = 0;
const check = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); if (!ok) failures++; };
const ab = (path, init = {}) => fetch(API + path, { ...init, headers: { Authorization: `Bearer ${apiToken}`, 'Content-Type': 'application/json', ...init.headers } });
const bapi = (path, body) => fetch(BRIDGE + path, { method: 'POST', headers: { Authorization: `Bearer ${bridgeToken}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

// ident: the chat the MCP server runs as. With per-chat pods it is a throwaway chat of the
// smoke's own (HAPPY_SESSION_ID=smoke-<random>), never the caller's: whatever chat identity the
// caller's environment carries is dropped, so the smoke never drives a real chat's browser.
const IDENT_ENV = /^(CLAUDE_CODE_SESSION_ID|CLAUDE_SESSION_ID|CODEX_.*SESSION.*|HAPPY_[A-Z_]*(SESSION|CHAT|THREAD)[A-Z_]*)$/;
function mcp(ident = null) {
    const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !ident || !IDENT_ENV.test(k)));
    const child = spawn(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), '../bridge/mcp.mjs')], {
        env: { ...env, ...(ident ? { HAPPY_SESSION_ID: ident } : {}), HAPPY_BROWSER_HOME: home, BRIDGE_URL: BRIDGE, AUTO_BROWSER_URL: API }, stdio: ['pipe', 'pipe', 'inherit'],
    });
    const waiting = new Map();
    const notes = [];
    createInterface({ input: child.stdout }).on('line', (l) => {
        const m = JSON.parse(l);
        if (m.id != null && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); } else notes.push(m);
    });
    let n = 0;
    const request = (method, params) => new Promise((resolve) => { const id = ++n; waiting.set(id, resolve); child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n'); });
    return { request, notes, close: () => child.stdin.end() };
}

// The browser fills the screen and nothing else shows: a maximized Chromium window with its tab
// strip and address bar (BROWSER_KIOSK=0, the default), or with BROWSER_KIOSK=1 the kiosk (no
// tab strip, no address bar, no window frame); a window.open popup the same. Measured from inside
// the browser-node by scripts/kiosk-probe.mjs. And Xvfb must not listen on the abstract socket
// @/tmp/.X11-unix/X99: with host networking it would be in the host's namespace, a display
// anything on this machine could open.
// The window rule kiosk-probe.mjs measures against: at 0,0 and the full screen, and either no
// browser UI at all (kiosk) or some (a normal window: tab strip, address bar).
const windowShaped = (w, kiosk) => !!w && w.screenX === 0 && w.screenY === 0
    && w.outerWidth === w.screenWidth && w.outerHeight === w.screenHeight && w.innerWidth === w.screenWidth
    && (kiosk ? w.innerHeight === w.screenHeight : w.innerHeight < w.outerHeight);
const WANT_KIOSK = process.env.BROWSER_KIOSK === '1';
function kiosk() {
    const probe = spawnSync('docker', ['exec', '-i', '-w', '/opt/browser-node', '-u', 'browser', NODE_CONTAINER, 'node', '--input-type=module', '-'], {
        input: readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'kiosk-probe.mjs')), encoding: 'utf8', timeout: 60000,
    });
    let g = {};
    try { g = JSON.parse(probe.stdout.trim().split('\n').pop()); } catch { g = { error: `probe exited ${probe.status}` }; }
    check(!g.error, `kiosk probe ran in ${NODE_CONTAINER}${g.error ? `: ${g.error}` : ''}`);
    check(g.kiosk === WANT_KIOSK, `browser-node runs with BROWSER_KIOSK=${WANT_KIOSK ? 1 : 0}`);
    const how = WANT_KIOSK ? 'with no browser UI' : 'maximized, with its tab strip and address bar';
    check(windowShaped(g.page, WANT_KIOSK), `page fills the screen ${how}: ${JSON.stringify(g.page)}`);
    check(windowShaped(g.popup, WANT_KIOSK), `window.open popup fills the screen too: ${JSON.stringify(g.popup)}`);
    const ss = spawnSync('ss', ['-xlH'], { encoding: 'utf8' });
    check(ss.status === 0 && !/@\/tmp\/\.X11-unix\//.test(ss.stdout), 'no abstract X11 socket in the host network namespace');
}

// A websocket handshake only: the status code, then the socket is closed before any VNC
// exchange, so it never reaches VNC auth or bumps another viewer.
function wsProbe(u, path) {
    return new Promise((resolve) => {
        const s = connect(Number(u.port), u.hostname);
        const done = (v) => { s.destroy(); resolve(v); };
        s.setTimeout(10_000, () => done('timeout'));
        s.on('error', (e) => done(e.code || 'error'));
        s.on('connect', () => s.write(`GET ${path} HTTP/1.1\r\nHost: ${u.host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n`
            + `Sec-WebSocket-Key: ${randomBytes(16).toString('base64')}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n`));
        let buf = '';
        s.on('data', (d) => { buf += d.toString('latin1'); if (buf.includes('\r\n')) done(Number(buf.split(' ')[1]) || buf.split('\r\n')[0]); });
    });
}

let sessionId, liveBase, podChat = null;
if (process.env.SMOKE_KIOSK !== '0') kiosk();
try {
    const created = await (await ab('/sessions', { method: 'POST', body: JSON.stringify({ name: 'bridge-smoke', start_url: START_URL }) })).json();
    sessionId = created.id;
    check(!!sessionId, `created auto-browser session ${sessionId}`);

    const linkRes = await bapi('/api/links', { session_id: sessionId });
    const link = await linkRes.json();
    check(linkRes.ok && new RegExp(`^http://localhost:${new URL(BRIDGE).port}/live/[0-9a-f]{32}$`).test(link.url), `link ${link.url}`);
    const live = (liveBase = `${BRIDGE}/live/${link.id}`);

    const page = await fetch(live);
    const html = await page.text();
    check(page.ok && /text\/html/.test(page.headers.get('content-type')) && html.includes('Take control'), `GET /live/<id> -> ${page.status} html`);

    const state = await (await fetch(`${live}/state`)).json();
    check(state.status === 'watching', `state ${JSON.stringify(state)}`);

    const f = await fetch(`${live}/frame.jpg`);
    const body = Buffer.from(await f.arrayBuffer());
    const sig = body.subarray(0, 4).toString('hex');
    const ct = f.headers.get('content-type');
    check(f.ok && ((ct === 'image/png' && sig === '89504e47') || (ct === 'image/jpeg' && sig.startsWith('ffd8'))), `frame.jpg -> ${f.status} ${ct} ${body.length} bytes`);

    const t0 = Date.now();
    await fetch(`${live}/frame.jpg`).then((r) => r.arrayBuffer());
    check(Date.now() - t0 < 300, `second frame within the cache window took ${Date.now() - t0}ms`);

    const after = await (await fetch(`${live}/state`)).json();
    const leaked = [apiToken, bridgeToken, vncPassword].some((s) => JSON.stringify(after).includes(s));
    check(!leaked && after.url && after.title, `state after a frame: ${JSON.stringify(after)}`);

    const tk = await (await bapi('/api/takeover', { session_id: sessionId, reason: 'Smoke test: tap Done' })).json();
    check(tk.status === 'takeover' && tk.id === link.id, 'takeover requested, same link');
    const st2 = await (await fetch(`${live}/state`)).json();
    check(st2.status === 'takeover' && st2.reason === 'Smoke test: tap Done', `state ${JSON.stringify(st2)}`);

    const waited = bapi('/api/wait', { id: link.id, wait_s: 20 }).then((r) => r.json());
    await new Promise((r) => setTimeout(r, 300));
    const done = await (await fetch(`${live}/done`, { method: 'POST' })).json();
    check(done.status === 'watching', 'POST /done (alias of release) -> watching');
    check((await waited).status === 'watching', 'waiter woke');

    const took = await (await fetch(`${live}/take`, { method: 'POST' })).json();
    check(took.status === 'user' && typeof took.novnc_url === 'string', `POST /take -> ${took.status}`);
    // noVNC through the bridge's own port, on this smoke's own link only. The URL holds the
    // password, so it is checked, never printed.
    const nv = new URL(took.novnc_url);
    check(nv.port === new URL(BRIDGE).port && nv.pathname === `/live/${link.id}/vnc/vnc.html`
        && new URL(nv.searchParams.get('path') || '', nv).pathname === `/live/${link.id}/vnc/websockify` && nv.hash === `#password=${encodeURIComponent(vncPassword)}`,
        'novnc_url: the bridge port, the link\'s vnc path, path= and the password in the fragment');
    const vh = await fetch(`${live}/vnc/vnc.html`);
    const vhtml = await vh.text();
    check(vh.ok && /noVNC/i.test(vhtml) && !vh.headers.get('set-cookie'), `GET /live/<id>/vnc/vnc.html -> ${vh.status} ${vhtml.length} bytes`);
    const ws = await wsProbe(new URL(BRIDGE), `/live/${link.id}/vnc/websockify`);
    check(ws === 101, `websocket handshake through ${new URL(BRIDGE).port} -> ${ws}`);
    const rel = await (await fetch(`${live}/release`, { method: 'POST' })).json();
    check(rel.status === 'watching', `POST /release -> ${rel.status}`);

    const unknown = await fetch(`${BRIDGE}/live/${'0'.repeat(32)}/state`);
    check(unknown.status === 404, `unknown id -> ${unknown.status}`);

    // MCP over stdio, against the live bridge. With per-chat pods the MCP server drives its
    // chat's own pod, not the session above, so it runs as a throwaway chat and the checks use
    // that chat's session and link; the pod is closed at the end.
    const podsOn = await fetch(`${BRIDGE}/api/pods`, { headers: { Authorization: `Bearer ${bridgeToken}` } })
        .then((r) => r.json()).then((j) => !!j.pods && j.pods !== false).catch(() => false);
    const ident = podsOn ? `smoke-${randomBytes(8).toString('hex')}` : null;
    if (ident) podChat = createHash('sha256').update(`happy:${ident}`).digest('hex').slice(0, 32);
    const m = mcp(ident);
    const init = await m.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'smoke', version: '0' } });
    check(init.result?.serverInfo?.name === 'happy-browser-bridge', 'mcp initialize');
    const tools = await m.request('tools/list', {});
    const names = tools.result?.tools?.map((x) => x.name) || [];
    check(names[0] === 'browser_live_link' && names[1] === 'browser_wait_for_human', `mcp own tools: ${names.slice(0, 2).join(', ')}`);
    check(names.includes('browser_list_sessions') && names.includes('browser_observe') && names.every((x) => /^[a-zA-Z0-9_-]{1,64}$/.test(x)),
        `mcp passes auto-browser tools through (${names.length - 2}): ${names.slice(2).join(', ')}`);
    let mSid = sessionId, mLink = link, mLive = live;
    if (podsOn) {
        const cs = await m.request('tools/call', { name: 'browser_create_session', arguments: { start_url: START_URL } });
        const pod = await (await bapi('/api/pod', { chat_key: podChat })).json();
        check(!cs.error && !cs.result?.isError && !!pod.session_id && JSON.stringify(cs.result).includes(pod.session_id), `mcp browser_create_session starts the smoke chat's own pod (slot ${pod.slot})`);
        mSid = pod.session_id;
        mLink = { id: new URL(pod.url).pathname.split('/').pop(), url: pod.url };
        mLive = `${BRIDGE}/live/${mLink.id}`;
    }
    const ls = await m.request('tools/call', { name: 'browser_list_sessions', arguments: {} });
    const lsText = JSON.stringify(ls.result ?? ls.error);
    check(!ls.error && !ls.result?.isError && lsText.includes(mSid), 'mcp browser_list_sessions (pass-through) lists the smoke session');
    const gs = await m.request('tools/call', { name: 'browser_get_session', arguments: { session_id: mSid } });
    check(!gs.error && !gs.result?.isError && JSON.stringify(gs.result).includes(mSid), 'mcp browser_get_session (pass-through)');
    const leakedMcp = [apiToken, bridgeToken, vncPassword].some((s) => [JSON.stringify(tools), lsText, JSON.stringify(gs)].some((t) => t.includes(s)));
    check(!leakedMcp, 'no secret in pass-through responses');
    const ll = await m.request('tools/call', { name: 'browser_live_link', arguments: { session_id: mSid } });
    check(ll.result?.structuredContent?.link === mLink.url, 'mcp browser_live_link returns the same link');
    await fetch(`${mLive}/take`, { method: 'POST' });
    const refused = await m.request('tools/call', { name: 'browser_execute_action', arguments: { session_id: mSid, action: { action: 'scroll', reason: 'smoke' } } });
    check(refused.result?.isError && /taken control/.test(refused.result.content?.[0]?.text || ''), 'mcp execute_action refused while the user has control');
    const obs = await m.request('tools/call', { name: 'browser_get_session', arguments: { session_id: mSid } });
    check(!obs.error && !obs.result?.isError, 'mcp get_session still works while the user has control');
    await fetch(`${mLive}/release`, { method: 'POST' });
    const wait = m.request('tools/call', { name: 'browser_wait_for_human', arguments: { session_id: mSid, reason: 'MCP smoke', timeout_s: 30 }, _meta: { progressToken: 'smoke' } });
    await new Promise((r) => setTimeout(r, 1500));
    check(m.notes.some((x) => x.method === 'notifications/progress' && x.params.message.includes(mLink.url)), 'mcp progress notification carries the link');
    await fetch(`${mLive}/done`, { method: 'POST' });
    const wres = await wait;
    check(wres.result?.structuredContent?.status === 'done', `mcp browser_wait_for_human -> ${wres.result?.structuredContent?.status}`);
    const tmo = await m.request('tools/call', { name: 'browser_wait_for_human', arguments: { session_id: mSid, reason: 'MCP smoke timeout', timeout_s: 5 } });
    check(tmo.result?.structuredContent?.status === 'timeout', `mcp browser_wait_for_human (5 s, nobody) -> ${tmo.result?.structuredContent?.status}`);
    m.close();
} catch (err) {
    check(false, `error: ${err.message}`);
} finally {
    if (podChat) {
        const pc = await bapi('/api/pod/close', { chat_key: podChat }).catch(() => null);
        check(!!pc?.ok, `closed the smoke chat's pod (${pc?.status})`);
    }
    if (sessionId) {
        const del = await ab(`/sessions/${sessionId}`, { method: 'DELETE' }).catch(() => null);
        check(!!del?.ok, `deleted session ${sessionId}`);
        if (process.env.SMOKE_CHECK_CLOSED !== '0') {
            await new Promise((r) => setTimeout(r, 500));
            const code = (await bapi('/api/links', { session_id: sessionId })).status;
            check(code === 404, `bridge refuses a link for the deleted session (${code})`);
            if (liveBase) {
                await new Promise((r) => setTimeout(r, 1200)); // past the frame cache
                const fr = await fetch(`${liveBase}/frame.jpg`);
                await new Promise((r) => setTimeout(r, 300));
                const st = await (await fetch(`${liveBase}/state`)).json();
                check(st.status === 'done' && st.reason === 'session_closed', `phone view after delete: frame ${fr.status}, state ${JSON.stringify(st)}`);
            }
        }
    }
}
console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed');
process.exit(failures ? 1 : 0);
