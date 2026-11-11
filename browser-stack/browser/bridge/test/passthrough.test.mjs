// node:test suite for passing auto-browser's MCP tools through the bridge's
// stdio MCP server, with auto-browser's Streamable HTTP endpoint mocked.
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createMcpServer, mapUpstreamTools, actionOf, sessionOf, USER_HAS_CONTROL, USER_ENDED, evidenceBarPx } from '../mcp.mjs';
import { createUpstreamMcp, parseSse, localToolName } from '../lib/upstream.mjs';

const TOKEN = 'ab-secret-token-fedcba9876543210';
const UPSTREAM_TOOLS = [
    { name: 'browser.create_session', description: 'Create a session. Then use browser.observe.', inputSchema: { type: 'object', properties: { name: { type: 'string' } } } },
    { name: 'browser.list_sessions', description: 'List sessions.', inputSchema: { type: 'object', properties: {} }, annotations: { readOnlyHint: true } },
    { name: 'browser.observe', description: 'Observe.', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } },
    { name: 'browser.execute_action', description: 'Act.', inputSchema: { type: 'object', properties: { session_id: { type: 'string' }, action: { type: 'object' } } } },
];

// ── mock auto-browser /mcp ───────────────────────────────────────────────
const mock = { sessions: new Set(), requests: [], sse: false, n: 0, page2: false };
let server, url;

before(async () => {
    server = createServer(async (req, res) => {
        let body = '';
        for await (const c of req) body += c;
        const msg = JSON.parse(body || '{}');
        const sid = req.headers['mcp-session-id'];
        mock.requests.push({ method: msg.method, sid, auth: req.headers.authorization, accept: req.headers.accept, params: msg.params });
        const json = (status, obj, headers = {}) => { res.writeHead(status, { 'content-type': 'application/json', ...headers }); res.end(JSON.stringify(obj)); };
        if (req.headers.authorization !== `Bearer ${TOKEN}`) return json(401, { error: 'unauthorized' });
        if (msg.method === 'initialize') {
            const id = `sess-${++mock.n}`;
            mock.sessions.add(id);
            return json(200, { jsonrpc: '2.0', id: msg.id, result: { protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'auto-browser', version: 'x' } } }, { 'mcp-session-id': id });
        }
        if (!sid) return json(400, { jsonrpc: '2.0', id: msg.id ?? null, error: { code: -32000, message: 'Missing required header: MCP-Session-Id' } });
        if (!mock.sessions.has(sid)) return json(404, { jsonrpc: '2.0', id: msg.id ?? null, error: { code: -32001, message: 'Session not found' } });
        if (msg.id === undefined) { res.writeHead(202); return res.end(); }
        if (msg.method === 'tools/list') {
            if (mock.page2 && !msg.params?.cursor) return json(200, { jsonrpc: '2.0', id: msg.id, result: { tools: UPSTREAM_TOOLS.slice(0, 1), nextCursor: 'c2' } });
            return json(200, { jsonrpc: '2.0', id: msg.id, result: { tools: mock.page2 ? UPSTREAM_TOOLS.slice(1) : UPSTREAM_TOOLS } });
        }
        if (msg.method === 'tools/call') {
            const { name, arguments: args } = msg.params;
            let reply;
            if (name === 'browser.list_sessions') reply = { jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: '[{"id":"s1"}]' }], structuredContent: { result: [{ id: 's1' }] }, isError: false } };
            else if (name === 'browser.execute_action') reply = { jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: `acted ${args.action?.action}` }], isError: false } };
            // The session check the bridge makes before a call that names a session.
            else if (name === 'browser.get_session') reply = { jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: `{"id":"${args.session_id}","status":"active"}` }], isError: false } };
            else if (name === 'browser.observe') reply = { jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: `observed ${args.session_id}` }], isError: false } };
            else reply = { jsonrpc: '2.0', id: msg.id, error: { code: -32602, message: `Unknown tool: ${name}` } };
            if (mock.sse) {
                const token = msg.params._meta?.progressToken;
                res.writeHead(200, { 'content-type': 'text/event-stream', 'mcp-session-id': sid });
                if (token !== undefined) res.write(`event: message\ndata: ${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/progress', params: { progressToken: token, progress: 1 } })}\n\n`);
                res.write(`event: message\ndata: ${JSON.stringify(reply)}\n\n`);
                return res.end();
            }
            return json(200, reply);
        }
        json(200, { jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'nope' } });
    });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    url = `http://127.0.0.1:${server.address().port}/mcp`;
});
after(() => server.close());
beforeEach(() => { mock.sessions.clear(); mock.requests.length = 0; mock.sse = false; mock.page2 = false; });

