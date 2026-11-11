// The 1Password provider: a service account, through the official SDK
// (@1password/sdk), behind the provider contract (../index.mjs). 1Password's
// shapes stop at map.mjs; the token stays in token.mjs and the SDK client.
//
// Policy config ("backends" entry):
//   {"type": "onepassword", "vault": "<vault name or id>",
//    "token_file": "onepassword.token" (optional, a file in secrets/<backend>/),
//    "remove": "archive" (default) | "tag"}
//
// Safety:
//   - one vault only, resolved by exact id or exact title; missing or ambiguous
//     fails closed. Every item read or written must carry that vault id.
//   - the cache holds metadata only (toMeta: no password, TOTP or field
//     value). readItem fetches the one item it is asked for.
//   - items are never deleted. Remove tags the item TRASH_TAG (so it stays
//     identifiable as removed by the filler) and, with "remove": "archive"
//     (the default), archives it. The SDK cannot unarchive, so restore of an
//     archived login is refused (409) until a person unarchives it in
//     1Password; then restore takes the tag off. capabilities.restore says
//     which: 'manual' (archive) or 'tag' (tag only).
//   - error messages are fixed strings: no SDK message (which can quote input),
//     no value, no token.
//   - a rate limit puts the provider in a cooldown that doubles up to 5
//     minutes; calls in it fail fast, and status() reports it.
import { ProviderError } from '../index.mjs';
import { DEFAULT_TOKEN_FILE, checkTokenFile, readToken, tokenPath } from './token.mjs';
import { ID, NEW_WEBSITE_BEHAVIOR, TRASH_TAG, byNameThenId, isTrashed, passwordField, toLogin, toMeta, usernameField } from './map.mjs';

const CONFIG_KEYS = new Set(['type', 'id', 'secretsDir', 'vault', 'token_file', 'remove']);
const MAX_NAME = 512, MAX_VALUE = 4096, MAX_URIS = 32, MAX_URI = 2048, MAX_ITEMS = 10_000;
const COOLDOWN_MIN_MS = 5_000, COOLDOWN_MAX_MS = 300_000;
const INTEGRATION = { integrationName: 'happy-secret-filler', integrationVersion: '1.0.0' };
const LOGIN = 'Login';
const REMOVE_MODES = ['archive', 'tag'];

const err = (message, status) => new ProviderError(message, status);
const errName = (e) => e?.constructor?.name || e?.name || '';

/** Whether s is a 1Password item id (any case). */
export const isId = (s) => typeof s === 'string' && ID.test(s.toLowerCase());

function checkConfig(config) {
    for (const k of Object.keys(config)) if (!CONFIG_KEYS.has(k)) throw err(`1Password backend: unknown setting ${JSON.stringify(k).slice(0, 40)}`, 500);
    const { vault, remove = 'archive' } = config;
    if (typeof vault !== 'string' || !vault.trim() || vault.length > 256 || /[\u0000-\u001f\u007f]/.test(vault)) throw err('1Password backend: "vault" must be a vault name or id', 500);
    if (!REMOVE_MODES.includes(remove)) throw err('1Password backend: "remove" must be "archive" or "tag"', 500);
}

function checkString(v, what, max, { allowEmpty = true } = {}) {
    if (v === null && allowEmpty) return '';
    if (typeof v !== 'string' || v.length > max || (!allowEmpty && !v.trim()) || /[\u0000]/.test(v)) throw err(`${what} is not valid`, 400);
    return v;
}
function checkUris(uris) {
    if (!Array.isArray(uris) || uris.length > MAX_URIS) throw err(`uris must be a list of at most ${MAX_URIS} URLs`, 400);
    return uris.map((u) => {
        if (typeof u !== 'string' || u.length > MAX_URI) throw err('a URI is not valid', 400);
        let x; try { x = new URL(u); } catch { throw err('a URI is not valid', 400); }
        if (!/^https?:$/.test(x.protocol) || x.username || x.password) throw err('a URI must be http(s) with no user info', 400);
        return u;
    });
}

/**
 * A 1Password provider.
 * config: {id, secretsDir, vault, token_file?, remove?} (type is allowed).
 * deps (tests): client (a ready SDK client) or createClient(token) -> client;
 *   now, ttlMs (15 s), batchSize (50).
 */
