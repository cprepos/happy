import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { createVaultMcp, TOOLS, checkArgs, NO_CHAT, chatKeyOf, envChat } from '../mcp.mjs';
import { chatKeyOf as bridgeChatKeyOf } from '../../browser/bridge/mcp.mjs';
import { runPipe } from '../lib/pipe.mjs';

const ID = '0b8e6f3a-8c1d-4c1e-9d1e-2f3a4b5c6d7e';
const VALUE = 'canary-Pw:9f2e"&<x>+/=';
const TOKEN = 'vault-token-for-tests';

// A command that echoes its stdin in a few forms, so the scrub has work to do.
const ECHO = [process.execPath, '-e', `let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{console.log('got',s);console.error(JSON.stringify(s),encodeURIComponent(s));console.log(Buffer.from(s).toString('base64'));process.exit(s.length?0:5)})`];

async function fakeFiller(handler) {
    const calls = [];
    const srv = createServer((req, res) => {
        let b = '';
        req.on('data', (d) => (b += d)).on('end', () => {
            const call = { path: req.url, auth: req.headers.authorization, chat: req.headers['x-happy-chat'], body: b ? JSON.parse(b) : null };
            calls.push(call);
            const [status, out] = handler(call);
            res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(out));
        });
    });
    await new Promise((r) => srv.listen(0, '127.0.0.1', r));
    return { url: `http://127.0.0.1:${srv.address().port}`, calls, close: () => new Promise((r) => srv.close(r)) };
}

function client(opts) {
    const out = [];
    const server = createVaultMcp({ readToken: () => TOKEN, write: (m) => out.push(m), ...opts });
    let n = 0;
    return {
        async call(name, args) {
            const id = ++n;
            await server.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } });
            return out.find((m) => m.id === id);
        },
        async rpc(method, params) { const id = ++n; await server.handle({ jsonrpc: '2.0', id, method, params }); return out.find((m) => m.id === id); },
    };
}
const textOf = (r) => r.result.content[0].text;

test('nine strict tools, no client or email parameter anywhere', () => {
    assert.deepEqual(TOOLS.map((t) => t.name), ['vault_list', 'vault_search', 'vault_create', 'vault_update', 'vault_remove', 'vault_restore', 'vault_compare', 'vault_pipe', 'vault_save_download']);
    const walk = (s) => {
        if (s.type === 'object' && s.properties) {
            assert.equal(s.additionalProperties === false || typeof s.additionalProperties === 'object', true);
            for (const k of Object.keys(s.properties)) assert.doesNotMatch(k, /client|email|password_value|value|session|port/);
            Object.values(s.properties).forEach(walk);
        }
        if (s.items) walk(s.items);
    };
    for (const t of TOOLS) { assert.equal(t.inputSchema.additionalProperties, false, t.name); walk(t.inputSchema); }
    assert.ok(!TOOLS.some((t) => /purge|delete_forever|read|reveal|get_password/.test(t.name)));
});

test('arguments are checked locally before anything reaches the filler', async () => {
    const f = await fakeFiller(() => [200, {}]);
    try {
        const c = client({ fillerUrl: f.url });
        for (const [name, args, msg] of [
            ['vault_list', { client_id: 'acme' }, /unknown key "client_id"/],
            ['vault_create', { name: 'x', uris: ['https://a.example'], username: 'u', password: 'hunter2' }, /password must be an object/],
            ['vault_create', { name: 'x', uris: ['http://a.example'], username: 'u' }, /uris\[0\] is not in the expected form/],
            ['vault_update', { id: 'nope' }, /id is not in the expected form/],
            ['vault_compare', { id: ID, field: 'password', algo: 'md5', digest: 'x' }, /algo must be one of/],
            ['vault_pipe', { id: ID, field: 'password', target: 'x', args: { a: 1 } }, /args\.a must be a string/],
            ['vault_remove', {}, /id is required/],
        ]) {
            const r = await c.call(name, args);
            assert.equal(r.result.isError, true, name);
            assert.match(textOf(r), msg);
        }
        assert.equal(f.calls.length, 0);
        assert.equal((await c.rpc('tools/call', { name: 'vault_purge', arguments: {} })).error.code, -32602);
        assert.equal(checkArgs(TOOLS[2].inputSchema, { name: 'n', uris: ['https://a.example/x'], username: 'u', password: { length: 40, classes: ['lower', 'digits'] } }), null);
    } finally { await f.close(); }
});

