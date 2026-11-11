// 1Password SDK shapes -> the provider contract (../index.mjs). Pure functions;
// no SDK import, so the mapping is testable without the WASM core.
//
// Item (SDK)                               contract
//   title                                  name
//   built-in field id "username"           username
//   built-in field id "password"           password
//   first Totp field's value (the seed)    totp
//   websites[].url / autofillBehavior      uris[].url / match (MATCH below)
//   other fields (title, value)            fields[] (hidden: Concealed)
//   notes                                  notes
//   tags includes TRASH_TAG                trashed
//   updatedAt                              revisionDate
import { httpsHost } from '../../hosts.mjs';

/** The tag that marks a login as removed (capabilities.restore = 'tag'). */
export const TRASH_TAG = 'happy-trashed';

/** A 1Password item id: 26 of a-z 0-9 (canonical: lower case). */
export const ID = /^[a-z0-9]{26}$/;

// SDK AutofillBehavior -> contract match. Anything unknown reads as 'exact',
// the strictest rule the contract has.
const MATCH = new Map([['AnywhereOnWebsite', 'domain'], ['ExactDomain', 'host'], ['Never', 'never']]);
export const matchName = (b) => MATCH.get(b) ?? 'exact';
/** The autofill behaviour for a new website (1Password's own default). */
export const NEW_WEBSITE_BEHAVIOR = 'AnywhereOnWebsite';

// Field types whose value is a plain string a login form could take.
const VALUE_TYPES = new Set(['Text', 'Concealed', 'Email', 'Phone', 'Url', 'Menu', 'Date', 'MonthYear', 'CreditCardType', 'CreditCardNumber']);
const HIDDEN_TYPES = new Set(['Concealed', 'CreditCardNumber']);

const str = (v) => (typeof v === 'string' && v !== '' ? v : null);
const builtIn = (f) => !f.sectionId;

/** The built-in username field, else a top-level Text/Email field titled "username". */
export function usernameField(item) {
    const fs = item.fields || [];
    return fs.find((f) => builtIn(f) && f.id === 'username')
        || fs.find((f) => builtIn(f) && (f.fieldType === 'Text' || f.fieldType === 'Email') && /^user ?name$/i.test(f.title || ''))
        || null;
}
/** The built-in password field. */
export function passwordField(item) {
    return (item.fields || []).find((f) => builtIn(f) && f.id === 'password' && f.fieldType === 'Concealed') || null;
}
/** The first one-time password field. */
export function totpField(item) {
    return (item.fields || []).find((f) => f.fieldType === 'Totp') || null;
}
/** Every other field that carries a plain value. */
export function customFields(item) {
    const skip = new Set([usernameField(item), passwordField(item)]);
    return (item.fields || []).filter((f) => !skip.has(f) && VALUE_TYPES.has(f.fieldType) && typeof f.title === 'string' && f.title);
}

export const isTrashed = (item) => Array.isArray(item.tags) && item.tags.includes(TRASH_TAG);

/** Scheme, host and path of an http(s) URL, else null (never userinfo, query or fragment). */
export function shownUri(u) {
    try {
        const x = new URL(u);
        if (!/^https?:$/.test(x.protocol) || !x.host) return null;
        return `${x.protocol}//${x.host}${x.pathname === '/' ? '' : x.pathname}`.slice(0, 300);
    } catch { return null; }
}

const iso = (d) => {
    const t = d instanceof Date ? d.getTime() : (typeof d === 'string' ? Date.parse(d) : NaN);
    return Number.isFinite(t) ? new Date(t).toISOString() : null;
};

/** A full SDK Item as a contract Login (with values). */
export function toLogin(item) {
    const t = totpField(item);
    return {
        id: item.id,
        name: str(item.title),
        username: str(usernameField(item)?.value),
        password: str(passwordField(item)?.value),
        totp: str(t?.value),
        uris: (item.websites || []).filter((w) => typeof w?.url === 'string' && w.url).map((w) => ({ url: w.url, match: matchName(w.autofillBehavior) })),
        fields: customFields(item).map((f) => ({ name: f.title, value: str(f.value), hidden: HIDDEN_TYPES.has(f.fieldType) })),
        notes: str(item.notes),
    };
}

/** A full SDK Item as a contract LoginMeta: no password, TOTP or field value. */
export function toMeta(item) {
    const hosts = [];
    for (const w of item.websites || []) {
        const h = httpsHost(w?.url);
        if (h && !hosts.includes(h)) hosts.push(h);
    }
    return {
        id: item.id,
        name: str(item.title),
        username: str(usernameField(item)?.value),
        uris: (item.websites || []).map((w) => ({ url: shownUri(w?.url), match: matchName(w?.autofillBehavior) })).filter((u) => u.url),
        hosts,
        has: { username: !!str(usernameField(item)?.value), password: !!str(passwordField(item)?.value), totp: !!str(totpField(item)?.value) },
        fields: customFields(item).map((f) => ({ name: f.title, hidden: HIDDEN_TYPES.has(f.fieldType) })),
        revisionDate: iso(item.updatedAt),
        trashed: isTrashed(item),
        shared: false,
    };
}

export const byNameThenId = (a, b) => String(a.name ?? '').localeCompare(String(b.name ?? '')) || a.id.localeCompare(b.id);
