#!/usr/bin/env node
// happy-browser-bridge MCP server (stdio, newline-delimited JSON-RPC 2.0).
// Its own tools are a thin client of the bridge HTTP service on
// 127.0.0.1:6090 (bridge token). It also passes auto-browser's own tools
// through from its Streamable HTTP MCP endpoint, so a client needs only this
// one server and no auto-browser token of its own: the token is read from its
// 600 file here and sent only to 127.0.0.1:8010. It never holds the VNC password.
import { createHash, randomBytes } from 'node:crypto';
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
            properties: { session_id: { type: 'string', description: 'The browser session id (from browser_create_session or browser_list_sessions). Optional when this chat has its own browser.' } },
            required: [],
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
                session_id: { type: 'string', description: 'The auto-browser session id. Optional when this chat has its own browser.' },
                reason: { type: 'string', description: 'What you need the user to do, shown on the live view.' },
                timeout_s: { type: 'number', description: `How long to wait, in seconds (default ${waitDefault}, max ${waitMaxS}).`, default: waitDefault },
            },
            required: ['reason'],
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

// ── Per-chat pods: which chat this server serves, and its browser pod ──────
// The Happy CLI gives each agent's MCP servers HAPPY_SESSION_ID (the Happy session, i.e. the
// chat); Claude Code itself sets CLAUDE_CODE_SESSION_ID. Without either (a daemon serving many
// chats from one process), every browser session gets a pod of its own instead.
export function chatIdentity(env = process.env) {
    if (env.HAPPY_SESSION_ID) return { source: 'happy', id: String(env.HAPPY_SESSION_ID) };
    if (env.CLAUDE_CODE_SESSION_ID) return { source: 'claude', id: String(env.CLAUDE_CODE_SESSION_ID) };
    return null;
}
// The bridge's chat key: sha256("<source>:<id>"), first 32 hex chars. The app computes the same
// from the Happy session id to find a chat's live link (GET /live/chat/<key>).
export const chatKeyOf = (ident) => createHash('sha256').update(`${ident.source}:${ident.id}`).digest('hex').slice(0, 32);

// Routes each call to its chat's pod through the bridge (/api/pod), one upstream MCP client per
// pod. route() returns null when the bridge has pods off (the shared controller then serves).
export function createChatRouter({ bridge, makeUpstream, chat = null, newKey = () => randomBytes(16).toString('hex'), now = Date.now, recheckMs = 60_000 }) {
    let legacyAt = null; // when the bridge last said pods are off
    let known = false; // the bridge has answered a pod request
    const upstreams = new Map(); // mcp_url -> upstream client
    const pods = new Map(); // chat key -> last /api/pod answer
    const bySession = new Map(); // browser session id -> chat key
    let current = null; // without a chat identity: the key for calls that name no session

    const upstreamFor = (url) => {
        if (!upstreams.has(url)) upstreams.set(url, makeUpstream(url));
        return upstreams.get(url);
    };
    function keyFor(name, args) {
        if (chat) return chat.key;
        const sid = typeof args?.session_id === 'string' && args.session_id ? args.session_id : null;
        if (name === 'browser_create_session') return (current = newKey());
        if (sid) return bySession.get(sid) ?? null;
        return current ?? (current = newKey());
    }
    function remember(key, d) {
        pods.set(key, d);
        if (d.session_id) bySession.set(d.session_id, key);
        if (!chat) current = key;
    }

    return {
        get pods() { return known && legacyAt === null; },
        get legacy() { return legacyAt !== null && now() - legacyAt < recheckMs; },
        // This call's pod: {key, session_id, mcp_url, api_url, link_id, upstream}, or null with pods off.
        async route(name, args, signal, { verify = false } = {}) {
            if (legacyAt !== null && now() - legacyAt < recheckMs) return null;
            let key = keyFor(name, args);
            let d;
            try {
                if (key) d = await bridge('/api/pod', { chat_key: key, source: chat?.source ?? 'session', ...(verify ? { verify: true } : {}) }, signal);
                else {
                    // A session this process has not seen (another process made it, or before a restart).
                    d = await bridge('/api/pod', { session_id: args.session_id, ...(verify ? { verify: true } : {}) }, signal);
                    key = d.chat_key;
                }
            } catch (err) {
                if (err.status === 409 && err.code === 'pods_disabled') { legacyAt = now(); known = true; return null; }
                throw err;
            }
            legacyAt = null;
            known = true;
            remember(key, d);
            return { key, ...d, upstream: upstreamFor(d.mcp_url) };
        },
        markLegacy() { legacyAt = now(); known = true; },
        keyOfSession: (sid) => (sid ? bySession.get(sid) ?? null : null),
        // The pod's API port for a call's session (the secret filler types into that pod).
        apiPortFor(args) {
            const key = (chat && this.pods) ? chat.key : bySession.get(args?.session_id);
            const url = key ? pods.get(key)?.api_url : null;
            return url ? Number(new URL(url).port) : null;
        },
        forget(key) {
            const d = pods.get(key);
            pods.delete(key);
            for (const [sid, k] of bySession) if (k === key) bySession.delete(sid);
            if (current === key) current = null;
            return d;
        },
        get chatKey() { return chat?.key ?? null; },
    };
}

