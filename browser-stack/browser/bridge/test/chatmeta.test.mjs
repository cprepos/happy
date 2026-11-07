// Behind the LAN gateway (BROWSER_CHAT_FROM_META=1): each call's chat comes from the
// _meta["browserstack/chat"] the Mac's gateway client stamps, never from tool arguments, and a
// server started without the flag ignores that _meta entirely.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chatKeyOf, createMcpServer, metaCallChat, NO_CALL_CHAT } from '../mcp.mjs';
import { chatFromMeta, chatOfMeta, CHAT_META_KEY, withoutChatMeta } from '../../../identity/chatmeta.mjs';
import { createSecretGate } from '../lib/secrets.mjs';

const UP_TOOLS = [
    { name: 'browser.observe', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } },
    { name: 'browser.get_session', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } },
];
const chatMeta = (c, extra = {}) => ({ [CHAT_META_KEY]: c, progressToken: 1, ...extra });

function harness({ fromMeta = true, chat = null, secrets = null } = {}) {
    const seen = { bridge: [], calls: [] };
    const podFor = new Map();
    let n = 0;
    const makeUpstream = (url) => ({
        listTools: async () => UP_TOOLS,
        async callTool(name, args, meta) { seen.calls.push({ url, name, args, meta }); return { result: { content: [{ type: 'text', text: 'ok' }] } }; },
    });
    const shared = { listTools: async () => UP_TOOLS, async callTool(name, args, meta) { seen.calls.push({ url: 'shared', name, args, meta }); return { result: { content: [] } }; } };
    const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
    const fetchImpl = async (url, init) => {
        const path = new URL(url).pathname;
        const body = JSON.parse(init.body || '{}');
        seen.bridge.push({ path, body });
        if (path === '/api/tools') return json(200, { tools: UP_TOOLS });
        if (path === '/api/pod') {
            if (!body.chat_key) return json(404, { error: 'no_chat' });
            if (!podFor.has(body.chat_key)) podFor.set(body.chat_key, { slot: n, sid: `pod${n++}` });
            const p = podFor.get(body.chat_key);
            return json(200, { chat_key: body.chat_key, session_id: p.sid, mcp_url: `http://127.0.0.1:${8100 + p.slot}/mcp`, api_url: `http://127.0.0.1:${8100 + p.slot}`, link_id: `L${p.slot}` });
        }
        if (path === '/api/state') return json(200, { status: 'watching' });
        if (path === '/api/links') return json(200, { id: 'L', url: 'http://localhost/live/L', status: 'watching' });
        return json(404, { error: 'not_found' });
    };
    const out = [];
    let server;
    const s = secrets ? secrets((args, cc) => server.router?.apiPortFor(args, cc) ?? null) : null;
    server = createMcpServer({
        bridgeUrl: 'http://127.0.0.1:1', bridgeToken: 't', write: (m) => out.push(m), fetchImpl, upstream: shared, retryMs: 0,
        chatPods: { chat, makeUpstream }, chatFromMeta: fromMeta, secrets: s,
    });
    let rid = 0;
    const call = async (name, args = {}, meta = undefined) => {
        const id = ++rid;
        await server.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args, ...(meta ? { _meta: meta } : {}) } });
        return out.find((m) => m.id === id);
    };
    const podBodies = () => seen.bridge.filter((b) => b.path === '/api/pod').map((b) => b.body);
    return { server, seen, call, podBodies };
}

