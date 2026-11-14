// node:test suite for approvals: an auto-browser action held for the user's approval is shown
// in the live view (scrubbed), decided there by the link's own user only, and the MCP call waits
// for the answer.
import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request as httpRequest } from 'node:http';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBridge, AUTO_APPROVE_NOTE } from '../lib/app.mjs';
import { LinkStore } from '../lib/store.mjs';
import { approvalSummary, scrubReason, placeOf } from '../lib/approval.mjs';
import { createMcpServer, APPROVAL_DENIED, APPROVAL_PENDING } from '../mcp.mjs';

const BRIDGE_TOKEN = 'bridge-secret-token-0123456789abcdef';
const SECRET_TEXT = 'Hunter2-Very-Secret';

function mockClient() {
    const sessions = new Map([
        ['sess1', { id: 'sess1', status: 'active', current_url: 'https://accounts.example.com/settings?token=abc', title: 'Settings' }],
        ['sess2', { id: 'sess2', status: 'active', current_url: 'https://other.example.org/', title: 'Other' }],
    ]);
    const approvals = new Map();
    const calls = { approve: [], reject: [], get: 0 };
    const notFound = () => Object.assign(new Error('not found'), { status: 404 });
    const conflict = () => Object.assign(new Error('conflict'), { status: 409 });
    return {
        sessions, approvals, calls,
        async getSession(id) { if (!sessions.has(id)) throw notFound(); return sessions.get(id); },
        async share(id) { return { token: `t-${id}`, expires_at: Date.now() / 1000 + 86400 }; },
        async observeShared() { throw notFound(); },
        async fetchFrame() { throw notFound(); },
        async requestTakeover() { return {}; },
        async navigate() { return {}; },
        async closeSession(id) { sessions.set(id, { ...sessions.get(id), status: 'closed' }); return {}; },
        async getApproval(id) { calls.get++; if (!approvals.has(id)) throw notFound(); return approvals.get(id); },
        async approve(id, comment) {
            const a = approvals.get(id);
            if (!a) throw notFound();
            if (a.status !== 'pending') throw conflict();
            calls.approve.push({ id, comment });
            a.status = 'approved';
            return a;
        },
        async reject(id, comment) {
            const a = approvals.get(id);
            if (!a) throw notFound();
            if (a.status !== 'pending') throw conflict();
            calls.reject.push({ id, comment });
            a.status = 'rejected';
            return a;
        },
    };
}

function approvalRecord(id, sessionId, extra = {}) {
    return {
        id, session_id: sessionId, kind: 'account_change', status: 'pending', origin: 'action',
        reason: `change the password to ${SECRET_TEXT}`,
        action: { action: 'type', element_id: 'e7', text: SECRET_TEXT, reason: `type ${SECRET_TEXT} into the new password field`, risk_category: 'account_change' },
        observation: { url: 'https://accounts.example.com/settings/password?session=xyz', title: 'Settings' },
        ...extra,
    };
}

let server, base, client, store, bridgeApp, dir, logs;
async function start() {
    dir = mkdtempSync(join(tmpdir(), 'bridge-approval-'));
    client = mockClient();
    store = new LinkStore({ path: join(dir, 'links.json') });
    logs = [];
    bridgeApp = createBridge({ client, store, log: (l) => logs.push(l), config: { bridgeToken: BRIDGE_TOKEN, vncPassword: 'Vnc8Pass', tunnelCheckMs: 50 } });
    server = createServer(bridgeApp.handler);
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
const post = (path, body) => fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body ?? {}) });
const state = async (id) => (await fetch(`${base}/live/${id}/state`)).json();