test('calls go to /v1/vault/<action> with the vault token and the chat id, errors are relayed', async () => {
    const f = await fakeFiller((c) => (c.path === '/v1/vault/remove' ? [403, { error: 'the filler policy does not let this chat\'s client remove vault logins' }] : [200, { client: 'agent', items: [] }]));
    try {
        let c = client({ fillerUrl: f.url, chat: 'chat-123' });
        assert.deepEqual(JSON.parse(textOf(await c.call('vault_search', { query: 'docker' }))), { client: 'agent', items: [] });
        assert.deepEqual(f.calls[0], { path: '/v1/vault/search', auth: `Bearer ${TOKEN}`, chat: 'chat-123', body: { query: 'docker' } });
        const r = await c.call('vault_remove', { id: ID });
        assert.equal(r.result.isError, true);
        assert.match(textOf(r), /^Error: vault: the filler policy does not let/);
        c = client({ fillerUrl: f.url });
        await c.call('vault_list', {});
        assert.equal(f.calls.at(-1).chat, NO_CHAT);
        const out = [];
        const s2 = createVaultMcp({ tokenPath: '/nonexistent/vault-client-token', fillerUrl: f.url, write: (m) => out.push(m) });
        await s2.handle({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'vault_list', arguments: {} } });
        assert.match(out[0].result.content[0].text, /not set up on this machine/);
    } finally { await f.close(); }
});

test('vault_pipe writes the value to stdin only and returns scrubbed output', async () => {
    const f = await fakeFiller(() => [200, { target: 'sha', argv: ECHO, value: VALUE }]);
    try {
        const c = client({ fillerUrl: f.url });
        const r = await c.call('vault_pipe', { id: ID, field: 'password', target: 'sha' });
        const text = textOf(r);
        assert.equal(r.result.isError, undefined, text);
        const out = JSON.parse(text);
        assert.equal(out.exit_code, 0);
        assert.equal(out.target, 'sha');
        assert.match(out.stdout, /^got \[secret:password\]/);
        assert.equal(out.stderr, '"[secret:password]" [secret:password]\n');
        assert.ok(!text.includes(VALUE));
        assert.ok(!text.includes(Buffer.from(VALUE).toString('base64')));
        assert.ok(!text.includes(encodeURIComponent(VALUE)));
        assert.ok(!JSON.stringify(f.calls).includes(VALUE), 'the value never goes back to the filler');
    } finally { await f.close(); }
});

test('the pipe runner: timeout, output cap, a missing command', async () => {
    const slow = await runPipe({ argv: [process.execPath, '-e', 'setTimeout(()=>{},10000)'], value: 'x', timeoutMs: 200 });
    assert.equal(slow.timed_out, true);
    const big = await runPipe({ argv: [process.execPath, '-e', 'process.stdout.write("a".repeat(200000))'], value: 'x', maxOutput: 1000 });
    assert.equal(big.truncated, true);
    assert.equal(big.stdout.length, 1000);
    await assert.rejects(runPipe({ argv: ['/nonexistent/cmd'], value: 'x' }), /cannot run \/nonexistent\/cmd/);
    await assert.rejects(runPipe({ argv: [], value: 'x' }), /no usable command/);
    // A command that never reads stdin still finishes.
    const deaf = await runPipe({ argv: [process.execPath, '-e', 'process.exit(3)'], value: 'x'.repeat(1 << 20) });
    assert.equal(deaf.exit_code, 3);
});