function harness({ to = url, token = TOKEN, retryMs = 0 } = {}) {
    const out = [];
    const logs = [];
    const write = (m) => out.push(m);
    const upstream = createUpstreamMcp({ url: to, getToken: () => token, timeoutMs: 2000, onNotification: (m) => m.method === 'notifications/progress' && write(m) });
    // bridgeUrl is unused by pass-through calls.
    const mcp = createMcpServer({ bridgeUrl: 'http://127.0.0.1:9', bridgeToken: 'b', write, upstream, log: (l) => logs.push(l), retryMs, waitMaxS: 570 });
    const req = async (id, method, params) => { await mcp.handle({ jsonrpc: '2.0', id, method, params }); return out.find((m) => m.id === id); };
    const call = (id, name, args, meta) => req(id, 'tools/call', { name, arguments: args, ...(meta ? { _meta: meta } : {}) });
    return { mcp, out, logs, req, call };
}

test('names: dots map to underscores; descriptions follow; own names win', () => {
    assert.equal(localToolName('browser.navigate'), 'browser_navigate');
    assert.equal(localToolName('a b/c-d_e'), 'a_b_c-d_e');
    const logs = [];
    const m = mapUpstreamTools([...UPSTREAM_TOOLS, { name: 'browser.live_link', description: '' }, { name: 'browser_list_sessions', description: '' }], (l) => logs.push(l));
    assert.deepEqual(m.tools.map((t) => t.name), ['browser_create_session', 'browser_list_sessions', 'browser_observe', 'browser_execute_action']);
    assert.match(m.tools[3].description, /Refused while the user has control/);
    assert.doesNotMatch(m.tools[2].description, /Refused/);
    assert.equal(m.byLocal.get('browser_observe'), 'browser.observe');
    assert.match(m.tools[0].description, /use browser_observe\./);
    assert.match(m.tools[0].description, /browser_live_link/);
    assert.equal(logs.length, 2);
    for (const t of m.tools) assert.match(t.name, /^[a-zA-Z0-9_-]{1,64}$/);
});

test('sse: parses data lines and skips junk', () => {
    const msgs = parseSse('event: message\ndata: {"a":1}\n\n: comment\n\ndata: not json\n\r\ndata: {"b":\ndata: 2}\n\n');
    assert.deepEqual(msgs, [{ a: 1 }, { b: 2 }]);
});

test('tools/list merges our tools with auto-browser\'s, sessions handled', async () => {
    const { req } = harness();
    const init = await req(1, 'initialize', { protocolVersion: '2025-06-18' });
    assert.equal(init.result.capabilities.tools.listChanged, true);
    assert.match(init.result.instructions, /browser_live_link/);
    const r = await req(2, 'tools/list', {});
    const names = r.result.tools.map((t) => t.name);
    assert.deepEqual(names, ['browser_live_link', 'browser_wait_for_human', 'browser_create_session', 'browser_list_sessions', 'browser_observe', 'browser_execute_action']);
    assert.deepEqual(r.result.tools[3].annotations, { readOnlyHint: true });
    assert.match(r.result.tools[1].inputSchema.properties.timeout_s.description, /max 570/);
    // initialize, then notifications/initialized with the new session id, then tools/list on it.
    const sid = `sess-${mock.n}`;
    assert.deepEqual(mock.requests.map((x) => [x.method, x.sid]), [['initialize', undefined], ['notifications/initialized', sid], ['tools/list', sid]]);
    assert.ok(mock.requests.every((x) => x.auth === `Bearer ${TOKEN}` && /text\/event-stream/.test(x.accept)));
    await req(3, 'tools/list', {});
    assert.equal(mock.requests.filter((x) => x.method === 'initialize').length, 1, 'session reused');
});

