// An in-memory stand-in for the @1password/sdk Client, with the SDK's shapes
// (types.d.ts of 0.5.0): client.vaults.list, client.items.{list, get, getAll,
// create, put, archive, delete}. It holds the same logins as
// fake-vaultwarden.mjs's buildVault() so one conformance suite runs on both.
//
// Like the SDK, items.get / put / delete on a missing item reject with a plain
// Error whose message quotes the input; the provider must never pass it on.
// rateLimit(n) makes the next n calls throw RateLimitExceededError.
import { randomBytes } from 'node:crypto';

export class RateLimitExceededError extends Error { constructor(m) { super(); this.message = m; } }
export class AuthExpiredError extends Error { constructor(m) { super(); this.message = m; } }

const ALPHA = 'abcdefghijklmnopqrstuvwxyz0123456789';
export const newId = () => [...randomBytes(26)].map((b) => ALPHA[b % 36]).join('');

export const TOTP_SECRET = 'JBSWY3DPEHPK3PXP';
export const VAULT_TITLE = 'Agent - Happy';

const clone = (x) => structuredClone(x);

/** The seed logins, by label. Mirrors fake-vaultwarden.mjs. */
export function seedItems(vaultId) {
    const t = new Date('2026-01-02T03:04:05.000Z');
    const login = (title, { username, password, websites = [], fields = [], totp, notes = '', tags = [], category = 'Login' } = {}) => ({
        id: newId(), title, category, vaultId,
        fields: [
            ...(username !== undefined ? [{ id: 'username', title: 'username', fieldType: 'Text', value: username }] : []),
            ...(password !== undefined ? [{ id: 'password', title: 'password', fieldType: 'Concealed', value: password }] : []),
            ...(totp ? [{ id: 'TOTP_abc', title: 'one-time password', sectionId: 'add more', fieldType: 'Totp', value: totp, details: { type: 'Otp', content: { code: '123456' } } }] : []),
            ...fields,
        ],
        sections: [{ id: 'add more', title: '' }], notes, tags, websites, version: 1, files: [], createdAt: t, updatedAt: t,
    });
    const site = (url, autofillBehavior = 'AnywhereOnWebsite') => ({ url, label: 'website', autofillBehavior });
    return {
        'acme-github': login('acme-github', { username: 'agent@example.com', password: 'gh-pass', totp: TOTP_SECRET, websites: [site('https://github.com/login'), site('https://www.github.com')] }),
        'acme-portal': login('acme-portal', {
            username: 'portal-user', password: 'portal-pass', websites: [site('https://portal.acme.test')],
            fields: [
                { id: 'f1', title: 'token', sectionId: 'add more', fieldType: 'Concealed', value: 'tok-value' },
                { id: 'f2', title: 'api-key', sectionId: 'add more', fieldType: 'Concealed', value: 'api-secret' },
            ],
        }),
        'acme-trashed': login('acme-trashed', { username: 'old', password: 'old-pass', websites: [site('https://old.acme.test')], tags: ['happy-trashed'] }),
        'gmail-host': login('gmail-host', { username: 'g@example.com', password: 'g-pass', websites: [site('https://mail.google.com', 'ExactDomain')] }),
        'never-site': login('never-site', { username: 'n', password: 'n-pass', websites: [site('https://never.acme.test', 'Never')] }),
        'a-note': login('a-note', { category: 'SecureNote', notes: 'not a login' }),
    };
}

/**
 * A fake client. opts: {vaults: [{id, title}] (default: one VAULT_TITLE vault),
 * items: label -> Item (default: seedItems)}. Returns {client, vaultId, items,
 * calls, rateLimit(n), expireAuth(), byLabel(label)}.
 */
export function fakeOnePassword(opts = {}) {
    const vaultId = newId();
    const vaults = opts.vaults || [{ id: vaultId, title: VAULT_TITLE }];
    const seeded = opts.items || seedItems(vaultId);
    const store = new Map(Object.values(seeded).map((it) => [it.id, { item: clone(it), state: 'active' }]));
    const labels = new Map(Object.entries(seeded).map(([k, it]) => [k, it.id]));
    const calls = [];
    let limited = 0, expired = false;

    const gate = (name, args) => {
        calls.push({ name, args });
        if (limited > 0) { limited--; throw new RateLimitExceededError('rate limit exceeded'); }
        if (expired) { expired = false; throw new AuthExpiredError('auth expired'); }
    };
    const find = (vid, id) => {
        const e = store.get(id);
        if (!e || e.item.vaultId !== vid) throw new Error(`item ${id} not found in vault ${vid}`);
        return e;
    };
    const overview = (e) => ({ id: e.item.id, title: e.item.title, category: e.item.category, vaultId: e.item.vaultId, websites: clone(e.item.websites), tags: [...e.item.tags], createdAt: e.item.createdAt, updatedAt: e.item.updatedAt, state: e.state });

    const client = {
        vaults: {
            async list() { gate('vaults.list', []); return vaults.map((v) => ({ id: v.id, title: v.title, description: '', vaultType: 'userCreated', activeItemCount: 0, contentVersion: 1, attributeVersion: 1 })); },
        },
        items: {
            async list(vid, ...filters) {
                gate('items.list', [vid, ...filters]);
                const f = filters.find((x) => x?.type === 'ByState')?.content ?? { active: true, archived: false };
                return [...store.values()].filter((e) => e.item.vaultId === vid && (e.state === 'active' ? f.active : f.archived)).map(overview);
            },
            async get(vid, id) { gate('items.get', [vid, id]); return clone(find(vid, id).item); },
            async getAll(vid, ids) {
                gate('items.getAll', [vid, ids]);
                return { individualResponses: ids.map((id) => { try { return { content: clone(find(vid, id).item) }; } catch { return { error: { type: 'itemNotFound' } }; } }) };
            },
            async create(p) {
                gate('items.create', [{ ...p, fields: '<redacted>' }]);
                if (!vaults.some((v) => v.id === p.vaultId)) throw new Error(`vault ${p.vaultId} not found`);
                const t = new Date();
                const item = { id: newId(), title: p.title, category: p.category, vaultId: p.vaultId, fields: clone(p.fields || []), sections: clone(p.sections || []), notes: p.notes || '', tags: [...(p.tags || [])], websites: clone(p.websites || []), version: 1, files: [], createdAt: t, updatedAt: t };
                store.set(item.id, { item, state: 'active' });
                return clone(item);
            },
            async put(item) {
                gate('items.put', [item.id]);
                const e = find(item.vaultId, item.id);
                if (item.version !== e.item.version) throw new Error('item version conflict');
                e.item = { ...clone(item), version: e.item.version + 1, updatedAt: new Date(e.item.updatedAt.getTime() + 1000) };
                return clone(e.item);
            },
            async archive(vid, id) { gate('items.archive', [vid, id]); find(vid, id).state = 'archived'; },
            async delete(vid, id) { gate('items.delete', [vid, id]); store.delete(find(vid, id).item.id); },
            async deleteAll(vid, ids) { gate('items.deleteAll', [vid, ids]); for (const id of ids) store.delete(id); return { individualResponses: [] }; },
        },
    };
    return {
        client, vaultId, store, calls,
        rateLimit(n = 1) { limited = n; },
        expireAuth() { expired = true; },
        byLabel: (label) => labels.get(label),
        unarchive(id) { store.get(id).state = 'active'; },
    };
}
