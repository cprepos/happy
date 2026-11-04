// The live bridge's HTTP surface.
//
// Public, for the phone (reached only through the Happy Agent workspace proxy):
//   GET  /live/<id>            phone page: live frame, status, Take control, Done
//   GET  /live/<id>/frame.jpg  latest frame (image/png as auto-browser captures it)
//   GET  /live/<id>/state      {status: watching|takeover|done, reason, url, title}
//   POST /live/<id>/done       ends a takeover
// Unknown id -> 404, expired id -> 410.
//
// Private, for the MCP server (Authorization: Bearer <bridge-token>):
//   POST /api/links     {session_id}                -> {id, url, status}
//   POST /api/takeover  {session_id, reason}        -> {id, url, status}
//   POST /api/wait      {id, wait_s}                -> state, once status leaves takeover or wait_s passes
//   POST /api/release   {id, reason}                -> state; a takeover nobody finished goes back to watching
import { timingSafeEqual, randomBytes, createHash } from 'node:crypto';
import { renderPage, renderGone } from './page.mjs';

const LIVE_ROUTE = /^\/live\/([^/]+)(\/frame\.jpg|\/state|\/done)?\/?$/;
const MAX_BODY = 16 * 1024;
const MAX_WAIT_S = 120;

function sameSecret(a, b) {
    const ha = createHash('sha256').update(String(a)).digest();
    const hb = createHash('sha256').update(String(b)).digest();
    return timingSafeEqual(ha, hb);
}

// A deleted session stays readable with status "closed".
const isClosed = (s) => s?.status === 'closed';

export function stateOf(rec) {
    return { status: rec.status, reason: rec.reason ?? null, url: rec.url ?? null, title: rec.title ?? null };
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
        if (status !== 'takeover') {
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
        const image = await client.fetchFrame(observed.screenshot_url);
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
                    // The share route says 404 for a closed session; confirm before marking it done.
                    if (err.status === 404) {
                        client.getSession(rec.sessionId).then(
                            (s) => { if (isClosed(s)) sessionGone(rec); },
                            (e) => { if (e.status === 404) sessionGone(rec); },
                        );
                    }
                    throw err;
                })
                .finally(() => { r.inflight = null; });
        }
        return r.inflight;
    }

    async function refreshMeta(rec) {
        const r = rt(rec.id);
        if (rec.url || now() - r.metaAt < 5000) return;
        r.metaAt = now();
        try {
            const s = await client.getSession(rec.sessionId);
            if (isClosed(s)) return sessionGone(rec);
            store.update(rec, { url: s.current_url ?? null, title: s.title ?? null });
        } catch (err) {
            if (err.status === 404) sessionGone(rec);
        }
    }

    function waitForHandBack(rec, waitMs) {
        if (rec.status !== 'takeover') return Promise.resolve();
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
        if (isClosed(s)) throw Object.assign(new Error('auto-browser session is closed'), { status: 404 });
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

        if (sub === '/done') {
            if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' }, { Allow: 'POST' });
            if (rec.status === 'takeover') setStatus(rec, 'done', null);
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
        return send(res, 200, renderPage({ id: rec.id, state: stateOf(rec), takeoverUrl, nonce }), {
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
