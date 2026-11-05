// Equivalent domains, as the Bitwarden extension applies them: a login saved
// for www.gmail.com also fills on accounts.google.com, because the vault
// groups gmail.com, google.com and youtube.com as one site.
//
// The groups come from the vault's /api/sync (domains): the account's own
// groups (equivalentDomains, set in the web vault under Settings > Domain
// rules) and Bitwarden's global groups (globalEquivalentDomains) that the
// account has not excluded. Matching is on registrable domains ("eTLD+1",
// psl.mjs): a page host is allowed through equivalence when its registrable
// domain is in a group with the saved host's registrable domain.
//
// Only all_items logins use this (fill.mjs), only for URIs with the default
// match detection, and only on https pages. A policy secret with its own hosts
// stays exact.
import { normalizeHost } from './hosts.mjs';
import { SUFFIXES, WILDCARD_TLDS } from './psl.mjs';

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
 * The equivalence index from a sync's domains object: Map registrable domain
 * -> Set of the registrable domains equivalent to it (itself included). A
 * domain in several groups gets their union, as in the extension. Excluded
 * global groups are skipped; so are listed entries that are not registrable
 * domains themselves (a public suffix such as net.cn or myshopify.com, a
 * subdomain, junk), and groups left with fewer than two domains.
 */
export function buildEquivalence(domains) {
    const index = new Map();
    if (!domains || typeof domains !== 'object') return index;
    const groups = [];
    const take = (list) => {
        if (!Array.isArray(list)) return;
        const g = [...new Set(list.map(normalizeHost).filter((d) => d && registrableDomain(d) === d))];
        if (g.length >= 2) groups.push(g);
    };
    for (const g of domains.equivalentDomains || domains.EquivalentDomains || []) take(g);
    for (const g of domains.globalEquivalentDomains || domains.GlobalEquivalentDomains || []) {
        if (!g || typeof g !== 'object' || g.excluded === true || g.Excluded === true) continue;
        take(g.domains || g.Domains);
    }
    for (const g of groups) {
        for (const d of g) {
            let s = index.get(d);
            if (!s) index.set(d, (s = new Set()));
            for (const x of g) s.add(x);
        }
    }
    return index;
}

/**
 * For saved hosts, the equivalence grants: Map registrable domain -> the saved
 * host that grants it. Empty when no saved host's domain is in a group.
 */
export function equivalentsFor(hosts, index) {
    const out = new Map();
    if (!index?.size) return out;
    for (const h of hosts || []) {
        const group = index.get(registrableDomain(h));
        if (!group) continue;
        for (const d of [...group].sort()) if (!out.has(d)) out.set(d, h);
    }
    return out;
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