test('stdio: initialize, tools/list and a call through the real process', async () => {
    const f = await fakeFiller(() => [200, { client: 'agent', items: [{ id: ID, name: 'Docker Hub' }] }]);
    const home = mkdtempSync(join(tmpdir(), 'vmcp-'));
    mkdirSync(join(home, 'secrets'));
    writeFileSync(join(home, 'secrets', 'vault-client-token'), `${TOKEN}\n`, { mode: 0o600 });
    const child = spawn(process.execPath, [fileURLToPath(new URL('../mcp.mjs', import.meta.url))], {
        env: { ...process.env, HAPPY_VAULT_MCP_HOME: home, HAPPY_VAULT_FILLER_URL: f.url, HAPPY_SESSION_ID: 'chat-9' },
        stdio: ['pipe', 'pipe', 'inherit'],
    });
    const lines = createInterface({ input: child.stdout });
    const got = new Map();
    const waiters = new Map();
    lines.on('line', (l) => { const m = JSON.parse(l); got.set(m.id, m); waiters.get(m.id)?.(m); });
    const ask = (id, method, params) => new Promise((r) => { waiters.set(id, r); child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n'); });
    try {
        const init = await ask(1, 'initialize', { protocolVersion: '2025-03-26' });
        assert.equal(init.result.protocolVersion, '2025-03-26');
        assert.match(init.result.instructions, /only way to use the vault/);
        assert.equal((await ask(2, 'tools/list', {})).result.tools.length, 9);
        const r = await ask(3, 'tools/call', { name: 'vault_list', arguments: {} });
        assert.match(r.result.content[0].text, /Docker Hub/);
        assert.equal(f.calls[0].auth, `Bearer ${TOKEN}`);
        assert.equal(f.calls[0].chat, 'chat-9');
    } finally {
        child.stdin.end();
        await f.close();
    }
});

// Behind the LAN gateway (fromMeta): the chat of each call is the _meta the Mac's client stamps.
function metaClient(opts) {
    const out = [];
    const server = createVaultMcp({ readToken: () => TOKEN, write: (m) => out.push(m), ...opts });
    let n = 0;
    return async (name, args, meta) => {
        const id = ++n;
        await server.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args, ...(meta ? { _meta: meta } : {}) } });
        return out.find((m) => m.id === id);
    };
}
const chatMeta = (c) => ({ 'browserstack/chat': c });

test('fromMeta: each call tells the filler its own chat (Happy session id, else none)', async () => {
    const f = await fakeFiller(() => [200, { items: [] }]);
    try {
        const call = metaClient({ fillerUrl: f.url, fromMeta: true, chat: 'PROCESS' });
        await call('vault_list', {}, chatMeta({ source: 'happy', id: 'S1' }));
        await call('vault_list', {}, chatMeta({ source: 'happy', id: 'S2' }));
        await call('vault_list', {}, chatMeta({ source: 'claude', id: 'C1' }));
        assert.deepEqual(f.calls.map((c) => c.chat), ['S1', 'S2', NO_CHAT]);
    } finally { await f.close(); }
});

test('fromMeta: a call with no chat, or a malformed one, never reaches the filler', async () => {
    const f = await fakeFiller(() => [200, { items: [] }]);
    try {
        const call = metaClient({ fillerUrl: f.url, fromMeta: true });
        for (const meta of [undefined, {}, chatMeta({ source: 'happy', id: 'a b' }), chatMeta({ source: 'x', id: 'S1' }), chatMeta('S1')]) {
            const r = await call('vault_list', {}, meta);
            assert.equal(r.result.isError, true);
            assert.match(textOf(r), /could not be matched to its chat/);
        }
        // Not from the arguments either (the schema refuses unknown ones before anything is sent).
        const r = await call('vault_list', { chat: 'S1' });
        assert.equal(r.result.isError, true);
        assert.equal(f.calls.length, 0);
    } finally { await f.close(); }
});

test('without fromMeta a forged browserstack/chat _meta is ignored: the process chat is used', async () => {
    const f = await fakeFiller(() => [200, { items: [] }]);
    try {
        const call = metaClient({ fillerUrl: f.url, chat: 'OWN' });
        await call('vault_list', {}, chatMeta({ source: 'happy', id: 'VICTIM' }));
        const none = metaClient({ fillerUrl: f.url });
        await none('vault_list', {}, chatMeta({ source: 'happy', id: 'VICTIM' }));
        assert.deepEqual(f.calls.map((c) => c.chat), ['OWN', NO_CHAT]);
    } finally { await f.close(); }
});

