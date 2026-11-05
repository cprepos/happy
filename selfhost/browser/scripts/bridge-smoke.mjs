#!/usr/bin/env node
// End-to-end smoke test of the live bridge against the running stack
// (make browser-up). Creates a throwaway auto-browser session, walks the
// bridge's routes and the MCP server (its own tools and the auto-browser
// tools it passes through), then deletes the session.
// Secrets are read from their files and never printed.
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

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

function mcp() {
    const child = spawn(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), '../bridge/mcp.mjs')], {
        env: { ...process.env, HAPPY_BROWSER_HOME: home, BRIDGE_URL: BRIDGE, AUTO_BROWSER_URL: API }, stdio: ['pipe', 'pipe', 'inherit'],
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

// The browser shows one page and nothing else: Chromium in kiosk mode (no tab strip, no address
// bar, no window frame), and a window.open popup is fullscreen too. Measured from inside the
// browser-node by scripts/kiosk-probe.mjs. And Xvfb must not listen on the abstract socket
// @/tmp/.X11-unix/X99: with host networking it would be in the host's namespace, a display
// anything on this machine could open.
function kiosk() {
    const probe = spawnSync('docker', ['exec', '-i', '-w', '/opt/browser-node', '-u', 'browser', NODE_CONTAINER, 'node', '--input-type=module', '-'], {
        input: readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'kiosk-probe.mjs')), encoding: 'utf8', timeout: 60000,
    });
    let g = {};
    try { g = JSON.parse(probe.stdout.trim().split('\n').pop()); } catch { g = { error: `probe exited ${probe.status}` }; }
    check(!g.error, `kiosk probe ran in ${NODE_CONTAINER}${g.error ? `: ${g.error}` : ''}`);
    const full = (w) => !!w && w.screenX === 0 && w.screenY === 0 && w.outerHeight === w.innerHeight
        && w.innerHeight === w.screenHeight && w.innerWidth === w.screenWidth;
    check(full(g.page), `page fills the screen with no browser UI: ${JSON.stringify(g.page)}`);
    check(full(g.popup), `window.open popup fills the screen too: ${JSON.stringify(g.popup)}`);
    const ss = spawnSync('ss', ['-xlH'], { encoding: 'utf8' });
    check(ss.status === 0 && !/@\/tmp\/\.X11-unix\//.test(ss.stdout), 'no abstract X11 socket in the host network namespace');
}

let sessionId, liveBase;
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
    const rel = await (await fetch(`${live}/release`, { method: 'POST' })).json();
    check(rel.status === 'watching', `POST /release -> ${rel.status}`);

    const unknown = await fetch(`${BRIDGE}/live/${'0'.repeat(32)}/state`);
    check(unknown.status === 404, `unknown id -> ${unknown.status}`);

    // MCP over stdio, against the live bridge.
    const m = mcp();
    const init = await m.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'smoke', version: '0' } });
    check(init.result?.serverInfo?.name === 'happy-browser-bridge', 'mcp initialize');
    const tools = await m.request('tools/list', {});
    const names = tools.result?.tools?.map((x) => x.name) || [];
    check(names[0] === 'browser_live_link' && names[1] === 'browser_wait_for_human', `mcp own tools: ${names.slice(0, 2).join(', ')}`);
    check(names.includes('browser_list_sessions') && names.includes('browser_observe') && names.every((x) => /^[a-zA-Z0-9_-]{1,64}$/.test(x)),
        `mcp passes auto-browser tools through (${names.length - 2}): ${names.slice(2).join(', ')}`);
    const ls = await m.request('tools/call', { name: 'browser_list_sessions', arguments: {} });
    const lsText = JSON.stringify(ls.result ?? ls.error);
    check(!ls.error && !ls.result?.isError && lsText.includes(sessionId), 'mcp browser_list_sessions (pass-through) lists the smoke session');
    const gs = await m.request('tools/call', { name: 'browser_get_session', arguments: { session_id: sessionId } });
    check(!gs.error && !gs.result?.isError && JSON.stringify(gs.result).includes(sessionId), 'mcp browser_get_session (pass-through)');
    const leakedMcp = [apiToken, bridgeToken, vncPassword].some((s) => [JSON.stringify(tools), lsText, JSON.stringify(gs)].some((t) => t.includes(s)));
    check(!leakedMcp, 'no secret in pass-through responses');
    const ll = await m.request('tools/call', { name: 'browser_live_link', arguments: { session_id: sessionId } });
    check(ll.result?.structuredContent?.link === link.url, 'mcp browser_live_link returns the same link');
    await fetch(`${live}/take`, { method: 'POST' });
    const refused = await m.request('tools/call', { name: 'browser_execute_action', arguments: { session_id: sessionId, action: { action: 'scroll', reason: 'smoke' } } });
    check(refused.result?.isError && /taken control/.test(refused.result.content?.[0]?.text || ''), 'mcp execute_action refused while the user has control');
    const obs = await m.request('tools/call', { name: 'browser_get_session', arguments: { session_id: sessionId } });
    check(!obs.error && !obs.result?.isError, 'mcp get_session still works while the user has control');
    await fetch(`${live}/release`, { method: 'POST' });
    const wait = m.request('tools/call', { name: 'browser_wait_for_human', arguments: { session_id: sessionId, reason: 'MCP smoke', timeout_s: 30 }, _meta: { progressToken: 'smoke' } });
    await new Promise((r) => setTimeout(r, 1500));
    check(m.notes.some((x) => x.method === 'notifications/progress' && x.params.message.includes(link.url)), 'mcp progress notification carries the link');
    await fetch(`${live}/done`, { method: 'POST' });
    const wres = await wait;
    check(wres.result?.structuredContent?.status === 'done', `mcp browser_wait_for_human -> ${wres.result?.structuredContent?.status}`);
    const tmo = await m.request('tools/call', { name: 'browser_wait_for_human', arguments: { session_id: sessionId, reason: 'MCP smoke timeout', timeout_s: 5 } });
    check(tmo.result?.structuredContent?.status === 'timeout', `mcp browser_wait_for_human (5 s, nobody) -> ${tmo.result?.structuredContent?.status}`);
    m.close();
} catch (err) {
    check(false, `error: ${err.message}`);
} finally {
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
