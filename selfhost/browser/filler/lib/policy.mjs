// policy.json: which chat belongs to which client, and which vault items each
// client's agent may have typed, for which fields and hosts.
//
//   { "version": 1,
//     "clients": { "acme": { "secrets": { "github": { "item_id": "<cipher uuid>",
//                                                     "hosts": ["github.com"],
//                                                     "fields": ["username", "password", "totp"] } } } },
//     "chats": { "<happy session id>": "acme" },
//     "default_client": "acme" }          // optional
//
// default_client is an explicit opt-in: a chat with no entry in chats uses that
// client, and so does a caller that has no chat id at all (it names the chat
// NO_CHAT, "none", which may never be a key in chats). Without default_client
// an unmapped chat reaches nothing, as before. A mapped chat always uses its
// own client.
//
// The items live in the agent account's personal vault (no organization), so
// this file is the only thing that separates clients: a chat reaches only the
// item ids its client lists, and an item id may be listed by one client only.
// The file must be owned by root and writable by nobody else (it lives at
// /srv/happy-filler/policy.json, root:1990 0640): uid 1000 code, which the agent
// runs as, can never rebind a chat or widen a secret. A malformed policy fails
// the whole load; nothing is guessed.
import { lstatSync, readFileSync } from 'node:fs';
import { normalizeHost } from './hosts.mjs';

export class PolicyError extends Error {}

export const FIELDS = ['username', 'password', 'totp'];
const SLUG = /^[a-z0-9][a-z0-9_-]{0,62}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CHAT = /^[A-Za-z0-9_.:-]{1,200}$/;
/** The chat a caller with no chat id names. Only default_client can serve it. */
export const NO_CHAT = 'none';
const TOP_KEYS = new Set(['version', 'clients', 'chats', 'default_client']);

export function checkPolicyFile(path, { requireRoot = true } = {}) {
    let st;
    try { st = lstatSync(path); } catch { throw new PolicyError(`policy file ${path} missing`); }
    if (!st.isFile()) throw new PolicyError('policy file must be a regular file (not a symlink)');
    if (requireRoot && st.uid !== 0) throw new PolicyError('policy file must be owned by root');
    if (st.mode & 0o022) throw new PolicyError('policy file must not be group- or world-writable');
}

