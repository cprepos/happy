// Fill and login flows. The agent names a secret ("github.password"); the
// filler decides whether it may be typed, where, and into what, and types it
// with its own controller token. No value is ever returned.
//
// Guards, in order, for every fill:
//   1. the chat is bound to a client in the policy (its own entry in chats, or
//      default_client when the policy has one; a caller with no chat id names
//      chat "none", which only default_client serves); the session is not
//      bound to another (chat, client). The audit says which: path mapped or
//      default;
//   2. the name resolves through that client's policy to one item id (each id
//      belongs to one client only), read from the agent account's vault; or,
//      for an all_items client and a name its secrets do not list, to the
//      vault login of that name that no client lists by id;
//   3. allowed hosts = item https URIs ∩ policy hosts, matched exactly (for an
//      all_items login, the policy hosts are the item's own https URI hosts;
//      an item without one is refused). An all_items login also allows the
//      hosts the vault's equivalent domains grant (domains.mjs) unless its
//      client sets "equivalent_domains": false; explicit secrets never do;
//   4. the session's page is https on an allowed host (a fill allowed through
//      equivalence is audited with via and equivalent_of);
//   5. the element is in the main document's current interactables and its
//      kind fits the field (password into type=password only, and so on);
//   6. type with sensitive:true, response discarded;
//   7. the page is checked again: a host change is an error and is audited.
import { allowedHosts, httpsHost, matchAllowed } from './hosts.mjs';
import { describeEquivalents } from './providers/vaultwarden/domains.mjs';
import { currentTotp } from './totp.mjs';
import { pageUrl, isLive } from './controller.mjs';
import { FIELDS, itemSlug, NO_CHAT } from './policy.mjs';

/** "https://github.com" for a page URL: scheme and host only, never a path, query or userinfo. */
function shownOrigin(url) {
    try {
        const u = new URL(String(url));
        return u.host && /^[a-z0-9.:\[\]-]+$/i.test(u.host) ? `${u.protocol}//${u.host}` : null;
    } catch { return null; }
}

export class FillError extends Error {
    constructor(message, status = 403, outcome = 'refused') { super(message); this.status = status; this.outcome = outcome; }
}

const TOTP_LABEL = /\b(otp|totp|2fa|mfa|one[- ]?time|two[- ]?factor|verification|authenticat\w*|security code|auth code)\b|\bcode\b/i;
const USER_LABEL = /user|email|e-mail|login|account|phone|mobile|identifier|name/i;
const TEXTISH = new Set([null, undefined, '', 'text', 'email', 'tel']);

/** What an observed interactable can take: 'password' | 'username' | 'totp' | null. */
export function kindsOf(el) {
    if (!el || String(el.tag || '').toLowerCase() !== 'input' || el.disabled) return [];
    const type = el.type == null ? null : String(el.type).toLowerCase();
    if (type === 'password') return ['password'];
    const out = [];
    const label = String(el.label || '');
    if ((TEXTISH.has(type) || type === 'number') && TOTP_LABEL.test(label)) out.push('totp');
    if (TEXTISH.has(type)) out.push('username');
    return out;
}

