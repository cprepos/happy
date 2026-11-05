// The bridge's side of the secret filler (selfhost/browser/filler). The agent
// gets three tools that work by name only:
//   browser_list_secrets()                         names, hosts and kinds
//   browser_fill_secret(session_id, element_id, name)
//   browser_login(session_id, site)
// The filler types the value itself; nothing here ever holds one.
//
// Around every auto-browser tool call this module also:
//   - always refuses totp_secret / totp_hosts (auto-browser's own TOTP store
//     would hand the agent a secret);
//   - while a session holds a filled secret, refuses calls that could read it
//     back (eval_js, raw HTML, value selectors, fork, saving auth, copy/cut
//     keys, non-http(s) navigation);
//   - scrubs every result through the filler while anything is tainted, so a
//     value that turns up (OCR, page text, an echoed form) reads [secret:<name>].
//
// The chat comes from the process environment (HAPPY_SESSION_ID, set by the
// Happy CLI for its MCP children), never from tool arguments. A process without
// one (a Happy Agent daemon serving many chats) names the chat "none": the
// filler serves that only when its policy has a default_client, and refuses it
// otherwise. The tools are listed either way; the filler decides. When the
// filler's client token exists but the filler cannot be reached, browser calls
// fail closed.
import { existsSync, readFileSync } from 'node:fs';

export const SECRET_TOOLS = [
    {
        name: 'browser_list_secrets',
        description:
            'List the vault secrets this chat may have typed into the browser: names like "github.password", the hosts each one ' +
            'is allowed on, and its kind (username, password or totp). Values are never shown to you. Use it proactively: call ' +
            'it as soon as a page asks you to sign in, before asking the user anything or calling browser_wait_for_human. ' +
            'If a login\'s hosts include the page\'s host, use browser_login (or browser_fill_secret) and carry on; if ' +
            'several match, ask the user which login to use. Never ask the user to type a password in chat.',
        inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    },
    {
        name: 'browser_fill_secret',
        description:
            'Type one vault secret into a field, by name (from browser_list_secrets). The value is typed by the secret filler and ' +
            'never shown to you. The page must be on one of the secret\'s hosts and the element must be a field of the right kind ' +
            '(a password into a password field, and so on). Get element_id from browser_observe. Returns {ok, kind, host}. After a ' +
            'fill, the session is marked: tools that could read the value back (eval_js, raw HTML, copy) are refused, and any ' +
            'copy of the value in a result reads [secret:<name>].',
        inputSchema: {
            type: 'object',
            properties: {
                session_id: { type: 'string', description: 'The browser session id.' },
                element_id: { type: 'string', description: 'The field\'s element_id from browser_observe.' },
                name: { type: 'string', description: 'The secret, e.g. "github.password".' },
            },
            required: ['session_id', 'element_id', 'name'],
            additionalProperties: false,
        },
    },
    {
        name: 'browser_login',
        description:
            'Log in to a site with its vault login (the part before the dot in browser_list_secrets, e.g. "github"). The secret ' +
            'filler finds the username, password and one-time-code fields on the current page itself, types them and submits. ' +
            'Use it proactively: when a sign-in page matches a login from browser_list_secrets, call this yourself and carry on ' +
            'with the task, without asking the user first. Navigate to the login page first. Returns {status: "submitted" | ' +
            '"totp_submitted" | "needs_human", host}. On needs_human (a CAPTCHA, an unusual page, a phone or SMS second ' +
            'factor), call browser_wait_for_human. A refusal because the page is on another host names the page\'s host and ' +
            'the hosts the login allows: tell the user which URI to add to the vault item, or navigate to an allowed host. ' +
            'Observe the page afterwards to check.',
        inputSchema: {
            type: 'object',
            properties: {
                session_id: { type: 'string', description: 'The browser session id.' },
                site: { type: 'string', description: 'The login, e.g. "github".' },
            },
            required: ['session_id', 'site'],
            additionalProperties: false,
        },
    },
];
export const SECRET_TOOL_NAMES = new Set(SECRET_TOOLS.map((t) => t.name));

const COPY_KEYS = new Set(['control+c', 'ctrl+c', 'meta+c', 'cmd+c', 'command+c', 'control+x', 'ctrl+x', 'meta+x', 'cmd+x', 'command+x',
    'control+insert', 'ctrl+insert', 'shift+delete', 'control+shift+c', 'ctrl+shift+c', 'meta+shift+c']);
