#!/usr/bin/env node
// happy-browser-bridge MCP server (stdio, newline-delimited JSON-RPC 2.0).
// Its own tools are a thin client of the bridge HTTP service on
// 127.0.0.1:6090 (bridge token). It also passes auto-browser's own tools
// through from its Streamable HTTP MCP endpoint, so a client needs only this
// one server and no auto-browser token of its own: the token is read from its
// 600 file here and sent only to 127.0.0.1:8010. It never holds the VNC password.
import { createHash } from 'node:crypto';
import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { loadConfig, readSecret } from './lib/config.mjs';
import { createUpstreamMcp, localToolName } from './lib/upstream.mjs';
import { createSecretGate, SECRET_TOOL_NAMES } from './lib/secrets.mjs';

const PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05'];
const SERVER_INFO = { name: 'happy-browser-bridge', version: '1.2.0' };

export function ownTools(waitMaxS = 3600) {
    const waitDefault = Math.min(900, waitMaxS);
    return [
    {
        name: 'browser_live_link',
        description:
            'Get the live-view link for a browser session so the user can watch the browser from their phone. ' +
            'ALWAYS call this right after you create a browser session (browser_create_session), or the first time you ' +
            'use one, and post the returned link in chat as a bare URL on its own line before you start browsing. ' +
            'The same session always gets the same link. The link opens only inside the Happy app.',
        inputSchema: {
            type: 'object',
            properties: { session_id: { type: 'string', description: 'The browser session id (from browser_create_session or browser_list_sessions).' } },
            required: ['session_id'],
            additionalProperties: false,
        },
    },
    {
        name: 'browser_wait_for_human',
        description:
            'Hand the browser to the user and wait. Call this whenever you need the user in the page: logging in, a CAPTCHA, ' +
            'two-factor codes, payment, a confirmation, or any consent you must not give yourself. Use it instead of ' +
            'browser_request_human_takeover. It flags the live view as "Needs you", and BLOCKS until the user taps Release ' +
            'control or timeout_s passes. Before calling it, tell the user in chat what you need and repeat the live link. Do ' +
            'not send any browser actions for this session while it waits. Also call it when a browser action is refused ' +
            'because the user has taken control: it then waits, without flagging "Needs you", until the user releases ' +
            'control. Returns {status: "done"} when the user handed control back (observe the page again before continuing, ' +
            'since it may have changed), {status: "timeout"} (you may ask again by calling it once more), or {status: "ended"} ' +
            '(the user ended this browser: start a new one only if the task still needs it).',
        inputSchema: {
            type: 'object',
            properties: {
                session_id: { type: 'string', description: 'The auto-browser session id.' },
                reason: { type: 'string', description: 'What you need the user to do, shown on the live view.' },
                timeout_s: { type: 'number', description: `How long to wait, in seconds (default ${waitDefault}, max ${waitMaxS}).`, default: waitDefault },
            },
            required: ['session_id', 'reason'],
            additionalProperties: false,
        },
    },
    ];
}
export const TOOLS = ownTools();
const OWN_NAMES = new Set([...TOOLS.map((t) => t.name), ...SECRET_TOOL_NAMES]);

const HELD = new Set(['user', 'takeover']);
const isUserEnded = (s) => s?.status === 'done' && s?.reason === 'user_ended';
export const USER_ENDED = 'The user ended this browser. Start a new one only if the task still needs it.';
const SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/;
// Tools whose result names no session the agent goes on using.
const NO_LINK_TOOLS = new Set(['browser_list_sessions', 'browser_close_session', 'browser_list_auth_profiles']);

// The browser session a passed-through call is about: its session_id argument, else the session its
// result names (browser_create_session returns the session, browser_observe without a session_id
// creates one, browser_execute_action returns {session: {...}}).
export function sessionOf(args, r) {
    const ok = (v) => (typeof v === 'string' && SESSION_ID.test(v) ? v : null);
    const fromArgs = ok(args?.session_id);
    if (fromArgs) return fromArgs;
    const pick = (o) => (o && typeof o === 'object' && !Array.isArray(o) ? ok(o.session_id) || ok(o.session?.id) || ok(o.id) : null);
    const sc = r?.structuredContent;
    const found = pick(sc) || pick(sc?.result);
    if (found) return found;
    for (const c of Array.isArray(r?.content) ? r.content : []) {
        if (c?.type !== 'text' || typeof c.text !== 'string' || !c.text.trimStart().startsWith('{')) continue;
        try { const v = pick(JSON.parse(c.text)); if (v) return v; } catch {}
    }
    return null;
}

