#!/usr/bin/env node
// A harness's stdio MCP server that is really the browser stack on prep-ml, reached through the
// LAN gateway (agentgateway, streamable HTTP). Node 18+, no dependencies.
//
//   node mcp-gateway-client.mjs --url http://192.168.2.72:8904/browser/mcp
//        [--key-file ~/.config/browser-stack/gateway-key] [--agent-db <agent.sqlite>]
//        [--agent-python /usr/bin/python3]
//
// It reads JSON-RPC lines on stdin, POSTs each one to the gateway, and writes every message that
// comes back (a JSON body, or each event of an SSE stream: results, progress, logging) to stdout.
//
// The chat: every tools/call goes out with _meta["browserstack/chat"] = {source, id, forked_from?}
// (identity/chatmeta.mjs), from this process's own environment (identity/env.mjs:
// HAPPY_SESSION_ID, CLAUDE_CODE_SESSION_ID, BROWSER_CHAT_ID). With --agent-db (Happy Agent, one
// process for many chats) each call's chat is looked up in this Mac's agent database instead
// (identity/agentchat.mjs, read-only); a call it can't place goes out without a chat and the
// server refuses it. A harness with none of these gets one chat for this process's lifetime.
// Whatever the harness put under that _meta key is replaced, so the model can't pick a chat.
//
// The gateway key (Authorization: Bearer) is read from the key file, which must be mode 600;
// it is never logged. Logs go to stderr.
import http from 'node:http';
import https from 'node:https';
import { randomUUID } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';
import { CHAT_META_KEY } from '../identity/chatmeta.mjs';
import { chatOfEnv } from '../identity/env.mjs';

const log = (s) => process.stderr.write(`[browser-stack client] ${s}\n`);
const expand = (p) => (p && p.startsWith('~/') ? homedir() + p.slice(1) : p);

export function parseArgs(argv, env = process.env) {
    const o = {
        url: env.BROWSER_STACK_GATEWAY_URL || null,
        keyFile: env.BROWSER_STACK_GATEWAY_KEY_FILE || '~/.config/browser-stack/gateway-key',
        agentDb: env.BROWSER_STACK_AGENT_DB || null,
        agentPython: env.BROWSER_STACK_AGENT_PYTHON || '/usr/bin/python3',
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        const v = () => { if (i + 1 >= argv.length) throw new Error(`${a} needs a value`); return argv[++i]; };
        if (a === '--url') o.url = v();
        else if (a === '--key-file') o.keyFile = v();
        else if (a === '--agent-db') o.agentDb = v();
        else if (a === '--agent-python') o.agentPython = v();
        else throw new Error(`unknown argument ${a}`);
    }
    if (!o.url) throw new Error('--url is required');
    const u = new URL(o.url);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new Error('--url must be http or https');
    o.keyFile = expand(o.keyFile);
    o.agentDb = expand(o.agentDb);
    return o;
}

/** The gateway key: a mode-600 file holding one token. */
export function readKey(path) {
    const st = statSync(path);
    if (st.mode & 0o077) throw new Error(`${path} is readable by others; chmod 600 it`);
    const k = readFileSync(path, 'utf8').trim();
    if (!/^[A-Za-z0-9._~+/=-]{16,512}$/.test(k)) throw new Error(`${path} does not hold a key`);
    return k;
}

/**
 * The chat stamper: (message) -> message with our _meta key set (tools/call) or removed (anything
 * else). chatOf(message, signal) resolves {source, id, forked_from?} or null.
 */
export function stampWith(chatOf) {
    return async function stamp(m, signal) {
        if (!m || typeof m !== 'object' || typeof m.method !== 'string') return m;
        const params = m.params && typeof m.params === 'object' ? m.params : undefined;
        const meta = params?._meta && typeof params._meta === 'object' ? { ...params._meta } : {};
        delete meta[CHAT_META_KEY];
        if (m.method === 'tools/call') {
            const chat = await chatOf(m, signal).catch((err) => { log(`chat of a call: ${err.message}`); return null; });
            if (chat) meta[CHAT_META_KEY] = chat;
        }
        if (!params) return Object.keys(meta).length ? { ...m, params: { _meta: meta } } : m;
        const out = { ...params };
        if (Object.keys(meta).length) out._meta = meta; else delete out._meta;
        return { ...m, params: out };
    };
}