test('tools/list follows nextCursor', async () => {
    mock.page2 = true;
    const { req } = harness();
    const r = await req(1, 'tools/list', {});
    assert.equal(r.result.tools.length, 6);
});

test('tools/call forwards under the original name and returns the result verbatim (JSON)', async () => {
    const { req, call } = harness();
    await req(1, 'tools/list', {});
    const r = await call(2, 'browser_list_sessions', {});
    assert.deepEqual(r, { jsonrpc: '2.0', id: 2, result: { content: [{ type: 'text', text: '[{"id":"s1"}]' }], structuredContent: { result: [{ id: 's1' }] }, isError: false } });
    const sent = mock.requests.find((x) => x.method === 'tools/call');
    assert.equal(sent.params.name, 'browser.list_sessions');
});

test('tools/call over SSE, relaying progress; works without a prior tools/list', async () => {
    mock.sse = true;
    const { call, out } = harness();
    const r = await call(7, 'browser_observe', { session_id: 'abc' }, { progressToken: 'p9' });
    assert.equal(r.result.content[0].text, 'observed abc');
    const prog = out.find((m) => m.method === 'notifications/progress');
    assert.equal(prog.params.progressToken, 'p9');
    assert.equal(mock.requests.find((x) => x.method === 'tools/call').params._meta.progressToken, 'p9');
});

test('upstream JSON-RPC errors pass through as errors', async () => {
    const { req, call } = harness();
    await req(1, 'tools/list', {});
    const r = await call(2, 'no_such_tool', {});
    assert.equal(r.error.code, -32602);
});

test('an expired upstream session is re-initialized and the call retried once', async () => {
    const { req, call } = harness();
    await req(1, 'tools/list', {});
    mock.sessions.clear(); // controller restarted
    const r = await call(2, 'browser_list_sessions', {});
    assert.equal(r.result.isError, false);
    const sids = mock.requests.filter((x) => x.method === 'tools/call').map((x) => x.sid);
    assert.equal(sids.length, 2);
    assert.notEqual(sids[0], sids[1]);
    assert.ok(mock.sessions.has(sids[1]));
});

test('auto-browser down: own tools still listed, calls get a clear tool error, nothing leaks', async () => {
    const dead = createServer();
    await new Promise((r) => dead.listen(0, '127.0.0.1', r));
    const port = dead.address().port;
    await new Promise((r) => dead.close(r));
    const { req, call, logs } = harness({ to: `http://127.0.0.1:${port}/mcp` });
    const list = await req(1, 'tools/list', {});
    assert.deepEqual(list.result.tools.map((t) => t.name), ['browser_live_link', 'browser_wait_for_human']);
    const r = await call(2, 'browser_list_sessions', {});
    assert.equal(r.result.isError, true);
    assert.match(r.result.content[0].text, /not reachable/);
    assert.ok(logs.some((l) => /unreachable/.test(l)));
    for (const s of [JSON.stringify(list), JSON.stringify(r), logs.join('\n')]) assert.ok(!s.includes(TOKEN));
});

