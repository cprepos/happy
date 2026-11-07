// The gateway client against a fake streamable-HTTP MCP endpoint on loopback.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtempSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createClient, stampWith, chatResolver, sseParser, readKey, parseArgs } from '../mcp-gateway-client.mjs';
import { chatOfEnv } from '../../identity/env.mjs';

const KEY = 'k'.repeat(64);

function fakeGateway(handler) {
    const seen = [];
    const server = http.createServer((req, res) => {
        let body = '';
        req.on('data', (c) => { body += c; });
        req.on('end', () => {
            const m = body ? JSON.parse(body) : null;
            seen.push({ method: req.method, headers: req.headers, m });
            if (req.headers.authorization !== `Bearer ${KEY}`) { res.writeHead(401); return res.end(); }
            handler(req, res, m, seen);
        });
    });
    return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, seen, url: `http://127.0.0.1:${server.address().port}/browser/mcp` })));
}

const sse = (res, msgs, sid = 's1') => {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'mcp-session-id': sid });
    for (const m of msgs) res.write(`event: message\ndata: ${JSON.stringify(m)}\n\n`);
    res.end();
};

function run(url, chat = { source: 'happy', id: 'S1' }) {
    const got = [];
    const waiters = [];
    const write = (m) => { got.push(m); for (const w of waiters.splice(0)) w(); };
    const client = createClient({ url, key: KEY, stamp: stampWith(async () => chat), write });
    const until = async (pred) => { while (!got.some(pred)) await new Promise((r) => waiters.push(r)); return got.find(pred); };
    return { client, got, until };
}

const INIT = { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 't', version: '1' } } };

function standard(req, res, m) {
    if (req.method === 'GET') { res.writeHead(405); return res.end(); }
    if (req.method === 'DELETE') { res.writeHead(200); return res.end(); }
    if (m.method === 'initialize') return sse(res, [{ jsonrpc: '2.0', id: m.id, result: { protocolVersion: '2025-06-18', capabilities: {} } }]);
    if (!m.id || !m.method) { res.writeHead(202); return res.end(); }
    if (m.method === 'tools/call') return sse(res, [
        { jsonrpc: '2.0', method: 'notifications/progress', params: { progressToken: 'p', progress: 1 } },
        { jsonrpc: '2.0', id: m.id, result: { content: [{ type: 'text', text: JSON.stringify(m.params._meta ?? null) }] } },
    ]);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ jsonrpc: '2.0', id: m.id, result: { tools: [] } }));
}

test('stamps tools/call with the chat and replaces a forged one', async () => {
    const g = await fakeGateway(standard);
    const { client, until, got } = run(g.url);
    client.onLine(JSON.stringify(INIT));
    await until((m) => m.id === 1);
    client.onLine(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }));
    client.onLine(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'x', arguments: { chat: 'other' }, _meta: { 'browserstack/chat': { source: 'happy', id: 'forged' }, progressToken: 'p' } } }));
    const r = await until((m) => m.id === 2);
    assert.deepEqual(JSON.parse(r.result.content[0].text), { 'browserstack/chat': { source: 'happy', id: 'S1' }, progressToken: 'p' });
    assert.ok(got.some((m) => m.method === 'notifications/progress'), 'progress passed through');
    const call = g.seen.find((s) => s.m?.id === 2);
    assert.equal(call.headers['mcp-session-id'], 's1');
    assert.equal(call.headers['mcp-protocol-version'], '2025-06-18');
    assert.deepEqual(call.m.params.arguments, { chat: 'other' }, 'arguments untouched');
    await client.close();
    assert.ok(g.seen.some((s) => s.method === 'DELETE'));
    g.server.close();
});

test('removes our meta key from anything but tools/call', async () => {
    const stamp = stampWith(async () => ({ source: 'claude', id: 'C' }));
    const m = await stamp({ jsonrpc: '2.0', id: 3, method: 'tools/list', params: { _meta: { 'browserstack/chat': { source: 'happy', id: 'x' } } } });
    assert.deepEqual(m.params, {});
    const c = await stamp({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'a' } });
    assert.deepEqual(c.params._meta, { 'browserstack/chat': { source: 'claude', id: 'C' } });
    const none = await stampWith(async () => null)({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'a', _meta: { 'browserstack/chat': { source: 'happy', id: 'forged' } } } });
    assert.equal(none.params._meta, undefined, 'no chat: the forged one is still gone');
    const resp = { jsonrpc: '2.0', id: 9, result: {} };
    assert.equal(await stamp(resp), resp, 'responses pass as they are');
});

test('a gateway that forgot the session gets the initialize again, then the call', async () => {
    let gen = 1;
    const g = await fakeGateway((req, res, m, seen) => {
        if (req.method === 'POST' && m.method === 'tools/call' && req.headers['mcp-session-id'] === 's1') { res.writeHead(404); return res.end(); }
        if (req.method === 'POST' && m.method === 'initialize') return sse(res, [{ jsonrpc: '2.0', id: m.id, result: { protocolVersion: '2025-06-18', capabilities: {} } }], `s${gen++}`);
        standard(req, res, m);
    });
    const { client, until, got } = run(g.url);
    client.onLine(JSON.stringify(INIT));
    await until((m) => m.id === 1);
    client.onLine(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'x' } }));
    const r = await until((m) => m.id === 2);
    assert.ok(r.result, 'answered after the new session');
    assert.equal(g.seen.filter((s) => s.m?.method === 'initialize').length, 2);
    assert.ok(g.seen.some((s) => s.m?.method === 'notifications/initialized' && s.headers['mcp-session-id'] === 's2'));
    assert.ok(!got.some((m) => typeof m.id === 'string'), 'the replayed initialize answer is not shown to the harness');
    await client.close();
    g.server.close();
});

