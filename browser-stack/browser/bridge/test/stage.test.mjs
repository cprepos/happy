// browser_stage_upload end to end in pieces: the file reading (lib/stage.mjs), the MCP tool
// (mcp.mjs, the bridge faked), the bridge route /api/pod/upload (lib/app.mjs, the pod manager
// faked) and the pod client's raw POST (lib/pods.mjs, the controller faked). Also
// browser_list_downloads' host_path.
import { test, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, truncateSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBridge, UPLOAD_MAX_BODY } from '../lib/app.mjs';
import { LinkStore } from '../lib/store.mjs';
import { createPodClient } from '../lib/pods.mjs';
import { createMcpServer, FILE_INSTRUCTIONS } from '../mcp.mjs';
import { CHAT_META_KEY } from '../../../identity/chatmeta.mjs';
import { readStageFiles, uploadName, StageRefused, FILE_MAX } from '../lib/stage.mjs';

const TOKEN = 'bridge-secret-token-0123456789abcdef';
const KEY_A = 'a'.repeat(32);
const KEY_B = 'b'.repeat(32);
const sha = (b) => createHash('sha256').update(b).digest('hex');

// A chat's working directory and an unrelated directory outside both roots.
function dirs() {
    const top = mkdtempSync(join(tmpdir(), 'stage-'));
    const cwd = join(top, 'project');
    const scratch = join(top, 'scratch');
    const outside = mkdtempSync(join(tmpdir(), 'stage-outside-'));
    for (const d of [cwd, scratch]) mkdirSync(d);
    return { top, cwd, scratch, outside };
}

// ── lib/stage.mjs ──────────────────────────────────────────────────────────
test('stage files: inside the roots only, nothing hidden or secret, no symlinks, sizes capped', () => {
    const d = dirs();
    const roots = [d.cwd, d.scratch];
    writeFileSync(join(d.cwd, 'lease.pdf'), 'pdf-bytes');
    writeFileSync(join(d.scratch, 'photo one.jpg'), 'jpg');
    const ok = readStageFiles(['lease.pdf', join(d.scratch, 'photo one.jpg')], { roots, cwd: d.cwd });
    assert.deepEqual(ok.map((f) => [f.name, f.size, f.sha256]), [['lease.pdf', 9, sha('pdf-bytes')], ['photo_one.jpg', 3, sha('jpg')]]);
    assert.equal(ok[0].data.toString(), 'pdf-bytes');

    const refused = (paths, opts = {}) => assert.throws(() => readStageFiles(paths, { roots, cwd: d.cwd, ...opts }), StageRefused);
    writeFileSync(join(d.outside, 'x.txt'), 'x');
    refused([join(d.outside, 'x.txt')]);
    refused(['../x.txt']);
    refused([d.cwd]);
    mkdirSync(join(d.cwd, '.ssh'));
    writeFileSync(join(d.cwd, '.ssh', 'id'), 'k');
    refused(['.ssh/id']);
    writeFileSync(join(d.cwd, '.env'), 'K=v');
    refused(['.env']);
    for (const s of ['secrets', 'Credentials']) {
        mkdirSync(join(d.cwd, s));
        writeFileSync(join(d.cwd, s, 'a.txt'), 'a');
        refused([`${s}/a.txt`]);
    }
    symlinkSync(join(d.cwd, 'lease.pdf'), join(d.cwd, 'link.pdf'));
    refused(['link.pdf']);
    // A symlinked directory leading out of the roots is judged by where it really goes.
    symlinkSync(d.outside, join(d.cwd, 'out'));
    refused(['out/x.txt']);
    refused(['missing.pdf']);
    refused([]);
    refused(Array.from({ length: 11 }, () => 'lease.pdf'));
    writeFileSync(join(d.cwd, 'big.bin'), '');
    truncateSync(join(d.cwd, 'big.bin'), FILE_MAX + 1);
    refused(['big.bin']);
    refused(['lease.pdf', 'lease.pdf'], { callMax: 17 });
    assert.equal(readStageFiles(['lease.pdf', 'lease.pdf'], { roots, cwd: d.cwd, callMax: 18 }).length, 2);
});

test('stage files: names made into ones the controller takes', () => {
    assert.equal(uploadName('/x/Report (final).PDF'), 'Report__final_.PDF');
    assert.equal(uploadName('/x/' + 'n'.repeat(200) + '.pdf').length, 128);
    assert.ok(uploadName('/x/' + 'n'.repeat(200) + '.pdf').endsWith('.pdf'));
    assert.equal(uploadName('/x/ü'), '_');
});