test('scrubbing: typed text, values, queries and tool arguments never reach the summary', () => {
    const s = approvalSummary(approvalRecord('a1', 'sess1'));
    const all = JSON.stringify(s);
    assert.equal(s.kind, 'account_change');
    assert.equal(s.summary, 'The agent wants to change account settings.');
    assert.ok(!all.includes(SECRET_TEXT), 'never the typed text');
    assert.ok(!all.includes('session=xyz'), 'never a query string');
    assert.ok(s.details.includes('Type text (19 characters, hidden)'));
    assert.ok(s.details.includes('Page: accounts.example.com/settings/password'));

    const tool = approvalSummary({ kind: 'account_change', origin: 'tool_call', reason: 'Approve browser.set_cookies with {"value":"sekrit-cookie"}', action: { action: 'request_human_takeover', text: 'browser.set_cookies sha256:0123' } }, 'https://x.example/a?b=c');
    assert.deepEqual(tool.details, ['Set cookies in the browser', 'Page: x.example/a']);
    assert.ok(!JSON.stringify(tool).includes('sekrit'), 'never a tool argument preview');

    assert.equal(scrubReason('log in with password: abc123 and api key=XYZ'), 'log in with password: ••• and api key=•••');
    assert.equal(scrubReason('token eyJhbGciOiJIUzI1NiJ9abcdefghij here'), 'token ••• here');
    assert.equal(scrubReason('pay with 4111111111111111 now'), 'pay with ••• now');
    assert.equal(placeOf('javascript:alert(1)'), null);
    assert.equal(placeOf('https://user:pw@h.example/p?q=1#f'), 'h.example/p');
    const odd = approvalSummary({ kind: 'nonsense', origin: 'action', action: { action: '<script>' } });
    assert.equal(odd.kind, 'write');
});

test('register, show in state, approve from the live view; waiters wake', async () => {
    const { id } = await link();
    client.approvals.set('ap1', approvalRecord('ap1', 'sess1'));
    const reg = await (await api('/api/approval', { session_id: 'sess1', approval_id: 'ap1' })).json();
    assert.equal(reg.id, id);
    assert.equal(reg.approval.id, 'ap1');

    const s = await state(id);
    assert.equal(s.approval.id, 'ap1');
    assert.equal(s.approval.kind, 'account_change');
    assert.ok(!JSON.stringify(s).includes(SECRET_TEXT));
    const page = await (await fetch(`${base}/live/${id}`)).text();
    assert.match(page, /id="approve"/);
    assert.ok(!page.includes(SECRET_TEXT), 'the page never carries the typed text');

    const waiting = api('/api/approval/wait', { id, approval_id: 'ap1', wait_s: 10 }).then((r) => r.json());
    await new Promise((r) => setTimeout(r, 50));
    assert.equal((await post(`/live/${id}/approve`, {})).status, 409, 'the approval id is required');
    assert.equal((await post(`/live/${id}/approve`, { approval_id: 'other' })).status, 409);
    assert.equal((await fetch(`${base}/live/${id}/approve`)).status, 405);
    const r = await post(`/live/${id}/approve`, { approval_id: 'ap1' });
    assert.equal(r.status, 200);
    const body = await r.json();
    assert.equal(body.approval_status, 'approved');
    assert.equal(body.approval, null);
    assert.deepEqual(client.calls.approve.map((c) => c.id), ['ap1']);
    const w = await waiting;
    assert.equal(w.approval_status, 'approved');
    assert.equal((await state(id)).approval, null);
    assert.equal((await post(`/live/${id}/approve`, { approval_id: 'ap1' })).status, 409, 'decided once');
    store.flush();
    const saved = readFileSync(join(dir, 'links.json'), 'utf8');
    assert.match(saved, /"approval"/);
    assert.ok(!saved.includes(SECRET_TEXT), 'the saved links never carry the typed text');
});

test('deny from the live view tells the waiter denied', async () => {
    const { id } = await link();
    client.approvals.set('ap2', approvalRecord('ap2', 'sess1'));
    await api('/api/approval', { session_id: 'sess1', approval_id: 'ap2' });
    const r = await post(`/live/${id}/deny`, { approval_id: 'ap2' });
    assert.equal(r.status, 200);
    assert.deepEqual(client.calls.reject.map((c) => c.id), ['ap2']);
    const w = await (await api('/api/approval/wait', { id, approval_id: 'ap2', wait_s: 1 })).json();
    assert.equal(w.approval_status, 'denied');
});

test('isolation: another session\'s approval is refused, and one link cannot decide another\'s', async () => {
    const one = await link('sess1');
    const two = await link('sess2');
    client.approvals.set('apX', approvalRecord('apX', 'sess2'));
    // Session 1's link cannot claim session 2's approval.
    const bad = await api('/api/approval', { session_id: 'sess1', approval_id: 'apX' });
    assert.equal(bad.status, 403);
    assert.equal((await state(one.id)).approval, null);
    // Shown on its own link only.
    assert.equal((await api('/api/approval', { session_id: 'sess2', approval_id: 'apX' })).status, 200);
    assert.equal((await state(two.id)).approval.id, 'apX');
    assert.equal((await state(one.id)).approval, null);
    // Link one cannot decide it, even with the id.
    assert.equal((await post(`/live/${one.id}/approve`, { approval_id: 'apX' })).status, 409);
    assert.equal(client.calls.approve.length, 0);
    // Unknown and malformed ids.
    assert.equal((await api('/api/approval', { session_id: 'sess1', approval_id: 'nope' })).status, 404);
    assert.equal((await api('/api/approval', { session_id: 'sess1', approval_id: '../x' })).status, 400);
    assert.equal((await api('/api/approval', { session_id: 'sess1', approval_id: 'apX' }, null)).status, 401);
});