test('a known tool whose call fails mid-flight gets a tool error', async () => {
    const realFetch = globalThis.fetch;
    const upstream = createUpstreamMcp({ url, getToken: () => TOKEN, fetchImpl: async (u, init) => { if (JSON.parse(init.body).method === 'tools/call') throw Object.assign(new TypeError('fetch failed'), { cause: { code: 'ECONNRESET' } }); return realFetch(u, init); } });
    const out = [];
    const mcp = createMcpServer({ bridgeUrl: 'http://127.0.0.1:9', bridgeToken: 'b', write: (m) => out.push(m), upstream, retryMs: 0 });
    await mcp.handle({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
    await mcp.handle({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'browser_list_sessions', arguments: {} } });
    const r = out.find((m) => m.id === 2);
    assert.equal(r.result.isError, true);
    assert.match(r.result.content[0].text, /ECONNRESET/);
});

test('a rejected token is reported without echoing it', async () => {
    const { req, call } = harness({ token: 'wrong-token-123456' });
    const list = await req(1, 'tools/list', {});
    assert.equal(list.result.tools.length, 2);
    const r = await call(2, 'browser_list_sessions', {});
    assert.equal(r.result.isError, true);
    assert.ok(!JSON.stringify(r).includes('wrong-token-123456'));
});

test('when auto-browser comes back, the client is told the tool list changed', async () => {
    let up = false;
    const realFetch = globalThis.fetch;
    const upstream = createUpstreamMcp({ url, getToken: () => TOKEN, fetchImpl: (u, init) => (up ? realFetch(u, init) : Promise.reject(new TypeError('fetch failed'))) });
    const out = [];
    const mcp = createMcpServer({ bridgeUrl: 'http://127.0.0.1:9', bridgeToken: 'b', write: (m) => out.push(m), upstream, retryMs: 50 });
    await mcp.handle({ jsonrpc: '2.0', method: 'notifications/initialized' });
    await mcp.handle({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
    assert.equal(out[0].result.tools.length, 2);
    up = true;
    await new Promise((r) => setTimeout(r, 200));
    assert.ok(out.some((m) => m.method === 'notifications/tools/list_changed'));
    await mcp.handle({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
    assert.equal(out.find((m) => m.id === 2).result.tools.length, 6);
});

test('without pass-through, an unknown tool is a JSON-RPC error as before', async () => {
    const out = [];
    const mcp = createMcpServer({ bridgeUrl: 'http://127.0.0.1:9', bridgeToken: 'b', write: (m) => out.push(m) });
    await mcp.handle({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'browser_observe', arguments: {} } });
    assert.equal(out[0].error.code, -32602);
});

// ── the control lock, with the bridge's /api/state mocked ────────────────
async function mockBridge(status) {
    const seen = [];
    const srv = createServer(async (req, res) => {
        let body = '';
        for await (const c of req) body += c;
        seen.push({ path: req.url, auth: req.headers.authorization, body: JSON.parse(body || '{}') });
        res.writeHead(200, { 'content-type': 'application/json' });
        const sid = JSON.parse(body || '{}').session_id;
        if (req.url === '/api/state') return res.end(JSON.stringify({ id: 'x', status: status.value, reason: status.reason ?? null }));
        if (req.url === '/api/links' && status.links && sid) return res.end(JSON.stringify({ id: 'x', url: `http://localhost:6090/live/${sid}-link`, status: 'watching' }));
        res.end(JSON.stringify({ error: 'nope' }));
    });
    await new Promise((r) => srv.listen(0, '127.0.0.1', r));
    return { srv, seen, url: `http://127.0.0.1:${srv.address().port}` };
}

test('while the user has control, execute_action is refused and observe still passes', async () => {
    const status = { value: 'user' };
    const b = await mockBridge(status);
    try {
        const out = [];
        const upstream = createUpstreamMcp({ url, getToken: () => TOKEN, timeoutMs: 2000 });
        const mcp = createMcpServer({ bridgeUrl: b.url, bridgeToken: 'bt', write: (m) => out.push(m), upstream, retryMs: 0 });
        const call = async (id, name, args) => { await mcp.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } }); return out.find((m) => m.id === id); };
        const act = { session_id: 's1', action: { action: 'click', label: 'Sign in', reason: 'r' } };
        const blocked = await call(1, 'browser_execute_action', act);
        assert.equal(blocked.result.isError, true);
        assert.equal(blocked.result.content[0].text, USER_HAS_CONTROL);
        assert.equal(mock.requests.filter((x) => x.method === 'tools/call' && x.params?.name !== 'browser.get_session').length, 0, 'never reached auto-browser');
        assert.deepEqual(b.seen[0], { path: '/api/state', auth: 'Bearer bt', body: { session_id: 's1', action: { kind: 'click', target: 'Sign in' } } });

        const seen = await call(2, 'browser_observe', { session_id: 's1' });
        assert.equal(seen.result.content[0].text, 'observed s1');
        assert.deepEqual(b.seen.slice(1).map((x) => [x.path, x.body]), [['/api/state', { session_id: 's1' }], ['/api/links', { session_id: 's1' }]],
            'observe is only asked about an ended session, with no action recorded, then linked');

        status.value = 'takeover';
        assert.equal((await call(3, 'browser_execute_action', act)).result.isError, true, 'refused while the agent waits for the user too');

        status.value = 'watching';
        const ok = await call(4, 'browser_execute_action', act);
        assert.equal(ok.result.content[0].text, 'acted click');
        status.value = null;
        assert.equal((await call(5, 'browser_execute_action', { action: { action: 'scroll', reason: 'r' } })).result.content[0].text, 'acted scroll');
        assert.deepEqual(b.seen.at(-1).body, { action: { kind: 'scroll' } }, 'no session id: the bridge checks for any held link');
    } finally {
        b.srv.close();
    }
});

test('a bridge that cannot answer does not block browsing', async () => {
    const { req, call, logs } = harness(); // bridgeUrl is a closed port
    await req(1, 'tools/list', {});
    const r = await call(2, 'browser_execute_action', { session_id: 's1', action: { action: 'reload', reason: 'r' } });
    assert.equal(r.result.content[0].text, 'acted reload');
    assert.ok(logs.some((l) => /control check failed/.test(l)));
});

test('actionOf: kinds and short targets, never typed text', () => {
    assert.deepEqual(actionOf('browser_execute_action', { action: { action: 'type', text: 'hunter2', element_id: 'e1' } }), { kind: 'type' });
    assert.deepEqual(actionOf('browser_execute_action', { action: { action: 'navigate', url: 'https://example.com/a?b=c' } }), { kind: 'navigate', target: 'example.com' });
    assert.deepEqual(actionOf('browser_execute_action', { action: { action: 'click', label: 'x'.repeat(200) } }).target.length, 120);
    assert.deepEqual(actionOf('browser_execute_action', { action: { action: 'press', key: 'Enter' } }), { kind: 'press', target: 'Enter' });
    assert.deepEqual(actionOf('browser_eval_js', { script: 'secret()' }), { kind: 'eval_js' });
    assert.equal(actionOf('browser_wait_for_selector', {}), null);
    assert.equal(actionOf('browser_execute_action', {}), null);
});

test('results about a session carry its live link: from the argument, or the session a result names', async () => {
    const status = { value: 'watching', links: true };
    const b = await mockBridge(status);
    try {
        const out = [];
        const upstream = createUpstreamMcp({ url, getToken: () => TOKEN, timeoutMs: 2000 });
        const mcp = createMcpServer({ bridgeUrl: b.url, bridgeToken: 'bt', write: (m) => out.push(m), upstream, retryMs: 0 });
        const call = async (id, name, args) => { await mcp.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } }); return out.find((m) => m.id === id); };
        const seen = await call(1, 'browser_observe', { session_id: 's1' });
        assert.match(seen.result.content[0].text, /http:\/\/localhost:6090\/live\/s1-link/, 'the link comes first');
        assert.match(seen.result.content[0].text, /post it on its own line/);
        assert.equal(seen.result.content[1].text, 'observed s1', 'then auto-browser\'s own result, unchanged');
        const listed = await call(2, 'browser_list_sessions', {});
        assert.equal(listed.result.content.length, 1, 'a list names no one session');
        assert.equal(b.seen.filter((x) => x.path === '/api/links').length, 1);
    } finally {
        b.srv.close();
    }
});

