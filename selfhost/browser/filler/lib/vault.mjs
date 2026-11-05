// The filler's Vaultwarden client: API-key login, /api/sync, decryption in
// memory. Holds the agent account's API key and user key; never the master
// password. A sync is reused for ttlMs (15 s) and kept in memory only.
//
// There is no organization: the agent account keeps its logins in its own
// personal vault, and any cipher it can decrypt (personal ones with its user
// key, or, should it ever join one, an organization's with that org key) is
// readable. Which item a chat may use is decided only by the root-owned
// policy (policy.mjs): a chat reaches a cipher only through a name its client
// lists, and every item id belongs to at most one client.
//
// The sync asks for the account's equivalent domains (excludeDomains=false):
// its own groups and the global groups it has not excluded (domains.mjs).
// listLogins attaches them to each login; only all_items clients use them.
//
// Writes (manage.mjs, /v1/vault/*): createLogin, updateLogin, trashLogin and
// restoreLogin, on the account's personal vault only (an organization item is
// refused). trashLogin is Bitwarden's soft delete: the item goes to the vault's
// trash, from which restoreLogin brings it back. There is no purge or hard
// delete here, by design. Every write drops the cached sync.
import { createHash, randomBytes } from 'node:crypto';
import { decryptKey, decryptSym, decryptSymText, encryptSym, VaultCryptoError } from './vaultcrypto.mjs';
import { httpsHost } from './hosts.mjs';
import { buildEquivalence, equivalentsFor } from './domains.mjs';

export class VaultError extends Error {
    constructor(message, status = 502) { super(message); this.status = status; }
}

const DEVICE_TYPE = '14'; // SDK / CLI-like device
const DEVICE_NAME = 'happy-secret-filler';

export function checkVaultUrl(url, { allowLoopbackHttp = true } = {}) {
    const u = new URL(url);
    const loopback = ['127.0.0.1', 'localhost', '[::1]'].includes(u.hostname);
    if (u.protocol === 'https:' || (u.protocol === 'http:' && loopback && allowLoopbackHttp)) return u.toString().replace(/\/+$/, '');
    throw new VaultError('the vault URL must be https, or http on loopback', 500);
}