test('a refused key or an unreachable gateway answers the call with an error', async () => {
    const g = await fakeGateway(standard);
    const got = [];
    const bad = createClient({ url: g.url, key: 'wrong'.repeat(5), stamp: stampWith(async () => null), write: (m) => got.push(m) });
    bad.onLine(JSON.stringify({ jsonrpc: '2.0', id: 7, method: 'tools/list' }));
    while (!got.length) await new Promise((r) => setTimeout(r, 10));
    assert.match(got[0].error.message, /refused this Mac \(HTTP 401\)/);
    assert.ok(!JSON.stringify(got).includes('wrong'), 'the key is never echoed');
    await bad.close();
    g.server.close();
    const gone = [];
    const c = createClient({ url: g.url, key: KEY, stamp: stampWith(async () => null), write: (m) => gone.push(m) });
    c.onLine(JSON.stringify({ jsonrpc: '2.0', id: 8, method: 'tools/list' }));
    while (!gone.length) await new Promise((r) => setTimeout(r, 10));
    assert.match(gone[0].error.message, /unreachable/);
    await c.close();
});

test('cancelling a call forwards the notification and stops waiting', async () => {
    let held = null;
    const g = await fakeGateway((req, res, m) => {
        if (req.method === 'POST' && m.method === 'tools/call') { held = res; res.writeHead(200, { 'content-type': 'text/event-stream' }); res.write(': keep-alive\n\n'); return; }
        standard(req, res, m);
    });
    const { client, got } = run(g.url);
    client.onLine(JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'wait' } }));
    while (!held) await new Promise((r) => setTimeout(r, 10));
    client.onLine(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: 3 } }));
    while (!g.seen.some((s) => s.m?.method === 'notifications/cancelled')) await new Promise((r) => setTimeout(r, 10));
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(got.filter((m) => m.id === 3).length, 0, 'no answer made up for a cancelled call');
    held.end();
    await client.close();
    g.server.close();
});

test('SSE parsing: multi-line data, CRLF, comments, split chunks', () => {
    const out = [];
    const feed = sseParser((d) => out.push(d));
    feed(': ping\r\n\r\nevent: message\r\ndata: {"a":\r\ndata: 1}\r\n');
    feed('\r\ndata: {"b"');
    feed(':2}\n\n');
    assert.deepEqual(out, ['{"a":\n1}', '{"b":2}']);
});

test('the chat from the environment, never from a call', async () => {
    assert.deepEqual(chatOfEnv({ HAPPY_SESSION_ID: 'h1', CLAUDE_CODE_SESSION_ID: 'c1', HAPPY_FORKED_FROM_SESSION_ID: 'p1' }), { source: 'happy', id: 'h1', forked_from: 'p1' });
    assert.deepEqual(chatOfEnv({ HAPPY_SESSION_ID: 'h1', HAPPY_FORKED_FROM_SESSION_ID: 'h1' }), { source: 'happy', id: 'h1' });
    assert.deepEqual(chatOfEnv({ CLAUDE_CODE_SESSION_ID: 'c1' }), { source: 'claude', id: 'c1' });
    assert.deepEqual(chatOfEnv({ BROWSER_CHAT_ID: 'g1' }), { source: 'chat', id: 'g1' });
    assert.equal(chatOfEnv({ HAPPY_SESSION_ID: 'bad id;rm' }), null);
    const fixed = await chatResolver({ agentDb: null }, {});
    const a = await fixed({ params: { arguments: { chat: 'x' } } });
    const b = await fixed({});
    assert.equal(a.source, 'chat');
    assert.match(a.id, /^proc-[0-9a-f-]{36}$/);
    assert.deepEqual(a, b, 'one chat for the life of the process');
});

test('Happy Agent: the chat comes from the local agent database lookup', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'gwc-'));
    // A stand-in for python: answers as agentchat.py would, for any lookup.
    const fake = join(dir, 'py');
    writeFileSync(fake, '#!/bin/sh\ncat >/dev/null\necho \'{"agent":"ag1","happy":"hs1","call":"t1"}\'\n');
    chmodSync(fake, 0o755);
    const chatOf = await chatResolver({ agentDb: join(dir, 'agent.sqlite'), agentPython: fake }, {});
    assert.deepEqual(await chatOf({ params: { name: 'browser_observe', arguments: {}, _meta: { 'claudecode/toolUseId': 't1' } } }), { source: 'happy', id: 'hs1' });
    assert.deepEqual(await chatOf({ params: { name: 'browser_observe', arguments: {} } }), { source: 'happy', id: 'hs1' });
    writeFileSync(fake, '#!/bin/sh\ncat >/dev/null\necho \'{"ambiguous":true}\'\n');
    assert.equal(await chatOf({ params: { name: 'browser_observe', arguments: {} } }), null, 'ambiguous: no chat, so the server refuses');
});

test('key file must be private; arguments are checked', () => {
    const dir = mkdtempSync(join(tmpdir(), 'gwk-'));
    const p = join(dir, 'key');
    writeFileSync(p, KEY + '\n');
    chmodSync(p, 0o644);
    assert.throws(() => readKey(p), /readable by others/);
    chmodSync(p, 0o600);
    assert.equal(readKey(p), KEY);
    assert.throws(() => parseArgs([], {}), /--url is required/);
    assert.throws(() => parseArgs(['--url', 'file:///x'], {}), /http or https/);
    assert.throws(() => parseArgs(['--url', 'http://h/x', '--chat', 'y'], {}), /unknown argument/);
    assert.equal(parseArgs(['--url', 'http://h/x', '--key-file', '~/k'], { }).keyFile.endsWith('/k'), true);
});