test('custom_field: compare and pipe take exactly one of field and custom_field, a well-formed name', async () => {
    const f = await fakeFiller(() => [200, { match: true }]);
    try {
        const c = client({ fillerUrl: f.url });
        for (const name of ['vault_compare', 'vault_pipe']) {
            const t = TOOLS.find((x) => x.name === name);
            assert.deepEqual(t.inputSchema.properties.custom_field.pattern, '^[A-Za-z0-9 _.-]{1,64}$');
            assert.ok(!t.inputSchema.required.includes('field') && !t.inputSchema.required.includes('custom_field'), name);
            assert.ok(!('exactlyOne' in JSON.parse(JSON.stringify(t.inputSchema))), 'no non-standard keyword in tools/list');
            assert.ok(!('oneOf' in t.inputSchema) && !('anyOf' in t.inputSchema), 'no top-level oneOf/anyOf');
        }
        assert.match(TOOLS.find((x) => x.name === 'vault_list').description, /custom_fields/);
        assert.match(TOOLS.find((x) => x.name === 'vault_pipe').inputSchema.properties.field.description, /stored TOTP seed/);
        assert.doesNotMatch(TOOLS.find((x) => x.name === 'vault_pipe').inputSchema.properties.field.description, /totp is the current code/);
        const cmp = { id: ID, algo: 'sha256', digest: 'ab' };
        for (const [name, args, msg] of [
            ['vault_compare', { ...cmp }, /exactly one of field, custom_field/],
            ['vault_compare', { ...cmp, field: 'password', custom_field: 'token' }, /exactly one of field, custom_field/],
            ['vault_pipe', { id: ID, target: 'sha' }, /exactly one of field, custom_field/],
            ['vault_pipe', { id: ID, target: 'sha', field: 'password', custom_field: 'token' }, /exactly one/],
            ['vault_pipe', { id: ID, target: 'sha', custom_field: '' }, /custom_field is too short/],
            ['vault_pipe', { id: ID, target: 'sha', custom_field: 'x'.repeat(65) }, /custom_field is too long/],
            ['vault_pipe', { id: ID, target: 'sha', custom_field: 'to/ken' }, /custom_field is not in the expected form/],
            ['vault_pipe', { id: ID, target: 'sha', custom_field: 7 }, /custom_field must be a string/],
            ['vault_pipe', { id: ID, target: 'sha', field: 'notes' }, /field must be one of/],
        ]) {
            const r = await c.call(name, args);
            assert.equal(r.result.isError, true, JSON.stringify(args));
            assert.match(textOf(r), msg);
        }
        assert.equal(f.calls.length, 0, 'refused locally');
        assert.deepEqual(JSON.parse(textOf(await c.call('vault_compare', { ...cmp, custom_field: 'API key.v2' }))), { match: true });
        assert.deepEqual(f.calls[0].body, { ...cmp, custom_field: 'API key.v2' });
    } finally { await f.close(); }
});

test('vault_pipe with custom_field: the value is scrubbed as [secret:<name>]', async () => {
    const f = await fakeFiller(() => [200, { target: 'jira-login', argv: ECHO, value: VALUE }]);
    try {
        const c = client({ fillerUrl: f.url });
        const r = await c.call('vault_pipe', { id: ID, custom_field: 'token', target: 'jira-login', args: { site: 'team.atlassian.net' } });
        const text = textOf(r);
        assert.equal(r.result.isError, undefined, text);
        const out = JSON.parse(text);
        assert.match(out.stdout, /^got \[secret:token\]/);
        assert.equal(out.stderr, '"[secret:token]" [secret:token]\n');
        assert.ok(!text.includes(VALUE) && !text.includes(Buffer.from(VALUE).toString('base64')) && !text.includes(encodeURIComponent(VALUE)));
        assert.deepEqual(f.calls[0].body, { id: ID, custom_field: 'token', target: 'jira-login', args: { site: 'team.atlassian.net' } });
    } finally { await f.close(); }
});

