// node:test suite for the secret-filler gate (lib/secrets.mjs) in the stdio MCP
// server, with a fake filler on loopback and a fake auto-browser upstream.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMcpServer } from '../mcp.mjs';
import { createSecretGate, refusal } from '../lib/secrets.mjs';

const TOKEN = 'filler-client-token-0123456789abcdef';
const SECRET = 'hunter2-canary-Zq9';

async function startFakeFiller() {
    const f = { requests: [], tainted: new Set(), up: true };
    const server = createServer(async (req, res) => {
        let body = '';
        for await (const c of req) body += c;
        const msg = body ? JSON.parse(body) : {};
        f.requests.push({ path: req.url, chat: req.headers['x-happy-chat'] ?? null, auth: req.headers.authorization, body: msg });
        const json = (status, obj) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
        if (req.headers.authorization !== `Bearer ${TOKEN}`) return json(401, { error: 'unauthorized' });
        switch (req.url) {
            case '/v1/session': return json(200, { tainted: f.tainted.has(msg.session_id), any_tainted: f.tainted.size > 0, drop_images: false });
            case '/v1/scrub': return json(200, { payload: f.tainted.size ? JSON.parse(JSON.stringify(msg.payload).split(SECRET).join('[secret:github.password]')) : msg.payload });
            case '/v1/list': if (msg && req.headers['x-happy-chat'] === 'none' && !f.hasDefault) return json(403, { error: 'this agent process has no chat id, and the filler policy has no default_client, so it may not use vault secrets', outcome: 'unbound_chat' });
                return json(200, { client: 'acme', secrets: [{ name: 'github.password', hosts: ['github.com'], kind: 'password' }] });
            case '/v1/fill': f.tainted.add(msg.session_id); return json(200, { ok: true, kind: 'password', host: 'github.com' });
            case '/v1/login': return json(422, { error: 'no login form on this page', outcome: 'no_form' });
            default: return json(404, { error: 'not found' });
        }
    });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    f.url = `http://127.0.0.1:${server.address().port}`;
    f.close = () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); });
    return f;
}

const UPSTREAM_TOOLS = ['browser.observe', 'browser.eval_js', 'browser.get_html', 'browser.execute_action', 'browser.create_session']
    .map((name) => ({ name, description: name, inputSchema: { type: 'object', properties: {} } }));

function fakeUpstream(calls) {
    return {
        listTools: async () => UPSTREAM_TOOLS,
        async callTool(name, args) {
            calls.push({ name, args });
            if (name === 'browser.get_html') return { error: { code: -32000, message: `page echoed ${SECRET}` } };
            if (name === 'browser.create_session') throw new Error(`boom ${SECRET}`);
            return { result: { content: [{ type: 'text', text: `${name} sees ${SECRET}` }], isError: false } };
        },
    };
}

function harness({ filler, tokenPath, chat = 'chat-acme', fillerUrl = filler?.url }) {
    const out = []; const calls = [];
    const secrets = createSecretGate({ fillerUrl, tokenPath, chat, controllerPort: () => 8010, timeoutMs: 2000 });
    const mcp = createMcpServer({ bridgeUrl: 'http://127.0.0.1:9', bridgeToken: 'b', write: (m) => out.push(m), upstream: fakeUpstream(calls), retryMs: 0, secrets });
    const req = async (id, method, params) => { await mcp.handle({ jsonrpc: '2.0', id, method, params }); return out.find((m) => m.id === id); };
    const call = (id, name, args) => req(id, 'tools/call', { name, arguments: args });
    const text = (m) => JSON.stringify(m);
    return { out, calls, req, call, text };
}

function tokenFile() {
    const dir = mkdtempSync(join(tmpdir(), 'bridge-secrets-'));
    const p = join(dir, 'filler-client-token');
    writeFileSync(p, `${TOKEN}\n`, { mode: 0o600 });
    return { path: p, missing: join(dir, 'nope') };
}

