// The live bridge's HTTP surface.
//
// Public, for the phone (reached only through the Happy Agent workspace proxy):
//   GET  /live/<id>            phone page: live frame, status, Take control, Release control
//   GET  /live/<id>/frame.jpg  latest frame (image/png as auto-browser captures it)
//   GET  /live/<id>/state      {status: watching|user|takeover|done, reason, url, title, last_action}
//   POST /live/<id>/take       the user takes control: watching -> user (takeover stays takeover);
//                              -> state plus novnc_url
//   POST /live/<id>/release    the user hands control back: user|takeover -> watching, waking waiters
//   POST /live/<id>/done       alias of /release, for app builds that predate it
// Unknown id -> 404, expired id -> 410.
//
// Private, for the MCP server (Authorization: Bearer <bridge-token>):
//   POST /api/links     {session_id}                -> {id, url, status}
//   POST /api/takeover  {session_id, reason}        -> {id, url, status}
//   POST /api/wait      {id, wait_s}                -> state, once status leaves takeover/user or wait_s passes
//   POST /api/release   {id, reason}                -> state; a takeover nobody finished goes back to watching
//   POST /api/state     {session_id?, action?}      -> the session's link state ({status: null} without one);
//                       with no session_id, a held link if any. With an action ({kind, target}) on a link
//                       nobody holds, records it as last_action.
//
// Statuses: watching (the agent drives), user (the user took control on their own; the agent's
// actions are refused), takeover (the agent asked for the user and waits), done (session closed).
import { timingSafeEqual, randomBytes, createHash } from 'node:crypto';
import { renderPage, renderGone } from './page.mjs';

const LIVE_ROUTE = /^\/live\/([^/]+)(\/frame\.jpg|\/state|\/done|\/take|\/release)?\/?$/;
const MAX_BODY = 16 * 1024;
const MAX_WAIT_S = 120;

function sameSecret(a, b) {
    const ha = createHash('sha256').update(String(a)).digest();
    const hb = createHash('sha256').update(String(b)).digest();
    return timingSafeEqual(ha, hb);
}

// auto-browser's SessionStatus is active | closed | interrupted | failed. A deleted
// session stays readable as "closed"; a controller restart leaves every session that
// was active as "interrupted", which no longer has a browser behind it. Only
// "active" is live; "ended" is accepted too in case a later controller names it so.
export const ENDED_STATUSES = new Set(['closed', 'interrupted', 'failed', 'ended']);
const isEnded = (s) => ENDED_STATUSES.has(s?.status);
// The user is in the page: the agent waits (takeover) or is locked out (user).
export const HELD_STATUSES = new Set(['takeover', 'user']);
const ACTION_KINDS = new Set(['navigate', 'click', 'hover', 'select_option', 'type', 'press', 'scroll', 'wait', 'reload', 'go_back', 'go_forward', 'upload', 'eval_js', 'activate_tab', 'close_tab']);

export function stateOf(rec) {
    return { status: rec.status, reason: rec.reason ?? null, url: rec.url ?? null, title: rec.title ?? null, last_action: rec.lastAction ?? null };
}

// {kind, target} from the MCP server: a known kind, and a short target with no control characters.
function cleanAction(a, at) {
    if (!a || typeof a !== 'object' || !ACTION_KINDS.has(a.kind)) return null;
    const target = typeof a.target === 'string' ? a.target.replace(/[\u0000-\u001f\u007f]+/g, ' ').trim().slice(0, 120) : '';
    return { kind: a.kind, target: target || null, at };
}