/** The chat resolver for this process: env, Happy Agent lookup, or one chat for this process. */
export async function chatResolver(o, env = process.env) {
    if (o.agentDb) {
        const { createAgentChatLookup } = await import('../identity/agentchat.mjs');
        const lookup = createAgentChatLookup({ dbPath: o.agentDb, python: o.agentPython });
        return async (m, signal) => {
            const callId = m.params?._meta?.['claudecode/toolUseId'];
            const c = callId !== undefined
                ? await lookup(callId, signal)
                : await lookup.match(m.params?.name, m.params?.arguments ?? {}, signal);
            if (!c || c.ambiguous || typeof c.source !== 'string' || typeof c.id !== 'string') return null;
            return { source: c.source, id: c.id };
        };
    }
    const fixed = chatOfEnv(env) ?? { source: 'chat', id: `proc-${randomUUID()}` };
    return async () => fixed;
}

/** Split an SSE byte stream into events; onData(dataString) for each one with data. */
export function sseParser(onData) {
    let buf = '';
    let data = [];
    return (chunk) => {
        buf += chunk;
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
            let line = buf.slice(0, nl);
            buf = buf.slice(nl + 1);
            if (line.endsWith('\r')) line = line.slice(0, -1);
            if (line === '') {
                if (data.length) onData(data.join('\n'));
                data = [];
            } else if (line.startsWith('data:')) {
                data.push(line.slice(5).replace(/^ /, ''));
            }
            // event:, id:, retry: and comments (keep-alives) carry nothing we need.
        }
    };
}