export function createFiller({ getPolicy, vault, controllers, taint, audit, sleep = (ms) => new Promise((r) => setTimeout(r, ms)), allowLoopbackHttp = false, totpOpts = {} }) {
    // allow = {hosts: exact hosts, equiv: Map registrable domain -> granting saved host, or null}.
    const matchOf = (url, allow) => {
        const m = matchAllowed(url, allow);
        if (m) return m;
        if (allowLoopbackHttp) {
            try {
                const u = new URL(url);
                if (u.protocol === 'http:' && u.hostname === '127.0.0.1' && allow.hosts.includes('127.0.0.1')) return { host: '127.0.0.1' };
            } catch {}
        }
        return null;
    };
    const hostOf = (url, allow) => matchOf(url, allow)?.host ?? null;
    const allowFor = (uris, sec) => {
        const hosts = allowedHosts(uris, sec.hosts);
        if (allowLoopbackHttp && sec.hosts.includes('127.0.0.1') && uris.some((u) => /^http:\/\/127\.0\.0\.1(:\d+)?\//.test(u))) hosts.push('127.0.0.1');
        // Equivalence only for grants whose saved host the item still has.
        const equiv = sec.equiv?.size ? new Map([...sec.equiv].filter(([, saved]) => hosts.includes(saved))) : null;
        return { hosts, equiv: equiv?.size ? equiv : null };
    };
    const allowedText = (allow) => allow.hosts.map((h) => `https://${h}`).join(', ') + (allow.equiv ? ` (${describeEquivalents(allow.hosts, allow.equiv) || 'and their equivalent domains'})` : '');

    // A request names its browser by controller port (the shared stack's 8010,
    // or a per-chat pod's 81NN); only ports in the configured list are reached.
    // Taint and bindings are kept per (port, session).
    function browser(body) {
        const port = body.controller_port ?? null;
        const r = controllers(port);
        if (!r) throw new FillError('that browser controller is not one the filler may use', 403, 'refused_controller');
        if (typeof body.session_id !== 'string' || !body.session_id || body.session_id.length > 200) throw new FillError('session_id is required', 400, 'bad_request');
        return { controller: r.controller, port: r.port, session: body.session_id, key: `${r.port}/${body.session_id}` };
    }

    function scope(chat) {
        const policy = getPolicy();
        const sc = policy.scopeOf(chat);
        if (!sc) {
            if (chat === NO_CHAT) throw new FillError('this agent process has no chat id, and the filler policy has no default_client, so it may not use vault secrets', 403, 'unbound_chat');
            throw new FillError('this chat is not bound to a client in the filler policy; ask the user to bind it', 403, 'unbound_chat');
        }
        return { policy, client: sc.client, path: sc.path, cfg: policy.client(sc.client) };
    }

    // all_items: the client's vault logins by name ("github-work" -> login),
    // from the vault's cached sync, so a login added to the vault appears on
    // the next sync. Skipped: organization items, items some client lists by
    // id, names the client's secrets already use. Two items with one name map
    // to null (ambiguous, refused).
    async function vaultLogins(ctx) {
        if (!ctx.policy.allItems(ctx.client)) return new Map();
        const logins = await vault.listLogins({ force: false }).catch((err) => {
            throw new FillError(`vault: ${err.message}`, err.status === 404 ? 404 : 502, 'vault');
        });
        const by = new Map();
        for (const l of logins) {
            if (l.organization || ctx.policy.isListed(l.id)) continue;
            const slug = itemSlug(l.name);
            if (!slug || ctx.cfg.secrets.has(slug)) continue;
            by.set(slug, by.has(slug) ? null : l);
        }
        return by;
    }

    /** An all_items login as a policy secret {secret, item_id, hosts, fields, all_items}, or null. */
    async function vaultSecret(ctx, secret) {
        const by = await vaultLogins(ctx);
        if (!by.has(secret)) return null;
        const l = by.get(secret);
        if (!l) throw new FillError(`two vault logins are named "${secret}"; rename one in the vault`, 409, 'refused_ambiguous');
        const equiv = ctx.policy.equivalentDomains(ctx.client) && l.equivalents?.size ? l.equivalents : null;
        return { secret, item_id: l.id, hosts: l.hosts, fields: FIELDS, all_items: true, equiv };
    }

    async function vaultEntry(ctx, name) {
        const m = /^([a-z0-9][a-z0-9_-]{0,62})\.(username|password|totp)$/.exec(String(name ?? ''));
        if (!m) return null;
        const s = await vaultSecret(ctx, m[1]);
        return s ? { name: `${m[1]}.${m[2]}`, secret: m[1], field: m[2], item_id: s.item_id, hosts: s.hosts, equiv: s.equiv } : null;
    }

    async function liveHost(b, allowed) {
        let rec;
        try { rec = await b.controller.getSession(b.session); } catch (err) {
            throw new FillError(err.status === 404 ? 'no such browser session' : 'browser controller unavailable', err.status === 404 ? 404 : 502, 'controller');
        }
        if (!isLive(rec)) throw new FillError('the browser session is not active', 409, 'session_closed');
        const url = pageUrl(rec);
        const m = matchOf(url, allowed);
        return { host: m?.host ?? null, equivalent_of: m?.equivalent_of ?? null, pageHost: httpsHost(url), shown: shownOrigin(url) };
    }

    async function readValue(ctx, entry) {
        const item = await vault.readItem(entry.item_id).catch((err) => {
            throw new FillError(`vault: ${err.message}`, err.status === 404 ? 404 : 403, 'vault');
        });
        return item;
    }

    // A host refusal names the page's host and the hosts allowed (never a value or a full URL), so the
    // agent can tell the user which URI to add to the vault item.
    const hostRefusal = (what, page, allowed) =>
        `the page is on ${page.shown || 'a page with no host'}, which is not a host this ${what} is allowed on ` +
        `(allowed: ${allowedText(allowed)}). Navigate to one of those` +
        (page.pageHost ? `, or ask the user to add https://${page.pageHost} as a URI on the vault item (and to the filler policy hosts, if the login is listed there)` : ' (only https pages can be filled)');

    /** Type one field. Shared by fill() and login(). Returns {kind, host}. */
    async function typeField(ctx, { chat, b, element, name, field, item, allowed, observed }) {
        const base = { chat, client: ctx.client, path: ctx.path, session: b.key, name, field_kind: field };
        const page = await liveHost(b, allowed);
        const { host } = page;
        const via = page.equivalent_of ? { via: 'equivalent_domains', equivalent_of: page.equivalent_of } : {};
        if (!host) { audit.record({ ...base, ...(page.pageHost ? { host: page.pageHost } : {}), outcome: 'refused_host' }); throw new FillError(hostRefusal('secret', page, allowed), 403, 'refused_host'); }
        const obs = observed || await b.controller.observe(b.session);
        if (hostOf(pageUrl(obs), allowed) !== host) { audit.record({ ...base, host, ...via, outcome: 'refused_host' }); throw new FillError('the page changed host', 409, 'refused_host'); }
        const el = (obs.interactables || []).find((e) => e.element_id === element);
        if (!el) { audit.record({ ...base, host, ...via, outcome: 'refused_element' }); throw new FillError('element not found in the page (observe again for current element ids)', 404, 'refused_element'); }
        if (!kindsOf(el).includes(field)) { audit.record({ ...base, host, ...via, outcome: 'refused_kind' }); throw new FillError(`that element cannot take a ${field}`, 422, 'refused_kind'); }
        let value;
        if (field === 'totp') {
            if (!item.totp) throw new FillError('this item has no TOTP', 422, 'no_value');
            try { value = await currentTotp(item.totp, totpOpts); } catch (err) { throw new FillError(`TOTP: ${err.message}`, 422, 'no_value'); }
        } else {
            value = item[field];
            if (!value) throw new FillError(`this item has no ${field}`, 422, 'no_value');
        }
        taint.mark(b.key, { chat, client: ctx.client, name, value, kind: field, port: b.port, session: b.session });
        try {
            await b.controller.type(b.session, element, value);
        } catch (err) {
            audit.record({ ...base, host, ...via, outcome: 'type_failed' });
            throw new FillError('typing failed in the browser', 502, 'type_failed');
        } finally { value = null; }
        const after = await liveHost(b, allowed).catch(() => ({ host: null }));
        if (after.host !== host) {
            audit.record({ ...base, host, ...via, outcome: 'host_changed' });
            throw new FillError('the page left the allowed host while the secret was typed; the session stays tainted', 409, 'host_changed');
        }
        audit.record({ ...base, host, ...via, outcome: 'filled' });
        return { kind: field, host, ...(page.equivalent_of ? { equivalent_of: page.equivalent_of } : {}) };
    }

    async function list({ chat }) {
        const ctx = scope(chat);
        const secrets = ctx.policy.entries(ctx.client).map((e) => ({ name: e.name, hosts: [...e.hosts], kind: e.field }));
        // all_items: each usable vault login by name, with the fields it has. Logins
        // with no https URI, or sharing a name, cannot be filled and are not listed.
        for (const [slug, l] of [...(await vaultLogins(ctx))].sort((a, b) => a[0].localeCompare(b[0]))) {
            if (!l || !l.hosts.length) continue;
            const eq = ctx.policy.equivalentDomains(ctx.client) ? describeEquivalents(l.hosts, l.equivalents) : null;
            for (const f of FIELDS) if (l.fields.includes(f)) secrets.push({ name: `${slug}.${f}`, hosts: [...l.hosts], kind: f, ...(eq ? { equivalents: eq } : {}) });
        }
        return { client: ctx.client, secrets };
    }

    async function fill(body) {
        const { chat, element_id: element, name } = body;
        if (typeof element !== 'string' || !element) throw new FillError('session_id and element_id are required', 400, 'bad_request');
        const b = browser(body);
        const session = b.key;
        const ctx = scope(chat);
        const bind = taint.checkBinding(session, chat, ctx.client);
        if (bind) { audit.record({ chat, client: ctx.client, path: ctx.path, session, name, outcome: 'refused_binding' }); throw new FillError(bind, 403, 'refused_binding'); }
        let entry;
        try { entry = ctx.policy.resolve(ctx.client, name) || await vaultEntry(ctx, name); } catch (err) {
            if (err instanceof FillError && err.outcome === 'refused_ambiguous') audit.record({ chat, client: ctx.client, path: ctx.path, session, name: String(name ?? '').slice(0, 80), outcome: 'refused_ambiguous' });
            throw err;
        }
        if (!entry) { audit.record({ chat, client: ctx.client, path: ctx.path, session, name: String(name ?? '').slice(0, 80), outcome: 'refused_name' }); throw new FillError('no such secret for this chat (see browser_list_secrets)', 404, 'refused_name'); }
        const item = await readValue(ctx, entry);
        const allowed = allowFor(item.uris, entry);
        if (!allowed.hosts.length) { audit.record({ chat, client: ctx.client, path: ctx.path, session, name: entry.name, outcome: 'refused_no_hosts' }); throw new FillError('this secret has no host that both the vault item and the policy allow', 403, 'refused_no_hosts'); }
        const r = await typeField(ctx, { chat, b, element, name: entry.name, field: entry.field, item, allowed });
        return { ok: true, ...r };
    }

    /** Pick username / password / totp fields from an observe result. */
    function pickFields(obs) {
        const els = (obs.interactables || []).filter((e) => kindsOf(e).length);
        const password = els.find((e) => kindsOf(e).includes('password')) || null;
        const totp = els.find((e) => kindsOf(e).includes('totp')) || null;
        const users = els.filter((e) => kindsOf(e).includes('username') && e !== totp);
        const username = users.find((e) => USER_LABEL.test(String(e.label || '')) || String(e.type) === 'email') || (users.length === 1 ? users[0] : null);
        return { password, totp, username };
    }

    async function login(body) {
        const { chat, site } = body;
        const b = browser(body);
        const ctx = scope(chat);
        const bind = taint.checkBinding(b.key, chat, ctx.client);
        if (bind) throw new FillError(bind, 403, 'refused_binding');
        const sec = ctx.policy.secret(ctx.client, site) || (typeof site === 'string' && /^[a-z0-9][a-z0-9_-]{0,62}$/.test(site) ? await vaultSecret(ctx, site) : null);
        if (!sec) throw new FillError('no such site for this chat (see browser_list_secrets)', 404, 'refused_name');
        const item = await readValue(ctx, sec);
        const allowed = allowFor(item.uris, sec);
        if (!allowed.hosts.length) throw new FillError('this site has no host that both the vault item and the policy allow', 403, 'refused_no_hosts');
        const can = (f) => sec.fields.includes(f) && (f === 'totp' ? !!item.totp : !!item[f]);
        const done = new Set();
        let host = null;
        for (let step = 1; step <= 3; step++) {
            const page = await liveHost(b, allowed);
            const h = page.host;
            if (!h && step === 1) {
                audit.record({ chat, client: ctx.client, path: ctx.path, session: b.key, name: site, ...(page.pageHost ? { host: page.pageHost } : {}), outcome: 'refused_host' });
                throw new FillError(hostRefusal('login', page, allowed), 403, 'refused_host');
            }
            if (!h) return { status: 'needs_human', host, reason: `the page moved to ${page.shown || 'a page with no host'}, not a host this login is allowed on (allowed: ${allowedText(allowed)})` };
            host = h;
            const obs = await b.controller.observe(b.session);
            const f = pickFields(obs);
            const type = (el, field) => typeField(ctx, { chat, b, element: el.element_id, name: `${site}.${field}`, field, item, allowed, observed: obs });
            if (f.totp && can('totp') && !f.password) {
                await type(f.totp, 'totp');
                await b.controller.press(b.session, 'Enter');
                return { status: 'totp_submitted', host };
            }
            let acted = false;
            if (f.username && can('username') && !done.has('username')) { await type(f.username, 'username'); done.add('username'); acted = true; }
            if (f.password && can('password')) { await type(f.password, 'password'); done.add('password'); acted = true; }
            if (!acted) return { status: done.has('password') ? 'submitted' : 'needs_human', host, ...(done.has('password') ? {} : { reason: 'no fillable login field on the page' }) };
            await b.controller.press(b.session, 'Enter');
            await sleep(2000);
            if (done.has('password')) {
                // A one-time-code page may follow on the same host.
                const next = await liveHost(b, allowed);
                if (!next.host) return { status: 'submitted', host };
                const f2 = pickFields(await b.controller.observe(b.session));
                if (f2.totp && !f2.password && can('totp')) {
                    await typeField(ctx, { chat, b, element: f2.totp.element_id, name: `${site}.totp`, field: 'totp', item, allowed });
                    await b.controller.press(b.session, 'Enter');
                    return { status: 'totp_submitted', host };
                }
                return { status: 'submitted', host };
            }
        }
        return { status: done.size ? 'submitted' : 'needs_human', host };
    }

    return { list, fill, login, browserKey: (body) => browser(body).key };
}