test('refusal rules', () => {
    assert.match(refusal('browser_create_session', { totp_secret: 'x' }, false), /totp_secret/);
    assert.match(refusal('browser_save_auth_profile', { totp_hosts: [] }, false), /totp_secret/);
    assert.equal(refusal('browser_eval_js', { script: '1' }, false), null);
    for (const [name, args] of [
        ['browser_eval_js', {}], ['browser_fork_session', {}], ['browser_save_auth_profile', {}],
        ['browser_get_html', {}], ['browser_get_html', { text_only: 'true' }],
        ['browser_find_elements', { selector: 'input[value*="a"]' }], ['browser_wait_for_selector', { selector: 'input:-webkit-autofill' }],
        ['browser_execute_action', { action: { action: 'press', key: 'Control+C' } }],
        ['browser_execute_action', { action: { action: 'press', key: 'Meta + X' } }],
        ['browser_execute_action', { action: { action: 'navigate', url: 'javascript:alert(1)' } }],
        ['browser_execute_action', { action: { action: 'navigate', url: 'view-source:https://github.com' } }],
    ]) assert.ok(refusal(name, args, true), `${name} ${JSON.stringify(args)} refused while tainted`);
    for (const [name, args] of [
        ['browser_get_html', { text_only: true }], ['browser_find_elements', { query: 'Sign in' }],
        ['browser_execute_action', { action: { action: 'press', key: 'Enter' } }],
        ['browser_execute_action', { action: { action: 'navigate', url: 'https://github.com/x' } }],
        ['browser_observe', {}],
    ]) assert.equal(refusal(name, args, true), null, `${name} allowed while tainted`);
});

test('no token file: no secret tools, no filler calls, results untouched', async () => {
    const filler = await startFakeFiller(); const tf = tokenFile();
    try {
        const h = harness({ filler, tokenPath: tf.missing });
        const names = (await h.req(1, 'tools/list', {})).result.tools.map((t) => t.name);
        assert.ok(!names.includes('browser_fill_secret') && names.includes('browser_observe'));
        const r = await h.call(2, 'browser_observe', { session_id: 's1' });
        assert.match(r.result.content[0].text, /sees hunter2/);
        const f = await h.call(3, 'browser_fill_secret', { session_id: 's1', element_id: 'e', name: 'github.password' });
        assert.equal(f.result.isError, true);
        assert.match(f.result.content[0].text, /not set up/);
        assert.equal(filler.requests.length, 0);
        // totp_secret is refused even without a filler.
        const t = await h.call(4, 'browser_create_session', { totp_secret: 'JBSWY3DP' });
        assert.match(t.result.content[0].text, /totp_secret/);
        assert.equal(h.calls.length, 1);
    } finally { await filler.close(); }
});

test('the chat comes from the environment, never from tool arguments', async () => {
    const filler = await startFakeFiller(); const tf = tokenFile();
    try {
        const h = harness({ filler, tokenPath: tf.path, chat: 'chat-acme' });
        const names = (await h.req(1, 'tools/list', {})).result.tools.map((t) => t.name);
        for (const n of ['browser_list_secrets', 'browser_fill_secret', 'browser_login']) assert.ok(names.includes(n));
        const tools = (await h.req(9, 'tools/list', {})).result.tools.filter((t) => t.name.includes('secret') || t.name === 'browser_login');
        for (const t of tools) assert.ok(!JSON.stringify(t.inputSchema).match(/chat|client|email/), `${t.name} takes no chat or client`);
        await h.call(2, 'browser_list_secrets', { chat: 'chat-globex', client: 'globex' });
        await h.call(3, 'browser_fill_secret', { session_id: 's1', element_id: 'p1', name: 'github.password', chat: 'chat-globex', controller_port: 9999 });
        const own = filler.requests.filter((x) => x.path !== '/v1/session' && x.path !== '/v1/scrub');
        assert.deepEqual(own.map((x) => x.chat), ['chat-acme', 'chat-acme']);
        assert.deepEqual(own[1].body, { session_id: 's1', element_id: 'p1', name: 'github.password', controller_port: 8010 });
        assert.ok(!('chat' in own[0].body) && !('client' in own[0].body));
        const l = await h.call(4, 'browser_login', { session_id: 's1', site: 'github' });
        assert.equal(l.result.isError, true);
        assert.match(l.result.content[0].text, /no login form/);
        // No chat id in the environment and no default_client: the filler refuses chat "none".
        const n = harness({ filler, tokenPath: tf.path, chat: null });
        const r = await n.call(5, 'browser_list_secrets', {});
        assert.equal(r.result.isError, true);
        assert.match(r.result.content[0].text, /no chat id, and the filler policy has no default_client/);
    } finally { await filler.close(); }
});

