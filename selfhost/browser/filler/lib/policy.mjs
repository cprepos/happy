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
// A client may also say "all_items": true: every login in the agent account's
// personal vault that no client lists by item_id may then be used by that
// client, under a name made from the item's name ("GitHub (work)" ->
// "github-work"), with the fields username, password and totp, and only on
// the https hosts of the item's own saved URIs (exact match, as for hosts). An
// item with no https URI cannot be used. Names the client lists in secrets
// take precedence, and an item some client lists by item_id never appears
// under all_items, so its own hosts and fields keep applying. At most one
// client may set all_items.
//
// An all_items login also honours the vault's equivalent domains, as the
// Bitwarden extension does: a login saved for www.gmail.com fills on
// accounts.google.com, since gmail.com and google.com are one group (the
// account's own groups and the global ones it has not excluded; see
// domains.mjs). Only on https pages, and only for URIs with the default match
// detection. "equivalent_domains": false on the client turns that off, so its
// logins fill only on their exact saved hosts. Explicit secrets entries never
// use equivalence: their hosts list is the operator's precise choice, and
// widening it from vault data the agent account can edit would undo it.
//
// "manage" lets a client's agents change the vault through /v1/vault/* (the
// vault-mcp tools, with the vault-client-token): {"create": true, "update":
// true, "remove": true, "compare": true, "pipe": ["docker-login"]}. Every key
// is optional and off when absent; a client without manage can only list and
// fill, as before. create needs all_items (a new login is reachable only
// through all_items, so an explicit-secrets client could otherwise hand its
// logins to the all_items client). update, remove (soft delete to the vault's
// trash; there is no purge), compare and pipe act only on logins the client
// already reaches: its secrets' item ids, and for all_items every personal
// login no client lists.
//
// "pipe_targets" (top level) is the only list of commands a password may be
// piped into, chosen here and never by the agent: {"docker-login": {"argv":
// ["docker", "login", "--username", "{username}", "--password-stdin",
// "{arg:registry}"], "args": {"registry": "^[a-z0-9.-]+(:[0-9]+)?$"}}}. An
// argv element is a literal, or exactly "{username}" or "{arg:<slot>}"; each
// slot's value must match its regex in full. The value only ever goes to the
// command's stdin. A client names the targets it may use in manage.pipe.
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
const TOP_KEYS = new Set(['version', 'clients', 'chats', 'default_client', 'pipe_targets']);
const MANAGE_FLAGS = ['create', 'update', 'remove', 'compare'];
const SLOT = /^[a-z][a-z0-9_]{0,31}$/;

function parsePipeTargets(raw) {
    const out = new Map();
    if (raw === undefined) return out;
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new PolicyError('pipe_targets must be an object');
    for (const [name, t] of Object.entries(raw)) {
        if (!SLUG.test(name)) throw new PolicyError(`bad pipe target name ${JSON.stringify(name).slice(0, 70)}`);
        if (!t || typeof t !== 'object' || Array.isArray(t)) throw new PolicyError(`pipe target ${name}: must be an object`);
        const extra = Object.keys(t).filter((k) => !['argv', 'args'].includes(k));
        if (extra.length) throw new PolicyError(`pipe target ${name}: unknown key ${JSON.stringify(extra[0]).slice(0, 40)}`);
        const argv = t.argv;
        if (!Array.isArray(argv) || !argv.length || argv.length > 32 || argv.some((a) => typeof a !== 'string' || !a.length || a.length > 256 || a.includes('\0'))) {
            throw new PolicyError(`pipe target ${name}: argv must be 1..32 non-empty strings`);
        }
        const args = new Map();
        if (t.args !== undefined) {
            if (!t.args || typeof t.args !== 'object' || Array.isArray(t.args)) throw new PolicyError(`pipe target ${name}: args must be an object`);
            for (const [slot, re] of Object.entries(t.args)) {
                if (!SLOT.test(slot)) throw new PolicyError(`pipe target ${name}: bad arg slot ${JSON.stringify(slot).slice(0, 40)}`);
                if (typeof re !== 'string' || !re.length || re.length > 200) throw new PolicyError(`pipe target ${name}.${slot}: the regex must be a string`);
                try { args.set(slot, new RegExp(`^(?:${re})$`)); } catch { throw new PolicyError(`pipe target ${name}.${slot}: the regex does not compile`); }
            }
        }
        const used = new Set();
        argv.forEach((a, i) => {
            if (!/[{}]/.test(a)) return;
            const m = /^\{(username|arg:([a-z][a-z0-9_]{0,31}))\}$/.exec(a);
            if (!m) throw new PolicyError(`pipe target ${name}: argv element ${i} must be a literal, "{username}" or "{arg:<slot>}"`);
            if (i === 0) throw new PolicyError(`pipe target ${name}: argv[0] must be a literal command`);
            if (m[2]) { if (!args.has(m[2])) throw new PolicyError(`pipe target ${name}: {arg:${m[2]}} has no regex in args`); used.add(m[2]); }
        });
        for (const slot of args.keys()) if (!used.has(slot)) throw new PolicyError(`pipe target ${name}: arg slot ${slot} is not used in argv`);
        out.set(name, Object.freeze({ name, argv: Object.freeze([...argv]), args }));
    }
    return out;
}