export function createClient({ url, key, stamp, write, httpImpl = null }) {
    const u = new URL(url);
    const mod = httpImpl ?? (u.protocol === 'https:' ? https : http);
    const agent = new mod.Agent({ keepAlive: true });
    let sessionId = null;
    let protocolVersion = null;
    let initMsg = null; // the harness's initialize, replayed when the gateway forgets the session
    let initialized = false;
    let reinit = null;
    let getStream = null;
    let closed = false;
    const inflight = new Map(); // request id -> AbortController

    const headers = (extra = {}) => ({
        Accept: 'application/json, text/event-stream',
        Authorization: `Bearer ${key}`,
        ...(sessionId ? { 'Mcp-Session-Id': sessionId } : {}),
        ...(protocolVersion ? { 'MCP-Protocol-Version': protocolVersion } : {}),
        ...extra,
    });

    // One HTTP exchange. onMessage(obj) for each JSON-RPC message in the reply.
    function request(method, body, onMessage, signal) {
        return new Promise((resolve, reject) => {
            const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
            const req = mod.request(u, {
                method, agent, signal,
                headers: headers(payload ? { 'Content-Type': 'application/json', 'Content-Length': payload.length } : {}),
            }, (res) => {
                const sid = res.headers['mcp-session-id'];
                if (typeof sid === 'string' && sid) sessionId = sid;
                const type = String(res.headers['content-type'] || '');
                res.setEncoding('utf8');
                const each = (s) => {
                    let m;
                    try { m = JSON.parse(s); } catch { return log('a reply that is not JSON'); }
                    for (const x of Array.isArray(m) ? m : [m]) onMessage(x);
                };
                if (res.statusCode >= 200 && res.statusCode < 300 && type.startsWith('text/event-stream')) {
                    const feed = sseParser(each);
                    res.on('data', feed);
                } else {
                    let text = '';
                    res.on('data', (c) => { if (text.length < 1 << 20) text += c; });
                    res.on('end', () => { if (res.statusCode >= 200 && res.statusCode < 300 && text.trim() && type.includes('json')) each(text); });
                }
                res.on('end', () => resolve(res.statusCode));
                res.on('error', reject);
            });
            req.on('error', reject);
            // No timeout of our own: browser_wait_for_human holds a call for minutes; the harness
            // has its own tool limit and cancels.
            req.setTimeout(0);
            req.end(payload);
        });
    }

    function deliver(m) {
        if (m && typeof m === 'object' && 'id' in m && !('method' in m)) {
            if (typeof m.id === 'string' && m.id.startsWith('browser-stack-reinit-')) return;
            inflight.delete(m.id);
        }
        if (m?.result?.protocolVersion && typeof m.result.protocolVersion === 'string' && initMsg && m.id === initMsg.id) protocolVersion = m.result.protocolVersion;
        write(m);
    }

    // The gateway restarted or dropped the session: start a new one the way the harness did.
    async function reinitialize() {
        if (reinit) return reinit;
        reinit = (async () => {
            sessionId = null;
            const id = `browser-stack-reinit-${randomUUID()}`;
            let ok = false;
            const status = await request('POST', { ...initMsg, id }, (m) => {
                if (m.id === id && m.result) { ok = true; if (typeof m.result.protocolVersion === 'string') protocolVersion = m.result.protocolVersion; }
            });
            if (status !== 200 || !ok) throw new Error(`could not start a new gateway session (HTTP ${status})`);
            await request('POST', { jsonrpc: '2.0', method: 'notifications/initialized' }, deliver);
            log('gateway session restarted');
        })().finally(() => { reinit = null; });
        return reinit;
    }

    function fail(m, message) {
        if (m && typeof m === 'object' && m.method && m.id !== undefined) {
            inflight.delete(m.id);
            write({ jsonrpc: '2.0', id: m.id, error: { code: -32000, message } });
        }
    }

    // Server-to-client messages outside any call (optional in the protocol; 405 means none).
    async function openGetStream() {
        if (getStream || closed) return;
        getStream = new AbortController();
        let backoff = 1000;
        while (!closed) {
            try {
                const status = await request('GET', undefined, deliver, getStream.signal);
                if (status === 405 || status === 404 || status === 401 || status === 403) break;
                backoff = 1000;
            } catch (err) {
                if (closed || err.name === 'AbortError') break;
            }
            await new Promise((r) => setTimeout(r, backoff));
            backoff = Math.min(backoff * 2, 30000);
        }
    }

    async function send(raw) {
        const m = await stamp(raw);
        if (m.method === 'initialize') initMsg = m;
        const isRequest = m.method !== undefined && m.id !== undefined;
        const ac = new AbortController();
        if (isRequest) inflight.set(m.id, ac);
        const post = () => request('POST', m, deliver, ac.signal);
        try {
            let status = await post();
            if (status === 404 && sessionId !== null && initMsg && m.method !== 'initialize') {
                await reinitialize();
                status = await post();
            }
            if (m.method === 'notifications/initialized' && status < 300) { initialized = true; openGetStream(); }
            if (status >= 300 && isRequest && inflight.has(m.id)) {
                fail(m, status === 401 || status === 403
                    ? `the browser stack gateway refused this Mac (HTTP ${status}); check its key`
                    : `the browser stack gateway answered HTTP ${status}`);
            } else if (isRequest && inflight.has(m.id) && m.method !== undefined) {
                // The exchange ended without an answer to this call.
                fail(m, 'the browser stack gateway closed the call without an answer; try it again');
            }
        } catch (err) {
            if (ac.signal.aborted) return;
            fail(m, `the browser stack gateway is unreachable (${err.code ?? err.message}); try it again`);
        }
    }

    function onLine(line) {
        if (!line.trim()) return;
        let m;
        try { m = JSON.parse(line); } catch { return log('a line on stdin that is not JSON'); }
        for (const x of Array.isArray(m) ? m : [m]) {
            // The harness gave up on a call: tell the server, and stop waiting for it here.
            if (x?.method === 'notifications/cancelled') {
                const ac = inflight.get(x.params?.requestId);
                send(x).finally(() => { if (ac) { inflight.delete(x.params.requestId); ac.abort(); } });
                continue;
            }
            send(x);
        }
    }

    async function close() {
        closed = true;
        getStream?.abort();
        for (const ac of inflight.values()) ac.abort();
        if (sessionId) {
            await new Promise((resolve) => {
                const req = mod.request(u, { method: 'DELETE', agent, headers: headers(), timeout: 2000 }, (res) => { res.resume(); res.on('end', resolve); });
                req.on('error', resolve);
                req.on('timeout', () => { req.destroy(); resolve(); });
                req.end();
            });
        }
        agent.destroy();
    }

    return { onLine, close, get sessionId() { return sessionId; }, get initialized() { return initialized; } };
}

async function main() {
    let o;
    let key;
    try {
        o = parseArgs(process.argv.slice(2));
        key = readKey(o.keyFile);
    } catch (err) {
        log(err.message);
        process.exit(2);
    }
    const stamp = stampWith(await chatResolver(o));
    const client = createClient({ url: o.url, key, stamp, write: (m) => process.stdout.write(JSON.stringify(m) + '\n') });
    const rl = createInterface({ input: process.stdin });
    rl.on('line', client.onLine);
    let ending = false;
    const end = async () => {
        if (ending) return;
        ending = true;
        await client.close();
        process.exit(0);
    };
    rl.on('close', end);
    process.on('SIGTERM', end);
    process.on('SIGINT', end);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main();
