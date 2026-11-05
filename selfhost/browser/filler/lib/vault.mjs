// The filler's Vaultwarden client: API-key login, /api/sync, decryption in
// memory. Holds the agent account's API key and user key; never the master
// password. A sync is reused for ttlMs (15 s) and kept in memory only.
//
// Which ciphers may be decrypted at all is decided by the caller (fill.mjs)
// through readItem's org and collection arguments: an item outside the
// client's organization or its Agents collection is never decrypted.
import { createHash } from 'node:crypto';
import { decryptKey, decryptSym, decryptSymText, VaultCryptoError } from './vaultcrypto.mjs';

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
        return res.json();
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
            data = await req('/api/sync?excludeDomains=true', { headers: { Authorization: `Bearer ${t}`, Accept: 'application/json' } });
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
        synced = { at: now(), ciphers: data.ciphers || data.Ciphers || [], orgKeys, fingerprint: createHash('sha256').update(userKey).digest('hex').slice(0, 8) };
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
     * Decrypt one login item, but only if it is in orgId and collectionId.
     * Returns {username, password, totp, uris} (strings, or null for empty), or throws.
     */
    async function readItem(itemId, { orgId, collectionId }) {
        const s = await sync();
        const c = findCipher(s, String(itemId).toLowerCase());
        if (!c) throw new VaultError('item not found in the vault (or not shared with the agent account)', 404);
        if (c.deletedDate) throw new VaultError('item is in the trash', 404);
        if (String(c.organizationId || '').toLowerCase() !== orgId) throw new VaultError('item is not in this client\'s organization', 403);
        const cols = (c.collectionIds || []).map((x) => String(x).toLowerCase());
        if (!cols.includes(collectionId)) throw new VaultError('item is not in this client\'s Agents collection', 403);
        if (c.type !== 1 || !c.login) throw new VaultError('item is not a login', 422);
        const orgKey = s.orgKeys.get(orgId);
        if (!orgKey) throw new VaultError('no key for this organization (is the agent account confirmed?)', 403);
        let key = orgKey;
        try {
            if (c.key) key = decryptKey(c.key, { symKey: orgKey });
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

    return {
        sync,
        readItem,
        status: () => ({ unlocked: true, sync_age_s: synced ? Math.round((now() - synced.at) / 1000) : null }),
        lock() { token = null; synced = null; },
    };
}
