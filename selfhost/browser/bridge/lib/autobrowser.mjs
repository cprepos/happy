// Thin client for the auto-browser controller's REST API. Holds the bearer
// token; nothing it returns to callers carries it.

export class AutoBrowserError extends Error {
    constructor(message, status) {
        super(message);
        this.status = status;
    }
}

export function createAutoBrowserClient({ baseUrl, token, fetchImpl = fetch, timeoutMs = 20_000 }) {
    const base = baseUrl.replace(/\/+$/, '');
    const auth = { Authorization: `Bearer ${token}` };

    async function call(method, path, { body, authed = true, raw = false, timeout = timeoutMs } = {}) {
        const headers = { ...(authed ? auth : {}) };
        if (body !== undefined) headers['Content-Type'] = 'application/json';
        let res;
        try {
            res = await fetchImpl(base + path, {
                method,
                headers,
                body: body === undefined ? undefined : JSON.stringify(body),
                signal: AbortSignal.timeout(timeout),
            });
        } catch (err) {
            throw Object.assign(new AutoBrowserError(`auto-browser unreachable: ${err.name}`, 502), { timedOut: err.name === 'TimeoutError' });
        }
        if (!res.ok) {
            // The body is auto-browser's error detail; it never echoes the token.
            let detail = '';
            try { detail = (await res.text()).slice(0, 200); } catch {}
            throw new AutoBrowserError(`auto-browser ${method} ${path.split('/').slice(0, 3).join('/')} -> ${res.status} ${detail}`, res.status);
        }
        if (raw) return res;
        return res.json();
    }

    return {
        /** The session record (url, title, status). Throws 404 for an unknown session. */
        getSession: (sessionId) => call('GET', `/sessions/${encodeURIComponent(sessionId)}`),
        /** A signed observe-only token for /share/<token>/..., valid ttlMinutes (max 1440). */
        share: (sessionId, ttlMinutes) =>
            call('POST', `/sessions/${encodeURIComponent(sessionId)}/share`, { body: { ttl_minutes: ttlMinutes } }),
        /** One fresh frame: {url, title, screenshot_url}. Keeps only recent frames on disk. */
        observeShared: (shareToken) => call('GET', `/share/${encodeURIComponent(shareToken)}/observe`, { authed: false }),
        /** The frame image behind observeShared().screenshot_url. */
        async fetchFrame(screenshotPath) {
            if (!screenshotPath.startsWith('/share/')) throw new AutoBrowserError('unexpected screenshot url', 502);
            const res = await call('GET', screenshotPath, { authed: false, raw: true });
            return {
                contentType: res.headers.get('content-type') || 'image/png',
                body: Buffer.from(await res.arrayBuffer()),
            };
        },
        requestTakeover: (sessionId, reason) =>
            call('POST', `/sessions/${encodeURIComponent(sessionId)}/takeover`, { body: { reason } }),
        /**
         * Back, forward, reload or goto (`url`, already checked) on the session's current tab.
         * Resolves to the session record; a timeout throws with timedOut set.
         */
        navigate(sessionId, action, url, timeout = 10_000) {
            const s = `/sessions/${encodeURIComponent(sessionId)}/actions/`;
            const path = { back: 'go-back', forward: 'go-forward', reload: 'reload', goto: 'navigate' }[action];
            return call('POST', s + path, { body: action === 'goto' ? { url } : undefined, timeout }).then((r) => r.session ?? r);
        },
        /** Closes the session and its browser. The record stays readable as "closed". */
        closeSession: (sessionId) => call('DELETE', `/sessions/${encodeURIComponent(sessionId)}`),
    };
}