test('sessionOf: argument, created session, observe or action result', () => {
    assert.equal(sessionOf({ session_id: 'a1' }, null), 'a1');
    assert.equal(sessionOf({}, { content: [{ type: 'text', text: '{"id": "6a80ac99d644", "status": "active"}' }] }), '6a80ac99d644');
    assert.equal(sessionOf({}, { content: [{ type: 'text', text: '{"action": "navigate", "session": {"id": "b2"}}' }] }), 'b2');
    assert.equal(sessionOf({}, { structuredContent: { session_id: 'c3' } }), 'c3');
    assert.equal(sessionOf({}, { structuredContent: { result: { id: 'd4' } } }), 'd4');
    assert.equal(sessionOf({}, { content: [{ type: 'text', text: 'observed' }] }), null);
    assert.equal(sessionOf({}, { content: [{ type: 'text', text: '[{"id":"s1"}]' }] }), null, 'a list is not one session');
    assert.equal(sessionOf({ session_id: '../x' }, null), null);
});

test('a session the user ended gets USER_ENDED for any tool, and auto-browser is never asked', async () => {
    const status = { value: 'done', reason: 'user_ended' };
    const b = await mockBridge(status);
    try {
        const out = [];
        const upstream = createUpstreamMcp({ url, getToken: () => TOKEN, timeoutMs: 2000 });
        const mcp = createMcpServer({ bridgeUrl: b.url, bridgeToken: 'bt', write: (m) => out.push(m), upstream, retryMs: 0 });
        const call = async (id, name, args) => { await mcp.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } }); return out.find((m) => m.id === id); };
        for (const [i, name, args] of [[1, 'browser_observe', { session_id: 's1' }], [2, 'browser_execute_action', { session_id: 's1', action: { action: 'reload', reason: 'r' } }]]) {
            const r = await call(i, name, args);
            assert.equal(r.result.isError, true);
            assert.equal(r.result.content[0].text, USER_ENDED);
        }
        assert.equal(USER_ENDED, 'The user ended this browser. Start a new one only if the task still needs it.');
        assert.equal(mock.requests.filter((x) => x.method === 'tools/call' && x.params?.name !== 'browser.get_session').length, 0);
        status.value = 'done'; status.reason = 'session_closed';
        assert.equal((await call(3, 'browser_observe', { session_id: 's1' })).result.content[0].text, 'observed s1', 'only the user ending it is refused');
    } finally {
        b.srv.close();
    }
});

