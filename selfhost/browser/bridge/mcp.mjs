#!/usr/bin/env node
// happy-browser-bridge MCP server (stdio, newline-delimited JSON-RPC 2.0).
// A thin client of the bridge HTTP service on 127.0.0.1:6090: it holds only
// the bridge token (read from a 600 file), never auto-browser's token or the
// VNC password.
import { createInterface } from 'node:readline';
import { loadConfig, readSecret } from './lib/config.mjs';

const PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05'];
const SERVER_INFO = { name: 'happy-browser-bridge', version: '1.0.0' };

export const TOOLS = [
    {
        name: 'browser_live_link',
        description:
            'Get the live-view link for an auto-browser session so the user can watch the browser from their phone. ' +
            'Call this as soon as you create or start using a browser session (browser.create_session), and post the ' +
            'returned link in chat as a bare URL on its own line, before you start browsing. The same session always ' +
            'gets the same link. The link opens only inside the Happy app.',
        inputSchema: {
            type: 'object',
            properties: { session_id: { type: 'string', description: 'The auto-browser session id (from browser.create_session).' } },
            required: ['session_id'],
            additionalProperties: false,
        },
    },
    {
        name: 'browser_wait_for_human',
        description:
            'Hand the browser to the user and wait. Use this when a person must act in the page: logging in, a CAPTCHA, ' +
            'two-factor codes, payment, or any consent you must not give yourself. It flags the live view as "Needs you", ' +
            'and BLOCKS until the user taps Done or timeout_s passes. Do not send any browser actions for this session ' +
            'while it waits. Tell the user what you need in `reason`. Returns {status: "done"} when the user handed control ' +
            'back (observe the page again before continuing, since it may have changed) or {status: "timeout"}.',
        inputSchema: {
            type: 'object',
            properties: {
                session_id: { type: 'string', description: 'The auto-browser session id.' },
                reason: { type: 'string', description: 'What you need the user to do, shown on the live view.' },
                timeout_s: { type: 'number', description: 'How long to wait, in seconds (default 900, max 3600).', default: 900 },
            },
            required: ['session_id', 'reason'],
            additionalProperties: false,
        },
    },
];

export function createMcpServer({ bridgeUrl, bridgeToken, write, fetchImpl = fetch, pollS = 60 }) {
    const inflight = new Map(); // request id -> AbortController

    async function bridge(path, body, signal) {
        const res = await fetchImpl(bridgeUrl + path, {
            method: 'POST',
            headers: { Authorization: `Bearer ${bridgeToken}`, 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
            signal,
        });
        let data = null;
        try { data = await res.json(); } catch {}
        if (!res.ok) {
            const why = data?.error || `HTTP ${res.status}`;
            throw new Error(res.status === 404 && body.session_id ? `${why}: ${body.session_id}` : `bridge ${path}: ${why}`);
        }
        return data;
    }

    const result = (id, value) => write({ jsonrpc: '2.0', id, result: value });
    const error = (id, code, message) => write({ jsonrpc: '2.0', id, error: { code, message } });
    const toolResult = (obj, isError = false) => ({
        content: [{ type: 'text', text: typeof obj === 'string' ? obj : JSON.stringify(obj) }],
        ...(typeof obj === 'object' ? { structuredContent: obj } : {}),
        isError,
    });

    async function liveLink(args, signal) {
        const r = await bridge('/api/links', { session_id: String(args.session_id ?? '') }, signal);
        return { link: r.url, status: r.status, instructions: 'Post this link in chat on its own line so the user can watch live.' };
    }

    async function waitForHuman(args, signal, progress) {
        const timeoutS = Math.max(5, Math.min(3600, Number(args.timeout_s) || 900));
        const reason = String(args.reason ?? '').trim() || 'The agent needs you to take over.';
        const t = await bridge('/api/takeover', { session_id: String(args.session_id ?? ''), reason }, signal);
        const deadline = Date.now() + timeoutS * 1000;
        progress(0, `Waiting for you: open ${t.url} and tap Take control, then Done.`);
        let state = { status: 'takeover' };
        try {
            while (Date.now() < deadline) {
                const waitS = Math.min(pollS, Math.ceil((deadline - Date.now()) / 1000));
                state = await bridge('/api/wait', { id: t.id, wait_s: waitS }, signal);
                if (state.status !== 'takeover') break;
                progress(Math.round(timeoutS - (deadline - Date.now()) / 1000), `Still waiting for you at ${t.url}`);
            }
        } catch (err) {
            if (signal.aborted) await bridge('/api/release', { id: t.id, reason: 'cancelled' }).catch(() => {});
            throw err;
        }
        if (state.status === 'takeover') {
            await bridge('/api/release', { id: t.id, reason: 'timeout' }).catch(() => {});
            return { status: 'timeout', link: t.url, waited_s: timeoutS };
        }
        // Done by the user, or the session closed under them.
        return { status: 'done', link: t.url, ...(state.reason === 'session_closed' ? { note: 'the browser session closed' } : {}) };
    }

    async function handle(msg) {
        const { id, method, params } = msg;
        const isRequest = id !== undefined && id !== null;
        switch (method) {
            case 'initialize': {
                const asked = params?.protocolVersion;
                return result(id, {
                    protocolVersion: PROTOCOLS.includes(asked) ? asked : PROTOCOLS[0],
                    capabilities: { tools: { listChanged: false } },
                    serverInfo: SERVER_INFO,
                    instructions:
                        'Live view for auto-browser sessions. When you start browsing, call browser_live_link and post the link. ' +
                        'When a person must act in the page, call browser_wait_for_human and do nothing in that session until it returns.',
                });
            }
            case 'ping':
                return isRequest && result(id, {});
            case 'tools/list':
                return result(id, { tools: TOOLS });
            case 'tools/call': {
                const name = params?.name;
                const args = params?.arguments || {};
                const token = params?._meta?.progressToken;
                const ac = new AbortController();
                inflight.set(id, ac);
                const progress = (p, message) => {
                    if (token !== undefined) write({ jsonrpc: '2.0', method: 'notifications/progress', params: { progressToken: token, progress: p, message } });
                };
                try {
                    let out;
                    if (name === 'browser_live_link') out = await liveLink(args, ac.signal);
                    else if (name === 'browser_wait_for_human') out = await waitForHuman(args, ac.signal, progress);
                    else return error(id, -32602, `unknown tool ${name}`);
                    if (!ac.signal.aborted) result(id, toolResult(out));
                } catch (err) {
                    if (!ac.signal.aborted) result(id, toolResult(`Error: ${err.message}`, true));
                } finally {
                    inflight.delete(id);
                }
                return;
            }
            case 'notifications/cancelled':
                inflight.get(params?.requestId)?.abort();
                return;
            default:
                if (method?.startsWith('notifications/')) return;
                if (isRequest) return error(id, -32601, `method not found: ${method}`);
        }
    }

    return {
        handle,
        onLine(line) {
            if (!line.trim()) return;
            let msg;
            try { msg = JSON.parse(line); } catch { return write({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }); }
            for (const m of Array.isArray(msg) ? msg : [msg]) handle(m).catch((e) => m.id != null && error(m.id, -32603, e.message));
        },
    };
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const cfg = loadConfig();
    const server = createMcpServer({
        bridgeUrl: cfg.bridgeUrl,
        bridgeToken: readSecret(cfg.files.bridgeToken),
        write: (obj) => process.stdout.write(JSON.stringify(obj) + '\n'),
    });
    const rl = createInterface({ input: process.stdin });
    rl.on('line', (l) => server.onLine(l));
    rl.on('close', () => process.exit(0));
}
