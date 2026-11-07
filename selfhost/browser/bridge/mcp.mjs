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
import { createAgentChatLookup } from '../../../browser-stack/identity/agentchat.mjs';
import { chatFromMeta, chatOfMeta, fillerChatOf, withoutChatMeta } from '../../../browser-stack/identity/chatmeta.mjs';

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
            'two-factor codes, payment, a confirmation, or any consent you must not give yourself. For logins, try ' +
            'browser_list_secrets/browser_login first, if those tools are available, and call this only when no vault login ' +
            'matches the page\'s host, the fill is refused, or a CAPTCHA or a non-TOTP second factor (phone prompt, SMS) ' +
            'comes up. Never ask the user to type a password in chat. ' +
            'Use it instead of browser_request_human_takeover. It flags the live view as "Needs you", and BLOCKS until the user taps Release ' +
            'control or timeout_s passes. Before calling it, tell the user in chat what you need and repeat the live link. Do ' +
            'not send any browser actions for this session while it waits. Also call it when a browser action is refused ' +
            'because the user has taken control: it then waits, without flagging "Needs you", until the user releases ' +
            'control. Returns {status: "done"} when the user handed control back (observe the page again before continuing, ' +
            'since it may have changed), {status: "timeout"} (you may ask again by calling it once more), {status: "released"} ' +
            '(control came back without the user releasing it: the bridge restarted, or the user left the live view; observe the page and call it again if you still need the user), ' +
            'or {status: "ended"} (the user ended this browser: start a new one only if the task still needs it). ' +
            'When a browser action came back {status: "approval_pending"}, call this to keep waiting for the user\'s approval: ' +
            'it returns {status: "approved", approval_id} (repeat the exact same call once with that approval_id added) or ' +
            '{status: "denied"} (do not retry; ask the user in chat).',
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

// Added to the server instructions only when the secret filler is set up (its client token exists).
export const SECRET_INSTRUCTIONS =
    'Vault logins: when a page asks you to sign in, call browser_list_secrets first, without asking the user. If one ' +
    'login matches the page\'s host, call browser_login (or browser_fill_secret for a split or unusual form), then carry ' +
    'on with the task. If several logins match the host, ask the user in chat which one to use (by login name only) ' +
    'before filling. Call browser_wait_for_human for a sign-in only when no login matches the host, the fill is refused ' +
    '(tell the user what the refusal said, e.g. which URI to add to the vault item), a CAPTCHA appears, or a second ' +
    'factor comes up that is not a stored TOTP (a phone prompt, an SMS code). Never ask the user to type a password in chat. ';
const OWN_NAMES = new Set([...TOOLS.map((t) => t.name), ...SECRET_TOOL_NAMES]);

const HELD = new Set(['user', 'takeover']);
const isUserEnded = (s) => s?.status === 'done' && s?.reason === 'user_ended';
export const APPROVAL_DENIED = 'The user denied this action. Do not retry it or look for another way to do the same thing. Tell the user in chat what you were trying to do and ask how they want to proceed.';
export const APPROVAL_PENDING = 'The user has been asked to approve this action in the live view and has not answered yet. Do not repeat the action and do not send other actions for this session. Tell the user in chat that an approval is waiting for them (with the live link), then call browser_wait_for_human to keep waiting. When it returns approved, repeat the exact same call with approval_id added.';
export const approvedRepeatNote = (aid) => `The user approved the action. Repeat the exact same call (same tool, same arguments) once, with approval_id: "${aid}" added; the approval is good for 15 minutes.`;
export const VIEWER_LEFT = 'released: the user left the live view (closed it, or lost the connection) without releasing control. They may not be finished. Observe the page, and if you still need them, call browser_wait_for_human again.';
export const BRIDGE_RESTARTING = 'released: bridge restarting. The user may not be finished. Observe the page, and if you still need them, call browser_wait_for_human again once the bridge is back (a few seconds).';
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
// Preflight (before a browser call, the chat's session is checked and a dead one recovered): the
// calls that may go on against a recovered browser. Anything else could act on a page the agent
// has not seen, so it is refused with RECOVERED_REFUSED.
export const READ_ONLY_TOOLS = new Set([
    'browser_observe', 'browser_screenshot', 'browser_get_html', 'browser_find_elements', 'browser_list_tabs',
    'browser_get_session', 'browser_list_sessions', 'browser_wait_for_selector', 'browser_list_downloads',
    'browser_read_download', 'browser_live_link', 'browser_create_session', 'browser_list_auth_profiles', 'browser_list_secrets',
]);
const RECOVERY_WHY = { session_ended: 'its session ended', pod_crashed: 'it stopped answering', pod_asleep: 'it was asleep', ended: 'it was ended' };
export function recoveredNote(via) {
    const r = via.recovered;
    return `The browser was restarted (${RECOVERY_WHY[r.reason] || r.reason}). Session ${r.previous_session_id || '(none)'} is gone; `
        + `this chat's browser is now session ${via.session_id}, signed in with its saved login and `
        + (r.reason === 'ended' ? 'on a new page (the user ended the last one).' : 'reopened at its last page if it had one.')
        + (via.url ? ` Live view: ${via.url}` : '');
}
export const RECOVERED_REFUSED = 'Nothing was done: observe the page again (browser_observe) before acting, since element ids from before no longer apply.';
export const SHARED_DOWN = 'The shared browser is down (auto-browser is not answering). It is not restarted automatically; try again shortly or ask the user to check the browser stack.';
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