// auto-browser tools that change the page. While the user holds the browser (they took control,
// or the agent asked for them) these are refused; reading tools still go through.
export const MUTATING_TOOLS = new Set([
    'browser_execute_action', 'browser_eval_js', 'browser_close_tab', 'browser_activate_tab',
    'browser_wait_for_selector', 'browser_fork_session', 'browser_save_auth_profile',
]);
export const USER_HAS_CONTROL =
    'The user has taken control of this browser. Call browser_wait_for_human(session_id, reason) and do nothing until it returns.';

/** What the live view shows the agent last did: {kind, target}, never typed text. */
export function actionOf(name, args) {
    if (name === 'browser_eval_js') return { kind: 'eval_js' };
    if (name === 'browser_activate_tab') return { kind: 'activate_tab' };
    if (name === 'browser_close_tab') return { kind: 'close_tab' };
    if (name !== 'browser_execute_action') return null;
    const a = args?.action;
    if (!a || typeof a.action !== 'string') return null;
    const short = (v) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, 120) : null);
    switch (a.action) {
        case 'navigate': {
            try { return { kind: 'navigate', target: new URL(a.url).host || null }; } catch { return { kind: 'navigate' }; }
        }
        case 'click': case 'hover': return { kind: a.action, target: short(a.label) };
        case 'select_option': return { kind: a.action, target: short(a.label) };
        case 'press': return { kind: 'press', target: short(a.key) };
        case 'type': case 'scroll': case 'wait': case 'reload': case 'go_back': case 'go_forward': case 'upload':
            return { kind: a.action };
        default: return null;
    }
}

// What the bridge appends to a few auto-browser tool descriptions, so an agent
// that only reads those still finds the live view.
const HINTS = {
    browser_create_session: ' Then call browser_live_link with the new session id and post the link in chat.',
    browser_observe: ' If this created a new session, call browser_live_link for it and post the link in chat.',
    browser_request_human_takeover: ' Prefer browser_wait_for_human, which also shows "Needs you" on the live view and waits for the user.',
};
const LOCK_HINT = ' Refused while the user has control of the browser; then call browser_wait_for_human and wait.';

/** Expose upstream tools under API-safe names, with references in descriptions renamed too. */
export function mapUpstreamTools(tools, log = () => {}) {
    const byLocal = new Map();
    const renames = tools.filter((t) => typeof t?.name === 'string').map((t) => [t.name, localToolName(t.name)]).filter(([a, b]) => a !== b);
    const rename = (text) => renames.reduce((acc, [from, to]) => acc.split(from).join(to), text);
    const listed = [];
    for (const t of tools) {
        if (typeof t?.name !== 'string') continue;
        const name = localToolName(t.name);
        if (OWN_NAMES.has(name) || byLocal.has(name)) { log(`skipping auto-browser tool ${t.name}: name ${name} already taken`); continue; }
        byLocal.set(name, t.name);
        const description = rename(t.description || '') + (HINTS[name] || '') + (MUTATING_TOOLS.has(name) ? LOCK_HINT : '');
        listed.push({ ...t, name, description });
    }
    return { tools: listed, byLocal, rename };
}

// ── Phase-0 probe: what a client tells us about the chat it serves ────────
// BRIDGE_LOG_META=1 logs to stderr (or BRIDGE_LOG_META=/abs/path appends to that
// file) the KEYS of each request's _meta, the client's name and the keys of its
// clientInfo, and a short hash of chat-ish environment values. Never a raw value.
const META_ENV_KEYS = /^(CLAUDE_CODE_SESSION_ID|CLAUDE_SESSION_ID|CODEX_.*SESSION.*|HAPPY_[A-Z_]*(SESSION|CHAT|THREAD)[A-Z_]*)$/;
export function createMetaProbe(env = process.env, sink = null) {
    const target = env.BRIDGE_LOG_META;
    if (!target || target === '0') return null;
    const shortHash = (v) => createHash('sha256').update(String(v)).digest('hex').slice(0, 12);
    const out = sink || ((line) => {
        if (target.startsWith('/')) { try { appendFileSync(target, line + '\n', { mode: 0o600 }); } catch {} }
        else process.stderr.write(`happy-browser-bridge meta: ${line}\n`);
    });
    const envHashes = Object.fromEntries(Object.keys(env).filter((k) => META_ENV_KEYS.test(k)).sort().map((k) => [k, shortHash(env[k])]));
    out(JSON.stringify({ ev: 'start', pid: process.pid, ppid: process.ppid, env: envHashes }));
    const keysOf = (o) => (o && typeof o === 'object' ? Object.keys(o).sort() : []);
    return {
        initialize(params) {
            const ci = params?.clientInfo;
            out(JSON.stringify({ ev: 'initialize', client: typeof ci?.name === 'string' ? ci.name.slice(0, 60) : null, clientInfoKeys: keysOf(ci), metaKeys: keysOf(params?._meta), capabilityKeys: keysOf(params?.capabilities) }));
        },
        call(method, params) {
            const meta = params?._meta;
            // Values hashed, so two calls from one chat can be told apart from two chats.
            const metaHashes = Object.fromEntries(keysOf(meta).filter((k) => k !== 'progressToken').map((k) => [k, shortHash(JSON.stringify(meta[k]))]));
            out(JSON.stringify({ ev: method, tool: typeof params?.name === 'string' ? params.name : null, metaKeys: keysOf(meta), metaHashes }));
        },
    };
}