// ── the MCP tool ───────────────────────────────────────────────────────────
// The bridge faked: /api/pod gives each chat its pod, /api/pod/upload records what was sent.
function mcpHarness({ chat = { key: KEY_A, source: 'happy' }, podsOn = true, linkStatus = 'watching', linkReason = null, fromMeta = false, roots, listReply = null } = {}) {
    const seen = { bridge: [], uploads: [], calls: [] };
    const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
    const fetchImpl = async (url, init) => {
        const u = new URL(url);
        if (u.pathname === '/api/pod/upload') {
            const q = Object.fromEntries(u.searchParams);
            const data = Buffer.from(init.body);
            seen.uploads.push({ ...q, data: data.toString(), type: init.headers['Content-Type'] });
            if (!podsOn) return json(409, { error: 'pods_disabled' });
            return json(200, { file_path: `/data/uploads/sess-${q.chat_key.slice(0, 1)}/${q.name}`, name: q.name, size: data.length, sha256: q.sha256, session_id: `sess-${q.chat_key.slice(0, 1)}`, slot: 3 });
        }
        const body = JSON.parse(init.body || '{}');
        seen.bridge.push({ path: u.pathname, body });
        if (!podsOn && (u.pathname.startsWith('/api/pod') || u.pathname === '/api/tools')) return json(409, { error: 'pods_disabled' });
        if (u.pathname === '/api/tools') return json(200, { tools: [{ name: 'browser.list_downloads', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } }] });
        if (u.pathname === '/api/pod') {
            const k = body.chat_key;
            return json(200, { chat_key: k, session_id: `sess-${k.slice(0, 1)}`, slot: 3, mcp_url: 'http://127.0.0.1:8103/mcp', api_url: 'http://127.0.0.1:8103', link_id: 'L3' });
        }
        if (u.pathname === '/api/state') return json(200, { status: linkStatus, reason: linkReason });
        if (u.pathname === '/api/links') return json(200, { id: 'L3', url: 'http://localhost/live/L3', status: 'watching' });
        return json(404, { error: 'not_found' });
    };
    const makeUpstream = () => ({
        listTools: async () => [],
        async callTool(name, args) {
            seen.calls.push({ name, args });
            const r = listReply ?? { downloads: [{ id: 'd1', filename: 'a.pdf', path: '/data/artifacts/sess-a/downloads/a.pdf' }, { id: 'd2', path: '/data/artifacts/sess-b/downloads/b.pdf' }] };
            return { result: { content: [{ type: 'text', text: JSON.stringify(r) }], structuredContent: r, isError: false } };
        },
    });
    const shared = { listTools: async () => [{ name: 'browser.list_downloads', inputSchema: { type: 'object', properties: { session_id: { type: 'string' } } } }], callTool: async () => ({ result: { content: [] } }) };
    const out = [];
    const server = createMcpServer({
        bridgeUrl: 'http://127.0.0.1:1', bridgeToken: TOKEN, write: (m) => out.push(m), fetchImpl, upstream: shared, retryMs: 0,
        chatPods: { chat, makeUpstream }, chatFromMeta: fromMeta, stageRoots: () => roots, podsHome: '/home/u/.local/share/happy-browser',
    });
    let id = 0;
    const call = async (name, args, meta) => {
        const rid = ++id;
        await server.handle({ jsonrpc: '2.0', id: rid, method: 'tools/call', params: { name, arguments: args, ...(meta ? { _meta: meta } : {}) } });
        return out.find((m) => m.id === rid);
    };
    const init = async () => { await server.handle({ jsonrpc: '2.0', id: 'i', method: 'initialize', params: {} }); return out.find((m) => m.id === 'i').result.instructions; };
    return { server, seen, call, init };
}
const errText = (r) => { assert.equal(r.result.isError, true, JSON.stringify(r)); return r.result.content[0].text; };

