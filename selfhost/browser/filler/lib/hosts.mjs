// Exact host matching for fills. A host is allowed only if it is both in the
// vault item's https URIs and in the policy's hosts for that secret. Matching is
// exact on the punycoded, lowercased hostname: no suffix match, no userinfo, the
// default https port only.
import { domainToASCII } from 'node:url';

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