test('vault_pipe with attachment: exactly one of three sources; the file goes to stdin only, scrubbed as [secret:attachment:<file name>]', async () => {
    const PEM = '-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49McpAttachCanary+/=\n-----END PRIVATE KEY-----\n';
    const f = await fakeFiller((call) => (call.path === '/v1/vault/list'
        ? [200, { client: 'agent', items: [{ id: ID, name: 'ASC key', kind: 'note', attachments: [{ id: 'att0123', file_name: 'AuthKey_X.p8', size: PEM.length }] }] }]
        : [200, { target: 'gh-secret', argv: ECHO, value: PEM }]));
    try {
        const c = client({ fillerUrl: f.url });
        const t = TOOLS.find((x) => x.name === 'vault_pipe');
        assert.equal(t.inputSchema.properties.attachment.pattern, '^[A-Za-z0-9_-]{1,64}$');
        assert.ok(!t.inputSchema.required.includes('attachment'));
        assert.match(t.description, /any target/i);
        assert.match(t.description, /attachment/);
        for (const args of [
            { id: ID, target: 'gh-secret' },
            { id: ID, target: 'gh-secret', field: 'password', attachment: 'att0123' },
            { id: ID, target: 'gh-secret', custom_field: 'token', attachment: 'att0123' },
            { id: ID, target: 'gh-secret', field: 'password', custom_field: 'token', attachment: 'att0123' },
        ]) {
            const r = await c.call('vault_pipe', args);
            assert.equal(r.result.isError, true);
            assert.match(textOf(r), /exactly one of field, custom_field, attachment/);
        }
        for (const [bad, msg] of [['', /too short/], ['a/b', /expected form/], ['x'.repeat(65), /too long/]]) {
            assert.match(textOf(await c.call('vault_pipe', { id: ID, target: 'gh-secret', attachment: bad })), msg);
        }
        assert.equal(f.calls.length, 0, 'refused locally');
        const args = { id: ID, attachment: 'att0123', target: 'gh-secret', args: { name: 'ASC_KEY_P8', repo: 'owner/repo' } };
        const r = await c.call('vault_pipe', args);
        const text = textOf(r);
        assert.equal(r.result.isError, undefined, text);
        const out = JSON.parse(text);
        assert.equal(out.exit_code, 0);
        assert.match(out.stdout, /^got \[secret:attachment:AuthKey_X\.p8\]/);
        assert.ok(!text.includes('McpAttachCanary') && !text.includes(Buffer.from(PEM).toString('base64')) && !text.includes(encodeURIComponent(PEM)));
        assert.ok(!out.argv.some((a) => a.includes('McpAttachCanary')), 'never in argv');
        assert.deepEqual(f.calls.find((x) => x.path === '/v1/vault/pipe').body, args);
        assert.ok(!JSON.stringify(f.calls).includes('McpAttachCanary'), 'the value never goes back to the filler');
    } finally { await f.close(); }
});

// A fake bridge /api/pod: chats (chat key -> {session_id, port}) have a running browser.
async function fakeBridge(chats, { status = null } = {}) {
    const calls = [];
    const srv = createServer((req, res) => {
        let b = '';
        req.on('data', (d) => (b += d)).on('end', () => {
            const body = b ? JSON.parse(b) : null;
            calls.push({ path: req.url, auth: req.headers.authorization, body });
            const send = (st, o) => res.writeHead(st, { 'Content-Type': 'application/json' }).end(JSON.stringify(o));
            if (req.headers.authorization !== 'Bearer bridge-token-for-tests') return send(401, { error: 'unauthorized' });
            if (status) return send(status, { error: 'pods_disabled' });
            const c = chats[body?.chat_key];
            if (!body?.peek) return send(500, { error: 'a start was asked for' });
            if (!c) return send(404, { error: 'no_browser' });
            send(200, { chat_key: body.chat_key, state: 'running', session_id: c.session_id, api_url: `http://127.0.0.1:${c.port}`, slot: 0 });
        });
    });
    await new Promise((r) => srv.listen(0, '127.0.0.1', r));
    return { url: `http://127.0.0.1:${srv.address().port}`, calls, close: () => new Promise((r) => srv.close(r)) };
}