test('a process with no chat id names chat "none"; the tools are listed and work when the filler has a default_client', async () => {
    const filler = await startFakeFiller(); const tf = tokenFile();
    try {
        const n = harness({ filler, tokenPath: tf.path, chat: null });
        const names = (await n.req(1, 'tools/list', {})).result.tools.map((t) => t.name);
        for (const t of ['browser_list_secrets', 'browser_fill_secret', 'browser_login']) assert.ok(names.includes(t), `${t} listed without a chat id`);
        // Without a default the filler refuses; the bridge relays it.
        assert.equal((await n.call(2, 'browser_list_secrets', {})).result.isError, true);
        filler.hasDefault = true;
        const l = await n.call(3, 'browser_list_secrets', {});
        assert.equal(l.result.isError, false);
        assert.match(l.result.content[0].text, /github\.password/);
        const f = await n.call(4, 'browser_fill_secret', { session_id: 's1', element_id: 'p1', name: 'github.password', chat: 'chat-acme' });
        assert.equal(f.result.isError, false);
        const own = filler.requests.filter((x) => x.path === '/v1/list' || x.path === '/v1/fill');
        assert.deepEqual(own.map((x) => x.chat), ['none', 'none', 'none'], 'never empty, never taken from the arguments');
        assert.ok(filler.requests.every((x) => x.chat === 'none'));
        // The taint gate still applies to a no-chat process.
        const ev = await n.call(5, 'browser_eval_js', { session_id: 's1', script: '1' });
        assert.match(ev.result.content[0].text, /Refused/);
    } finally { await filler.close(); }
});

test('after a fill: read-back tools refused, every result and error scrubbed', async () => {
    const filler = await startFakeFiller(); const tf = tokenFile();
    try {
        const h = harness({ filler, tokenPath: tf.path });
        const before = await h.call(1, 'browser_observe', { session_id: 's1' });
        assert.match(before.result.content[0].text, /sees hunter2/, 'nothing tainted yet: values pass');
        assert.equal((await h.call(2, 'browser_fill_secret', { session_id: 's1', element_id: 'p1', name: 'github.password' })).result.isError, false);
        const n = h.calls.length;
        const ev = await h.call(3, 'browser_eval_js', { session_id: 's1', script: 'document.querySelector("input").value' });
        assert.equal(ev.result.isError, true);
        assert.match(ev.result.content[0].text, /Refused/);
        assert.equal(h.calls.length, n, 'refused calls never reach auto-browser');
        const ob = await h.call(4, 'browser_observe', { session_id: 's1' });
        assert.match(ob.result.content[0].text, /\[secret:github\.password\]/);
        const er = await h.call(5, 'browser_get_html', { session_id: 's1', text_only: true });
        assert.match(er.error.message, /\[secret:github\.password\]/);
        const th = await h.call(6, 'browser_create_session', {});
        assert.match(th.result.content[0].text, /boom \[secret:/);
        // Another session is scrubbed too (any taint scrubs everything).
        const other = await h.call(7, 'browser_observe', { session_id: 's2' });
        assert.match(other.result.content[0].text, /\[secret:/);
        for (const id of [3, 4, 5, 6, 7]) assert.ok(!h.text(h.out.find((m) => m.id === id)).includes(SECRET), `result ${id} carries no value`);
    } finally { await filler.close(); }
});

test('fails closed when the filler is configured but down', async () => {
    const tf = tokenFile();
    const filler = await startFakeFiller(); const deadUrl = filler.url; await filler.close();
    const h = harness({ filler: null, tokenPath: tf.path, fillerUrl: deadUrl });
    const r = await h.call(1, 'browser_observe', { session_id: 's1' });
    assert.equal(r.result.isError, true);
    assert.match(r.result.content[0].text, /secret filler is not reachable/);
    assert.equal(h.calls.length, 0);
    const f = await h.call(2, 'browser_fill_secret', { session_id: 's1', element_id: 'p1', name: 'github.password' });
    assert.match(f.result.content[0].text, /not reachable/);
});
