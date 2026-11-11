// Host matching for fills. A host is allowed if it is both in the vault item's
// https URIs and in the policy's hosts for that secret. Matching is exact on the
// punycoded, lowercased hostname: no suffix match, no userinfo, the default
// https port only. The one widening is equivalent domains, which only
// all_items logins get: matchAllowed takes an equiv map from fill.mjs, built by
// the vault provider (providers/vaultwarden/domains.mjs for Vaultwarden).
import { domainToASCII } from 'node:url';
import { SUFFIXES, WILDCARD_TLDS } from './psl.mjs';

/** Normalize a policy host entry ("github.com", "Bücher.de") or null. */
export function normalizeHost(h) {
    if (typeof h !== 'string') return null;
    const s = h.trim().replace(/\.$/, '');
    if (!s || /[/:@\s?#\\]/.test(s)) return null;
    const ascii = domainToASCII(s.toLowerCase());
    return ascii && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/.test(ascii) ? ascii : null;
}

/** The hostname of an https URL with no userinfo and the default port, else null. */
export function httpsHost(url) {
    let u;
    try { u = new URL(String(url)); } catch { return null; }
    if (u.protocol !== 'https:' || u.username || u.password || u.port !== '') return null;
    // WHATWG URL already punycodes and lowercases; strip a trailing dot.
    const h = u.hostname.replace(/\.$/, '');
    return h && !h.startsWith('[') ? h : null;
}

/** Hosts a secret may be typed into: item URIs intersected with the policy's hosts. */
export function allowedHosts(itemUris, policyHosts) {
    const fromItem = new Set((itemUris || []).map(httpsHost).filter(Boolean));
    const out = [];
    for (const h of policyHosts || []) {
        const n = normalizeHost(h);
        if (n && fromItem.has(n) && !out.includes(n)) out.push(n);
    }
    return out;
}

/** Whether a page URL is https on one of the allowed hosts. Returns the host or null. */
export function matchHost(pageUrl, allowed) {
    const h = httpsHost(pageUrl);
    return h && allowed.includes(h) ? h : null;
}

/**
 * Whether a page URL is https on an allowed host: exactly one of allow.hosts,
 * or (allow.equiv, registrable domain -> granting saved host) a host whose
 * registrable domain an equivalence grants. Returns {host} or
 * {host, equivalent_of} or null.
 */
export function matchAllowed(pageUrl, allow) {
    const h = httpsHost(pageUrl);
    if (!h || !allow) return null;
    if (allow.hosts.includes(h)) return { host: h };
    const saved = allow.equiv?.size ? allow.equiv.get(registrableDomain(h)) : null;
    return saved ? { host: h, equivalent_of: saved } : null;
}

const IPV4 = /^\d{1,3}(?:\.\d{1,3}){3}$/;

/** The registrable domain of a host ("accounts.google.co.uk" -> "google.co.uk"), or null for a suffix, an IP or junk. */
export function registrableDomain(host) {
    if (typeof host !== 'string') return null;
    const h = host.trim().toLowerCase().replace(/\.$/, '');
    if (!h || IPV4.test(h) || /[^a-z0-9.-]/.test(h)) return null;
    const labels = h.split('.');
    if (labels.length < 2 || labels.some((l) => !l)) return null;
    let suffix = 1; // the TLD
    for (let k = labels.length; k >= 2; k--) {
        if (SUFFIXES.has(labels.slice(-k).join('.'))) { suffix = k; break; }
    }
    if (suffix === 1 && WILDCARD_TLDS.has(labels.at(-1))) suffix = 2;
    return labels.length > suffix ? labels.slice(-(suffix + 1)).join('.') : null;
}

/**
 * A short label for the equivalents of saved hosts: the domains beyond the
 * saved hosts' own, at most three, e.g. "+ google.com, youtube.com equivalents"
 * or "+ amazon.ca, amazon.cn, amazon.co.jp … 20 more equivalents". Null when there are none.
 */
export function describeEquivalents(hosts, equivalents) {
    if (!equivalents?.size) return null;
    const own = new Set((hosts || []).map(registrableDomain));
    const others = [...equivalents.keys()].filter((d) => !own.has(d)).sort();
    if (!others.length) return null;
    return `+ ${others.slice(0, 3).join(', ')}${others.length > 3 ? ` … ${others.length - 3} more` : ''} equivalents`;
}
