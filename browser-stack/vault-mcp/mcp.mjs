#!/usr/bin/env node
// happy-vault-mcp: the agents' vault tools (stdio, newline-delimited JSON-RPC
// 2.0). Every agent vault interaction goes through these eight tools, one
// strict function per action, each a thin client of the secret filler's
// POST /v1/vault/<action> on 127.0.0.1:6091 with the vault-client token
// (~/.local/share/happy-vault-mcp/secrets/vault-client-token, written by
// make filler-token-issue NAME=vault-client and make filler-token-take; a different token from the browser bridge's).
//
// No tool returns a password, TOTP or custom field value. New passwords are generated in
// the filler. vault_compare answers match or no match. vault_pipe is the one
// call where a value reaches this process: lib/pipe.mjs writes it to an
// allowlisted command's stdin and returns only the scrubbed output.
// vault_remove is a soft delete to the vault trash; there is no purge.
import { readFileSync, realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { runPipe, scrubValue } from './lib/pipe.mjs';
import { chatFromMeta, chatOfMeta, fillerChatOf } from '../identity/chatmeta.mjs';

const PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05'];
const SERVER_INFO = { name: 'happy-vault', version: '1.0.0' };
export const NO_CHAT = 'none'; // must match NO_CHAT in browser/filler/lib/policy.mjs
// Behind the LAN gateway (fromMeta): a call whose _meta names no chat goes nowhere.
export const NO_META_CHAT = 'this vault call could not be matched to its chat, so it was not sent to the vault. Try it again.';

const ID = { type: 'string', pattern: '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', description: 'The login\'s id, from vault_list or vault_search.' };
const NAME = { type: 'string', minLength: 1, maxLength: 100, description: 'The login\'s name in the vault. Its slug becomes the fill name browser_login and browser_fill_secret use.' };
const URIS = { type: 'array', minItems: 1, maxItems: 10, items: { type: 'string', minLength: 9, maxLength: 2048, pattern: '^https://' }, description: 'The https URLs the login is for (no user name or password in them). Logins fill only on these hosts.' };
const USERNAME = { type: 'string', minLength: 1, maxLength: 256, description: 'The account\'s user name or email.' };
const SPEC = {
    type: 'object',
    description: 'How to generate the password (it is always random, made inside the filler, and never shown). Default: 32 characters from every class.',
    properties: {
        length: { type: 'integer', minimum: 16, maximum: 128, description: 'Length, 16..128 (default 32).' },
        classes: { type: 'array', minItems: 1, maxItems: 4, items: { type: 'string', enum: ['lower', 'upper', 'digits', 'symbols'] }, description: 'Character classes; one of each is guaranteed (default all four).' },
        exclude: { type: 'string', maxLength: 64, description: 'Characters a site refuses, left out.' },
    },
    additionalProperties: false,
};
const FIELD = { type: 'string', enum: ['username', 'password', 'totp'], description: 'Which value of the login: username, password, or totp (the stored TOTP seed or otpauth URI, not a current code). Give this or custom_field, not both.' };
const CUSTOM_FIELD = { type: 'string', minLength: 1, maxLength: 64, pattern: '^[A-Za-z0-9 _.-]{1,64}$', description: 'The exact, case-sensitive name of one of the login\'s custom fields, as vault_list shows it in custom_fields (for example "token"). Give this or field, not both.' };
// compare and pipe take exactly one of these (checked in checkArgs; not in the schema, since
// tool schemas may not use a top-level oneOf).
const ONE_OF = ['field', 'custom_field'];
const TRASH = { type: 'boolean', description: 'Also list logins in the vault trash (default false).' };
const obj = (properties, required = [], exactlyOne = null) => {
    const s = { type: 'object', properties, required, additionalProperties: false };
    if (exactlyOne) Object.defineProperty(s, 'exactlyOne', { value: exactlyOne, enumerable: false }); // not sent in tools/list
    return s;
};

export const TOOLS = [
    {
        name: 'vault_list',
        description: 'List the vault logins this chat may use: id, name, fill name (secret), username, URIs, hosts, which fields are set, custom_fields (the names of the login\'s custom fields you may use with vault_pipe and vault_compare), revision date, trashed. Never a password, TOTP or custom field value.',
        inputSchema: obj({ include_trash: TRASH }),
    },
    {
        name: 'vault_search',
        description: 'Like vault_list, filtered to logins whose name, username or host contains the query (case-insensitive).',
        inputSchema: obj({ query: { type: 'string', minLength: 1, maxLength: 200, description: 'Text to look for.' }, include_trash: TRASH }, ['query']),
    },
    {
        name: 'vault_create',
        description: 'Create a vault login with a new random password generated inside the filler. You never see or choose the password: to use it, sign in with browser_login, or set it on the site with browser_fill_secret (field password) on the sign-up or change-password form. Returns the new login\'s metadata.',
        inputSchema: obj({ name: NAME, uris: URIS, username: USERNAME, password: SPEC }, ['name', 'uris', 'username']),
    },
    {
        name: 'vault_update',
        description: 'Change a login: rename it, replace its URIs or username, or rotate_password to a new random password generated inside the filler (the old one is kept in the item\'s password history). Give at least one change. Rotate in the vault first, then type the new one into the site\'s change-password form with browser_fill_secret. Returns metadata and the names of the fields changed.',
        inputSchema: obj({ id: ID, name: NAME, uris: URIS, username: USERNAME, rotate_password: SPEC }, ['id']),
    },
    {
        name: 'vault_remove',
        description: 'Move a login to the vault trash (a soft delete). It stays recoverable with vault_restore; nothing is ever purged.',
        inputSchema: obj({ id: ID }, ['id']),
    },
    {
        name: 'vault_restore',
        description: 'Bring a login back from the vault trash. Find its id with vault_list include_trash: true.',
        inputSchema: obj({ id: ID }, ['id']),
    },
    {
        name: 'vault_compare',
        description: 'Check whether a login\'s value matches a hash you have (from a config file, a database row, a leak list). Answers {match: true|false} only; the value and its hash never come back. algo: sha256 or sha512 (hex digest of salt + value; salt optional), bcrypt ($2a$/$2b$/$2y$ string), argon2 (PHC string $argon2id$...). Rate limited per login. Give field or custom_field.',
        inputSchema: obj({
            id: ID, field: FIELD, custom_field: CUSTOM_FIELD,
            algo: { type: 'string', enum: ['sha256', 'sha512', 'bcrypt', 'argon2'] },
            digest: { type: 'string', minLength: 1, maxLength: 512, description: 'The hash to check against.' },
            salt: { type: 'string', maxLength: 256, description: 'sha256/sha512 only: a prefix hashed before the value.' },
        }, ['id', 'algo', 'digest'], ONE_OF),
    },
    {
        name: 'vault_pipe',
        description: 'Feed a login\'s value to the standard input of a command the vault owner allowlisted (the filler policy\'s pipe_targets, for example docker-login or gh-auth), for logging a CLI in without the value ever appearing in chat, arguments or files. Returns the command\'s exit code and output, with the value scrubbed out. Targets your client may not use are refused; the refusal lists the allowed ones. Give field (username, password, totp) or custom_field (a name from vault_list custom_fields, such as token); in the output the value shows as [secret:<field or custom field name>].',
        inputSchema: obj({
            id: ID, field: FIELD, custom_field: CUSTOM_FIELD,
            target: { type: 'string', minLength: 1, maxLength: 64, pattern: '^[a-z0-9][a-z0-9_-]*$', description: 'The pipe target\'s name.' },
            args: { type: 'object', additionalProperties: { type: 'string', maxLength: 256 }, description: 'Values for the target\'s {arg:slot} placeholders, each checked against the target\'s pattern.' },
        }, ['id', 'target'], ONE_OF),
    },
];
const TOOL_BY_NAME = new Map(TOOLS.map((t) => [t.name, t]));

export const INSTRUCTIONS =
    'The vault tools (vault_*) are the only way to use the vault: listing, creating, changing, trashing and restoring ' +
    'logins, comparing a stored value against a hash, and piping a value into an allowlisted command. Do not use the bw ' +
    'CLI, the Vaultwarden API, the filler\'s files or docker, and never ask the user to paste a password in chat. New ' +
    'passwords are always generated inside the filler; you never see one. To sign in on a web page use the browser ' +
    'tools (browser_login, browser_fill_secret), which fill vault logins by name. vault_remove only moves a login to the ' +
    'trash, and vault_restore brings it back.';

/** A small JSON-schema check of exactly what TOOLS uses. Returns an error message or null. */
export function checkArgs(schema, v, at = 'arguments') {
    const t = schema.type;
    if (t === 'object') {
        if (!v || typeof v !== 'object' || Array.isArray(v)) return `${at} must be an object`;
        const props = schema.properties || {};
        for (const k of schema.required || []) if (!Object.hasOwn(v, k)) return `${at}.${k} is required`;
        if (schema.exactlyOne && schema.exactlyOne.filter((k) => Object.hasOwn(v, k)).length !== 1) return `${at}: give exactly one of ${schema.exactlyOne.join(', ')}`;
        for (const [k, x] of Object.entries(v)) {
            const sub = Object.hasOwn(props, k) ? props[k] : schema.additionalProperties;
            if (sub === false || sub === undefined) return `${at}: unknown key ${JSON.stringify(k).slice(0, 40)} (allowed: ${Object.keys(props).join(', ') || 'none'})`;
            if (sub !== true) { const e = checkArgs(sub, x, `${at}.${k}`); if (e) return e; }
        }
        return null;
    }
    if (t === 'array') {
        if (!Array.isArray(v)) return `${at} must be a list`;
        if (schema.minItems !== undefined && v.length < schema.minItems) return `${at} needs at least ${schema.minItems} item(s)`;
        if (schema.maxItems !== undefined && v.length > schema.maxItems) return `${at} takes at most ${schema.maxItems} item(s)`;
        for (let i = 0; i < v.length; i++) { const e = checkArgs(schema.items, v[i], `${at}[${i}]`); if (e) return e; }
        return null;
    }
    if (t === 'string') {
        if (typeof v !== 'string') return `${at} must be a string`;
        if (schema.minLength !== undefined && v.length < schema.minLength) return `${at} is too short`;
        if (schema.maxLength !== undefined && v.length > schema.maxLength) return `${at} is too long`;
        if (schema.pattern && !new RegExp(schema.pattern).test(v)) return `${at} is not in the expected form`;
        if (schema.enum && !schema.enum.includes(v)) return `${at} must be one of ${schema.enum.join(', ')}`;
        return null;
    }
    if (t === 'integer') {
        if (!Number.isInteger(v)) return `${at} must be an integer`;
        if (v < schema.minimum || v > schema.maximum) return `${at} must be ${schema.minimum}..${schema.maximum}`;
        return null;
    }
    if (t === 'boolean') return typeof v === 'boolean' ? null : `${at} must be true or false`;
    return `${at}: unsupported schema`;
}

export function defaultHome(env = process.env) {
    return env.BROWSER_VAULT_MCP_HOME || env.HAPPY_VAULT_MCP_HOME || join(homedir(), '.local', 'share', 'happy-vault-mcp');
}

// fromMeta (BROWSER_CHAT_FROM_META=1, the operator's env only): agentgateway runs one process for
// many chats, and each call's chat is the one the Mac's gateway client put in
// _meta["browserstack/chat"] (browser-stack/identity/chatmeta.mjs), never the tool arguments. The
// filler hears its Happy session id, else "none", as it would from HAPPY_SESSION_ID.
export function createVaultMcp({ fillerUrl = 'http://127.0.0.1:6091', tokenPath, readToken, chat = null, fromMeta = false, write, fetchImpl = fetch, pipe = runPipe, timeoutMs = 120_000 }) {
    const base = fillerUrl.replace(/\/+$/, '');
    const token = readToken || (() => {
        let t;
        try { t = readFileSync(tokenPath, 'utf8').trim(); } catch { t = ''; }
        if (!t) throw new Error('the vault tools are not set up on this machine (no vault-client token; the user runs make filler-token-issue NAME=vault-client as happy-filler, then make filler-token-take)');
        return t;
    });
    const inflight = new Map();
    const result = (id, r) => write({ jsonrpc: '2.0', id, result: r });
    const error = (id, code, message) => write({ jsonrpc: '2.0', id, error: { code, message } });
    const toolResult = (out, isError = false) => ({
        content: [{ type: 'text', text: typeof out === 'string' ? out : JSON.stringify(out, null, 2) }],
        ...(isError ? { isError: true } : {}),
    });

    async function filler(action, body, signal, who = chat) {
        const headers = { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json', 'X-Happy-Chat': who || NO_CHAT, 'X-Client-Chat': who || NO_CHAT };
        const sig = signal ? AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)]) : AbortSignal.timeout(timeoutMs);
        let res;
        try {
            res = await fetchImpl(`${base}/v1/vault/${action}`, { method: 'POST', headers, body: JSON.stringify(body), signal: sig });
        } catch (err) {
            if (signal?.aborted) throw err;
            throw new Error(`the secret filler is not reachable (${err.cause?.code || err.name}); the user checks make filler-status`);
        }
        let data = null;
        try { data = await res.json(); } catch {}
        if (!res.ok) throw new Error(data?.error ? `vault: ${data.error}` : `vault: HTTP ${res.status}`);
        return data;
    }

    async function call(name, args, signal, who = chat) {
        const tool = TOOL_BY_NAME.get(name);
        const bad = checkArgs(tool.inputSchema, args);
        if (bad) throw new Error(bad);
        const action = name.slice('vault_'.length);
        if (action !== 'pipe') return filler(action, args, signal, who);
        const got = await filler('pipe', args, signal, who);
        // The scrub label: the field, or the custom field's name ("[secret:token]").
        const label = `${args.custom_field ?? args.field}`;
        let value = typeof got?.value === 'string' ? got.value : '';
        try {
            const run = await pipe({ argv: got?.argv, value, label });
            // Scrubbed again as a whole, in case a form of the value crossed fields.
            const out = { target: got.target, argv: got.argv, ...run };
            return JSON.parse(scrubValue(JSON.stringify(out), value, label));
        } finally {
            if (got) got.value = null;
            value = null;
        }
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
                    instructions: INSTRUCTIONS,
                });
            }
            case 'ping':
                return isRequest && result(id, {});
            case 'tools/list':
                return result(id, { tools: TOOLS });
            case 'tools/call': {
                const name = params?.name;
                if (!TOOL_BY_NAME.has(name)) return error(id, -32602, `unknown tool ${String(name).slice(0, 64)}`);
                let who = chat;
                if (fromMeta) {
                    const c = chatOfMeta(params?._meta);
                    if (!c) return result(id, toolResult(`Error: ${NO_META_CHAT}`, true));
                    who = fillerChatOf(c);
                }
                const ac = new AbortController();
                inflight.set(id, ac);
                try {
                    const out = await call(name, params?.arguments ?? {}, ac.signal, who);
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

// Run as a program, also through a symlink (selfhost/browser and selfhost/vault-mcp point here).
const isMain = (() => { try { return import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href; } catch { return false; } })();
if (isMain) {
    const server = createVaultMcp({
        fillerUrl: process.env.BROWSER_VAULT_FILLER_URL || process.env.HAPPY_VAULT_FILLER_URL || 'http://127.0.0.1:6091',
        tokenPath: join(defaultHome(), 'secrets', 'vault-client-token'),
        // Behind the LAN gateway each call names its chat in _meta; the environment names none.
        chat: chatFromMeta() ? null : process.env.HAPPY_SESSION_ID || null,
        fromMeta: chatFromMeta(),
        write: (obj) => process.stdout.write(JSON.stringify(obj) + '\n'),
    });
    const rl = createInterface({ input: process.stdin });
    rl.on('line', (l) => server.onLine(l));
    rl.on('close', () => process.exit(0));
}