const VALUE_SELECTOR = /\[\s*value\b|:has\(.*value|::?(?:-webkit-)?autofill|\bvalue\s*[~|^$*]?=/i;

const TAINT_REFUSAL = 'Refused: a vault secret was typed into this browser, so tools that could read it back are off for this session. ' +
    'Use browser_observe, browser_find_elements or browser_get_html with text_only=true instead.';

/** Why a call is refused before it reaches auto-browser, or null. `tainted` says whether its session holds a secret. */
export function refusal(name, args, tainted) {
    const a = args && typeof args === 'object' ? args : {};
    if ('totp_secret' in a || 'totp_hosts' in a) return 'Refused: totp_secret and totp_hosts are not allowed. Store the TOTP in the vault and use browser_login or browser_fill_secret.';
    if (!tainted) return null;
    switch (name) {
        case 'browser_eval_js': case 'browser_fork_session': case 'browser_save_auth_profile':
            return TAINT_REFUSAL;
        case 'browser_get_html':
            return a.text_only === true ? null : TAINT_REFUSAL;
        case 'browser_find_elements': case 'browser_wait_for_selector':
            return VALUE_SELECTOR.test(JSON.stringify(a)) ? TAINT_REFUSAL : null;
        case 'browser_execute_action': {
            const act = a.action && typeof a.action === 'object' ? a.action : {};
            if (act.action === 'press' && typeof act.key === 'string' && COPY_KEYS.has(act.key.toLowerCase().replace(/\s+/g, ''))) return TAINT_REFUSAL;
            if (act.action === 'navigate') {
                let scheme = null;
                try { scheme = new URL(String(act.url)).protocol; } catch {}
                if (scheme !== 'https:' && scheme !== 'http:') return TAINT_REFUSAL;
            }
            return null;
        }
        default:
            return null;
    }
}

/** The X-Happy-Chat of a process with no chat id. Must match NO_CHAT in filler/lib/policy.mjs. */
export const NO_CHAT = 'none';

export function createSecretGate({ fillerUrl, tokenPath, chat = null, fetchImpl = fetch, controllerPort = () => null, timeoutMs = 120_000 }) {
    const base = String(fillerUrl).replace(/\/+$/, '');
    const configured = () => existsSync(tokenPath);
    const token = () => readFileSync(tokenPath, 'utf8').trim();

    async function call(path, body, signal) {
        const headers = { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json', 'X-Happy-Chat': chat || NO_CHAT };
        let res;
        try {
            res = await fetchImpl(base + path, { method: 'POST', headers, body: JSON.stringify(body), signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)]) : AbortSignal.timeout(timeoutMs) });
        } catch (err) {
            if (signal?.aborted) throw err;
            throw new Error('the secret filler is not reachable, so browser tools are off until it is back (make filler-status)');
        }
        let data = null;
        try { data = await res.json(); } catch {}
        if (!res.ok) throw new Error(data?.error ? `secret filler: ${data.error}` : `secret filler: HTTP ${res.status}`);
        return data;
    }
    const port = (args) => { const p = controllerPort(args); return Number.isInteger(p) ? { controller_port: p } : {}; };
    const sid = (args) => (typeof args?.session_id === 'string' && args.session_id ? args.session_id : null);

    return {
        configured,
        tools: () => (configured() ? SECRET_TOOLS : []),
        isOwn: (name) => SECRET_TOOL_NAMES.has(name),

        /** Run one of the three tools. Returns the filler's JSON answer; throws with a message for the agent. */
        async callOwn(name, args, signal) {
            if (!configured()) throw new Error('vault secrets are not set up on this machine (make filler-init)');
            const a = args || {};
            if (name === 'browser_list_secrets') return call('/v1/list', {}, signal);
            if (name === 'browser_fill_secret') return call('/v1/fill', { session_id: String(a.session_id ?? ''), element_id: String(a.element_id ?? ''), name: String(a.name ?? ''), ...port(a) }, signal);
            if (name === 'browser_login') return call('/v1/login', { session_id: String(a.session_id ?? ''), site: String(a.site ?? ''), ...port(a) }, signal);
            throw new Error(`unknown tool ${name}`);
        },

        /**
         * Before an auto-browser call. Returns {refuse, scrub}: refuse is a message
         * for the agent or null; scrub says the result must go through /v1/scrub
         * (always, once the filler is set up: a fill may land while this call runs).
         */
        async before(name, args, signal) {
            const always = refusal(name, args, false);
            if (always) return { refuse: always, scrub: false };
            if (!configured()) return { refuse: null, scrub: false };
            const s = await call('/v1/session', { ...(sid(args) ? { session_id: sid(args) } : {}), ...port(args) }, signal);
            const tainted = sid(args) ? !!s?.tainted || (!!s?.any_tainted && name === 'browser_fork_session') : !!s?.any_tainted;
            return { refuse: refusal(name, args, tainted), scrub: true };
        },

        /** Scrub a result (or error) with the values of every tainted session. */
        async scrub(payload, signal) {
            const r = await call('/v1/scrub', { payload }, signal);
            return r?.payload;
        },
    };
}