export function createBridge({ client, store, config, now = Date.now, log = () => {} }) {
    const {
        publicBase = 'http://localhost:6090',
        novncUrl = 'http://localhost:6080/vnc.html?autoconnect=true&resize=remote',
        vncPassword = '',
        bridgeToken,
        frameCacheMs = 1000,
        shareTtlMinutes = 1440,
        allowedHosts = null, // e.g. ['localhost:6090', '127.0.0.1:6090']; null admits any
        frameWidth = 480,
        frameHeight = 950,
    } = config;
    if (!bridgeToken) throw new Error('bridgeToken is required');

    const runtime = new Map(); // id -> {share, frame, inflight, waiters, metaAt}
    const rt = (id) => {
        let r = runtime.get(id);
        if (!r) runtime.set(id, (r = { share: null, frame: null, inflight: null, waiters: new Set(), metaAt: 0 }));
        return r;
    };
    const linkUrl = (rec) => `${publicBase}/live/${rec.id}`;
    const takeoverUrl = vncPassword ? `${novncUrl}#password=${encodeURIComponent(vncPassword)}` : novncUrl;

    function setStatus(rec, status, reason) {
        store.update(rec, { status, reason: reason ?? null });
        if (!HELD_STATUSES.has(status)) {
            const r = rt(rec.id);
            for (const wake of r.waiters) wake();
            r.waiters.clear();
        }
    }

    async function shareToken(rec, { fresh = false } = {}) {
        const r = rt(rec.id);
        const nowS = now() / 1000;
        if (!fresh && r.share && r.share.expiresAt - nowS > 300) return r.share.token;
        const res = await client.share(rec.sessionId, shareTtlMinutes);
        r.share = { token: res.token, expiresAt: Number(res.expires_at) || nowS + shareTtlMinutes * 60 };
        return r.share.token;
    }

    function sessionGone(rec) {
        if (rec.status !== 'done' || rec.reason !== 'session_closed') setStatus(rec, 'done', 'session_closed');
    }

    async function captureFrame(rec) {
        let observed;
        try {
            observed = await client.observeShared(await shareToken(rec));
        } catch (err) {
            if (err.status === 404) throw err;
            // A token signed before a controller restart, or expired: mint one and retry once.
            if (err.status !== 403 && err.status !== 401) throw err;
            observed = await client.observeShared(await shareToken(rec, { fresh: true }));
        }
        if (!observed?.screenshot_url) throw Object.assign(new Error('no frame'), { status: 502 });
        let image;
        try {
            image = await client.fetchFrame(observed.screenshot_url);
        } catch (err) {
            // The session answered observe, so it is live: a 404 here is a frame file the
            // controller already pruned, not a closed session. Try again next poll.
            throw Object.assign(new Error('frame file gone'), { status: 502 });
        }
        store.update(rec, { url: observed.url ?? rec.url, title: observed.title ?? rec.title });
        return { at: now(), ...image };
    }

    function frame(rec) {
        const r = rt(rec.id);
        if (r.frame && now() - r.frame.at < frameCacheMs) return Promise.resolve(r.frame);
        if (!r.inflight) {
            r.inflight = captureFrame(rec)
                .then((f) => (r.frame = f))
                .catch((err) => {
                    // Shared observe (or share minting) says 404 only when the controller has
                    // no live browser for the session: closed, interrupted by a restart, or
                    // unknown. Mark the link done now so /state stops saying watching.
                    if (err.status === 404) sessionGone(rec);
                    throw err;
                })
                .finally(() => { r.inflight = null; });
        }
        return r.inflight;
    }

    // /state polls this: at most every 5 s it asks auto-browser whether the session is
    // still live (and fills url/title the first time), so an interrupted or closed
    // session turns into done even when nobody is fetching frames.
    async function refreshMeta(rec) {
        const r = rt(rec.id);
        if ((rec.status === 'done' && rec.reason === 'session_closed') || now() - r.metaAt < 5000) return;
        r.metaAt = now();
        try {
            const s = await client.getSession(rec.sessionId);
            if (isEnded(s)) return sessionGone(rec);
            if (!rec.url) store.update(rec, { url: s.current_url ?? null, title: s.title ?? null });
        } catch (err) {
            if (err.status === 404) sessionGone(rec);
        }
    }

    function waitForHandBack(rec, waitMs) {
        if (!HELD_STATUSES.has(rec.status)) return Promise.resolve();
        return new Promise((resolve) => {
            const r = rt(rec.id);
            const wake = () => { clearTimeout(timer); r.waiters.delete(wake); resolve(); };
            const timer = setTimeout(wake, waitMs);
            r.waiters.add(wake);
        });
    }

    // ── HTTP plumbing ──────────────────────────────────────────────────────
    const send = (res, code, body, headers = {}) => {
        const isBuf = Buffer.isBuffer(body);
        const payload = isBuf || typeof body === 'string' ? body : JSON.stringify(body);
        res.writeHead(code, {
            'Content-Type': isBuf ? 'application/octet-stream' : typeof body === 'string' ? 'text/plain; charset=utf-8' : 'application/json',
            'Cache-Control': 'no-store',
            'X-Content-Type-Options': 'nosniff',
            'Referrer-Policy': 'no-referrer',
            ...headers,
        });
        res.end(payload);
    };

    function readJson(req) {
        return new Promise((resolve, reject) => {
            let size = 0;
            const chunks = [];
            req.on('data', (c) => {
                size += c.length;
                if (size > MAX_BODY) { reject(Object.assign(new Error('body too large'), { status: 413 })); req.destroy(); return; }
                chunks.push(c);
            });
            req.on('end', () => {
                if (!chunks.length) return resolve({});
                try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
                catch { reject(Object.assign(new Error('invalid json'), { status: 400 })); }
            });
            req.on('error', reject);
        });
    }

    const sessionIdOf = (body) => {
        const sid = body?.session_id;
        if (typeof sid !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(sid)) {
            throw Object.assign(new Error('session_id is required'), { status: 400 });
        }
        return sid;
    };

    async function verifiedSession(sid) {
        let s;
        try {
            s = await client.getSession(sid);
        } catch (err) {
            if (err.status === 404) throw Object.assign(new Error('unknown auto-browser session'), { status: 404 });
            throw Object.assign(new Error('auto-browser unavailable'), { status: 502 });
        }
        if (isEnded(s)) throw Object.assign(new Error(`auto-browser session is ${s.status}`), { status: 404 });
        return s;
    }

    async function api(req, res, path) {
        const auth = req.headers.authorization || '';
        const presented = auth.startsWith('Bearer ') ? auth.slice(7) : '';
        if (!presented || !sameSecret(presented, bridgeToken)) return send(res, 401, { error: 'unauthorized' });
        if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
        const body = await readJson(req);

        if (path === '/api/links' || path === '/api/takeover') {
            const sid = sessionIdOf(body);
            const session = await verifiedSession(sid);
            const rec = store.forSession(sid);
            if (session.current_url || session.title) store.update(rec, { url: session.current_url ?? rec.url, title: session.title ?? rec.title });
            if (rec.status === 'done' && rec.reason === 'session_closed') store.update(rec, { status: 'watching', reason: null });
            if (path === '/api/takeover') {
                const reason = typeof body.reason === 'string' && body.reason.trim() ? body.reason.trim().slice(0, 500) : 'The agent needs you';
                try {
                    await client.requestTakeover(sid, reason);
                } catch (err) {
                    return send(res, err.status === 404 ? 404 : 502, { error: 'takeover_request_failed' });
                }
                rt(rec.id).frame = null;
                setStatus(rec, 'takeover', reason);
            }
            return send(res, 200, { id: rec.id, url: linkUrl(rec), status: rec.status });
        }

        if (path === '/api/state') {
            let rec = null;
            if (body.session_id !== undefined && body.session_id !== null) rec = store.findSession(sessionIdOf(body));
            else rec = store.all().find((r) => HELD_STATUSES.has(r.status)) ?? null;
            if (!rec) return send(res, 200, { status: null });
            if (body.action !== undefined && !HELD_STATUSES.has(rec.status)) {
                const action = cleanAction(body.action, now());
                if (action) store.update(rec, { lastAction: action });
            }
            return send(res, 200, { id: rec.id, ...stateOf(rec) });
        }

        if (path === '/api/wait' || path === '/api/release') {
            const found = typeof body.id === 'string' ? store.lookup(body.id) : null;
            if (!found) return send(res, 404, { error: 'unknown_link' });
            if (found.expired) return send(res, 410, { error: 'expired_link' });
            const { rec } = found;
            if (path === '/api/wait') {
                const waitS = Math.max(0, Math.min(MAX_WAIT_S, Number(body.wait_s) || 30));
                await waitForHandBack(rec, waitS * 1000);
            } else if (rec.status === 'takeover') {
                setStatus(rec, 'watching', typeof body.reason === 'string' ? body.reason.slice(0, 200) : 'timeout');
            }
            return send(res, 200, stateOf(rec));
        }
        return send(res, 404, { error: 'not_found' });
    }

    async function live(req, res, id, sub) {
        const found = store.lookup(id);
        const wantsHtml = !sub;
        if (!found) {
            return wantsHtml ? send(res, 404, renderGone('This live view does not exist.'), { 'Content-Type': 'text/html; charset=utf-8' })
                : send(res, 404, { error: 'unknown_link' });
        }
        if (found.expired) {
            return wantsHtml ? send(res, 410, renderGone('This live view has expired.'), { 'Content-Type': 'text/html; charset=utf-8' })
                : send(res, 410, { error: 'expired_link' });
        }
        const { rec } = found;
        store.touch(rec);

        if (sub === '/take' || sub === '/release' || sub === '/done') {
            if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'POST' });
            if (sub === '/take') {
                if (rec.status === 'done' && rec.reason === 'session_closed') return send(res, 409, { error: 'session_closed', ...stateOf(rec) });
                // From takeover the agent is already waiting for the user: nothing changes.
                if (rec.status !== 'takeover' && rec.status !== 'user') setStatus(rec, 'user', 'user_took_control');
                return send(res, 200, { ...stateOf(rec), novnc_url: takeoverUrl });
            }
            if (HELD_STATUSES.has(rec.status)) setStatus(rec, 'watching', 'user_released');
            return send(res, 200, stateOf(rec));
        }
        if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'GET' });

        if (sub === '/state') {
            await refreshMeta(rec);
            return send(res, 200, stateOf(rec));
        }
        if (sub === '/frame.jpg') {
            try {
                const f = await frame(rec);
                return send(res, 200, f.body, { 'Content-Type': f.contentType });
            } catch (err) {
                return send(res, err.status === 404 ? 404 : 502, { error: err.status === 404 ? 'session_closed' : 'frame_unavailable' });
            }
        }
        const nonce = randomBytes(12).toString('base64');
        return send(res, 200, renderPage({ id: rec.id, state: stateOf(rec), takeoverUrl, nonce, frameWidth, frameHeight }), {
            'Content-Type': 'text/html; charset=utf-8',
            'Content-Security-Policy': `default-src 'none'; img-src 'self' blob:; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'`,
        });
    }

    async function handler(req, res) {
        const started = now();
        const url = new URL(req.url, 'http://bridge.invalid');
        const path = url.pathname;
        let route = path;
        res.on('finish', () => log(`${req.method} ${route} ${res.statusCode} ${now() - started}ms`));
        try {
            if (allowedHosts && !allowedHosts.includes(String(req.headers.host || '').toLowerCase())) {
                route = 'bad-host';
                return send(res, 421, { error: 'misdirected_request' });
            }
            if (path === '/healthz') return send(res, 200, { ok: true });
            if (path.startsWith('/api/')) return await api(req, res, path);
            const m = LIVE_ROUTE.exec(path);
            if (m) {
                route = `/live/${m[1].slice(0, 6)}…${m[2] || ''}`;
                return await live(req, res, m[1], m[2]);
            }
            return send(res, 404, { error: 'not_found' });
        } catch (err) {
            const status = err.status && err.status >= 400 && err.status < 600 ? err.status : 500;
            if (!res.headersSent) send(res, status, { error: status === 500 ? 'internal_error' : err.message });
        }
    }

    return { handler, store, linkUrl, stateOf };
}