const ONE_BROWSER = 'Each chat has one browser. Use the session it already has; a fork or a second session is not available.';

export function createMcpServer({ bridgeUrl, bridgeToken, write, fetchImpl = fetch, pollS = 60, upstream = null, waitMaxS = 3600, log = () => {}, retryMs = 30_000, metaProbe = null, secrets = null, chatPods = null }) {
    const inflight = new Map(); // request id -> AbortController
    // chatPods: {chat: {key, source} | null, makeUpstream(url)}. Each call then goes to its chat's
    // pod when the bridge runs pods, and to `upstream` (the shared controller) when it doesn't.
    const router = chatPods ? createChatRouter({ bridge: (p, b, s) => bridge(p, b, s), makeUpstream: chatPods.makeUpstream, chat: chatPods.chat, ...(chatPods.newKey ? { newKey: chatPods.newKey } : {}) }) : null;
    let withSession = new Set(); // local names of auto-browser tools that take a session_id
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
            const raw = await podTools() ?? await upstream.listTools();
            mapped = mapUpstreamTools(raw, log);
            withSession = new Set(raw.filter((t) => t?.inputSchema?.properties?.session_id).map((t) => localToolName(t.name)));
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

    // With pods, auto-browser's tool list comes from the bridge's cache, so listing tools never
    // starts a pod. null: no pods (or no list yet), ask `upstream`.
    async function podTools() {
        if (!router || router.legacy) return null;
        try {
            return (await bridge('/api/tools', {})).tools;
        } catch (err) {
            if (err.status === 409 && err.code === 'pods_disabled') router.markLegacy();
            return null;
        }
    }

    // The chat's pod for this call, its session put into the arguments. Some tools are answered
    // here: a chat has exactly one browser session. Returns {via, args} or {done: true}.
    async function routeCall(id, name, args, signal) {
        if (!router) return { via: null, args };
        let via;
        try {
            via = await router.route(name, args, signal);
        } catch (err) {
            if (!signal.aborted) result(id, toolResult(`Error: the browser for this chat is not available: ${err.message}`, true));
            return { done: true };
        }
        if (!via) return { via: null, args };
        if (name === 'browser_fork_session') { result(id, toolResult(ONE_BROWSER, true)); return { done: true }; }
        if (name === 'browser_close_session') {
            try {
                await bridge('/api/pod/close', { chat_key: via.key }, signal);
                router.forget(via.key);
                result(id, toolResult({ closed: true, session_id: via.session_id, note: 'The browser is closed and its login kept. It starts again (signed in) when you next use a browser tool.' }));
            } catch (err) {
                if (!signal.aborted) result(id, toolResult(`Error: ${err.message}`, true));
            }
            return { done: true };
        }
        const routed = withSession.has(name) ? { ...args, session_id: via.session_id } : args;
        return { via, args: routed };
    }

    // browser_create_session with pods: the chat's session already exists (the pod made it,
    // signed in with the chat's saved login). Answer with it, opening start_url if given.
    async function createInPod(via, args, meta, signal) {
        if (typeof args.start_url === 'string' && args.start_url) {
            const nav = await via.upstream.callTool(mapped.byLocal.get('browser_execute_action') || 'browser.execute_action',
                { session_id: via.session_id, action: 'navigate', url: args.start_url, reason: 'open start_url' }, meta, { signal });
            if (nav.error || nav.result?.isError) return nav;
        }
        const r = await via.upstream.callTool(mapped.byLocal.get('browser_get_session') || 'browser.get_session', { session_id: via.session_id }, meta, { signal });
        if (r.result && !r.result.isError) {
            r.result = { ...r.result, content: [{ type: 'text', text: `This chat's browser session is ${via.session_id} (one per chat, kept signed in across restarts).` }, ...(r.result.content || [])] };
        }
        return r;
    }
    const refused = (err) => /ECONNREFUSED/.test(err?.message || '');

    async function passThrough(id, name, args, meta, signal) {
        if (!mapped.byLocal.has(name)) await refreshUpstream();
        const remote = mapped.byLocal.get(name);
        if (!remote) {
            if (!upstreamOk) return result(id, toolResult(`Error: ${name} is an auto-browser tool, but auto-browser is not reachable right now. Is the browser stack up?`, true));
            return error(id, -32602, `unknown tool ${name}`);
        }
        // Routing first: the secret gate and the control check both need the chat's session.
        const routedCall = await routeCall(id, name, args, signal);
        if (routedCall.done) return;
        let via = routedCall.via;
        args = routedCall.args;
        const gate = await secretsBefore(id, name, args, signal);
        if (!gate) return;
        // One state check per call: a page-changing tool asks whether the user holds the browser
        // (recording the action), any other tool on a session only whether the user ended it.
        const state = MUTATING_TOOLS.has(name) ? await guard(name, args, signal, via) : await sessionState(args, signal, via);
        if (signal.aborted) return;
        if (isUserEnded(state)) return result(id, toolResult(USER_ENDED, true));
        if (MUTATING_TOOLS.has(name) && HELD.has(state?.status)) return result(id, toolResult(USER_HAS_CONTROL, true));
        const call = (v, a) => (v && name === 'browser_create_session' ? createInPod(v, a, meta, signal) : (v?.upstream || upstream).callTool(remote, a, meta, { signal }));
        let r;
        try {
            try {
                r = await call(via, args);
            } catch (err) {
                // The pod went away under us (crashed, stopped): have the bridge check it, and retry once.
                if (!via || signal.aborted || !refused(err)) throw err;
                via = await router.route(name, args, signal, { verify: true });
                if (via && withSession.has(name)) args = { ...args, session_id: via.session_id };
                r = await call(via, args);
            }
        } catch (err) {
            if (signal.aborted) return;
            r = { thrown: toolResult(`Error: ${err.message}`, true) };
        }
        if (signal.aborted) return;
        try {
            if (r.thrown) return result(id, await scrubOut(gate, r.thrown, signal));
            // Verbatim, under our request id.
            if (r.error) return write({ jsonrpc: '2.0', id, error: await scrubOut(gate, r.error, signal) });
            return result(id, await scrubOut(gate, await withLiveLink(name, args, r.result, signal, via), signal));
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
    // auto-browser's own result is kept as is after one text item with the link (and a
    // structured field). Without a bridge, or for an ended session, the result goes back unchanged.
    async function withLiveLink(name, args, value, signal, via = null) {
        if (!value || value.isError || NO_LINK_TOOLS.has(name)) return value;
        const sid = via?.session_id || sessionOf(args, value);
        if (!sid) return value;
        let l;
        try {
            l = await bridge('/api/links', linkRef(sid, via), signal);
        } catch {
            return value;
        }
        if (!l?.url) return value;
        const text = `Live view of browser session ${sid}: ${l.url}\nIf you have not posted this link in chat yet, post it on its own line so the user can watch live.`;
        // First, so it survives a client that cuts a long result (an observe, a page's HTML) short.
        const out = { ...value, content: [{ type: 'text', text }, ...(Array.isArray(value.content) ? value.content : [])] };
        if (value.structuredContent && typeof value.structuredContent === 'object' && !Array.isArray(value.structuredContent)) {
            out.structuredContent = { ...value.structuredContent, live_link: l.url };
        }
        return out;
    }

    // The link state of this call's session, or null without a session_id or a bridge. A session
    // the user ended from the app gets USER_ENDED instead of auto-browser's "session closed".
    async function sessionState(args, signal, via = null) {
        const sid = typeof args?.session_id === 'string' && args.session_id ? args.session_id : null;
        if (!sid && !via) return null;
        try { return await bridge('/api/state', linkRef(sid, via), signal); } catch { return null; }
    }
    const endedByUser = async (args, signal, via = null) => isUserEnded(await sessionState(args, signal, via));
    // How the bridge names this call's link: by chat with pods, by session without.
    const linkRef = (sid, via) => (via ? { chat_key: via.key } : { session_id: sid });

    // Asks the bridge whether the user holds this session's browser, recording the action as the
    // live view's "last action" when they don't. A bridge that can't answer doesn't block browsing:
    // without it nobody can have taken control.
    async function guard(name, args, signal, via = null) {
        const sid = typeof args?.session_id === 'string' && args.session_id ? args.session_id : null;
        const action = actionOf(name, args);
        try {
            return await bridge('/api/state', { ...(via ? { chat_key: via.key } : sid ? { session_id: sid } : {}), ...(action ? { action } : {}) }, signal);
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
            const err = new Error(res.status === 404 && body.session_id ? `${why}: ${body.session_id}` : `bridge ${path}: ${why}`);
            throw Object.assign(err, { status: res.status, code: data?.code || data?.error });
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

    // Our own tools with pods: the chat's pod (started if need be), or null without pods.
    async function ownVia(args, signal) {
        if (!router) return null;
        if (!router.chatKey && !(typeof args?.session_id === 'string' && args.session_id)) return null;
        return router.route('browser_live_link', args || {}, signal);
    }

    async function liveLink(args, signal) {
        const via = await ownVia(args, signal);
        if (await endedByUser(args, signal, via)) throw new Error(USER_ENDED);
        const r = await bridge('/api/links', linkRef(String(args.session_id ?? ''), via), signal);
        return { link: r.url, status: r.status, instructions: 'Post this link in chat on its own line so the user can watch live.' };
    }

    async function waitForHuman(args, signal, progress) {
        const timeoutS = Math.max(5, Math.min(waitMaxS, Number(args.timeout_s) || Math.min(900, waitMaxS)));
        const reason = String(args.reason ?? '').trim() || 'The agent needs you to take over.';
        const sessionId = String(args.session_id ?? '');
        const via = await ownVia(args, signal);
        const ref = linkRef(sessionId, via);
        if (await endedByUser(args, signal, via)) return { status: 'ended', note: USER_ENDED };
        // The user already took control on their own: keep it theirs (no "Needs you") and wait for Release.
        const current = await bridge('/api/state', ref, signal).catch(() => null);
        let t;
        if (current?.status === 'user') {
            const l = await bridge('/api/links', ref, signal);
            t = { id: l.id, url: l.url, status: 'user' };
        } else {
            t = await bridge('/api/takeover', { ...ref, reason }, signal);
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
        router,
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
    // Per-chat pods: each pod's MCP endpoint gets a client like `upstream`.
    const ident = chatIdentity();
    const makeUpstream = (url) => createUpstreamMcp({
        url,
        getToken: () => readSecret(cfg.files.apiToken),
        timeoutMs: cfg.passthroughTimeoutS * 1000,
        onNotification: (m) => { if (m.method === 'notifications/progress') write(m); },
    });
    let podPort = () => null;
    const server = createMcpServer({
        bridgeUrl: cfg.bridgeUrl,
        bridgeToken: readSecret(cfg.files.bridgeToken),
        write,
        upstream,
        chatPods: upstream ? { chat: ident ? { key: chatKeyOf(ident), source: ident.source } : null, makeUpstream } : null,
        waitMaxS: cfg.waitMaxS,
        log,
        metaProbe: createMetaProbe(),
        secrets: createSecretGate({
            fillerUrl: cfg.fillerUrl,
            tokenPath: cfg.files.fillerToken,
            chat: process.env.HAPPY_SESSION_ID || null,
            // The chat's pod when pods are on, else the shared controller.
            controllerPort: (args) => podPort(args) ?? cfg.autoBrowserPort,
        }),
    });
    podPort = (args) => server.router?.apiPortFor(args) ?? null;
    const rl = createInterface({ input: process.stdin });
    rl.on('line', (l) => server.onLine(l));
    rl.on('close', () => process.exit(0));
}
