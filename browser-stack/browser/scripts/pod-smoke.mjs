// End to end against a bridge running with BRIDGE_PODS=1 (`make browser-pod-smoke`): two chats get
// two pods with their own sessions, links, ports and noVNC passwords; every listener is on
// 127.0.0.1 and no abstract X11 socket is visible; each pod's browser window is locked to the screen;
// a screen shot of an https page shows the scheme in the address bar; take control goes through the
// bridge's own port, on each link's own path; a pod left idle stops by itself and a login cookie set
// before the stop is there after it wakes.
// The idle wait follows the bridge's own idle_min (/api/pods). When that wait is past the smoke's
// budget (SMOKE_IDLE_BUDGET_S, default 300 s; the deploy runs idle_min 60) the idle stop is skipped
// with a note and the pod is put to sleep through its link instead, so the cookie check still runs.
// Run the bridge with a short BRIDGE_POD_IDLE_MIN (e.g. 0.3) to check the idle stop itself.
// Never prints a token, password or noVNC URL: passwords are compared, not shown.
import { spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { connect } from 'node:net';
import { createUpstreamMcp } from '../bridge/lib/upstream.mjs';

// The window rule kiosk-probe.mjs measures against: the kiosk at 0,0 and the full screen with no
// browser UI at all; a normal window maximized to the screen less the desktop panel across the top
// (screen.availTop, the panel's height, at least 1 px), with some browser UI (tab strip, address bar).
const windowShaped = (w, kiosk) => !!w && w.screenX === 0 && w.outerWidth === w.screenWidth && w.innerWidth === w.screenWidth
    && (kiosk
        ? w.screenY === 0 && w.outerHeight === w.screenHeight && w.innerHeight === w.screenHeight
        : w.availTop > 0 && w.screenY === w.availTop && w.outerHeight === w.availHeight
            && w.availTop + w.availHeight === w.screenHeight && w.innerHeight < w.outerHeight);
const WANT_KIOSK = process.env.BROWSER_KIOSK === '1';

const BRIDGE = (process.env.BROWSER_BRIDGE || 'http://127.0.0.1:6090').replace(/\/+$/, '');
const HOME = process.env.HAPPY_BROWSER_HOME;
const PROJECT = process.env.BROWSER_PROJECT || 'happy-browser';
const IDLE_BUDGET_S = Number(process.env.SMOKE_IDLE_BUDGET_S || process.env.SMOKE_IDLE_WAIT_S || 300);
// A page that sets a cookie from its query (Set-Cookie, no script) and one that shows the cookies.
const COOKIE_BASE = (process.env.SMOKE_COOKIE_BASE || 'https://httpbin.org').replace(/\/+$/, '');
// An https page for the address bar check.
const SCHEME_URL = process.env.SMOKE_SCHEME_URL || 'https://example.com/';
const bridgeToken = readFileSync(join(HOME, 'secrets/bridge-token'), 'utf8').trim();
const apiToken = readFileSync(join(HOME, 'secrets/api-token'), 'utf8').trim();

let failed = 0;
const check = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); if (!ok) failed++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const bapi = async (path, body) => {
    const r = await fetch(BRIDGE + path, { method: 'POST', headers: { Authorization: `Bearer ${bridgeToken}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    return { status: r.status, body: await r.json().catch(() => null) };
};
const hash = (s) => createHash('sha256').update(String(s)).digest('hex').slice(0, 12);
const key = () => randomBytes(16).toString('hex');
const tool = async (mcpUrl, name, args) => {
    const up = createUpstreamMcp({ url: mcpUrl, getToken: () => apiToken, timeoutMs: 60_000 });
    const r = await up.callTool(name, args);
    if (r.error || r.result?.isError) throw new Error(`${name} failed: ${JSON.stringify(r.error || r.result?.content?.[0]?.text || '').slice(0, 200)}`);
    return r.result;
};
// A websocket handshake only: the status code, then the socket is closed before any VNC exchange.
function wsProbe(u, path) {
    return new Promise((resolve) => {
        const s = connect(Number(u.port) || 80, u.hostname);
        const done = (v) => { s.destroy(); resolve(v); };
        s.setTimeout(10_000, () => done('timeout'));
        s.on('error', (e) => done(e.code || 'error'));
        s.on('connect', () => s.write(`GET ${path} HTTP/1.1\r\nHost: ${u.host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n`
            + `Sec-WebSocket-Key: ${randomBytes(16).toString('base64')}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n`));
        let buf = '';
        s.on('data', (d) => { buf += d.toString('latin1'); if (buf.includes('\r\n')) done(Number(buf.split(' ')[1]) || buf.split('\r\n')[0]); });
    });
}
const textOf = (res) => (res?.content || []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');

const status = await fetch(`${BRIDGE}/api/pods`, { headers: { Authorization: `Bearer ${bridgeToken}` } }).then((r) => r.json());
if (!status.pods) { console.error('pod-smoke: the bridge runs without pods (BRIDGE_PODS=1 is needed)'); process.exit(2); }

const A = key(), B = key();
const closeAll = async () => { for (const k of [A, B]) await bapi('/api/pod/close', { chat_key: k }).catch(() => {}); };
try {
    // Two chats, two pods.
    const t0 = Date.now();
    const [a, b] = await Promise.all([bapi('/api/pod', { chat_key: A, source: 'smoke' }), bapi('/api/pod', { chat_key: B, source: 'smoke' })]);
    check(a.status === 200 && b.status === 200, `two chats got pods in ${Date.now() - t0} ms`);
    const pa = a.body, pb = b.body;
    check(pa.slot !== pb.slot && pa.session_id !== pb.session_id && pa.link_id !== pb.link_id && pa.mcp_url !== pb.mcp_url,
        `own slot, session, link and controller each (slots ${pa.slot}, ${pb.slot})`);
    const again = await bapi('/api/pod', { chat_key: A });
    check(again.body?.session_id === pa.session_id, 'asking again keeps the chat\'s session');

    // Discovery: the chat's link from its key.
    const d = await fetch(`${BRIDGE}/live/chat/${A}`).then((r) => r.json());
    check(d.id === pa.link_id && d.live === true && d.pod === 'running', 'GET /live/chat/<key> finds the chat\'s live link');

    // Take control goes through the bridge's own port, on each link's own path (/live/<id>/vnc/...),
    // which the bridge pipes to that link's pod; the pods' noVNC ports are never handed out.
    // The URLs hold the passwords, so they are compared by hash, never printed.
    const ta = await fetch(`${BRIDGE}/live/${pa.link_id}/take`, { method: 'POST' }).then((r) => r.json());
    const tb = await fetch(`${BRIDGE}/live/${pb.link_id}/take`, { method: 'POST' }).then((r) => r.json());
    const ua = new URL(ta.novnc_url), ub = new URL(tb.novnc_url);
    const bridgePort = new URL(BRIDGE).port || '80';
    const viaBridge = (u, p) => (u.port || '80') === bridgePort && u.pathname === `/live/${p.link_id}/vnc/vnc.html`
        && new URL(u.searchParams.get('path') || '', u).pathname === `/live/${p.link_id}/vnc/websockify`;
    check(viaBridge(ua, pa) && viaBridge(ub, pb) && ua.pathname !== ub.pathname && ![pa.novnc_port, pb.novnc_port].includes(Number(ua.port || 80)),
        `take control through the bridge's port ${bridgePort}, on each link's own /live/<id>/vnc path`);
    for (const [p, tag] of [[pa, 'A'], [pb, 'B']]) {
        const vh = await fetch(`${BRIDGE}/live/${p.link_id}/vnc/vnc.html`);
        const vhtml = await vh.text();
        const ws = await wsProbe(new URL(BRIDGE), `/live/${p.link_id}/vnc/websockify`);
        check(vh.ok && /noVNC/i.test(vhtml) && ws === 101, `chat ${tag}: noVNC page ${vh.status} and websocket ${ws} through the bridge (slot ${p.slot})`);
    }
    check(ua.hash.length > 10 && hash(ua.hash) !== hash(ub.hash), 'noVNC passwords differ between pods');
    await fetch(`${BRIDGE}/live/${pa.link_id}/release`, { method: 'POST' });
    await fetch(`${BRIDGE}/live/${pb.link_id}/release`, { method: 'POST' });

    // Loopback only; no abstract X11 socket.
    const ports = [pa, pb].flatMap((p) => [Number(new URL(p.api_url).port), p.novnc_port]);
    const ss = spawnSync('ss', ['-ltnH'], { encoding: 'utf8' }).stdout;
    const listeners = ss.split('\n').map((l) => l.trim().split(/\s+/)[3]).filter(Boolean);
    const mine = listeners.filter((addr) => ports.includes(Number(addr.split(':').pop())));
    check(mine.length >= ports.length && mine.every((addr) => addr.startsWith('127.0.0.1:')), `pod ports listen on 127.0.0.1 only (${mine.join(' ')})`);
    const x = spawnSync('ss', ['-xlpH'], { encoding: 'utf8' }).stdout;
    check(!/@\/tmp\/\.X11-unix\//.test(x) && !/X11/.test(x.split('\n').filter((l) => l.includes('@')).join('\n')), 'no abstract X11 socket visible (ss -xlp)');

    // The window lock in each pod's browser-node (maximized, or the kiosk with BROWSER_KIOSK=1).
    const probe = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'kiosk-probe.mjs'));
    for (const p of [pa, pb]) {
        const name = `${PROJECT}-pod-${p.slot}-node`;
        const r = spawnSync('docker', ['exec', '-i', '-w', '/opt/browser-node', '-u', 'browser', name, 'node', '--input-type=module', '-'], { input: probe, encoding: 'utf8', timeout: 60_000 });
        let g = {};
        try { g = JSON.parse(r.stdout.trim().split('\n').pop()); } catch { g = { error: `exit ${r.status}` }; }
        check(!g.error && g.kiosk === WANT_KIOSK && windowShaped(g.page, WANT_KIOSK) && windowShaped(g.popup, WANT_KIOSK),
            `slot ${p.slot}: page and popup fill the screen, ${WANT_KIOSK ? 'no browser UI (kiosk)' : 'maximized with the browser UI'}`);
    }

    // The address bar shows the full URL, scheme included (kiosk/policy.json's ShowFullUrlsInAddressBar):
    // a screen shot of an https page says OCR read "https://" in it. Not checked in kiosk mode (no address bar).
    if (!WANT_KIOSK) {
        await tool(pb.mcp_url, 'browser.execute_action', { session_id: pb.session_id, action: { action: 'navigate', url: SCHEME_URL, reason: 'pod smoke' } });
        const shot = await bapi('/api/screen', { chat_key: B, label: 'smoke-scheme' });
        check(shot.status === 200 && shot.body?.address_bar_scheme === true,
            `a screen shot of ${SCHEME_URL} shows https:// in the address bar (address_bar_scheme ${JSON.stringify(shot.body?.address_bar_scheme ?? shot.body?.error ?? shot.status)})`);
    }

    // A login cookie survives the idle stop.
    const mark = randomBytes(6).toString('hex');
    await tool(pa.mcp_url, 'browser.execute_action', { session_id: pa.session_id, action: { action: 'navigate', url: `${COOKIE_BASE}/cookies/set?happy_smoke=${mark}`, reason: 'pod smoke' } });
    await bapi('/api/pod/close', { chat_key: B });
    // The idle stop comes idle_min after the last activity, at the next idle sweep (every
    // min(30 s, idle/4)), and the stop itself (saving the login, stopping the containers) takes a while.
    const idleS = Number(status.idle_min) * 60;
    const waitS = Math.ceil(idleS + Math.min(30, Math.max(1, idleS / 4)) + 60);
    const t1 = Date.now();
    let slept = false;
    const asleep = async () => (await fetch(`${BRIDGE}/live/chat/${A}`).then((r) => r.json()).catch(() => ({}))).pod === 'asleep';
    if (Number.isFinite(idleS) && waitS <= IDLE_BUDGET_S) {
        while (Date.now() - t1 < waitS * 1000) {
            if (await asleep()) { slept = true; break; }
            await sleep(2000);
        }
        check(slept, `an idle pod stopped by itself (${Math.round((Date.now() - t1) / 1000)} s; idle_min ${status.idle_min}, waited up to ${waitS} s)`);
    } else {
        console.log(`skip idle stop not checked: the bridge's idle_min is ${status.idle_min}, so it would take up to ${waitS} s, past this smoke's budget of ${IDLE_BUDGET_S} s`
            + ' (SMOKE_IDLE_BUDGET_S; or run the bridge with a short BRIDGE_POD_IDLE_MIN). Putting the pod to sleep through its link instead.');
        const r = await fetch(`${BRIDGE}/live/${pa.link_id}/sleep`, { method: 'POST' });
        while (!slept && Date.now() - t1 < 60_000) { slept = await asleep(); if (!slept) await sleep(1000); }
        check(r.ok && slept, `the pod was put to sleep through its link (${r.status}, ${Math.round((Date.now() - t1) / 1000)} s)`);
    }
    const t2 = Date.now();
    const woke = await bapi('/api/pod', { chat_key: A });
    check(woke.status === 200 && woke.body.link_id === pa.link_id, `woke in ${Date.now() - t2} ms with the same link`);
    await tool(woke.body.mcp_url, 'browser.execute_action', { session_id: woke.body.session_id, action: { action: 'navigate', url: `${COOKIE_BASE}/cookies`, reason: 'pod smoke' } });
    const c = textOf(await tool(woke.body.mcp_url, 'browser.get_html', { session_id: woke.body.session_id, text_only: true }));
    check(c.includes(mark), 'the login cookie is still there after the pod restarted');
} catch (err) {
    check(false, `smoke stopped: ${err.message}`);
} finally {
    await closeAll();
}
console.log(failed ? `\n${failed} check(s) failed` : '\nall checks passed');
process.exit(failed ? 1 : 0);