test('chatOfMeta: only a known source with a plain id; forked_from only for a Happy session', () => {
    assert.deepEqual(chatOfMeta(chatMeta({ source: 'happy', id: 'S1' })), { source: 'happy', id: 'S1' });
    assert.deepEqual(chatOfMeta(chatMeta({ source: 'claude', id: 'c-1_x' })), { source: 'claude', id: 'c-1_x' });
    assert.deepEqual(chatOfMeta(chatMeta({ source: 'happy', id: 'S1', forked_from: 'P1' })), { source: 'happy', id: 'S1', forkedFrom: 'P1' });
    assert.deepEqual(chatOfMeta(chatMeta({ source: 'claude', id: 'c1', forked_from: 'P1' })), { source: 'claude', id: 'c1' });
    assert.deepEqual(chatOfMeta(chatMeta({ source: 'happy', id: 'S1', forked_from: 'S1' })), { source: 'happy', id: 'S1' });
    for (const bad of [undefined, null, 'S1', [], { source: 'root', id: 'x' }, { source: 'happy', id: '' }, { source: 'happy', id: 'a b' },
        { source: 'happy', id: 'x'.repeat(129) }, { source: 'happy', id: 7 }, { source: 'happy', id: '../etc' }]) {
        assert.equal(chatOfMeta(chatMeta(bad)), null, JSON.stringify(bad));
    }
    assert.equal(chatOfMeta(undefined), null);
    assert.equal(chatOfMeta([]), null);
});

test('chatFromMeta is the operator flag, exactly "1"', () => {
    assert.equal(chatFromMeta({ BROWSER_CHAT_FROM_META: '1' }), true);
    for (const v of [undefined, '', '0', 'true', 'yes']) assert.equal(chatFromMeta({ BROWSER_CHAT_FROM_META: v }), false);
});

test('withoutChatMeta drops only our key', () => {
    assert.deepEqual(withoutChatMeta({ [CHAT_META_KEY]: { source: 'happy', id: 'S' }, progressToken: 3 }), { progressToken: 3 });
    assert.equal(withoutChatMeta(undefined), undefined);
    const m = { progressToken: 1 };
    assert.equal(withoutChatMeta(m), m);
});

test('metaCallChat: the key is the same sha256("source:id") the env path and the app use', async () => {
    const r = metaCallChat();
    assert.deepEqual(await r(chatMeta({ source: 'happy', id: 'S1' })), { key: chatKeyOf({ source: 'happy', id: 'S1' }), source: 'happy', fromMeta: true, fillerChat: 'S1' });
    assert.equal((await r(chatMeta({ source: 'claude', id: 'C1' }))).fillerChat, null);
    assert.equal(await r({}), NO_CALL_CHAT);
    assert.equal(await r(undefined), NO_CALL_CHAT);
});

test('meta mode: each call goes to the pod of the chat its _meta names; tool arguments never pick it', async () => {
    const h = harness();
    const a = await h.call('browser_observe', {}, chatMeta({ source: 'happy', id: 'S1' }));
    assert.ok(!a.result.isError);
    const b = await h.call('browser_observe', { session_id: 'pod0' }, chatMeta({ source: 'happy', id: 'S2' }));
    assert.ok(!b.result.isError);
    const keys = h.podBodies().map((x) => x.chat_key);
    assert.deepEqual(keys, [chatKeyOf({ source: 'happy', id: 'S1' }), chatKeyOf({ source: 'happy', id: 'S2' })]);
    // S2 named S1's session in its arguments: it still got its own pod's session.
    assert.equal(h.seen.calls.at(-1).args.session_id, 'pod1');
    // Our _meta key is not passed on to auto-browser.
    for (const c of h.seen.calls) assert.ok(!(c.meta && CHAT_META_KEY in c.meta));
});

test('meta mode: a call without a chat (or a malformed one) is refused and reaches no browser', async () => {
    const h = harness();
    for (const meta of [undefined, { progressToken: 1 }, chatMeta({ source: 'happy', id: 'bad id' }), chatMeta('S1')]) {
        const r = await h.call('browser_observe', { session_id: 'pod0', chat: { source: 'happy', id: 'S1' } }, meta);
        assert.equal(r.result.isError, true);
        assert.match(r.result.content[0].text, /could not be matched to its chat/);
    }
    for (const name of ['browser_live_link', 'browser_wait_for_human']) {
        const r = await h.call(name, { session_id: 'pod0' });
        assert.equal(r.result.isError, true);
    }
    assert.deepEqual(h.podBodies(), []);
    assert.deepEqual(h.seen.calls, []);
});