// A forked or side chat: the Happy daemon sets HAPPY_FORKED_FROM_SESSION_ID to the parent's Happy
// session id, and the chat's browser starts with a copy of the parent's saved login. Read from
// the environment only (never a tool argument), and only for a Happy-identified chat. Returns the
// parent's chat key, or null.
export function forkParentKey(env = process.env, ident = chatIdentity(env)) {
    const parent = env.HAPPY_FORKED_FROM_SESSION_ID;
    if (!ident || ident.source !== 'happy' || typeof parent !== 'string' || !SESSION_ID.test(parent) || parent === ident.id) return null;
    return chatKeyOf({ source: 'happy', id: parent });
}

// A daemon that serves many chats from one process (Happy Agent) names the chat per call instead:
// its MCP client puts its own id for the tool call in _meta["claudecode/toolUseId"], and
// lookup(id) answers which chat made that call ({source, id}, see browser-stack/identity/agentchat.mjs). Without a
// call id (Happy Agent as deployed sends no _meta at all), lookup.match(name, args) finds the
// daemon's own journal record of this call instead: the one in-flight call of that tool with
// exactly these arguments. Either way the chat is the agent the daemon recorded, never a value
// in the arguments, so the model cannot pick another chat's browser. Returns {key, source};
// null when the call can't be found (routed by its browser session, as before); NO_CALL_CHAT
// when a call id was given but its chat can't be told, or identical calls from two chats are in
// flight (the call is then refused, and a retry tells them apart).
export const NO_CALL_CHAT = Object.freeze({ unknown: true });
const TOOL_USE_ID = /^[A-Za-z0-9_-]{1,128}$/;
export function callChatResolver(lookup, log = () => {}) {
    return async function callChatOf(meta, signal, call = null) {
        const id = meta && typeof meta === 'object' ? meta['claudecode/toolUseId'] : undefined;
        if (id === undefined) {
            if (typeof lookup.match !== 'function' || !call?.name) return null;
            try {
                const ident = await lookup.match(call.name, call.args, signal);
                if (ident?.ambiguous) { log(`chat of tool call ${call.name}: identical calls from two chats in flight`); return NO_CALL_CHAT; }
                if (ident && typeof ident.source === 'string' && typeof ident.id === 'string' && ident.id) return { key: chatKeyOf(ident), source: ident.source };
                log(`chat of tool call ${call.name} not in the daemon's journal; routed by session`);
            } catch (err) {
                log(`chat of tool call not found: ${err.message}`);
            }
            return null;
        }
        if (typeof id !== 'string' || !TOOL_USE_ID.test(id)) return NO_CALL_CHAT;
        try {
            const ident = await lookup(id, signal);
            if (ident && typeof ident.source === 'string' && typeof ident.id === 'string' && ident.id) return { key: chatKeyOf(ident), source: ident.source };
        } catch (err) {
            log(`chat of tool call not found: ${err.message}`);
        }
        return NO_CALL_CHAT;
    };
}
// The per-call chat resolver for a process with no chat of its own, from the operator's env
// (BRIDGE_AGENT_DB, BRIDGE_AGENT_PYTHON, BRIDGE_AGENT_SSH), never from a call. null: none.
export function agentCallChat(ident, env = process.env, log = () => {}) {
    if (ident || !env.BRIDGE_AGENT_DB) return null;
    try {
        return callChatResolver(createAgentChatLookup({ dbPath: env.BRIDGE_AGENT_DB, python: env.BRIDGE_AGENT_PYTHON || 'python3', ssh: env.BRIDGE_AGENT_SSH || null }), log);
    } catch (err) {
        log(`agent chat lookup off: ${err.message}`);
        return null;
    }
}
// Behind the LAN gateway (BROWSER_CHAT_FROM_META=1, set by the operator only): each call's chat
// is the one the Mac's gateway client stamped in _meta (browser-stack/identity/chatmeta.mjs). A call without it is
// refused (NO_CALL_CHAT), never routed by its arguments. fromMeta lets a fork's parent through.
export function metaCallChat() {
    return async function callChatOf(meta) {
        const c = chatOfMeta(meta);
        if (!c) return NO_CALL_CHAT;
        return {
            key: chatKeyOf(c),
            source: c.source,
            fromMeta: true,
            fillerChat: fillerChatOf(c),
            ...(c.forkedFrom ? { forkedFrom: chatKeyOf({ source: 'happy', id: c.forkedFrom }) } : {}),
        };
    };
}
const NO_CHAT = 'this browser call could not be matched to its chat, so it was not sent to any browser. Try it again.';

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
    // c: the chat of this call (from the MCP client, never the tool arguments), else the process's.
    function keyFor(name, args, c) {
        if (c) return c.key;
        const sid = typeof args?.session_id === 'string' && args.session_id ? args.session_id : null;
        if (name === 'browser_create_session') return (current = newKey());
        if (sid) return bySession.get(sid) ?? null;
        return current ?? (current = newKey());
    }
    function remember(key, d, c) {
        pods.set(key, d);
        if (d.session_id) bySession.set(d.session_id, key);
        if (!c) current = key;
    }

    return {
        get pods() { return known && legacyAt === null; },
        get legacy() { return legacyAt !== null && now() - legacyAt < recheckMs; },
        // This call's pod: {key, session_id, mcp_url, api_url, link_id, upstream}, or null with pods off.
        // callChat: {key, source} the MCP client named for this one call (a daemon serving many chats).
        async route(name, args, signal, { verify = false, check = false, chat: callChat = null } = {}) {
            if (legacyAt !== null && now() - legacyAt < recheckMs) return null;
            if (callChat?.unknown) throw new Error(NO_CHAT);
            const c = callChat ?? chat;
            let key = keyFor(name, args, c);
            let d;
            try {
                // forked_from only for this process's own chat, or one the gateway client named in
                // _meta (metaCallChat), never one a daemon's journal or the arguments name.
                const fork = c && (c === chat || c.fromMeta === true) && c.forkedFrom ? { forked_from: c.forkedFrom } : {};
                const flags = { ...(verify ? { verify: true } : {}), ...(check ? { check: true } : {}) };
                if (key) d = await bridge('/api/pod', { chat_key: key, source: c?.source ?? 'session', ...fork, ...flags }, signal);
                else {
                    // A session this process has not seen (another process made it, or before a restart).
                    d = await bridge('/api/pod', { session_id: args.session_id, ...flags }, signal);
                    key = d.chat_key;
                }
            } catch (err) {
                if (err.status === 409 && err.code === 'pods_disabled') { legacyAt = now(); known = true; return null; }
                throw err;
            }
            legacyAt = null;
            known = true;
            remember(key, d, c);
            return { key, ...d, upstream: upstreamFor(d.mcp_url) };
        },
        markLegacy() { legacyAt = now(); known = true; },
        keyOfSession: (sid) => (sid ? bySession.get(sid) ?? null : null),
        // The pod's API port for a call's session (the secret filler types into that pod).
        // cc: the call's own chat, when the client named one per call.
        apiPortFor(args, cc = null) {
            const key = cc?.key && this.pods ? cc.key : (chat && this.pods) ? chat.key : bySession.get(args?.session_id);
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

// The bridge names its live pages at its own localhost (`linkFrom`); an agent on another
// computer reaches them at the bridge's LAN address instead (BRIDGE_PUBLIC_BASE, `linkBase`).
// Every live-page URL in a bridge answer is moved to `linkBase`; nothing else changes.
export function linkRewriter(linkFrom, linkBase) {
    const base = String(linkBase || '').replace(/\/+$/, '');
    const from = String(linkFrom || '').replace(/\/+$/, '');
    if (!from || !base || base === from || !/^https?:\/\/[A-Za-z0-9.-]+(:\d{1,5})?$/.test(base)) return (v) => v;
    const prefix = `${from}/live/`;
    const walk = (v) => {
        if (typeof v === 'string') return v.startsWith(prefix) ? base + v.slice(from.length) : v;
        if (Array.isArray(v)) return v.map(walk);
        if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x)]));
        return v;
    };
    return walk;
}

