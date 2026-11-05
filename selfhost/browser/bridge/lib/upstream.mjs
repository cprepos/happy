// Minimal MCP client for auto-browser's Streamable HTTP endpoint (/mcp), so
// the stdio MCP server can pass auto-browser's tools through. The bearer token
// is read from its file per session and only ever goes into the Authorization
// header; no error, log line or result carries it.
//
// Tool names: auto-browser names its tools with dots (browser.observe). Model
// APIs only accept [a-zA-Z0-9_-] in tool names, so they are exposed with every
// other character mapped to "_" (browser_observe) and mapped back on call.

const CLIENT_INFO = { name: 'happy-browser-bridge', version: '1.1.0' };
const PROTOCOL = '2025-06-18';

export class UpstreamError extends Error {}

export const localToolName = (name) => String(name).replace(/[^a-zA-Z0-9_-]/g, '_');

/** Parse a text/event-stream body into the JSON-RPC messages it carries. */
export function parseSse(text) {
    const out = [];
    for (const block of text.split(/\r?\n\r?\n/)) {
        const data = block
            .split(/\r?\n/)
            .filter((l) => l.startsWith('data:'))
            .map((l) => l.slice(5).replace(/^ /, ''))
            .join('\n');
        if (!data) continue;
        try { out.push(JSON.parse(data)); } catch {}
    }
    return out;
}

export function createUpstreamMcp({ url, getToken, fetchImpl = fetch, timeoutMs = 120_000, onNotification = () => {} }) {
    let sessionId = null;
    let protocol = PROTOCOL;
    let initializing = null;
    let nextId = 1;

    function headers(token) {
        const h = {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
            Accept: 'application/json, text/event-stream',
            'MCP-Protocol-Version': protocol,
        };
        if (sessionId) h['Mcp-Session-Id'] = sessionId;
        return h;
    }

    // One POST. Resolves to the JSON-RPC response for `id` (or null for a
    // notification); relays notifications that arrive on an SSE stream.
    async function post(message, { signal, timeout = timeoutMs } = {}) {
        let token;
        try { token = getToken(); } catch { throw new UpstreamError('auto-browser token is not readable'); }
        const signals = [AbortSignal.timeout(timeout)];
        if (signal) signals.push(signal);
        let res;
        try {
            res = await fetchImpl(url, { method: 'POST', headers: headers(token), body: JSON.stringify(message), signal: AbortSignal.any(signals) });
        } catch (err) {
            if (signal?.aborted) throw err;
            const why = err.name === 'TimeoutError' ? `no answer within ${Math.round(timeout / 1000)} s` : `unreachable (${err.cause?.code || err.name})`;
            throw new UpstreamError(`auto-browser MCP ${why}. Is the browser stack up? (make -C selfhost browser-up)`);
        }
        if (res.status === 202 || message.id === undefined) {
            await res.body?.cancel().catch(() => {});
            if (!res.ok) throw Object.assign(new UpstreamError(`auto-browser MCP -> HTTP ${res.status}`), { status: res.status });
            return null;
        }
        const type = res.headers.get('content-type') || '';
        let text = '';
        try { text = await res.text(); } catch (err) { if (signal?.aborted) throw err; }
        if (!res.ok) {
            let detail = '';
            try { detail = JSON.parse(text)?.error?.message || ''; } catch { detail = text.slice(0, 200); }
            throw Object.assign(new UpstreamError(`auto-browser MCP -> HTTP ${res.status}${detail ? `: ${detail}` : ''}`), { status: res.status, detail });
        }
        const sid = res.headers.get('mcp-session-id');
        if (sid) sessionId = sid;
        const messages = type.includes('text/event-stream') ? parseSse(text) : (() => { try { return [JSON.parse(text)]; } catch { return []; } })();
        let reply = null;
        for (const m of messages.flat()) {
            if (m && m.id === message.id && ('result' in m || 'error' in m)) reply = m;
            else if (m?.method) onNotification(m);
        }
        if (!reply) throw new UpstreamError('auto-browser MCP sent no response');
        return reply;
    }

    async function initialize() {
        sessionId = null;
        protocol = PROTOCOL;
        const r = await post({ jsonrpc: '2.0', id: `init-${nextId++}`, method: 'initialize', params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: CLIENT_INFO } }, { timeout: 20_000 });
        if (r.error) throw new UpstreamError(`auto-browser MCP initialize: ${r.error.message}`);
        protocol = r.result?.protocolVersion || PROTOCOL;
        await post({ jsonrpc: '2.0', method: 'notifications/initialized' }, { timeout: 20_000 });
        return r.result;
    }

    function ensureSession() {
        if (sessionId) return Promise.resolve();
        if (!initializing) initializing = initialize().finally(() => { initializing = null; });
        return initializing;
    }

    // A session the controller no longer knows (restart, expiry) is answered
    // with 404, or 400 "Missing ... session". Start a new one and retry once.
    const staleSession = (err) => err.status === 404 || (err.status === 400 && /session/i.test(err.detail || err.message));

    async function request(method, params, opts = {}) {
        for (let attempt = 0; ; attempt++) {
            await ensureSession();
            const used = sessionId;
            try {
                const r = await post({ jsonrpc: '2.0', id: `req-${nextId++}`, method, ...(params === undefined ? {} : { params }) }, opts);
                return r;
            } catch (err) {
                if (attempt === 0 && err instanceof UpstreamError && staleSession(err)) {
                    if (sessionId === used) sessionId = null;
                    continue;
                }
                if (err instanceof UpstreamError && err.status === undefined) sessionId = null; // down: re-initialize next time
                throw err;
            }
        }
    }

    return {
        request,
        /** The raw upstream tools (paged through nextCursor). */
        async listTools(opts) {
            const tools = [];
            let cursor;
            for (let page = 0; page < 20; page++) {
                const r = await request('tools/list', cursor ? { cursor } : {}, opts);
                if (r.error) throw new UpstreamError(`auto-browser tools/list: ${r.error.message}`);
                tools.push(...(r.result?.tools || []));
                cursor = r.result?.nextCursor;
                if (!cursor) break;
            }
            return tools;
        },
        /** The whole JSON-RPC response ({result} or {error}) for one tool call. */
        callTool: (name, args, meta, opts) => request('tools/call', { name, arguments: args, ...(meta ? { _meta: meta } : {}) }, opts),
        notify: (method, params) => post({ jsonrpc: '2.0', method, params }).catch(() => {}),
        get sessionId() { return sessionId; },
    };
}