test('browser_screenshot and browser_observe say the image has a date/time bar of B px above page coordinates', () => {
    const tools = [...UPSTREAM_TOOLS, { name: 'browser.screenshot', description: 'Take a screenshot.' }];
    const sentence = (b) => `Every screenshot image has a ${b} px date/time bar across its top; coordinates in results (bbox, x/y) are page coordinates: page y = image y \u2212 ${b}.`;
    for (const [width, b] of [[1920, 67], [1280, 45], [400, 24]]) {
        assert.equal(evidenceBarPx(width), b);
        const m = mapUpstreamTools(tools, () => {}, { frameWidth: width });
        const by = Object.fromEntries(m.tools.map((t) => [t.name, t.description]));
        assert.ok(by.browser_screenshot.includes(sentence(b)), by.browser_screenshot);
        assert.ok(by.browser_observe.includes(sentence(b)), by.browser_observe);
        assert.ok(!by.browser_execute_action.includes('date/time bar'));
    }
    // Without a width: BRIDGE_FRAME_WIDTH, else 1920.
    const saved = process.env.BRIDGE_FRAME_WIDTH;
    try {
        delete process.env.BRIDGE_FRAME_WIDTH;
        assert.ok(mapUpstreamTools(tools).tools.find((t) => t.name === 'browser_observe').description.includes(sentence(67)));
        process.env.BRIDGE_FRAME_WIDTH = '1280';
        assert.ok(mapUpstreamTools(tools).tools.find((t) => t.name === 'browser_observe').description.includes(sentence(45)));
    } finally {
        if (saved === undefined) delete process.env.BRIDGE_FRAME_WIDTH; else process.env.BRIDGE_FRAME_WIDTH = saved;
    }
});