test('stage_upload: a good file goes, with its sha256, to the caller\'s own pod only; host_path from the slot', async () => {
    const d = dirs();
    writeFileSync(join(d.cwd, 'lease.pdf'), 'pdf-bytes');
    const h = mcpHarness({ roots: [d.cwd, d.scratch] });
    // A session_id argument is refused, not followed.
    assert.match(errText(await h.call('browser_stage_upload', { paths: [join(d.cwd, 'lease.pdf')], reason: 'lease', session_id: 'sess-b' })), /only paths and reason/);
    assert.equal(h.seen.uploads.length, 0);
    const r = await h.call('browser_stage_upload', { paths: [join(d.cwd, 'lease.pdf')], reason: 'the lease for the portal' });
    assert.equal(r.result.isError, false, JSON.stringify(r));
    const o = r.result.structuredContent;
    assert.equal(o.session_id, 'sess-a');
    assert.deepEqual(o.files.map((f) => [f.file_path, f.host_path, f.size, f.sha256]), [[
        '/data/uploads/sess-a/lease.pdf', '/home/u/.local/share/happy-browser/data/pods/slot-3/uploads/sess-a/lease.pdf', 9, sha('pdf-bytes'),
    ]]);
    assert.deepEqual(h.seen.uploads, [{ chat_key: KEY_A, name: 'lease.pdf', sha256: sha('pdf-bytes'), data: 'pdf-bytes', type: 'application/octet-stream' }]);
    // The pod is the chat's, asked for by its key.
    assert.ok(h.seen.bridge.filter((b) => b.path === '/api/pod').every((b) => b.body.chat_key === KEY_A && !b.body.session_id));
});