export function createVault({ url, clientId, clientSecret, userKey, deviceId, fetchImpl = fetch, ttlMs = 15_000, now = () => Date.now(), timeoutMs = 10_000 }) {
    const base = checkVaultUrl(url);
    if (!Buffer.isBuffer(userKey) || userKey.length !== 64) throw new VaultError('user key must be 64 bytes', 500);
    if (!/^user\.[0-9a-f-]{36}$/i.test(clientId || '')) throw new VaultError('client id must be user.<uuid> (the account API key)', 500);
    let token = null; // {value, expires}
    let synced = null; // {at, data, privateKey, orgKeys}
    let inflight = null;

    async function req(path, init) {
        let res;
        try {
            res = await fetchImpl(base + path, { ...init, signal: AbortSignal.timeout(timeoutMs) });
        } catch (err) {
            throw new VaultError(`vault unreachable: ${err.name}`);
        }
        if (!res.ok) {
            // Never echo the body: an identity error can repeat request fields.
            throw new VaultError(`vault ${path.split('?')[0]} -> HTTP ${res.status}`, res.status === 401 || res.status === 400 ? 502 : 502);
        }
        const text = await res.text();
        if (!text.trim()) return null; // a soft delete answers 200 with no body
        try { return JSON.parse(text); } catch { throw new VaultError(`vault ${path.split('?')[0]} -> a body that is not JSON`); }
    }

    async function authed(path, method, body) {
        const t = await login();
        try {
            return await req(path, { method, headers: { Authorization: `Bearer ${t}`, Accept: 'application/json', ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
        } catch (err) {
            if (/HTTP 401/.test(err.message)) token = null;
            throw err;
        } finally {
            synced = null; // a write (or a failed one) makes the cached sync stale
        }
    }

    async function login() {
        if (token && token.expires > now() + 30_000) return token.value;
        const body = new URLSearchParams({
            grant_type: 'client_credentials', scope: 'api', client_id: clientId, client_secret: clientSecret,
            deviceType: DEVICE_TYPE, deviceIdentifier: deviceId, deviceName: DEVICE_NAME,
        });
        const r = await req('/identity/connect/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' }, body: body.toString() });
        if (typeof r.access_token !== 'string') throw new VaultError('vault login returned no token');
        token = { value: r.access_token, expires: now() + Math.max(60, Number(r.expires_in) || 3600) * 1000 };
        return token.value;
    }

    async function doSync() {
        const t = await login();
        let data;
        try {
            data = await req('/api/sync?excludeDomains=false', { headers: { Authorization: `Bearer ${t}`, Accept: 'application/json' } });
        } catch (err) {
            token = null;
            throw err;
        }
        const profile = data.profile || data.Profile;
        if (!profile) throw new VaultError('sync without a profile');
        // The account key in sync must be the one we were enrolled with.
        let privateKey = null;
        try {
            if (profile.privateKey) privateKey = decryptSym(profile.privateKey, userKey);
        } catch (err) {
            throw new VaultError(`cannot decrypt the account's private key (re-run make filler-enroll): ${err.message}`, 503);
        }
        const orgKeys = new Map();
        for (const o of profile.organizations || []) {
            if (!o?.id || !o.key) continue;
            try { orgKeys.set(String(o.id).toLowerCase(), decryptKey(o.key, { privateKey, symKey: userKey })); } catch { /* unusable org: its items stay locked */ }
        }
        const equivalence = buildEquivalence(data.domains || data.Domains);
        synced = { at: now(), ciphers: data.ciphers || data.Ciphers || [], orgKeys, equivalence, fingerprint: createHash('sha256').update(userKey).digest('hex').slice(0, 8) };
        return synced;
    }

    async function sync({ force = false } = {}) {
        if (!force && synced && now() - synced.at < ttlMs) return synced;
        if (!inflight) inflight = doSync().finally(() => { inflight = null; });
        return inflight;
    }

    function findCipher(s, itemId) {
        return s.ciphers.find((c) => String(c.id || c.Id).toLowerCase() === itemId) || null;
    }

    /**
     * Decrypt one login item by id. The caller has already resolved the id
     * through the chat's client policy.
     * Returns {username, password, totp, uris} (strings, or null for empty), or throws.
     */
    async function readItem(itemId) {
        const s = await sync();
        const c = findCipher(s, String(itemId).toLowerCase());
        if (!c) throw new VaultError('item not found in the agent account\'s vault', 404);
        if (c.deletedDate) throw new VaultError('item is in the trash', 404);
        if (c.type !== 1 || !c.login) throw new VaultError('item is not a login', 422);
        // A personal item is under the user key; an organization item under
        // that organization's key, which only a confirmed member holds.
        const orgId = c.organizationId ? String(c.organizationId).toLowerCase() : null;
        const baseKey = orgId ? s.orgKeys.get(orgId) : userKey;
        if (!baseKey) throw new VaultError('the agent account holds no key for this item\'s organization', 403);
        let key = baseKey;
        try {
            if (c.key) key = decryptKey(c.key, { symKey: baseKey });
            const dec = (v) => (v ? decryptSymText(v, key) : null);
            return {
                username: dec(c.login.username),
                password: dec(c.login.password),
                totp: dec(c.login.totp),
                uris: (c.login.uris || []).map((u) => dec(u?.uri)).filter(Boolean),
            };
        } catch (err) {
            if (err instanceof VaultCryptoError) throw new VaultError(`cannot decrypt item: ${err.message}`, 422);
            throw err;
        }
    }

    /**
     * Every live login the account can decrypt, as {id, name, hosts, fields,
     * equivalents?}: the item's name, the https hosts of its URIs, and which of
     * username, password and totp it has (from whether the field is set;
     * nothing is decrypted but the name and URIs). Never a value. equivalents
     * (only when there are any) maps each registrable domain the vault's
     * equivalent domains grant to the saved host granting it; only URIs with
     * the default match detection (match null or 0, "Base domain") count, as
     * in the extension: Host, Starts with, Exact, Regex and Never do not. make filler-items lists
     * these (force: a fresh sync); all_items clients resolve names through them
     * on the normal sync cadence, so a login added to the vault shows up within
     * ttlMs.
     */
    async function listLogins({ force = true } = {}) {
        const s = await sync({ force });
        const out = [];
        for (const c of s.ciphers) {
            if (!c || c.type !== 1 || c.deletedDate || !c.login) continue;
            const orgId = c.organizationId ? String(c.organizationId).toLowerCase() : null;
            const baseKey = orgId ? s.orgKeys.get(orgId) : userKey;
            if (!baseKey) continue;
            let name = null; let hosts = []; let equivalents = new Map();
            try {
                const key = c.key ? decryptKey(c.key, { symKey: baseKey }) : baseKey;
                name = c.name ? decryptSymText(c.name, key) : '';
                const seen = new Set(); const byDomain = new Set();
                for (const u of c.login.uris || []) {
                    let h = null;
                    try { h = u?.uri ? httpsHost(decryptSymText(u.uri, key)) : null; } catch {}
                    if (!h) continue;
                    seen.add(h);
                    if (u.match == null || u.match === 0) byDomain.add(h);
                }
                hosts = [...seen];
                equivalents = equivalentsFor([...byDomain], s.equivalence);
            } catch { name = null; }
            const fields = ['username', 'password', 'totp'].filter((f) => !!c.login[f]);
            out.push({ id: String(c.id || c.Id).toLowerCase(), name, hosts, fields, ...(equivalents.size ? { equivalents } : {}), ...(orgId ? { organization: true } : {}) });
        }
        return out.sort((a, b) => String(a.name ?? '').localeCompare(String(b.name ?? '')) || a.id.localeCompare(b.id));
    }

    function keysOf(s, c) {
        const orgId = c.organizationId ? String(c.organizationId).toLowerCase() : null;
        const baseKey = orgId ? s.orgKeys.get(orgId) : userKey;
        if (!baseKey) return null;
        return { orgId, key: c.key ? decryptKey(c.key, { symKey: baseKey }) : baseKey };
    }

    /** A URI shown as metadata: scheme, host and path; never userinfo, a query or a fragment. */
    function shownUri(u) {
        try {
            const x = new URL(u);
            if (!/^https?:$/.test(x.protocol) || !x.host) return null;
            return `${x.protocol}//${x.host}${x.pathname === '/' ? '' : x.pathname}`.slice(0, 300);
        } catch { return null; }
    }

    /**
     * Login metadata for the vault tools: {id, name, username, uris, hosts,
     * fields, revision_date, trashed, organization}. The username is shown
     * (agents pick and create accounts by it); the password and TOTP never are,
     * only whether they are set. trash: true also lists trashed logins.
     */
    async function listItems({ force = true, trash = false } = {}) {
        const s = await sync({ force });
        const out = [];
        for (const c of s.ciphers) {
            if (!c || c.type !== 1 || !c.login) continue;
            if (c.deletedDate && !trash) continue;
            let k;
            try { k = keysOf(s, c); } catch { k = null; }
            if (!k) continue;
            const dec = (v) => { try { return v ? decryptSymText(v, k.key) : null; } catch { return null; } };
            const raw = (c.login.uris || []).map((u) => dec(u?.uri)).filter(Boolean);
            const hosts = [...new Set(raw.map((u) => { try { return httpsHost(u); } catch { return null; } }).filter(Boolean))];
            out.push({
                id: String(c.id || c.Id).toLowerCase(),
                name: dec(c.name),
                username: dec(c.login.username),
                uris: raw.map(shownUri).filter(Boolean),
                hosts,
                fields: ['username', 'password', 'totp'].filter((f) => !!c.login[f]),
                revision_date: c.revisionDate || null,
                trashed: !!c.deletedDate,
                ...(k.orgId ? { organization: true } : {}),
            });
        }
        return out.sort((a, b) => String(a.name ?? '').localeCompare(String(b.name ?? '')) || a.id.localeCompare(b.id));
    }

    const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    function checkId(id) {
        const v = String(id ?? '').toLowerCase();
        if (!ID.test(v)) throw new VaultError('item id must be a uuid', 400);
        return v;
    }

    /** The cipher for a write, from a fresh sync: a personal login, or throws. */
    async function personal(itemId, { trashed = false } = {}) {
        const s = await sync({ force: true });
        const c = findCipher(s, checkId(itemId));
        if (!c) throw new VaultError('item not found in the agent account\'s vault', 404);
        if (c.type !== 1 || !c.login) throw new VaultError('item is not a login', 422);
        if (c.organizationId) throw new VaultError('item belongs to an organization; the vault tools only change the agent account\'s own logins', 403);
        if (trashed && !c.deletedDate) throw new VaultError('item is not in the trash', 409);
        if (!trashed && c.deletedDate) throw new VaultError('item is in the trash', 409);
        return c;
    }

    const encUris = (uris, key, old = []) => uris.map((u) => {
        const prev = old.find((o) => { try { return o?.uri && decryptSymText(o.uri, key) === u; } catch { return false; } });
        return { uri: encryptSym(u, key), match: prev ? (prev.match ?? null) : null };
    });

    /**
     * A new login in the personal vault, under its own fresh item key.
     * Returns the new item id.
     */
    async function createLogin({ name, uris, username, password }) {
        const itemKey = randomBytes(64);
        try {
            const enc = (v) => (v == null || v === '' ? null : encryptSym(v, itemKey));
            const body = {
                type: 1, organizationId: null, folderId: null, favorite: false, reprompt: 0,
                key: encryptSym(itemKey, userKey),
                name: encryptSym(name, itemKey), notes: null, fields: [], passwordHistory: [],
                login: { username: enc(username), password: enc(password), totp: null, uris: encUris(uris, itemKey), passwordRevisionDate: null },
            };
            const r = await authed('/api/ciphers', 'POST', body);
            const id = r && (r.id || r.Id);
            if (!id) throw new VaultError('vault create returned no item id');
            return String(id).toLowerCase();
        } finally { itemKey.fill(0); }
    }

    /**
     * Change a personal login: name, uris, username and/or password (the
     * caller generated it). Fields not named are copied as they are; a
     * replaced password goes to the front of the item's password history.
     * Returns the names of the fields changed.
     */
    async function updateLogin(itemId, changes) {
        const c = await personal(itemId);
        const s = synced || await sync();
        const { key } = keysOf(s, c);
        const enc = (v) => (v == null || v === '' ? null : encryptSym(v, key));
        const login = { ...c.login };
        const changed = [];
        // Only the fields Vaultwarden's cipher update takes, copied as they are.
        const body = {
            type: 1, organizationId: null, folderId: c.folderId ?? null, favorite: !!c.favorite, reprompt: c.reprompt ?? 0,
            key: c.key ?? null, name: c.name, notes: c.notes ?? null, fields: c.fields ?? [], passwordHistory: c.passwordHistory ?? [], login,
        };
        for (const k of Object.keys(login)) if (!['username', 'password', 'totp', 'uris', 'passwordRevisionDate', 'autofillOnPageLoad', 'fido2Credentials'].includes(k)) delete login[k];
        if (changes.name !== undefined) { body.name = encryptSym(changes.name, key); changed.push('name'); }
        if (changes.uris !== undefined) { login.uris = encUris(changes.uris, key, c.login.uris || []); changed.push('uris'); }
        if (changes.username !== undefined) { login.username = enc(changes.username); changed.push('username'); }
        if (changes.password !== undefined) {
            const at = new Date(now()).toISOString();
            const history = Array.isArray(c.passwordHistory) ? c.passwordHistory : [];
            body.passwordHistory = c.login.password ? [{ password: c.login.password, lastUsedDate: at }, ...history].slice(0, 100) : history;
            login.password = enc(changes.password);
            login.passwordRevisionDate = at;
            changed.push('password');
        }
        if (!changed.length) throw new VaultError('nothing to change', 400);
        body.lastKnownRevisionDate = c.revisionDate || null;
        await authed(`/api/ciphers/${checkId(itemId)}`, 'PUT', body);
        return changed;
    }

    /** Soft delete: the login goes to the vault's trash (restorable). */
    async function trashLogin(itemId) {
        await personal(itemId);
        await authed(`/api/ciphers/${checkId(itemId)}/delete`, 'PUT');
    }

    /** Bring a trashed login back. */
    async function restoreLogin(itemId) {
        await personal(itemId, { trashed: true });
        await authed(`/api/ciphers/${checkId(itemId)}/restore`, 'PUT');
    }

    return {
        sync,
        readItem,
        listLogins,
        listItems,
        createLogin,
        updateLogin,
        trashLogin,
        restoreLogin,
        status: () => ({ unlocked: true, sync_age_s: synced ? Math.round((now() - synced.at) / 1000) : null }),
        lock() { token = null; synced = null; },
    };
}