test('meta mode: a Happy fork\'s parent goes to the bridge as forked_from (the parent\'s chat key)', async () => {
    const h = harness();
    await h.call('browser_observe', {}, chatMeta({ source: 'happy', id: 'S9', forked_from: 'P9' }));
    const [body] = h.podBodies();
    assert.equal(body.chat_key, chatKeyOf({ source: 'happy', id: 'S9' }));
    assert.equal(body.forked_from, chatKeyOf({ source: 'happy', id: 'P9' }));
    assert.equal(body.source, 'happy');
});

test('without the flag, a forged browserstack/chat _meta is ignored: the process\'s own chat is used', async () => {
    const own = { key: chatKeyOf({ source: 'happy', id: 'OWN' }), source: 'happy' };
    const h = harness({ fromMeta: false, chat: own });
    const r = await h.call('browser_observe', {}, chatMeta({ source: 'happy', id: 'VICTIM', forked_from: 'VICTIM2' }));
    assert.ok(!r.result.isError);
    assert.deepEqual(h.podBodies().map((b) => b.chat_key), [own.key]);
    assert.ok(!h.podBodies().some((b) => b.forked_from));
});

test('without the flag and without a chat, a forged _meta does not name a pod either', async () => {
    const h = harness({ fromMeta: false, chat: null });
    await h.call('browser_observe', {}, chatMeta({ source: 'happy', id: 'VICTIM' }));
    assert.ok(!h.podBodies().some((b) => b.chat_key === chatKeyOf({ source: 'happy', id: 'VICTIM' })));
});

async function fakeFiller() {
    const f = { requests: [] };
    const server = createServer(async (req, res) => {
        let body = '';
        for await (const c of req) body += c;
        f.requests.push({ path: req.url, chat: req.headers['x-happy-chat'] ?? null, body: body ? JSON.parse(body) : {} });
        res.writeHead(200, { 'content-type': 'application/json' });
        if (req.url === '/v1/session') return res.end(JSON.stringify({ tainted: false, any_tainted: false }));
        if (req.url === '/v1/scrub') return res.end(JSON.stringify({ payload: JSON.parse(body).payload }));
        return res.end(JSON.stringify({ ok: true, secrets: [] }));
    });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    f.url = `http://127.0.0.1:${server.address().port}`;
    f.close = () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); });
    return f;
}

test('meta mode: the filler hears each call\'s own chat (Happy session, else "none") and its pod\'s port', async () => {
    const f = await fakeFiller();
    try {
        const dir = mkdtempSync(join(tmpdir(), 'chatmeta-'));
        const tokenPath = join(dir, 'token');
        writeFileSync(tokenPath, 'tok\n');
        const h = harness({ secrets: (port) => createSecretGate({ fillerUrl: f.url, tokenPath, chat: 'PROCESS-CHAT', controllerPort: port, timeoutMs: 2000 }) });
        await h.call('browser_list_secrets', {}, chatMeta({ source: 'happy', id: 'S1' }));
        await h.call('browser_list_secrets', {}, chatMeta({ source: 'claude', id: 'C1' }));
        await h.call('browser_observe', {}, chatMeta({ source: 'happy', id: 'S2' }));
        await h.call('browser_fill_secret', { session_id: 'x', element_id: 'e1', name: 'github.password' }, chatMeta({ source: 'happy', id: 'S2' }));
        const r = await h.call('browser_list_secrets', {}, { progressToken: 1 });
        assert.equal(r.result.isError, true);
        const chats = f.requests.map((q) => `${q.path}:${q.chat}`);
        assert.deepEqual(chats, ['/v1/list:S1', '/v1/list:none', '/v1/session:S2', '/v1/scrub:S2', '/v1/fill:S2']);
        // The fill goes to S2's own pod (slot 0 here: the first pod made).
        assert.equal(f.requests.at(-1).body.controller_port, 8100);
        assert.ok(!chats.some((c) => c.endsWith('PROCESS-CHAT')));
    } finally {
        await f.close();
    }
});
