// Plugins: self-hosted voice (src/plugins/voice) against the TS server's
// voiceRoutes.ts and api/voiceStream.ts. The same scenario runs under each
// configuration; the env file decides what the servers offer:
//   plugins-voice        LiveKit only, its server unreachable
//   plugins-voice-both   LiveKit (unreachable) and ElevenLabs (the mock)
//   plugins-voice-bare   nothing configured
// The stream cases here end before a room is joined; plugins-voice-live joins
// a real LiveKit room.
import { createRequire } from 'node:module';
import net from 'node:net';
import { login } from './phase2.mjs';
import { startMock } from './mock.mjs';
const require = createRequire(import.meta.url);
const WebSocket = require('../../../node_modules/ws');

const STREAM = '/v1/voice/stream';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Claims of a JWT, keys sorted, times as offsets from `nbf`. */
export function claims(token) {
    if (typeof token !== 'string') return token;
    const [h, p] = token.split('.');
    const dec = (s) => JSON.parse(Buffer.from(s, 'base64url').toString());
    const sort = (v) => (Array.isArray(v) ? v.map(sort) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sort(v[k])])) : v);
    const payload = dec(p);
    const base = payload.nbf ?? payload.iat ?? 0;
    for (const k of ['exp', 'nbf', 'iat']) if (typeof payload[k] === 'number') payload[k] = `nbf${payload[k] - base >= 0 ? '+' : ''}${payload[k] - base}`;
    return { header: sort(dec(h)), payload: sort(payload) };
}

/**
 * One voice stream connection: runs `script(ws)` once it is open, then records
 * every message (text parsed, binary as its length) and how it closed.
 */
export async function stream(t, name, script, { wait = 3000, headers } = {}) {
    const ws = new WebSocket(t.base.replace(/^http/, 'ws') + STREAM, { headers, perMessageDeflate: false });
    const got = [];
    let closed = null;
    let failed = null;
    ws.on('message', (data, isBinary) => {
        if (isBinary) got.push({ binary: data.length });
        else {
            try { got.push(JSON.parse(data.toString())); } catch { got.push({ text: data.toString() }); }
        }
    });
    const done = new Promise((res) => {
        ws.on('close', (code, reason) => { closed = { code, reason: reason.toString() }; res(); });
        ws.on('error', (e) => { failed = e.message; });
        ws.on('unexpected-response', (_req, res2) => { failed = `HTTP ${res2.statusCode}`; res(); });
    });
    const opened = await Promise.race([new Promise((res) => ws.once('open', () => res(true))), done.then(() => false)]);
    if (opened) {
        await script(ws);
        await Promise.race([done, sleep(wait)]);
    }
    if (!closed && ws.readyState === WebSocket.OPEN) ws.close();
    t.note(`stream ${name}`, { opened, got, closed, failed });
    return { got, closed };
}

/** A hand-written upgrade request on a raw socket; records the status line and close. */
async function rawUpgrade(t, name, request) {
    const url = new URL(t.base);
    const out = await new Promise((resolve) => {
        const sock = net.connect(Number(url.port), url.hostname, () => sock.write(request));
        const chunks = [];
        sock.on('data', (c) => chunks.push(c));
        const end = () => resolve(Buffer.concat(chunks).toString('utf8'));
        sock.on('end', end);
        sock.on('error', end);
        setTimeout(() => { sock.destroy(); end(); }, 2500);
    });
    const [head, ...body] = out.split('\r\n\r\n');
    const lines = head.split('\r\n');
    const keep = lines.slice(1).filter((l) => /^(upgrade|connection|sec-websocket-accept|content-type):/i.test(l)).map((l) => l.toLowerCase());
    t.note(`raw ${name}`, { status: lines[0], headers: keep.sort(), body: body.join('\r\n\r\n') });
}

const hello = (fields) => JSON.stringify({ type: 'hello', ...fields });