export function createOnePasswordProvider(config = {}, deps = {}) {
    checkConfig(config);
    const { id = 'onepassword', secretsDir, vault: vaultRef, token_file: tokenFile = DEFAULT_TOKEN_FILE, remove = 'archive' } = config;
    const archive = remove === 'archive';
    const { now = () => Date.now(), ttlMs = 15_000, batchSize = 50 } = deps;
    let path = null;
    if (!deps.client) {
        path = tokenPath(secretsDir, tokenFile);
        checkTokenFile(path); // "not enrolled" here, when the backend is built
    }

    let client = deps.client || null;
    let connecting = null;
    let vaultId = null;
    let cache = null; // {at, metas: LoginMeta[] (trashed included), archived: Set of ids}
    let inflight = null;
    let cooldown = { until: 0, ms: 0 };
    let lastError = null;

    // Every SDK call goes through here: cooldown, error classes, no messages.
    async function call(what, fn) {
        if (now() < cooldown.until) throw err('1Password is rate limiting this account; try again later', 503);
        try {
            const r = await fn();
            cooldown.ms = 0;
            lastError = null;
            return r;
        } catch (e) {
            if (e instanceof ProviderError) throw e;
            const n = errName(e);
            if (n === 'RateLimitExceededError') {
                cooldown.ms = Math.min(COOLDOWN_MAX_MS, Math.max(COOLDOWN_MIN_MS, cooldown.ms * 2));
                cooldown.until = now() + cooldown.ms;
                lastError = 'rate_limited';
                throw err('1Password is rate limiting this account; try again later', 503);
            }
            if (n === 'AuthExpiredError' || n === 'DesktopSessionExpiredError') {
                client = null; vaultId = null; cache = null;
                lastError = 'auth';
                throw err('1Password sign-in expired; the provider will sign in again', 503);
            }
            lastError = 'unavailable';
            throw err(`1Password ${what} failed`, 502);
        }
    }

    async function connect() {
        if (client && vaultId) return client;
        if (!connecting) {
            connecting = (async () => {
                if (!client) {
                    let token = readToken(path);
                    try {
                        const make = deps.createClient || (async (auth) => (await import('@1password/sdk')).createClient({ auth, ...INTEGRATION }));
                        client = await call('sign-in', () => make(token));
                    } finally { token = null; }
                }
                vaultId = await resolveVault(client);
                return client;
            })().finally(() => { connecting = null; });
        }
        return connecting;
    }

    async function resolveVault(c) {
        const vaults = await call('vault list', () => c.vaults.list());
        if (!Array.isArray(vaults)) throw err('1Password vault list failed', 502);
        const byId = isId(vaultRef) ? vaults.filter((v) => v?.id === vaultRef.toLowerCase()) : [];
        const hits = byId.length ? byId : vaults.filter((v) => v?.title === vaultRef);
        if (hits.length === 0) throw err('the configured 1Password vault is not visible to the service account', 503);
        if (hits.length > 1) throw err('the configured 1Password vault name matches more than one vault; use its id', 503);
        return hits[0].id;
    }

    // An item from the SDK, checked: in our vault, a login, with an id.
    function own(item) {
        if (!item || typeof item !== 'object' || !isId(item.id) || item.vaultId !== vaultId) throw err('1Password returned an item outside the configured vault', 502);
        return item;
    }

    async function sync({ force = false } = {}) {
        if (!force && cache && now() - cache.at < ttlMs) return cache;
        if (inflight) return inflight;
        inflight = (async () => {
            const c = await connect();
            const filter = { type: 'ByState', content: { active: true, archived: true } };
            const overviews = await call('item list', () => c.items.list(vaultId, filter));
            if (!Array.isArray(overviews)) throw err('1Password item list failed', 502);
            // An archived login is listed only when we archived it (it carries
            // TRASH_TAG); one archived by hand stays out of the filler's view.
            const logins = overviews.filter((o) => o?.category === LOGIN && isId(o.id) && (o.state !== 'archived' || o.tags?.includes(TRASH_TAG)));
            const archivedIds = new Set(logins.filter((o) => o.state === 'archived').map((o) => o.id));
            const ids = logins.map((o) => o.id);
            if (ids.length > MAX_ITEMS) throw err('the 1Password vault has too many logins', 502);
            const metas = [];
            for (let i = 0; i < ids.length; i += batchSize) {
                const r = await call('item read', () => c.items.getAll(vaultId, ids.slice(i, i + batchSize)));
                for (const res of r?.individualResponses || []) {
                    if (!res?.content) continue; // itemNotFound (deleted since the list) or a per-item error
                    const item = own(res.content);
                    if (item.category === LOGIN) metas.push(toMeta(item));
                }
            }
            cache = { at: now(), metas: metas.sort(byNameThenId), archived: archivedIds };
            return cache;
        })().finally(() => { inflight = null; });
        return inflight;
    }

    const canonical = (itemId) => {
        if (!isId(itemId)) throw err('not a 1Password item id', 404);
        return itemId.toLowerCase();
    };

    // A fresh full item for a read or write: a login in our vault, or throws.
    // A write checks the item's state against a fresh listing (as Vaultwarden's
    // writes do); a read uses the cached one, so guessed ids cost no SDK calls.
    async function fetchItem(itemId, { forWrite = false } = {}) {
        const idc = canonical(itemId);
        const c = await connect();
        const s2 = await sync({ force: forWrite });
        if (!s2.metas.some((m) => m.id === idc)) throw err('item not found in the 1Password vault', 404);
        const item = own(await call('item read', () => c.items.get(vaultId, idc)));
        if (item.category !== LOGIN) throw err('item is not a login', 422);
        return { c, item, archived: s2.archived.has(idc) };
    }

    async function write(fn) {
        try { return await fn(); } finally { cache = null; }
    }

    return {
        id,
        type: 'onepassword',
        capabilities: Object.freeze({ restore: archive ? 'manual' : 'tag', equivalentDomains: false, totp: true }),
        checkId: (x) => (isId(x) ? x.toLowerCase() : null),
        status: () => {
            const out = { unlocked: !!(client && vaultId), sync_age_s: cache ? Math.round((now() - cache.at) / 1000) : null };
            if (now() < cooldown.until) out.rate_limited_s = Math.ceil((cooldown.until - now()) / 1000);
            if (lastError) out.last_error = lastError;
            return out;
        },
        async sync({ force = false } = {}) { await sync({ force }); },
        async listItems({ trash = false, force = false } = {}) {
            const s = await sync({ force });
            return s.metas.filter((m) => trash || !m.trashed).map((m) => ({ ...m, uris: m.uris.map((u) => ({ ...u })), hosts: [...m.hosts], has: { ...m.has }, fields: m.fields.map((f) => ({ ...f })) }));
        },
        async readItem(itemId) {
            const { item, archived: arch } = await fetchItem(itemId);
            if (isTrashed(item) || arch) throw err('item is in the trash', 404);
            return toLogin(item);
        },
        async createLogin({ name, uris = [], username = null, password = null } = {}) {
            const title = checkString(name, 'name', MAX_NAME, { allowEmpty: false });
            const sites = checkUris(uris);
            const user = checkString(username ?? null, 'username', MAX_VALUE);
            const pass = checkString(password ?? null, 'password', MAX_VALUE);
            const c = await connect();
            return write(async () => {
                const fields = [];
                if (user) fields.push({ id: 'username', title: 'username', fieldType: 'Text', value: user });
                if (pass) fields.push({ id: 'password', title: 'password', fieldType: 'Concealed', value: pass });
                const created = own(await call('item create', () => c.items.create({
                    category: LOGIN, vaultId, title, fields,
                    websites: sites.map((url) => ({ url, label: 'website', autofillBehavior: NEW_WEBSITE_BEHAVIOR })),
                })));
                return created.id.toLowerCase();
            });
        },
        async updateLogin(itemId, changes = {}) {
            const name = changes.name === undefined ? undefined : checkString(changes.name, 'name', MAX_NAME, { allowEmpty: false });
            const uris = changes.uris === undefined ? undefined : checkUris(changes.uris);
            const username = changes.username === undefined ? undefined : checkString(changes.username, 'username', MAX_VALUE);
            const password = changes.password === undefined ? undefined : checkString(changes.password, 'password', MAX_VALUE);
            const { c, item } = await fetchItem(itemId, { forWrite: true });
            if (isTrashed(item)) throw err('item is in the trash', 409);
            const next = { ...item, fields: (item.fields || []).map((f) => ({ ...f })), websites: (item.websites || []).map((w) => ({ ...w })) };
            const changed = [];
            if (name !== undefined) { next.title = name; changed.push('name'); }
            if (uris !== undefined) {
                // A URL already on the item keeps its autofill behaviour and label.
                next.websites = uris.map((url) => item.websites?.find((w) => w.url === url) || { url, label: 'website', autofillBehavior: NEW_WEBSITE_BEHAVIOR });
                changed.push('uris');
            }
            const setField = (find, fid, fieldType, value) => {
                const f = find(next);
                if (f) f.value = value;
                else if (value) next.fields.unshift({ id: fid, title: fid, fieldType, value });
            };
            if (username !== undefined) { setField(usernameField, 'username', 'Text', username); changed.push('username'); }
            if (password !== undefined) { setField(passwordField, 'password', 'Concealed', password); changed.push('password'); }
            if (!changed.length) throw err('nothing to change', 400);
            await write(() => call('item update', () => c.items.put(next)));
            return changed;
        },
        async trashLogin(itemId) {
            const { c, item, archived: arch } = await fetchItem(itemId, { forWrite: true });
            // Tagged but still active with remove "archive": an earlier remove
            // stopped between the tag and the archive; finish it.
            const unfinished = isTrashed(item) && archive && !arch;
            if (isTrashed(item) && !unfinished) throw err('item is in the trash', 409);
            await write(async () => {
                if (!unfinished) await call('item update', () => c.items.put({ ...item, tags: [...(item.tags || []), TRASH_TAG] }));
                if (archive) await call('item archive', () => c.items.archive(vaultId, item.id));
            });
        },
        async restoreLogin(itemId) {
            const { c, item, archived: arch } = await fetchItem(itemId, { forWrite: true });
            if (!isTrashed(item)) throw err('item is not in the trash', 409);
            if (arch) throw err('item is archived in 1Password; unarchive it in 1Password, then restore it', 409);
            await write(() => call('item update', () => c.items.put({ ...item, tags: item.tags.filter((t) => t !== TRASH_TAG) })));
        },
        lock() {
            cache = null; vaultId = null;
            if (!deps.client) client = null;
        },
    };
}