export function createMcpServer({ bridgeUrl, bridgeToken, write, fetchImpl = fetch, pollS = 60, upstream = null, waitMaxS = 3600, approvalWaitS = null, log = () => {}, retryMs = 30_000, metaProbe = null, secrets = null, chatPods = null, callChat = null, chatFromMeta: fromMeta = false, now = Date.now, linkFrom = null, linkBase = null }) {
    // fromMeta: every call names its chat in _meta (the LAN gateway's client); nothing else does.
    if (fromMeta) { callChat = metaCallChat(); if (chatPods) chatPods = { ...chatPods, chat: null }; }
    const relink = linkRewriter(linkFrom, linkBase);
    const inflight = new Map(); // request id -> AbortController
    // chatPods: {chat: {key, source, forkedFrom?} | null, makeUpstream(url)}. Each call then goes to its chat's
    // pod when the bridge runs pods, and to `upstream` (the shared controller) when it doesn't.
    const router = chatPods ? createChatRouter({ bridge: (p, b, s) => bridge(p, b, s), makeUpstream: chatPods.makeUpstream, chat: chatPods.chat, ...(chatPods.newKey ? { newKey: chatPods.newKey } : {}) }) : null;
    let withSession = new Set(); // local names of auto-browser tools that take a session_id
    const tools = ownTools(waitMaxS);
    // How long a call that needs the user's approval waits for it before saying "still pending".
    const approvalWait = Math.max(1, Math.min(waitMaxS, Number(approvalWaitS) || Math.min(900, waitMaxS)));
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

    // The chat a call comes from, when the MCP client names it per call (callChat). A process with
    // a chat of its own (HAPPY_SESSION_ID / CLAUDE_CODE_SESSION_ID) keeps that one. null: none.
    async function chatOfCall(meta, signal, call) {
        if (!router || !callChat || chatPods?.chat) return null;
        return await callChat(meta, signal, call);
    }

    // The chat's pod for this call, its session put into the arguments. Some tools are answered
    // here: a chat has exactly one browser session. Returns {via, args} or {done: true}.
    async function routeCall(id, name, args, signal, cc = null) {
        if (!router) return { via: null, args };
        let via;
        try {
            via = await router.route(name, args, signal, { chat: cc, check: name !== 'browser_close_session' });
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
        if (via.recovered && !READ_ONLY_TOOLS.has(name)) { result(id, toolResult(`${recoveredNote(via)} ${RECOVERED_REFUSED}`, true)); return { done: true }; }
        const routed = withSession.has(name) ? { ...args, session_id: via.session_id } : args;
        return { via, args: routed };
    }

    // browser_create_session with pods: the chat's session already exists (the pod made it,
    // signed in with the chat's saved login). Answer with it, opening start_url if given.
    async function createInPod(via, args, meta, signal) {
        if (typeof args.start_url === 'string' && args.start_url) {
            const nav = await via.upstream.callTool(mapped.byLocal.get('browser_execute_action') || 'browser.execute_action',
                { session_id: via.session_id, action: { action: 'navigate', url: args.start_url, reason: 'open start_url' } }, meta, { signal });
            if (nav.error || nav.result?.isError) return nav;
        }
        const r = await via.upstream.callTool(mapped.byLocal.get('browser_get_session') || 'browser.get_session', { session_id: via.session_id }, meta, { signal });
        if (r.result && !r.result.isError) {
            r.result = { ...r.result, content: [{ type: 'text', text: `This chat's browser session is ${via.session_id} (one per chat, kept signed in across restarts).` }, ...(r.result.content || [])] };
        }
        return r;
    }
    const refused = (err) => /ECONNREFUSED/.test(err?.message || '');

    // Shared browser (no pods): a call naming a session first asks auto-browser for it (cached a
    // couple of seconds). Nothing is recovered here. False when the refusal was written.
    const sharedSeen = new Map(); // session id -> when it last answered
    async function sharedPreflight(id, name, args, meta, signal) {
        const sid = typeof args?.session_id === 'string' && args.session_id ? args.session_id : null;
        if (!sid || !withSession.has(name) || name === 'browser_get_session' || name === 'browser_close_session') return true;
        if (now() - (sharedSeen.get(sid) ?? -Infinity) < 2000) return true;
        let r;
        try {
            r = await upstream.callTool(mapped.byLocal.get('browser_get_session') || 'browser.get_session', { session_id: sid }, meta, { signal });
        } catch (err) {
            if (signal.aborted) return false;
            if (refused(err) || /unreachable|ECONN|fetch failed/i.test(err?.message || '')) { result(id, toolResult(SHARED_DOWN, true)); return false; }
            return true;
        }
        const text = JSON.stringify(r?.result?.content ?? r?.error ?? '');
        if (r?.error || r?.result?.isError || /"status\\?":\s*\\?"(closed|interrupted)/.test(text)) {
            result(id, toolResult(`Session ${sid} is gone (${/unknown_session|No session/i.test(text) ? 'unknown session' : 'closed'}). Call browser_list_sessions to see the live ones, or browser_create_session for a new one.`, true));
            return false;
        }
        sharedSeen.set(sid, now());
        return true;
    }

    async function passThrough(id, name, args, meta, signal, cc = null, progress = () => {}) {
        if (!mapped.byLocal.has(name)) await refreshUpstream();
        const remote = mapped.byLocal.get(name);
        if (!remote) {
            if (!upstreamOk) return result(id, toolResult(`Error: ${name} is an auto-browser tool, but auto-browser is not reachable right now. Is the browser stack up?`, true));
            return error(id, -32602, `unknown tool ${name}`);
        }
        // Routing first: the secret gate and the control check both need the chat's session.
        const routedCall = await routeCall(id, name, args, signal, cc);
        if (routedCall.done) return;
        let via = routedCall.via;
        args = routedCall.args;
        if (!via && !(await sharedPreflight(id, name, args, meta, signal))) return;
        const gate = await secretsBefore(id, name, args, signal, cc);
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
                via = await router.route(name, args, signal, { verify: true, chat: cc });
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
            let out = r.result;
            // auto-browser wants the user's yes first: ask them in the live view and wait here.
            const pending = approvalRequired(out);
            if (pending) {
                const decided = await awaitApproval(pending, args, via, signal, progress, (a) => call(via, a));
                if (signal.aborted) return;
                if (decided.final) return result(id, await scrubOut(gate, decided.final, signal));
                out = decided.result;
            }
            if (via?.recovered && out && Array.isArray(out.content)) out = { ...out, content: [{ type: 'text', text: recoveredNote(via) }, ...out.content] };
            return result(id, await scrubOut(gate, await withLiveLink(name, args, out, signal, via), signal));
        } catch (err) {
            if (!signal.aborted) return result(id, toolResult(`Error: ${err.message}`, true));
        }
    }

    // The secret filler's gate (lib/secrets.mjs) around a passed-through call. Writes the refusal
    // and returns null when the call may not go ahead; the filler being down refuses too.
    async function secretsBefore(id, name, args, signal, cc = null) {
        if (!secrets) return { scrub: false };
        const ctx = secretCtx(cc);
        let g;
        try { g = { ...(await secrets.before(name, args, signal, ctx)), ctx }; } catch (err) {
            if (!signal.aborted) result(id, toolResult(`Error: ${err.message}`, true));
            return null;
        }
        if (signal.aborted) return null;
        if (g.refuse) { result(id, toolResult(g.refuse, true)); return null; }
        return g;
    }
    // A result (or error) with every filled secret replaced by [secret:<name>]. Throws if the filler can't scrub.
    const scrubOut = async (gate, value, signal) => (gate.scrub ? secrets.scrub(value, signal, gate.ctx) : value);
    // The filler's view of a call's chat: with fromMeta, the chat the call named (its Happy
    // session, else "none") and its pod; otherwise the process's own (lib/secrets.mjs).
    const secretCtx = (cc) => (fromMeta ? { chat: cc?.fillerChat ?? null, cc } : {});

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
        if (res.ok) data = relink(data);
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
    async function ownVia(args, signal, cc = null, check = false) {
        if (!router) return null;
        if (!cc && !router.chatKey && !(typeof args?.session_id === 'string' && args.session_id)) return null;
        return router.route('browser_live_link', args || {}, signal, { chat: cc, check });
    }

    async function liveLink(args, signal, cc = null) {
        const via = await ownVia(args, signal, cc, true);
        if (await endedByUser(args, signal, via)) throw new Error(USER_ENDED);
        const r = await bridge('/api/links', linkRef(String(args.session_id ?? ''), via), signal);
        return { link: r.url, status: r.status, ...(via?.recovered ? { note: recoveredNote(via) } : {}), instructions: 'Post this link in chat on its own line so the user can watch live.' };
    }

    async function waitForHuman(args, signal, progress, cc = null) {
        const timeoutS = Math.max(5, Math.min(waitMaxS, Number(args.timeout_s) || Math.min(900, waitMaxS)));
        const reason = String(args.reason ?? '').trim() || 'The agent needs you to take over.';
        const sessionId = String(args.session_id ?? '');
        const via = await ownVia(args, signal, cc);
        const ref = linkRef(sessionId, via);
        if (await endedByUser(args, signal, via)) return { status: 'ended', note: USER_ENDED };
        // The user already took control on their own: keep it theirs (no "Needs you") and wait for Release.
        const current = await bridge('/api/state', ref, signal).catch(() => null);
        // An action is waiting on the user's approval: wait for that decision, not a takeover.
        if (current?.approval?.id && current.id) {
            const aid = current.approval.id;
            const l = await bridge('/api/links', ref, signal).catch(() => null);
            const link = l?.url ?? null;
            const st = await waitApproval(current.id, aid, link, timeoutS, signal, progress);
            if (st === 'approved') return { status: 'approved', approval_id: aid, link, note: approvedRepeatNote(aid) };
            if (st === 'denied') return { status: 'denied', approval_id: aid, link, note: APPROVAL_DENIED };
            if (st === 'pending') return { status: 'timeout', approval_id: aid, link, waited_s: timeoutS, note: 'the user has not answered the approval yet; call browser_wait_for_human again to keep waiting' };
            return { status: 'done', link, note: 'the approval request is no longer pending (the browser closed or it was withdrawn); observe the page before continuing' };
        }
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
        // The bridge released it on its way down: the user may not be finished.
        if (state.reason === 'bridge_restarting') return { status: 'released', link: t.url, note: BRIDGE_RESTARTING };
        if (state.reason === 'viewer_left') return { status: 'released', link: t.url, note: VIEWER_LEFT };
        return { status: 'done', link: t.url, ...(state.reason === 'session_closed' ? { note: 'the browser session closed' } : {}) };
    }

    // ── Approvals ─────────────────────────────────────────────────────────
    // auto-browser answers a risky action (account settings, posting, payment, deleting) with
    // {status: approval_required, approval_id}. The bridge shows it to the user in the live view
    // and the app (scrubbed, with Approve and Deny), and this call waits for their answer like
    // browser_wait_for_human: approved runs the same call again with the approval, denied tells
    // the agent not to retry, and no answer in time says to keep waiting, not to repeat.
    function approvalRequired(value) {
        if (!value || typeof value !== 'object') return null;
        let p = value.structuredContent;
        if (!p || typeof p !== 'object' || p.status !== 'approval_required') {
            p = null;
            for (const c of Array.isArray(value.content) ? value.content : []) {
                if (c?.type !== 'text' || typeof c.text !== 'string' || !c.text.includes('approval_required')) continue;
                try { const j = JSON.parse(c.text); if (j?.status === 'approval_required') { p = j; break; } } catch {}
            }
        }
        const aid = p?.approval_id ?? p?.approval?.id;
        if (typeof aid !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(aid)) return null;
        const sid = typeof p?.approval?.session_id === 'string' ? p.approval.session_id : null;
        return { approvalId: aid, sessionId: sid, original: value };
    }

    // Waits on the bridge for approval `aid` of link `linkId`: approved | denied | pending | gone.
    async function waitApproval(linkId, aid, link, timeoutS, signal, progress) {
        const deadline = Date.now() + timeoutS * 1000;
        progress(0, `Waiting for the user to approve or deny this action${link ? ` at ${link}` : ' in the live view'}.`);
        let st = 'pending';
        while (Date.now() < deadline) {
            const waitS = Math.max(1, Math.min(pollS, Math.ceil((deadline - Date.now()) / 1000)));
            const r = await bridge('/api/approval/wait', { id: linkId, approval_id: aid, wait_s: waitS }, signal);
            st = r?.approval_status ?? 'gone';
            if (st !== 'pending') break;
            progress(Math.round(timeoutS - (deadline - Date.now()) / 1000), `Still waiting for the user's approval${link ? ` at ${link}` : ''}`);
        }
        return st;
    }

    // {final} to answer the call with, or {result} to go on with as the call's own result.
    async function awaitApproval(pending, args, via, signal, progress, again) {
        const sid = via?.session_id || pending.sessionId || (typeof args?.session_id === 'string' ? args.session_id : null);
        if (!sid && !via) return { result: pending.original };
        let reg;
        try {
            reg = await bridge('/api/approval', { ...linkRef(sid, via), approval_id: pending.approvalId }, signal);
        } catch (err) {
            if (signal.aborted) return { final: null };
            log(`could not show approval ${pending.approvalId} to the user: ${err.message}`);
            return { result: pending.original };
        }
        const aid = pending.approvalId;
        let st;
        try {
            st = await waitApproval(reg.id, aid, reg.url, approvalWait, signal, progress);
        } catch (err) {
            if (signal.aborted) return { final: null };
            throw err;
        }
        if (st === 'approved') {
            let r;
            try { r = await again({ ...args, approval_id: aid }); } catch (err) {
                if (signal.aborted) return { final: null };
                return { final: toolResult(`Error: the user approved the action, but running it failed: ${err.message}`, true) };
            }
            if (r?.error) return { final: toolResult(`Error: the user approved the action, but running it failed: ${r.error.message ?? 'unknown error'}`, true) };
            const out = r?.result;
            if (out && Array.isArray(out.content)) return { result: { ...out, content: [{ type: 'text', text: 'The user approved this action in the live view, and it ran.' }, ...out.content] } };
            return { result: out };
        }
        if (st === 'denied') return { final: toolResult({ status: 'denied', approval_id: aid, link: reg.url, note: APPROVAL_DENIED }, true) };
        if (st === 'pending') {
            return { final: toolResult({ status: 'approval_pending', approval_id: aid, link: reg.url, waited_s: approvalWait, note: APPROVAL_PENDING }, true) };
        }
        return { final: toolResult({ status: 'approval_gone', approval_id: aid, note: 'The approval request is no longer pending (the browser closed or the request was withdrawn). Observe the page before deciding what to do; ask the user in chat before trying this action again.' }, true) };
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
                        (secrets && secrets.configured() ? SECRET_INSTRUCTIONS : '') +
                        'When you need the user (' + (secrets && secrets.configured() ? 'a login no vault secret covers' : 'login') +
                        ', CAPTCHA, two-factor, payment, a confirmation), call browser_wait_for_human ' +
                        'and do nothing in that session until it returns. The user can also take control from the live view at ' +
                        'any time: while they have it, actions that change the page are refused, and you should call ' +
                        'browser_wait_for_human and wait until they release control. Observing and screenshots still work. ' +
                        'Some actions (changing account settings, posting, payments, deleting) need the user\'s approval: the call ' +
                        'then waits while the user is asked to Approve or Deny in the live view, and runs once they approve. If it ' +
                        'comes back denied, do not retry; if it comes back approval_pending, do not repeat it: tell the user an ' +
                        'approval is waiting and call browser_wait_for_human.',
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
                    // Behind the gateway every call names its chat; one that doesn't goes nowhere.
                    const cc = fromMeta ? await callChat(params?._meta)
                        : name === 'browser_live_link' || name === 'browser_wait_for_human' || (upstream && !(secrets && secrets.isOwn(name)))
                            ? await chatOfCall(params?._meta, ac.signal, { name, args: params?.arguments ?? {} }) : null;
                    if (cc?.unknown && fromMeta) return result(id, toolResult(`Error: ${NO_CHAT}`, true));
                    const meta = withoutChatMeta(params?._meta);
                    let out;
                    if (name === 'browser_live_link') out = await liveLink(args, ac.signal, cc);
                    else if (name === 'browser_wait_for_human') out = await waitForHuman(args, ac.signal, progress, cc);
                    else if (secrets && secrets.isOwn(name)) {
                        // A fill or login types into the page: not into a browser that was just restarted.
                        if (router && (name === 'browser_fill_secret' || name === 'browser_login')) {
                            const via = await ownVia(args, ac.signal, cc, true);
                            if (via?.recovered) return result(id, toolResult(`${recoveredNote(via)} ${RECOVERED_REFUSED}`, true));
                        }
                        out = await secrets.callOwn(name, args, ac.signal, secretCtx(cc));
                    }
                    else if (upstream) return await passThrough(id, name, args, meta, ac.signal, cc, progress);
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
    // Behind the LAN gateway each call names its chat in _meta; the environment names none.
    const fromMeta = chatFromMeta();
    const ident = fromMeta ? null : chatIdentity();
    const forkedFrom = fromMeta ? null : forkParentKey(process.env, ident);
    const makeUpstream = (url) => createUpstreamMcp({
        url,
        getToken: () => readSecret(cfg.files.apiToken),
        timeoutMs: cfg.passthroughTimeoutS * 1000,
        onNotification: (m) => { if (m.method === 'notifications/progress') write(m); },
    });
    let podPort = (_args, _cc) => null;
    const server = createMcpServer({
        bridgeUrl: cfg.bridgeUrl,
        linkFrom: `http://localhost:${cfg.port}`,
        linkBase: cfg.publicBase,
        bridgeToken: readSecret(cfg.files.bridgeToken),
        write,
        upstream,
        chatPods: upstream ? { chat: ident ? { key: chatKeyOf(ident), source: ident.source, ...(forkedFrom ? { forkedFrom } : {}) } : null, makeUpstream } : null,
        // Happy Agent (one process for all its chats): BRIDGE_AGENT_DB is the daemon's agent.sqlite,
        // and each call's chat is looked up there: by the call id in _meta, else by the daemon's
        // journal record of this very call (see callChatResolver).
        // BRIDGE_AGENT_SSH: the host that daemon runs on, when it reaches this process over ssh.
        callChat: fromMeta ? null : agentCallChat(ident, process.env, log),
        chatFromMeta: fromMeta,
        waitMaxS: cfg.waitMaxS,
        log,
        metaProbe: createMetaProbe(),
        secrets: createSecretGate({
            fillerUrl: cfg.fillerUrl,
            tokenPath: cfg.files.fillerToken,
            chat: fromMeta ? null : process.env.HAPPY_SESSION_ID || null,
            // The chat's pod when pods are on, else the shared controller.
            controllerPort: (args, cc) => podPort(args, cc) ?? cfg.autoBrowserPort,
        }),
    });
    podPort = (args, cc) => server.router?.apiPortFor(args, cc) ?? null;
    const rl = createInterface({ input: process.stdin });
    rl.on('line', (l) => server.onLine(l));
    rl.on('close', () => process.exit(0));
}