test('an approval decided elsewhere or already gone is noticed', async () => {
    const { id } = await link();
    client.approvals.set('ap3', approvalRecord('ap3', 'sess1'));
    await api('/api/approval', { session_id: 'sess1', approval_id: 'ap3' });
    client.approvals.get('ap3').status = 'rejected'; // decided through the controller's own API
    const w = await (await api('/api/approval/wait', { id, approval_id: 'ap3', wait_s: 0 })).json();
    assert.equal(w.approval_status, 'denied');

    client.approvals.set('ap4', { ...approvalRecord('ap4', 'sess1'), status: 'approved' });
    const r = await api('/api/approval', { session_id: 'sess1', approval_id: 'ap4' });
    assert.equal(r.status, 409);
    assert.equal((await r.json()).approval_status, 'approved');

    // Approve races a decision made elsewhere: 409, and the card goes away.
    client.approvals.set('ap5', approvalRecord('ap5', 'sess1'));
    await api('/api/approval', { session_id: 'sess1', approval_id: 'ap5' });
    client.approvals.get('ap5').status = 'approved';
    const race = await post(`/live/${id}/deny`, { approval_id: 'ap5' });
    assert.equal(race.status, 409);
    assert.equal((await race.json()).approval_status, 'approved');
    assert.equal((await state(id)).approval, null);
});

test('ending the browser drops a pending approval', async () => {
    const { id } = await link();
    client.approvals.set('ap6', approvalRecord('ap6', 'sess1'));
    await api('/api/approval', { session_id: 'sess1', approval_id: 'ap6' });
    await post(`/live/${id}/end`);
    const s = await state(id);
    assert.equal(s.status, 'done');
    assert.equal(s.approval, null);
    const w = await (await api('/api/approval/wait', { id, approval_id: 'ap6', wait_s: 0 })).json();
    assert.equal(w.approval_status, 'gone');
});

// A request with any Host header (fetch will not set one).
function raw(port, path, { host, method = 'GET', body } = {}) {
    return new Promise((resolve, reject) => {
        const req = httpRequest({ host: '127.0.0.1', port, path, method, headers: { Host: host, ...(body ? { 'Content-Type': 'application/json' } : {}) } }, (res) => {
            let b = '';
            res.setEncoding('utf8');
            res.on('data', (d) => { b += d; });
            res.on('end', () => resolve({ status: res.statusCode, body: b }));
        });
        req.on('error', reject);
        req.end(body ? JSON.stringify(body) : undefined);
    });
}

test('LAN listener: approve works on /live, /api stays 404, Host and allowlist still checked', async () => {
    const LAN_HOST = '192.168.2.72:6090';
    const lan = bridgeApp.listener({ allowedHosts: [LAN_HOST], publicBase: `http://${LAN_HOST}`, api: false, allowFrom: ['127.0.0.1'] });
    const srv = createServer(lan.handler);
    await new Promise((r) => srv.listen(0, '127.0.0.1', r));
    const port = srv.address().port;
    const denyAll = bridgeApp.listener({ allowedHosts: [LAN_HOST], publicBase: `http://${LAN_HOST}`, api: false, allowFrom: ['10.9.9.9'] });
    const srv2 = createServer(denyAll.handler);
    await new Promise((r) => srv2.listen(0, '127.0.0.1', r));
    try {
        const { id } = await link();
        client.approvals.set('ap7', approvalRecord('ap7', 'sess1'));
        assert.equal((await raw(port, '/api/approval', { host: LAN_HOST, method: 'POST', body: { session_id: 'sess1', approval_id: 'ap7' } })).status, 404);
        await api('/api/approval', { session_id: 'sess1', approval_id: 'ap7' });
        const st = JSON.parse((await raw(port, `/live/${id}/state`, { host: LAN_HOST })).body);
        assert.equal(st.approval.id, 'ap7');
        assert.equal((await raw(port, `/live/${id}/approve`, { host: 'evil.example', method: 'POST', body: { approval_id: 'ap7' } })).status, 421);
        assert.equal((await raw(srv2.address().port, `/live/${id}/approve`, { host: LAN_HOST, method: 'POST', body: { approval_id: 'ap7' } })).status, 403);
        assert.equal(client.calls.approve.length, 0);
        const ok = await raw(port, `/live/${id}/approve`, { host: LAN_HOST, method: 'POST', body: { approval_id: 'ap7' } });
        assert.equal(ok.status, 200);
        assert.deepEqual(client.calls.approve.map((c) => c.id), ['ap7']);
    } finally {
        await new Promise((r) => { srv.closeAllConnections?.(); srv.close(r); });
        await new Promise((r) => { srv2.closeAllConnections?.(); srv2.close(r); });
    }
});