test('vault_save_download: the chat\'s own browser, found by its chat key, never from the arguments', async () => {
    assert.equal(chatKeyOf({ source: 'happy', id: 'h-1' }), bridgeChatKeyOf({ source: 'happy', id: 'h-1' }), 'the same key the bridge uses');
    assert.deepEqual(envChat({ HAPPY_SESSION_ID: 'h1', CLAUDE_CODE_SESSION_ID: 'c1' }), { source: 'happy', id: 'h1' });
    assert.deepEqual(envChat({ CLAUDE_CODE_SESSION_ID: 'c1' }), { source: 'claude', id: 'c1' });
    assert.equal(envChat({}), null);
    const out = { item_id: ID, item_name: 'n', attachment_id: 'a1', file_name: 'f.pdf', size: 3, sha256: 'a'.repeat(64), download_deleted: true };
    const f = await fakeFiller(() => [200, out]);
    const mine = { source: 'happy', id: 'sess-mine' };
    const b = await fakeBridge({ [chatKeyOf(mine)]: { session_id: 'browser-mine', port: 8103 } });
    try {
        const opts = { fillerUrl: f.url, bridgeUrl: b.url, readBridgeToken: () => 'bridge-token-for-tests' };
        const c = client({ ...opts, chat: 'sess-mine', ident: mine });
        const r = await c.call('vault_save_download', { download_id: 'a1b2c3d4e5f6', new_item: { name: 'test-download' } });
        assert.equal(r.result.isError, undefined, textOf(r));
        assert.deepEqual(JSON.parse(textOf(r)), out);
        assert.deepEqual(b.calls[0].body, { chat_key: chatKeyOf(mine), source: 'happy', peek: true });
        assert.deepEqual(f.calls[0], { path: '/v1/vault/save_download', auth: `Bearer ${TOKEN}`, chat: 'sess-mine', body: { download_id: 'a1b2c3d4e5f6', new_item: { name: 'test-download' }, session_id: 'browser-mine', controller_port: 8103 } });
        // The agent may not name a session or port, nor both or neither of item and new_item.
        for (const [args, msg] of [
            [{ download_id: 'a1b2c3d4e5f6', item: 'x', session_id: 'browser-theirs' }, /unknown key "session_id"/],
            [{ download_id: 'a1b2c3d4e5f6', item: 'x', controller_port: 8104 }, /unknown key "controller_port"/],
            [{ download_id: 'a1b2c3d4e5f6' }, /exactly one of item, new_item/],
            [{ download_id: 'a1b2c3d4e5f6', item: 'x', new_item: { name: 'y' } }, /exactly one of item, new_item/],
            [{ download_id: '../etc', item: 'x' }, /download_id is not in the expected form/],
            [{ download_id: 'a1b2c3d4e5f6', item: 'x', file_name: 'a/b' }, /file_name is not in the expected form/],
        ]) {
            const x = await c.call('vault_save_download', args);
            assert.equal(x.result.isError, true);
            assert.match(textOf(x), msg);
        }
        assert.equal(f.calls.length, 1);
        // Another chat (no running browser), no chat id at all, a bridge with shared browsers only.
        const other = client({ ...opts, chat: 'sess-other', ident: { source: 'happy', id: 'sess-other' } });
        assert.match(textOf(await other.call('vault_save_download', { download_id: 'a1b2c3d4e5f6', item: 'x' })), /no running browser/);
        assert.match(textOf(await client({ ...opts }).call('vault_save_download', { download_id: 'a1b2c3d4e5f6', item: 'x' })), /no chat id/);
        const shared = await fakeBridge({}, { status: 409 });
        try {
            assert.match(textOf(await client({ ...opts, bridgeUrl: shared.url, ident: mine }).call('vault_save_download', { download_id: 'a1b2c3d4e5f6', item: 'x' })), /per-chat browser/);
        } finally { await shared.close(); }
        assert.match(textOf(await client({ fillerUrl: f.url, bridgeUrl: b.url, bridgeTokenPath: '/nonexistent/bridge-token', ident: mine }).call('vault_save_download', { download_id: 'a1b2c3d4e5f6', item: 'x' })), /no browser bridge token/);
        assert.equal(f.calls.length, 1, 'nothing more reached the filler');
    } finally { await f.close(); await b.close(); }
});

test('vault_save_download behind the gateway: each call\'s _meta chat picks the browser', async () => {
    const f = await fakeFiller(() => [200, { download_deleted: true }]);
    const a = { source: 'happy', id: 'sess-a' };
    const cc = { source: 'claude', id: 'cc-b' };
    const b = await fakeBridge({ [chatKeyOf(a)]: { session_id: 'browser-a', port: 8101 }, [chatKeyOf(cc)]: { session_id: 'browser-b', port: 8102 } });
    try {
        const out = [];
        const s = createVaultMcp({ readToken: () => TOKEN, write: (m) => out.push(m), fillerUrl: f.url, bridgeUrl: b.url, readBridgeToken: () => 'bridge-token-for-tests', fromMeta: true, ident: { source: 'happy', id: 'ignored' } });
        const call = async (id, meta) => { await s.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name: 'vault_save_download', arguments: { download_id: 'a1b2c3d4e5f6', item: 'x' }, _meta: meta } }); return out.find((m) => m.id === id); };
        await call(1, { 'browserstack/chat': a });
        await call(2, { 'browserstack/chat': cc });
        assert.deepEqual(f.calls.map((c) => [c.chat, c.body.session_id, c.body.controller_port]), [['sess-a', 'browser-a', 8101], [NO_CHAT, 'browser-b', 8102]]);
        assert.equal((await call(3, {})).result.isError, true);
        assert.equal(f.calls.length, 2);
    } finally { await f.close(); await b.close(); }
});