export function createMcpServer({ bridgeUrl, bridgeToken, write, fetchImpl = fetch, pollS = 60, upstream = null, waitMaxS = 3600, log = () => {}, retryMs = 30_000, metaProbe = null, secrets = null }) {
    const inflight = new Map(); // request id -> AbortController
    const tools = ownTools(waitMaxS);
    let mapped = { tools: [], byLocal: new Map(), rename: (t) => t };
    let upstreamOk = false;
    let retryTimer = null;
    let initialized = false;

    // Fetch auto-browser's tools. When it is down, list our own tools only and
    // try again in the background, telling the client once the list grows.
    async function refreshUpstream() {
        if (!upstream) return false;
        try {
            mapped = mapUpstreamTools(await upstream.listTools(), log);
            if (!upstreamOk) log(`auto-browser tools: ${mapped.tools.length}`);
            upstreamOk = true;
            return true;
        } catch (err) {
            if (upstreamOk || !retryTimer) log(`auto-browser tools unavailable: ${err.message}`);
            upstreamOk = false;
            scheduleRetry();
            return false;
        }
    }
    function scheduleRetry() {
        if (retryTimer || !retryMs) return;
        retryTimer = setTimeout(async () => {
            retryTimer = null;
            if (await refreshUpstream() && initialized) write({ jsonrpc: '2.0', method: 'notifications/tools/list_changed' });
        }, retryMs);
        retryTimer.unref?.();
    }

    async function passThrough(id, name, args, meta, signal) {
        if (!mapped.byLocal.has(name)) await refreshUpstream();
        const remote = mapped.byLocal.get(name);
        if (!remote) {
            if (!upstreamOk) return result(id, toolResult(`Error: ${name} is an auto-browser tool, but auto-browser is not reachable right now. Is the browser stack up?`, true));
            return error(id, -32602, `unknown tool ${name}`);
        }
        const gate = await secretsBefore(id, name, args, signal);
        if (!gate) return;
        // One state check per call: a page-changing tool asks whether the user holds the browser
        // (recording the action), any other tool on a session only whether the user ended it.
        const state = MUTATING_TOOLS.has(name) ? await guard(name, args, signal) : await sessionState(args, signal);
        if (signal.aborted) return;
        if (isUserEnded(state)) return result(id, toolResult(USER_ENDED, true));
        if (MUTATING_TOOLS.has(name) && HELD.has(state?.status)) return result(id, toolResult(USER_HAS_CONTROL, true));
        let r;
        try {
            r = await upstream.callTool(remote, args, meta, { signal });
        } catch (err) {
            if (signal.aborted) return;
            r = { thrown: toolResult(`Error: ${err.message}`, true) };
        }
        if (signal.aborted) return;
        try {
            if (r.thrown) return result(id, await scrubOut(gate, r.thrown, signal));
            // Verbatim, under our request id.
            if (r.error) return write({ jsonrpc: '2.0', id, error: await scrubOut(gate, r.error, signal) });
            return result(id, await scrubOut(gate, await withLiveLink(name, args, r.result, signal), signal));
        } catch (err) {
            if (!signal.aborted) return result(id, toolResult(`Error: ${err.message}`, true));
        }
    }

    // The secret filler's gate (lib/secrets.mjs) around a passed-through call. Writes the refusal
    // and returns null when the call may not go ahead; the filler being down refuses too.
    async function secretsBefore(id, name, args, signal) {
        if (!secrets) return { scrub: false };
        let g;
        try { g = await secrets.before(name, args, signal); } catch (err) {
            if (!signal.aborted) result(id, toolResult(`Error: ${err.message}`, true));
            return null;
        }
        if (signal.aborted) return null;
        if (g.refuse) { result(id, toolResult(g.refuse, true)); return null; }
        return g;
    }
    // A result (or error) with every filled secret replaced by [secret:<name>]. Throws if the filler can't scrub.
    const scrubOut = async (gate, value, signal) => (gate.scrub ? secrets.scrub(value, signal) : value);

    // Every result about a browser session carries its live link, so the link reaches the chat even
    // when the agent never calls browser_live_link. Asking for it creates the link the first time.
    // auto-browser's own result is kept as is; the link is one more text item (and a structured
    // field). Without a bridge, or for an ended session, the result goes back unchanged.
    async function withLiveLink(name, args, value, signal) {
        if (!value || value.isError || NO_LINK_TOOLS.has(name)) return value;
        const sid = sessionOf(args, value);
        if (!sid) return value;
        let l;
        try {
            l = await bridge('/api/links', { session_id: sid }, signal);
        } catch {
            return value;
        }
        if (!l?.url) return value;
        const text = `Live view of browser session ${sid}: ${l.url}\nIf you have not posted this link in chat yet, post it on its own line so the user can watch live.`;
        const out = { ...value, content: [...(Array.isArray(value.content) ? value.content : []), { type: 'text', text }] };
        if (value.structuredContent && typeof value.structuredContent === 'object' && !Array.isArray(value.structuredContent)) {
            out.structuredContent = { ...value.structuredContent, live_link: l.url };
        }
        return out;
    }

    // The link state of this call's session, or null without a session_id or a bridge. A session
    // the user ended from the app gets USER_ENDED instead of auto-browser's "session closed".
    async function sessionState(args, signal) {
        const sid = typeof args?.session_id === 'string' && args.session_id ? args.session_id : null;
        if (!sid) return null;
        try { return await bridge('/api/state', { session_id: sid }, signal); } catch { return null; }
    }
    const endedByUser = async (args, signal) => isUserEnded(await sessionState(args, signal));

    // Asks the bridge whether the user holds this session's browser, recording the action as the
    // live view's "last action" when they don't. A bridge that can't answer doesn't block browsing:
    // without it nobody can have taken control.
    async function guard(name, args, signal) {
        const sid = typeof args?.session_id === 'string' && args.session_id ? args.session_id : null;
        const action = actionOf(name, args);
        try {
            return await bridge('/api/state', { ...(sid ? { session_id: sid } : {}), ...(action ? { action } : {}) }, signal);
        } catch (err) {
            if (!signal.aborted) log(`control check failed, letting ${name} through: ${err.message}`);
            return null;
        }
    }

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
        if (await endedByUser(args, signal)) throw new Error(USER_ENDED);
        const r = await bridge('/api/links', { session_id: String(args.session_id ?? '') }, signal);
        return { link: r.url, status: r.status, instructions: 'Post this link in chat on its own line so the user can watch live.' };
    }

    async function waitForHuman(args, signal, progress) {
        const timeoutS = Math.max(5, Math.min(waitMaxS, Number(args.timeout_s) || Math.min(900, waitMaxS)));
        const reason = String(args.reason ?? '').trim() || 'The agent needs you to take over.';
        const sessionId = String(args.session_id ?? '');
        if (await endedByUser(args, signal)) return { status: 'ended', note: USER_ENDED };
        // The user already took control on their own: keep it theirs (no "Needs you") and wait for Release.
        const current = await bridge('/api/state', { session_id: sessionId }, signal).catch(() => null);
        let t;
        if (current?.status === 'user') {
            const l = await bridge('/api/links', { session_id: sessionId }, signal);
            t = { id: l.id, url: l.url, status: 'user' };
        } else {
            t = await bridge('/api/takeover', { session_id: sessionId, reason }, signal);
        }
        const deadline = Date.now() + timeoutS * 1000;
        const held = (s) => s === 'takeover' || s === 'user';
        progress(0, t.status === 'user'
            ? `The user has control at ${t.url}. Waiting for them to tap Release control.`
            : `Waiting for you: open ${t.url} and tap Take control, then Release control.`);
        let state = { status: t.status };
        try {
            while (Date.now() < deadline) {
                const waitS = Math.min(pollS, Math.ceil((deadline - Date.now()) / 1000));
                state = await bridge('/api/wait', { id: t.id, wait_s: waitS }, signal);
                if (!held(state.status)) break;
                progress(Math.round(timeoutS - (deadline - Date.now()) / 1000), `Still waiting for you at ${t.url}`);
            }
        } catch (err) {
            if (signal.aborted) await bridge('/api/release', { id: t.id, reason: 'cancelled' }).catch(() => {});
            throw err;
        }
        if (held(state.status)) {
            // Only an unanswered takeover goes back to watching; a user who took control keeps it.
            await bridge('/api/release', { id: t.id, reason: 'timeout' }).catch(() => {});
            return { status: 'timeout', link: t.url, waited_s: timeoutS, ...(state.status === 'user' ? { note: 'the user still has control' } : {}) };
        }
        // Done by the user, or the session closed under them.
        if (state.reason === 'user_ended') return { status: 'ended', link: t.url, note: USER_ENDED };
        return { status: 'done', link: t.url, ...(state.reason === 'session_closed' ? { note: 'the browser session closed' } : {}) };
    }

    async function handle(msg) {
        const { id, method, params } = msg;
        const isRequest = id !== undefined && id !== null;
        if (metaProbe) { try { if (method === 'initialize') metaProbe.initialize(params); else if (method === 'tools/call' || method === 'tools/list') metaProbe.call(method, params); } catch {} }
        switch (method) {
            case 'initialize': {
                const asked = params?.protocolVersion;
                return result(id, {
                    protocolVersion: PROTOCOLS.includes(asked) ? asked : PROTOCOLS[0],
                    capabilities: { tools: { listChanged: !!upstream } },
                    serverInfo: SERVER_INFO,
                    instructions:
                        'A real Chromium browser the user can watch live from their phone. ' +
                        (upstream ? 'Drive it with the browser_* tools: browser_observe (creates a session when none is live) to get element ids, then browser_execute_action. ' : '') +
                        'After you create a browser session, call browser_live_link and post the link in chat on its own line. ' +
                        'When you need the user (login, CAPTCHA, two-factor, payment, a confirmation), call browser_wait_for_human ' +
                        'and do nothing in that session until it returns. The user can also take control from the live view at ' +
                        'any time: while they have it, actions that change the page are refused, and you should call ' +
                        'browser_wait_for_human and wait until they release control. Observing and screenshots still work.',
                });
            }
            case 'ping':
                return isRequest && result(id, {});
            case 'tools/list':
                await refreshUpstream();
                return result(id, { tools: [...tools, ...(secrets ? secrets.tools() : []), ...mapped.tools] });
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
                    else if (secrets && secrets.isOwn(name)) out = await secrets.callOwn(name, args, ac.signal);
                    else if (upstream) return await passThrough(id, name, args, params?._meta, ac.signal);
                    else return error(id, -32602, `unknown tool ${name}`);
                    if (!ac.signal.aborted) result(id, toolResult(out));
                } catch (err) {
                    if (!ac.signal.aborted) result(id, toolResult(`Error: ${err.message}`, true));
                } finally {
                    inflight.delete(id);
                }
                return;
            }
            case 'notifications/initialized':
                initialized = true;
                return;
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
    const write = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');
    const log = (line) => process.stderr.write(`happy-browser-bridge: ${line}\n`);
    const upstream = process.env.BRIDGE_PASSTHROUGH === '0' ? null : createUpstreamMcp({
        url: cfg.autoBrowserMcpUrl,
        getToken: () => readSecret(cfg.files.apiToken),
        timeoutMs: cfg.passthroughTimeoutS * 1000,
        // auto-browser's progress for a call we forwarded, relayed as is.
        onNotification: (m) => { if (m.method === 'notifications/progress') write(m); },
    });
    const server = createMcpServer({
        bridgeUrl: cfg.bridgeUrl,
        bridgeToken: readSecret(cfg.files.bridgeToken),
        write,
        upstream,
        waitMaxS: cfg.waitMaxS,
        log,
        metaProbe: createMetaProbe(),
        secrets: createSecretGate({
            fillerUrl: cfg.fillerUrl,
            tokenPath: cfg.files.fillerToken,
            chat: process.env.HAPPY_SESSION_ID || null,
            controllerPort: () => cfg.autoBrowserPort,
        }),
    });
    const rl = createInterface({ input: process.stdin });
    rl.on('line', (l) => server.onLine(l));
    rl.on('close', () => process.exit(0));
}