function parseManage(slug, m, allItems, targets) {
    if (m === undefined) return null;
    if (!m || typeof m !== 'object' || Array.isArray(m)) throw new PolicyError(`client ${slug}: manage must be an object`);
    const extra = Object.keys(m).filter((k) => ![...MANAGE_FLAGS, 'pipe'].includes(k));
    if (extra.length) throw new PolicyError(`client ${slug}: manage: unknown key ${JSON.stringify(extra[0]).slice(0, 40)}`);
    for (const f of MANAGE_FLAGS) if (m[f] !== undefined && typeof m[f] !== 'boolean') throw new PolicyError(`client ${slug}: manage.${f} must be true or false`);
    if (m.create === true && !allItems) throw new PolicyError(`client ${slug}: manage.create needs all_items (a new login is reachable only through all_items)`);
    const pipe = m.pipe ?? [];
    if (!Array.isArray(pipe) || pipe.some((p) => typeof p !== 'string')) throw new PolicyError(`client ${slug}: manage.pipe must be a list of pipe target names`);
    for (const p of pipe) if (!targets.has(p)) throw new PolicyError(`client ${slug}: manage.pipe names ${JSON.stringify(p).slice(0, 64)}, which is not in pipe_targets`);
    return Object.freeze({ ...Object.fromEntries(MANAGE_FLAGS.map((f) => [f, m[f] === true])), pipe: Object.freeze([...new Set(pipe)]) });
}

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
    const targets = parsePipeTargets(raw.pipe_targets);
    const clients = new Map();
    const seenItems = new Map();
    let allItemsClient = null;
    for (const [slug, c] of Object.entries(raw.clients)) {
        if (!SLUG.test(slug)) throw new PolicyError(`bad client slug ${JSON.stringify(slug).slice(0, 70)}`);
        if (!c || typeof c !== 'object' || Array.isArray(c)) throw new PolicyError(`client ${slug}: must be an object`);
        if ('org_id' in c || 'collection_id' in c) throw new PolicyError(`client ${slug}: org_id and collection_id are no longer used (the items are in the agent account's own vault); remove them`);
        const extra = Object.keys(c).filter((k) => !['secrets', 'all_items', 'equivalent_domains', 'manage'].includes(k));
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
        if (c.all_items !== undefined && typeof c.all_items !== 'boolean') throw new PolicyError(`client ${slug}: all_items must be true or false`);
        const allItems = c.all_items === true;
        if (allItems) {
            if (allItemsClient) throw new PolicyError(`client ${slug}: all_items is already set by ${allItemsClient}; only one client may use every vault item`);
            allItemsClient = slug;
        }
        if (c.equivalent_domains !== undefined && typeof c.equivalent_domains !== 'boolean') throw new PolicyError(`client ${slug}: equivalent_domains must be true or false`);
        clients.set(slug, Object.freeze({ secrets, allItems, equivalentDomains: c.equivalent_domains !== false, manage: parseManage(slug, c.manage, allItems, targets) }));
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
    return createPolicy(clients, chats, defaultClient, new Set(seenItems.keys()), targets);
}

/** The name an all_items client uses for a vault item: its name as a slug ("GitHub (work)" -> "github-work"), or null. */
export function itemSlug(name) {
    if (typeof name !== 'string') return null;
    const s = name.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
        .replace(/[^a-z0-9_-]+/g, '-').replace(/-{2,}/g, '-').replace(/^[-_]+/, '').slice(0, 63).replace(/[-_]+$/, '');
    return SLUG.test(s) ? s : null;
}

function createPolicy(clients, chats, defaultClient, listedItems, targets = new Map()) {
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
        /** Whether a client may use every vault item no client lists (all_items). */
        allItems: (slug) => !!clients.get(slug)?.allItems,
        /** Whether a client's all_items logins also fill on equivalent domains (default true; never for explicit secrets). */
        equivalentDomains: (slug) => clients.get(slug)?.equivalentDomains !== false && clients.has(slug),
        /** A client's manage permissions {create, update, remove, compare, pipe:[names]}, or null (list and fill only). */
        manage: (slug) => clients.get(slug)?.manage ?? null,
        /** A pipe target {name, argv, args: Map slot -> RegExp}, or null. */
        pipeTarget: (name) => targets.get(String(name ?? '')) ?? null,
        pipeTargets: () => [...targets.keys()],
        /** The client that lists this item id in its secrets, or null. */
        listedBy(itemId) {
            const id = String(itemId ?? '').toLowerCase();
            for (const [slug, c] of clients) for (const s of c.secrets.values()) if (s.item_id === id) return slug;
            return null;
        },
        /** Whether some client lists this item id in its secrets (such an item is never reached through all_items). */
        isListed: (itemId) => listedItems.has(String(itemId ?? '').toLowerCase()),
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
