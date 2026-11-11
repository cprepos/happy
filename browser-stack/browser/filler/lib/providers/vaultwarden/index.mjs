// The Vaultwarden provider: the vault client (vault.mjs) behind the provider
// contract (../index.mjs). Bitwarden's shapes stop here: URI match numbers
// become match names, custom field types become hidden flags, linked fields
// (type 3) are dropped, and an organization item becomes `shared`.
import { createVault, shownUri } from './vault.mjs';
import { equivalentsFor } from './domains.mjs';
import { httpsHost } from '../../hosts.mjs';

// Bitwarden URI match detection: null or 0 base domain, 1 host, 2 starts with,
// 3 exact, 4 regular expression, 5 never. "Starts with" and regex are stricter
// than host and are not modelled by the filler: they read as 'exact'.
const MATCH = new Map([[0, 'domain'], [1, 'host'], [2, 'exact'], [3, 'exact'], [4, 'exact'], [5, 'never']]);
/** The contract's match name for a Bitwarden URI match number. */
export const matchName = (m) => (m == null ? 'domain' : MATCH.get(m) ?? 'exact');

// Bitwarden custom field types: 0 text, 1 hidden, 2 boolean, 3 linked.
const HIDDEN_FIELD = 1;
const LINKED_FIELD = 3;

const safeHost = (u) => { try { return httpsHost(u); } catch { return null; } };

/** A decrypted cipher (vault.readCipher) as a contract Login. */
export function toLogin(raw) {
    return {
        id: raw.id,
        name: raw.name ?? null,
        username: raw.login.username ?? null,
        password: raw.login.password ?? null,
        totp: raw.login.totp ?? null,
        uris: raw.login.uris.map((u) => ({ url: u.uri, match: matchName(u.match) })),
        fields: raw.fields.filter((f) => f.type !== LINKED_FIELD).map((f) => ({ name: f.name, value: f.value ?? null, hidden: f.type === HIDDEN_FIELD })),
        notes: raw.notes ?? null,
    };
}

/** A cipher's metadata (vault.listCipherMeta) as a contract LoginMeta. */
export function toMeta(raw, equivalence) {
    const hosts = []; const byDomain = [];
    for (const u of raw.uris) {
        const h = safeHost(u.uri);
        if (!h) continue;
        if (!hosts.includes(h)) hosts.push(h);
        if (matchName(u.match) === 'domain' && !byDomain.includes(h)) byDomain.push(h);
    }
    const equivalents = equivalentsFor(byDomain, equivalence);
    return {
        id: raw.id,
        name: raw.name,
        username: raw.username,
        uris: raw.uris.map((u) => ({ url: shownUri(u.uri), match: matchName(u.match) })).filter((u) => u.url),
        hosts,
        has: { username: raw.present.includes('username'), password: raw.present.includes('password'), totp: raw.present.includes('totp') },
        fields: raw.fields.filter((f) => f.type !== LINKED_FIELD).map((f) => ({ name: f.name, hidden: f.type === HIDDEN_FIELD })),
        revisionDate: raw.revisionDate,
        trashed: raw.trashed,
        shared: raw.organization,
        ...(equivalents.size ? { equivalents } : {}),
    };
}

/**
 * A Vaultwarden provider. config: {id?, url, clientId, clientSecret, userKey,
 * deviceId, and vault.mjs's optional fetchImpl, ttlMs, now, timeoutMs}.
 */
export function createVaultwardenProvider({ id = 'vaultwarden', ...config } = {}) {
    const v = createVault(config);
    return {
        id,
        type: 'vaultwarden',
        capabilities: Object.freeze({ restore: 'native', equivalentDomains: true, totp: true }),
        checkId: (x) => (v.isId(x) ? x.toLowerCase() : null),
        status: () => v.status(),
        async sync({ force = false } = {}) { await v.sync({ force }); },
        async listItems({ trash = false, force = false } = {}) {
            const { items, equivalence } = await v.listCipherMeta({ force, trash });
            return items.map((r) => toMeta(r, equivalence));
        },
        async readItem(itemId) { return toLogin(await v.readCipher(itemId)); },
        createLogin: (spec) => v.createLogin(spec),
        updateLogin: (itemId, patch) => v.updateLogin(itemId, patch),
        trashLogin: (itemId) => v.trashLogin(itemId),
        restoreLogin: (itemId) => v.restoreLogin(itemId),
        lock: () => v.lock(),
    };
}