// ── The MCP side ──────────────────────────────────────────────────────────
const UP_TOOLS = [
    { name: 'browser.execute_action', description: 'Act.', inputSchema: { type: 'object', properties: { session_id: { type: 'string' }, action: { type: 'object' }, approval_id: { type: 'string' } } } },
    { name: 'browser.get_session', description: 'Get.', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } },
];
function fakeUpstream() {
    const calls = [];
    return {
        calls,
        async listTools() { return UP_TOOLS; },
        async callTool(name, args) {
            calls.push({ name, args });
            if (name === 'browser.get_session') return { result: { content: [{ type: 'text', text: '{"id":"sess1","status":"active"}' }], isError: false } };
            if (!args.approval_id) {
                if (!client.approvals.has('apM')) client.approvals.set('apM', approvalRecord('apM', 'sess1'));
                const payload = { status: 'approval_required', message: 'needs approval', approval_id: 'apM', approval: client.approvals.get('apM') };
                return { result: { content: [{ type: 'text', text: JSON.stringify(payload) }], structuredContent: payload, isError: true } };
            }
            assert.equal(args.approval_id, 'apM');
            return { result: { content: [{ type: 'text', text: 'acted type' }], isError: false } };
        },
    };
}
function mcpHarness(opts = {}) {
    const out = [];
    const upstream = fakeUpstream();
    const mcp = createMcpServer({ bridgeUrl: base, bridgeToken: BRIDGE_TOKEN, write: (m) => out.push(m), upstream, retryMs: 0, pollS: 1, ...opts });
    const call = async (id, name, args) => { await mcp.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args, _meta: { progressToken: `p${id}` } } }); return out.find((m) => m.id === id); };
    return { out, upstream, call };
}
const ACT = { session_id: 'sess1', action: { action: 'type', element_id: 'e7', text: SECRET_TEXT, reason: 'set the new password' } };
async function untilPending(id) {
    for (let i = 0; i < 100; i++) {
        const s = await state(id);
        if (s.approval) return s.approval;
        await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error('approval never shown');
}

test('mcp: an action held for approval waits, runs again with the approval once the user approves', async () => {
    const { id } = await link();
    const h = mcpHarness();
    const pending = h.call(1, 'browser_execute_action', ACT);
    const a = await untilPending(id);
    assert.equal(a.id, 'apM');
    assert.equal((await post(`/live/${id}/approve`, { approval_id: 'apM' })).status, 200);
    const res = await pending;
    assert.equal(res.result.isError, false);
    const texts = res.result.content.map((c) => c.text).join('\n');
    assert.match(texts, /The user approved this action/);
    assert.match(texts, /acted type/);
    const acts = h.upstream.calls.filter((c) => c.name === 'browser.execute_action');
    assert.equal(acts.length, 2);
    assert.equal(acts[1].args.approval_id, 'apM');
    assert.ok(h.out.some((m) => m.method === 'notifications/progress' && /approve or deny/.test(m.params.message)), 'progress tells the client it waits');
});

test('mcp: denied comes back as a do-not-retry error; no answer comes back as approval_pending', async () => {
    const { id } = await link();
    const h = mcpHarness();
    const pending = h.call(1, 'browser_execute_action', ACT);
    await untilPending(id);
    await post(`/live/${id}/deny`, { approval_id: 'apM' });
    const res = await pending;
    assert.equal(res.result.isError, true);
    assert.equal(res.result.structuredContent.status, 'denied');
    assert.equal(res.result.structuredContent.note, APPROVAL_DENIED);
    assert.equal(h.upstream.calls.filter((c) => c.name === 'browser.execute_action').length, 1, 'never run');

    client.approvals.delete('apM');
    const quick = mcpHarness({ approvalWaitS: 1 });
    const res2 = await quick.call(2, 'browser_execute_action', ACT);
    assert.equal(res2.result.structuredContent.status, 'approval_pending');
    assert.equal(res2.result.structuredContent.note, APPROVAL_PENDING);
    assert.equal(res2.result.structuredContent.approval_id, 'apM');

    // browser_wait_for_human then waits on that approval, not a takeover.
    const waiting = quick.call(3, 'browser_wait_for_human', { session_id: 'sess1', reason: 'approve', timeout_s: 10 });
    await new Promise((r) => setTimeout(r, 100));
    assert.equal((await state(id)).status, 'watching', 'no takeover for an approval');
    await post(`/live/${id}/approve`, { approval_id: 'apM' });
    const w = await waiting;
    const out = w.result.structuredContent;
    assert.equal(out.status, 'approved');
    assert.equal(out.approval_id, 'apM');
    assert.match(out.note, /approval_id: "apM"/);
});

// ── Browser yolo (auto-approve) ───────────────────────────────────────────
test('yolo: POST /live/<id>/auto sets this chat\'s flag only, shows in state, survives a restart', async () => {
    const one = await link('sess1');
    const two = await link('sess2');
    const s0 = await state(one.id);
    assert.equal(s0.auto_approve, false, 'off by default');
    assert.deepEqual(s0.auto_approved, []);
    assert.equal((await fetch(`${base}/live/${one.id}/auto`)).status, 405);
    assert.equal((await post(`/live/${one.id}/auto`, {})).status, 400, 'on is required');
    assert.equal((await post(`/live/${one.id}/auto`, { on: 'yes' })).status, 400);
    assert.equal((await post('/live/0123456789abcdef0123456789abcdef/auto', { on: true })).status, 404);
    const r = await post(`/live/${one.id}/auto`, { on: true });
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { auto_approve: true });
    assert.equal((await state(one.id)).auto_approve, true);
    assert.equal((await state(two.id)).auto_approve, false, 'never another chat\'s');
    assert.ok(logs.some((l) => /yolo mode .* on/.test(l)));
    const page = await (await fetch(`${base}/live/${one.id}`)).text();
    // No switch on the page (the app's header has it): no checkbox, no yolo button, only
    // "Yolo mode enabled" while on.
    assert.doesNotMatch(page, /type="checkbox"/);
    assert.doesNotMatch(page, /id="yolo"[ >]/);
    assert.doesNotMatch(page, /\$\('yolo'\)/);
    assert.match(page, /<span id="yolo-on" role="status">.*Yolo mode enabled<\/span>/);
    // Inside the app's web view the row is not shown: the app says it itself.
    assert.match(page, /if \(inApp\) \$\('yolo-row'\)\.hidden = true/);
    // "?" lists what every button does; each button has it as its title too.
    assert.match(page, /<button id="help" type="button" aria-expanded="false"/);
    assert.match(page, /<ul id="help-pop" hidden><li><b>Take control<\/b>/);
    assert.match(page, /<li><b>Take control<\/b>Use the page yourself/);
    assert.match(page, /id="sleep" class="btn" type="button" title="Sleep: Pause the browser/);

    store.flush();
    const again = new LinkStore({ path: join(dir, 'links.json') });
    assert.equal(again.lookup(one.id).rec.autoApprove, true);
    assert.equal(again.lookup(two.id).rec.autoApprove, undefined);

    assert.deepEqual(await (await post(`/live/${one.id}/auto`, { on: false })).json(), { auto_approve: false });
    assert.equal((await state(one.id)).auto_approve, false);
    const off = await (await fetch(`${base}/live/${one.id}`)).text();
    assert.doesNotMatch(off, /type="checkbox"|id="yolo"[ >]/);
    assert.match(off, /<span id="yolo-on" role="status" hidden>/);
});

test('yolo: an approval is approved at once with the yolo note, recorded (last 5, scrubbed), never shown', async () => {
    const one = await link('sess1');
    const two = await link('sess2');
    await post(`/live/${one.id}/auto`, { on: true });
    for (let i = 1; i <= 6; i++) {
        client.approvals.set(`y${i}`, approvalRecord(`y${i}`, 'sess1'));
        const reg = await (await api('/api/approval', { session_id: 'sess1', approval_id: `y${i}` })).json();
        assert.equal(reg.auto_approved, true);
        assert.equal(reg.approval_status, 'approved');
        assert.equal(reg.approval, null);
    }
    assert.deepEqual(client.calls.approve.map((c) => c.comment), Array(6).fill(AUTO_APPROVE_NOTE));
    assert.equal(AUTO_APPROVE_NOTE, 'Auto-approved (yolo mode)');
    const s = await state(one.id);
    assert.equal(s.approval, null, 'never shown');
    assert.deepEqual(s.auto_approved.map((e) => e.id), ['y6', 'y5', 'y4', 'y3', 'y2']);
    assert.deepEqual(Object.keys(s.auto_approved[0]).sort(), ['at', 'id', 'summary']);
    assert.equal(s.auto_approved[0].summary, 'The agent wants to change account settings.');
    assert.ok(!JSON.stringify(s).includes(SECRET_TEXT));
    assert.ok(logs.some((l) => /auto-approved y6/.test(l)));

    // The other chat still asks, and cannot borrow this chat's yolo.
    client.approvals.set('z1', approvalRecord('z1', 'sess2'));
    const reg2 = await (await api('/api/approval', { session_id: 'sess2', approval_id: 'z1' })).json();
    assert.equal(reg2.auto_approved, undefined);
    assert.equal((await state(two.id)).approval.id, 'z1');
    assert.deepEqual((await state(two.id)).auto_approved, []);
    client.approvals.set('z2', approvalRecord('z2', 'sess2'));
    assert.equal((await api('/api/approval', { session_id: 'sess1', approval_id: 'z2' })).status, 403);
    assert.equal(client.approvals.get('z2').status, 'pending');
});

test('yolo: turning it on approves the approval already waiting, and its waiter wakes', async () => {
    const { id } = await link();
    client.approvals.set('w1', approvalRecord('w1', 'sess1'));
    await api('/api/approval', { session_id: 'sess1', approval_id: 'w1' });
    const waiting = api('/api/approval/wait', { id, approval_id: 'w1', wait_s: 10 }).then((r) => r.json());
    await new Promise((r) => setTimeout(r, 50));
    assert.equal((await post(`/live/${id}/auto`, { on: true })).status, 200);
    assert.equal((await waiting).approval_status, 'approved');
    assert.deepEqual(client.calls.approve, [{ id: 'w1', comment: AUTO_APPROVE_NOTE }]);
    assert.equal((await state(id)).auto_approved[0].id, 'w1');
});

test('yolo: a waiter on an approval yolo already approved reads approved, not gone', async () => {
    const { id } = await link();
    await post(`/live/${id}/auto`, { on: true });
    client.approvals.set('yw1', approvalRecord('yw1', 'sess1'));
    const reg = await (await api('/api/approval', { session_id: 'sess1', approval_id: 'yw1' })).json();
    assert.equal(reg.auto_approved, true);
    const w = await (await api('/api/approval/wait', { id, approval_id: 'yw1', wait_s: 0 })).json();
    assert.equal(w.approval_status, 'approved');
    const other = await (await api('/api/approval/wait', { id, approval_id: 'yw2', wait_s: 0 })).json();
    assert.equal(other.approval_status, 'gone');
});

test('mcp: with yolo on, the held action runs again at once without waiting for the user', async () => {
    const { id } = await link();
    await post(`/live/${id}/auto`, { on: true });
    const h = mcpHarness({ approvalWaitS: 1 });
    const res = await h.call(1, 'browser_execute_action', ACT);
    assert.equal(res.result.isError, false);
    const texts = res.result.content.map((c) => c.text).join('\n');
    assert.match(texts, /Yolo mode is on/);
    assert.match(texts, /acted type/);
    const acts = h.upstream.calls.filter((c) => c.name === 'browser.execute_action');
    assert.equal(acts.length, 2);
    assert.equal(acts[1].args.approval_id, 'apM');
    assert.deepEqual(client.calls.approve, [{ id: 'apM', comment: AUTO_APPROVE_NOTE }]);
    assert.ok(!h.out.some((m) => m.method === 'notifications/progress' && /approve or deny/.test(m.params.message)), 'never waits');
    assert.equal((await state(id)).auto_approved[0].id, 'apM');
});