export async function scenario(t, { sql }) {
    const mock = await startMock(t);
    try {
        await run(t, sql, mock);
    } finally {
        await mock.close();
    }
}

async function run(t, sql, mock) {
    const token = await login(t, 1);
    const token2 = await login(t, 2, 'auth user2');
    const H = { authorization: 'Bearer ' + token };
    const H2 = { authorization: 'Bearer ' + token2 };
    const s1 = await t.req('create session', 'POST', '/v1/sessions', { headers: H, body: { tag: 'v1', metadata: 'm' } });
    const sid = s1.session.id;
    const s2 = await t.req('create session user2', 'POST', '/v1/sessions', { headers: H2, body: { tag: 'v2', metadata: 'm' } });
    const sid2 = s2.session.id;

    // ElevenLabs, when offered, through the mock.
    const pages = { '': { json: { conversations: [{ call_duration_secs: 12 }], has_more: false, next_cursor: null } } };
    mock.route('/api.elevenlabs.io/v1/convai/conversations', ({ url }) => pages[url.searchParams.get('cursor') || ''] || { status: 500, json: {} });
    const jwt = (payload) => `eyJhbGciOiJIUzI1NiJ9.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.c2ln`;
    mock.route('/api.elevenlabs.io/v1/convai/conversation/token', () => ({ json: { token: jwt({ video: { room: 'room_conv_Z9y8_x' } }) } }));

    // --- REST ---
    await t.req('config no auth', 'GET', '/v1/voice/config');
    await t.req('config', 'GET', '/v1/voice/config', { headers: H });
    await t.req('conversation no auth', 'POST', '/v1/voice/conversations', { body: {} });

    const grant = async (name, body, opts = {}) => {
        const r = await t.req(`conversation ${name}`, 'POST', '/v1/voice/conversations', { headers: opts.headers || H, ...(body === undefined ? {} : opts.raw ? { raw: body, headers: { ...(opts.headers || H), 'content-type': 'application/json' } } : { body }) });
        if (r && typeof r.token === 'string') t.note(`conversation ${name} token`, claims(r.token));
        return r;
    };
    await grant('no body', undefined);
    await grant('null body', 'null', { raw: true });
    await grant('empty', {});
    const g1 = await grant('with session', { sessionId: sid, language: 'en' });
    await grant('other user session', { sessionId: sid2 });
    await grant('unknown session', { sessionId: 'nope' });
    await grant('session number', { sessionId: 5 });
    await grant('language null', { language: null });
    await grant('extra field', { language: 'de', extra: 1 });
    await grant('array body', [], {});
    await grant('elevenlabs agent', { agentId: 'agent_1' });
    await grant('elevenlabs agent with session', { agentId: 'agent_1', sessionId: sid });
    await grant('agent empty', { agentId: '' });
    await grant('agent number', { agentId: 7 });
    t.note('conversation rows', (await sql(`SELECT "roomName" = 'happy-voice-' || "id", "sessionId" IS NOT NULL, "language", "durationSecs" FROM "VoiceConversation" ORDER BY "createdAt"`)).trim().split('\n'));

    // Usage: recorded durations (LiveKit) or ElevenLabs.
    await t.req('usage no auth', 'GET', '/v1/voice/usage');
    await t.req('usage', 'GET', '/v1/voice/usage', { headers: H });
    if (g1 && g1.conversationId) {
        await sql(`UPDATE "VoiceConversation" SET "durationSecs" = 42 WHERE "id" = '${g1.conversationId}'`);
        await sql(`INSERT INTO "VoiceConversation" ("id","accountId","roomName","durationSecs","createdAt") SELECT 'old-conv', "accountId", 'happy-voice-old', 1000, now() - interval '31 days' FROM "VoiceConversation" WHERE "id" = '${g1.conversationId}'`);
    }
    await t.req('usage with durations', 'GET', '/v1/voice/usage', { headers: H });
    await t.req('usage user2', 'GET', '/v1/voice/usage', { headers: H2 });

    // --- stream: plain HTTP and handshakes ---
    await t.req('stream plain get', 'GET', STREAM);
    await t.req('stream post', 'POST', STREAM, { body: {} });
    const up = (method, key = 'dGhlIHNhbXBsZSBub25jZQ==', extra = '') => `${method} ${STREAM} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n${key === null ? '' : `Sec-WebSocket-Key: ${key}\r\n`}${extra}\r\n`;
    await rawUpgrade(t, 'upgrade ok', up('GET'));
    await rawUpgrade(t, 'upgrade post', up('POST'));
    await rawUpgrade(t, 'upgrade no key', up('GET', null));
    await rawUpgrade(t, 'upgrade bad key', up('GET', 'short'));
    await rawUpgrade(t, 'upgrade version 8', `GET ${STREAM} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 8\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n`);
    await rawUpgrade(t, 'upgrade query', up('GET').replace(STREAM, STREAM + '?x=1'));
    await rawUpgrade(t, 'upgrade trailing slash', up('GET').replace(STREAM, STREAM + '/'));

    // --- stream: hello ---
    await stream(t, 'no hello', async () => {}, { wait: 7000 });
    await stream(t, 'first not hello', async (ws) => ws.send(JSON.stringify({ type: 'end' })));
    await stream(t, 'first not json', async (ws) => ws.send('nope'));
    await stream(t, 'first null', async (ws) => ws.send('null'));
    await stream(t, 'missing token', async (ws) => ws.send(hello({})));
    await stream(t, 'empty token', async (ws) => ws.send(hello({ token: '' })));
    await stream(t, 'number token', async (ws) => ws.send(hello({ token: 5 })));
    await stream(t, 'language number', async (ws) => ws.send(hello({ token, language: 5 })));
    await stream(t, 'session null', async (ws) => ws.send(hello({ token, sessionId: null })));
    await stream(t, 'bad token', async (ws) => ws.send(hello({ token: 'x.y.z' })));
    await stream(t, 'other user session', async (ws) => ws.send(hello({ token, sessionId: sid2 })));
    await stream(t, 'unknown session', async (ws) => ws.send(hello({ token, sessionId: 'nope' })));
    await stream(t, 'audio before hello', async (ws) => {
        ws.send(Buffer.alloc(640));
        await sleep(200);
        ws.send(hello({ token: 'x.y.z' }));
    });
    await stream(t, 'hello as binary', async (ws) => ws.send(Buffer.from(hello({ token }))), { wait: 6500 });
    await stream(t, 'start', async (ws) => ws.send(hello({ token, sessionId: sid, language: 'en' })), { wait: 8000 });
    // Two messages in one TCP write: what follows the hello is handled before
    // the hello's checks go on (`ws` emits a chunk's messages back to back).
    const together = (ws, ...messages) => {
        ws._socket.cork();
        for (const m of messages) ws.send(m);
        process.nextTick(() => ws._socket.uncork());
    };
    await stream(t, 'start then end', async (ws) => together(ws, hello({ token }), JSON.stringify({ type: 'end' })), { wait: 8000 });
    await stream(t, 'start then hello', async (ws) => together(ws, hello({ token }), hello({ token })), { wait: 8000 });
    await stream(t, 'too large', async (ws) => ws.send('x'.repeat(1024 * 1024 + 1)));
    await stream(t, 'largest', async (ws) => ws.send(JSON.stringify({ type: 'hello', token: 'x.y.z', pad: 'x'.repeat(1024 * 1024 - 60) })));
    await stream(t, 'client closes', async (ws) => ws.close(4000, 'bye'));
    t.note('stream conversation rows', (await sql(`SELECT "sessionId" IS NOT NULL, "language", "durationSecs" FROM "VoiceConversation" WHERE "id" <> 'old-conv' ORDER BY "createdAt"`)).trim().split('\n'));
}

export function normalize(s) {
    return s;
}