export function parsePolicy(json) {
    let raw;
    try { raw = typeof json === 'string' ? JSON.parse(json) : json; } catch { throw new PolicyError('policy is not valid JSON'); }
    if (!raw || raw.version !== 1 || typeof raw.clients !== 'object' || raw.clients === null) throw new PolicyError('policy needs version 1 and clients');
    const extraTop = Object.keys(raw).filter((k) => !TOP_KEYS.has(k));
    if (extraTop.length) throw new PolicyError(`unknown top-level key ${JSON.stringify(extraTop[0]).slice(0, 40)}`);
    const clients = new Map();
    const seenItems = new Map();
    for (const [slug, c] of Object.entries(raw.clients)) {
        if (!SLUG.test(slug)) throw new PolicyError(`bad client slug ${JSON.stringify(slug).slice(0, 70)}`);
        if (!c || typeof c !== 'object' || Array.isArray(c)) throw new PolicyError(`client ${slug}: must be an object`);
        if ('org_id' in c || 'collection_id' in c) throw new PolicyError(`client ${slug}: org_id and collection_id are no longer used (the items are in the agent account's own vault); remove them`);
        const extra = Object.keys(c).filter((k) => k !== 'secrets');
        if (extra.length) throw new PolicyError(`client ${slug}: unknown key ${JSON.stringify(extra[0]).slice(0, 40)}`);
        if (c.secrets !== undefined && (typeof c.secrets !== 'object' || c.secrets === null || Array.isArray(c.secrets))) throw new PolicyError(`client ${slug}: secrets must be an object`);
        const secrets = new Map();
        for (const [name, s] of Object.entries(c.secrets || {})) {
            if (!SLUG.test(name)) throw new PolicyError(`client ${slug}: bad secret name`);
            if (!s || !UUID.test(s.item_id || '')) throw new PolicyError(`${slug}.${name}: item_id must be a uuid`);
            const item = s.item_id.toLowerCase();
            if (seenItems.has(item)) throw new PolicyError(`${slug}.${name}: item already used by ${seenItems.get(item)}`);
            seenItems.set(item, `${slug}.${name}`);
            const hosts = (Array.isArray(s.hosts) ? s.hosts : []).map((h) => {
                const n = normalizeHost(h);
                if (!n) throw new PolicyError(`${slug}.${name}: bad host`);
                return n;
            });
            if (!hosts.length) throw new PolicyError(`${slug}.${name}: needs at least one host`);
            const fields = Array.isArray(s.fields) ? s.fields : [];
            if (!fields.length || fields.some((f) => !FIELDS.includes(f))) throw new PolicyError(`${slug}.${name}: fields must be some of ${FIELDS.join(', ')}`);
            secrets.set(name, Object.freeze({ item_id: item, hosts: Object.freeze(hosts), fields: Object.freeze([...new Set(fields)]) }));
        }
        clients.set(slug, Object.freeze({ secrets }));
    }
    const chats = new Map();
    for (const [chat, slug] of Object.entries(raw.chats || {})) {
        if (!CHAT.test(chat)) throw new PolicyError('bad chat id in chats');
        if (chat === NO_CHAT) throw new PolicyError(`"${NO_CHAT}" is reserved for callers with no chat id; use default_client instead`);
        if (!clients.has(slug)) throw new PolicyError(`chat bound to unknown client ${String(slug).slice(0, 64)}`);
        chats.set(chat, slug);
    }
    let defaultClient = null;
    if (raw.default_client !== undefined) {
        if (typeof raw.default_client !== 'string' || !clients.has(raw.default_client)) throw new PolicyError(`default_client ${JSON.stringify(raw.default_client)?.slice(0, 64)} is not a client in clients`);
        defaultClient = raw.default_client;
    }
    return createPolicy(clients, chats, defaultClient);
}

function createPolicy(clients, chats, defaultClient) {
    const scopeOf = (chat) => {
        if (typeof chat !== 'string' || !chat) return null;
        if (chat !== NO_CHAT && chats.has(chat)) return { client: chats.get(chat), path: 'mapped' };
        return defaultClient ? { client: defaultClient, path: 'default' } : null;
    };
    return Object.freeze({
        clients: () => [...clients.keys()],
        client: (slug) => clients.get(slug) || null,
        /** The client default_client names, or null when the policy has none. */
        defaultClient: () => defaultClient,
        /** The client a chat is bound to, else default_client, else null. */
        clientForChat: (chat) => scopeOf(chat)?.client ?? null,
        /** {client, path: 'mapped' | 'default'} for a chat, or null. */
        scopeOf,
        /** Every fillable name for a client: [{name: "github.password", secret, field, item_id, hosts}]. */
        entries(slug) {
            const c = clients.get(slug);
            if (!c) return [];
            const out = [];
            for (const [secret, s] of c.secrets) for (const field of s.fields) out.push({ name: `${secret}.${field}`, secret, field, item_id: s.item_id, hosts: s.hosts });
            return out;
        },
        /** One name ("github.password") for a client, or null. */
        resolve(slug, name) {
            const m = /^([a-z0-9][a-z0-9_-]{0,62})\.(username|password|totp)$/.exec(String(name ?? ''));
            const s = m && clients.get(slug)?.secrets.get(m[1]);
            if (!s || !s.fields.includes(m[2])) return null;
            return { name: `${m[1]}.${m[2]}`, secret: m[1], field: m[2], item_id: s.item_id, hosts: s.hosts };
        },
        /** A secret ("github") with every field it allows. */
        secret(slug, secret) {
            const s = clients.get(slug)?.secrets.get(String(secret ?? ''));
            return s ? { secret, ...s } : null;
        },
    });
}

export function loadPolicy(path, opts = {}) {
    checkPolicyFile(path, opts);
    return parsePolicy(readFileSync(path, 'utf8'));
}