test('stage_upload: each refusal sends nothing', async () => {
    const d = dirs();
    const roots = [d.cwd, d.scratch];
    writeFileSync(join(d.cwd, 'ok.txt'), 'ok');
    writeFileSync(join(d.outside, 'x.txt'), 'x');
    mkdirSync(join(d.cwd, '.git'));
    writeFileSync(join(d.cwd, '.git', 'config'), 'c');
    symlinkSync(join(d.cwd, 'ok.txt'), join(d.cwd, 'link.txt'));
    writeFileSync(join(d.cwd, 'big.bin'), '');
    truncateSync(join(d.cwd, 'big.bin'), FILE_MAX + 1);
    const good = join(d.cwd, 'ok.txt');
    const cases = [
        [{}, { paths: [good] }, /give a reason/],
        [{}, { paths: [good], reason: '   ' }, /give a reason/],
        [{}, { paths: [join(d.outside, 'x.txt')], reason: 'r' }, /outside this chat's working directory/],
        [{}, { paths: [join(d.cwd, '.git', 'config')], reason: 'r' }, /hidden/],
        [{}, { paths: [join(d.cwd, 'link.txt')], reason: 'r' }, /symlink/],
        [{}, { paths: [join(d.cwd, 'big.bin')], reason: 'r' }, /at most/],
        [{}, { paths: Array.from({ length: 11 }, () => good), reason: 'r' }, /1 to 10/],
        [{}, { paths: [good, join(d.outside, 'x.txt')], reason: 'r' }, /outside/],
        [{ fromMeta: true }, { paths: [good], reason: 'r' }, /LAN gateway/],
        [{ podsOn: false }, { paths: [good], reason: 'r' }, /pods/],
        [{ linkStatus: 'done', linkReason: 'user_ended' }, { paths: [good], reason: 'r' }, /user ended this browser/],
    ];
    for (const [opts, args, want] of cases) {
        const h = mcpHarness({ roots, ...opts });
        const meta = opts.fromMeta ? { [CHAT_META_KEY]: { source: 'happy', id: 'h1' } } : undefined;
        const r = await h.call('browser_stage_upload', args, meta);
        assert.match(errText(r), want, JSON.stringify(args));
        assert.equal(h.seen.uploads.length, 0, `nothing sent for ${JSON.stringify(args)}`);
    }
    // No chat of its own and none named for the call: refused, never routed by a session.
    const h = mcpHarness({ roots, chat: null });
    assert.match(errText(await h.call('browser_stage_upload', { paths: [good], reason: 'r' })), /matched to its chat/);
    assert.equal(h.seen.uploads.length, 0);
});

test('stage_upload: in the tool list, and the instructions say how files move (not behind the gateway)', async () => {
    const h = mcpHarness({ roots: [] });
    const out = [];
    const listed = createMcpServer({ bridgeUrl: 'http://127.0.0.1:1', bridgeToken: TOKEN, write: (m) => out.push(m) });
    await listed.handle({ jsonrpc: '2.0', id: 'l', method: 'tools/list' });
    const tool = out[0].result.tools.find((t) => t.name === 'browser_stage_upload');
    assert.deepEqual(Object.keys(tool.inputSchema.properties), ['paths', 'reason']);
    assert.deepEqual(tool.inputSchema.required, ['paths', 'reason']);
    assert.equal(tool.inputSchema.additionalProperties, false);
    const instr = await h.init();
    assert.ok(instr.includes(FILE_INSTRUCTIONS));
    assert.match(FILE_INSTRUCTIONS, /browser_stage_upload/);
    assert.match(FILE_INSTRUCTIONS, /never copy files into the browser with docker/);
    assert.match(FILE_INSTRUCTIONS, /host_path/);
    assert.match(FILE_INSTRUCTIONS, /vault_save_download, never Read/);
    assert.ok(!(await mcpHarness({ roots: [], fromMeta: true }).init()).includes(FILE_INSTRUCTIONS));
});

test('list_downloads: host_path for the chat\'s own session\'s downloads only', async () => {
    const h = mcpHarness({ roots: [] });
    const r = await h.call('browser_list_downloads', {});
    assert.equal(r.result.isError, false, JSON.stringify(r));
    const sc = r.result.structuredContent;
    assert.equal(sc.downloads[0].host_path, '/home/u/.local/share/happy-browser/data/pods/slot-3/artifacts/sess-a/downloads/a.pdf');
    assert.ok(!('host_path' in sc.downloads[1]), 'another session\'s path gets none');
    assert.ok(r.result.content.some((c) => c.type === 'text' && c.text.includes('"host_path"')));
    // Anything that is not a plain file in that session's downloads gets none.
    const odd = mcpHarness({ roots: [], listReply: { downloads: [{ path: '/data/artifacts/sess-a/downloads/../x' }, { path: '/data/artifacts/sess-a/downloads/.hidden' }, { path: '/data/auth/x' }] } });
    const o = (await odd.call('browser_list_downloads', {})).result.structuredContent;
    assert.ok(o.downloads.every((x) => !('host_path' in x)));
});

// ── the bridge route ───────────────────────────────────────────────────────
let server, base, app;
afterEach(() => server && new Promise((r) => { app?.close(); server.closeAllConnections?.(); server.close(r); server = null; }));

async function startBridge({ withPods = true } = {}) {
    const dir = mkdtempSync(join(tmpdir(), 'stage-bridge-'));
    const store = new LinkStore({ path: join(dir, 'links.json'), idleMs: 3600_000 });
    const calls = [];
    const chats = new Map([[KEY_A, 'running'], [KEY_B, 'asleep']]);
    const pods = withPods ? {
        calls,
        podState: (k) => chats.get(k) ?? 'none',
        podOf: (k) => (chats.get(k) === 'running' ? { slot: 0, sessionId: `sess-${k[0]}` } : null),
        async stageUpload(k, { name, sha256, data }) {
            calls.push({ k, name, sha256, size: data.length });
            return { file_path: `/data/uploads/sess-${k[0]}/${name}`, name, size: data.length, sha256, session_id: `sess-${k[0]}`, slot: 0 };
        },
        liveness: () => ({ live: false, pod: 'none', reason: 'no_browser' }),
        status: () => ({}),
        touchViewer() {}, sessionSeen() {},
    } : null;
    app = createBridge({ client: {}, store, log: () => {}, config: { bridgeToken: TOKEN, vncPassword: 'x', novncUrl: 'http://localhost:6080/vnc.html', pods } });
    server = createServer(app.handler);
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${server.address().port}`;
    return { calls };
}
const upload = (q, body, headers = {}) => fetch(`${base}/api/pod/upload?${new URLSearchParams(q)}`, { method: 'POST', headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/octet-stream', ...headers }, body });

test('bridge /api/pod/upload: by chat_key only, its own body limit, re-hashed, unknown chat refused', async () => {
    const { calls } = await startBridge();
    const bytes = Buffer.alloc(64 * 1024, 7); // past the JSON routes' 16 KB
    const ok = await upload({ chat_key: KEY_A, name: 'a.bin', sha256: sha(bytes) }, bytes);
    assert.equal(ok.status, 200);
    assert.deepEqual(await ok.json(), { file_path: '/data/uploads/sess-a/a.bin', name: 'a.bin', size: bytes.length, sha256: sha(bytes), session_id: 'sess-a', slot: 0 });
    assert.deepEqual(calls, [{ k: KEY_A, name: 'a.bin', sha256: sha(bytes), size: bytes.length }]);
    // The JSON routes keep their 16 KB limit.
    const json = await fetch(`${base}/api/state`, { method: 'POST', headers: { Authorization: `Bearer ${TOKEN}` }, body: JSON.stringify({ x: 'y'.repeat(20000) }) }).catch(() => null);
    assert.ok(!json || json.status === 413);

    const status = async (r) => [r.status, (await r.json()).error];
    assert.equal((await upload({ chat_key: KEY_A, name: 'a.bin', sha256: sha('other') }, bytes)).status, 400, 'hash mismatch');
    assert.equal((await upload({ session_id: 'sess-a', name: 'a.bin', sha256: sha(bytes) }, bytes)).status, 400, 'a session id is no chat key');
    assert.equal((await upload({ chat_key: KEY_A, name: '.env', sha256: sha(bytes) }, bytes)).status, 400);
    assert.equal((await upload({ chat_key: KEY_A, name: 'a/b', sha256: sha(bytes) }, bytes)).status, 400);
    assert.deepEqual(await status(await upload({ chat_key: 'c'.repeat(32), name: 'a.bin', sha256: sha(bytes) }, bytes)), [404, 'this chat has no browser']);
    assert.equal((await upload({ chat_key: KEY_B, name: 'a.bin', sha256: sha(bytes) }, bytes)).status, 503, 'asleep: never woken');
    assert.equal((await fetch(`${base}/api/pod/upload?chat_key=${KEY_A}`, { method: 'POST', body: bytes })).status, 401);
    assert.equal((await fetch(`${base}/api/pod/upload?chat_key=${KEY_A}&name=a&sha256=${sha(bytes)}`, { method: 'GET', headers: { Authorization: `Bearer ${TOKEN}` } })).status, 405);
    // Past the route's own limit: 413 before the pod is asked.
    const big = Buffer.alloc(UPLOAD_MAX_BODY + 1);
    const r = await upload({ chat_key: KEY_A, name: 'big.bin', sha256: sha(big) }, big).catch((e) => e);
    assert.equal(r.status, 413, String(r?.status ?? r));
    // No declared length (chunked): stopped once past the limit while reading.
    const chunk = Buffer.alloc(1024 * 1024, 1);
    let sent = 0;
    const stream = new ReadableStream({ pull(c) { if (sent > UPLOAD_MAX_BODY) return c.close(); sent += chunk.length; c.enqueue(chunk); } });
    const s = await fetch(`${base}/api/pod/upload?${new URLSearchParams({ chat_key: KEY_A, name: 'c.bin', sha256: sha('x') })}`, { method: 'POST', headers: { Authorization: `Bearer ${TOKEN}` }, body: stream, duplex: 'half' }).catch((e) => e);
    assert.ok(s instanceof Error || s.status === 413, String(s?.status ?? s));
    assert.equal(calls.length, 1);
});

test('bridge /api/pod/upload: 409 with pods off', async () => {
    await startBridge({ withPods: false });
    assert.equal((await upload({ chat_key: KEY_A, name: 'a.bin', sha256: sha('x') }, Buffer.from('x'))).status, 409);
});

// ── the pod client ─────────────────────────────────────────────────────────
test('pod client stageUpload: raw bytes to the session\'s upload route, name and sha256 in the query', async () => {
    const seen = [];
    const client = createPodClient({
        baseUrl: 'http://pod', token: 't',
        fetchImpl: async (url, init) => { seen.push({ url, init }); return new Response(JSON.stringify({ file_path: '/data/uploads/s1/a.pdf', name: 'a.pdf', size: 3, sha256: sha('abc') }), { status: 200 }); },
    });
    const out = await client.stageUpload('s1', { name: 'a b.pdf', sha256: sha('abc'), data: Buffer.from('abc') });
    assert.equal(out.file_path, '/data/uploads/s1/a.pdf');
    assert.equal(seen[0].url, `http://pod/happy/sessions/s1/uploads?name=a%20b.pdf&sha256=${sha('abc')}`);
    assert.equal(seen[0].init.headers['Content-Type'], 'application/octet-stream');
    assert.equal(seen[0].init.headers.Authorization, 'Bearer t');
    assert.deepEqual(seen[0].init.body, Buffer.from('abc'));
});
