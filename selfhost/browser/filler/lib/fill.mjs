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
//      belongs to one client only), read from the agent account's vault;
//   3. allowed hosts = item https URIs ∩ policy hosts, matched exactly;
//   4. the session's page is https on an allowed host;
//   5. the element is in the main document's current interactables and its
//      kind fits the field (password into type=password only, and so on);
//   6. type with sensitive:true, response discarded;
//   7. the page is checked again: a host change is an error and is audited.
import { allowedHosts, httpsHost, matchHost } from './hosts.mjs';
import { currentTotp } from './totp.mjs';
import { pageUrl, isLive } from './controller.mjs';
import { NO_CHAT } from './policy.mjs';

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
    const hostOf = (url, allowed) => {
        const h = matchHost(url, allowed);
        if (h) return h;
        if (allowLoopbackHttp) {
            try {
                const u = new URL(url);
                if (u.protocol === 'http:' && u.hostname === '127.0.0.1' && allowed.includes('127.0.0.1')) return '127.0.0.1';
            } catch {}
        }
        return null;
    };
    const hostsFor = (uris, policyHosts) => {
        const hs = allowedHosts(uris, policyHosts);
        if (allowLoopbackHttp && policyHosts.includes('127.0.0.1') && uris.some((u) => /^http:\/\/127\.0\.0\.1(:\d+)?\//.test(u))) hs.push('127.0.0.1');
        return hs;
    };

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

    async function liveHost(b, allowed) {
        let rec;
        try { rec = await b.controller.getSession(b.session); } catch (err) {
            throw new FillError(err.status === 404 ? 'no such browser session' : 'browser controller unavailable', err.status === 404 ? 404 : 502, 'controller');
        }
        if (!isLive(rec)) throw new FillError('the browser session is not active', 409, 'session_closed');
        const url = pageUrl(rec);
        const host = hostOf(url, allowed);
        return { host, pageHost: httpsHost(url) };
    }

    async function readValue(ctx, entry) {
        const item = await vault.readItem(entry.item_id).catch((err) => {
            throw new FillError(`vault: ${err.message}`, err.status === 404 ? 404 : 403, 'vault');
        });
        return item;
    }

    /** Type one field. Shared by fill() and login(). Returns {kind, host}. */
    async function typeField(ctx, { chat, b, element, name, field, item, allowed, observed }) {
        const base = { chat, client: ctx.client, path: ctx.path, session: b.key, name, field_kind: field };
        const { host } = await liveHost(b, allowed);
        if (!host) { audit.record({ ...base, outcome: 'refused_host' }); throw new FillError('the page is not on a host this secret is allowed on', 403, 'refused_host'); }
        const obs = observed || await b.controller.observe(b.session);
        if (hostOf(pageUrl(obs), allowed) !== host) { audit.record({ ...base, host, outcome: 'refused_host' }); throw new FillError('the page changed host', 409, 'refused_host'); }
        const el = (obs.interactables || []).find((e) => e.element_id === element);
        if (!el) { audit.record({ ...base, host, outcome: 'refused_element' }); throw new FillError('element not found in the page (observe again for current element ids)', 404, 'refused_element'); }
        if (!kindsOf(el).includes(field)) { audit.record({ ...base, host, outcome: 'refused_kind' }); throw new FillError(`that element cannot take a ${field}`, 422, 'refused_kind'); }
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
            audit.record({ ...base, host, outcome: 'type_failed' });
            throw new FillError('typing failed in the browser', 502, 'type_failed');
        } finally { value = null; }
        const after = await liveHost(b, allowed).catch(() => ({ host: null }));
        if (after.host !== host) {
            audit.record({ ...base, host, outcome: 'host_changed' });
            throw new FillError('the page left the allowed host while the secret was typed; the session stays tainted', 409, 'host_changed');
        }
        audit.record({ ...base, host, outcome: 'filled' });
        return { kind: field, host };
    }

    async function list({ chat }) {
        const ctx = scope(chat);
        return {
            client: ctx.client,
            secrets: ctx.policy.entries(ctx.client).map((e) => ({ name: e.name, hosts: [...e.hosts], kind: e.field })),
        };
    }

    async function fill(body) {
        const { chat, element_id: element, name } = body;
        if (typeof element !== 'string' || !element) throw new FillError('session_id and element_id are required', 400, 'bad_request');
        const b = browser(body);
        const session = b.key;
        const ctx = scope(chat);
        const bind = taint.checkBinding(session, chat, ctx.client);
        if (bind) { audit.record({ chat, client: ctx.client, path: ctx.path, session, name, outcome: 'refused_binding' }); throw new FillError(bind, 403, 'refused_binding'); }
        const entry = ctx.policy.resolve(ctx.client, name);
        if (!entry) { audit.record({ chat, client: ctx.client, path: ctx.path, session, name: String(name ?? '').slice(0, 80), outcome: 'refused_name' }); throw new FillError('no such secret for this chat (see browser_list_secrets)', 404, 'refused_name'); }
        const item = await readValue(ctx, entry);
        const allowed = hostsFor(item.uris, entry.hosts);
        if (!allowed.length) { audit.record({ chat, client: ctx.client, path: ctx.path, session, name: entry.name, outcome: 'refused_no_hosts' }); throw new FillError('this secret has no host that both the vault item and the policy allow', 403, 'refused_no_hosts'); }
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
        const sec = ctx.policy.secret(ctx.client, site);
        if (!sec) throw new FillError('no such site for this chat (see browser_list_secrets)', 404, 'refused_name');
        const item = await readValue(ctx, sec);
        const allowed = hostsFor(item.uris, sec.hosts);
        if (!allowed.length) throw new FillError('this site has no host that both the vault item and the policy allow', 403, 'refused_no_hosts');
        const can = (f) => sec.fields.includes(f) && (f === 'totp' ? !!item.totp : !!item[f]);
        const done = new Set();
        let host = null;
        for (let step = 1; step <= 3; step++) {
            const { host: h } = await liveHost(b, allowed);
            if (!h) return { status: 'needs_human', host, reason: 'the page is not on an allowed host' };
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
