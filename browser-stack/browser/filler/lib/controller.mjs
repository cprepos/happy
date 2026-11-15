// The filler's REST client for the auto-browser controller, with its own copy
// of the controller token. Typing always sends sensitive:true, and the type
// response (whose after-action OCR can hold a visible value) is discarded.
//
// Downloads (for the vault tools' save_download): listDownloads gives a
// session's records, fetchDownload reads one file's bytes into memory with a
// size cap (never to disk), and deleteDownload calls the controller patch's
// DELETE route, which re-hashes the file and refuses on a different sha256.
// No error names a file, a source URL or a query string.

export class ControllerError extends Error {
    constructor(message, status = 502) { super(message); this.status = status; }
}

export function createController({ baseUrl, token, fetchImpl = fetch, timeoutMs = 30_000 }) {
    const base = baseUrl.replace(/\/+$/, '');
    async function call(method, path, body, { discard = false } = {}) {
        let res;
        try {
            res = await fetchImpl(base + path, {
                method,
                headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
                body: body ? JSON.stringify(body) : undefined,
                signal: AbortSignal.timeout(timeoutMs),
            });
        } catch (err) {
            throw new ControllerError(`browser controller unreachable: ${err.name}`);
        }
        if (!res.ok) {
            // The body is not read: for a type call it could echo the text.
            try { await res.body?.cancel(); } catch {}
            throw new ControllerError(`browser controller ${method} ${path.split('/').slice(0, 3).join('/')} -> HTTP ${res.status}`, res.status === 404 ? 404 : 502);
        }
        if (discard) { try { await res.body?.cancel(); } catch {} return null; }
        return res.json();
    }
    const sid = (id) => encodeURIComponent(String(id));

    /** The bytes of /artifacts/<session>/downloads/<name>, at most maxBytes, as a Buffer. */
    async function fetchDownload(id, name, { maxBytes }) {
        let res;
        try {
            res = await fetchImpl(`${base}/artifacts/${sid(id)}/downloads/${encodeURIComponent(String(name))}`, {
                headers: { Authorization: `Bearer ${token}` },
                signal: AbortSignal.timeout(Math.max(timeoutMs, 120_000)),
            });
        } catch (err) {
            throw new ControllerError(`browser controller unreachable: ${err.name}`);
        }
        if (!res.ok) {
            try { await res.body?.cancel(); } catch {}
            throw new ControllerError(`browser controller GET /artifacts -> HTTP ${res.status}`, res.status === 404 ? 404 : 502);
        }
        const declared = Number(res.headers.get('content-length'));
        if (Number.isFinite(declared) && declared > maxBytes) {
            try { await res.body?.cancel(); } catch {}
            throw new ControllerError('the download is larger than allowed', 413);
        }
        const chunks = []; let n = 0;
        try {
            for await (const chunk of res.body) {
                n += chunk.length;
                if (n > maxBytes) {
                    try { await res.body.cancel(); } catch {}
                    throw new ControllerError('the download is larger than allowed', 413);
                }
                chunks.push(Buffer.from(chunk));
            }
        } catch (err) {
            for (const c of chunks) c.fill(0);
            if (err instanceof ControllerError) throw err;
            throw new ControllerError(`browser controller download read failed: ${err.name}`);
        }
        const out = Buffer.concat(chunks, n);
        for (const c of chunks) c.fill(0);
        return out;
    }

    return {
        getSession: (id) => call('GET', `/sessions/${sid(id)}`),
        observe: (id) => call('GET', `/sessions/${sid(id)}/observe?preset=text&limit=120`),
        type: (id, elementId, text) => call('POST', `/sessions/${sid(id)}/actions/type`, { element_id: elementId, text, clear_first: true, sensitive: true }, { discard: true }),
        press: (id, key) => call('POST', `/sessions/${sid(id)}/actions/press`, { key }, { discard: true }),
        async listDownloads(id) {
            const r = await call('GET', `/sessions/${sid(id)}/downloads`);
            const list = Array.isArray(r) ? r : (r && Array.isArray(r.downloads) ? r.downloads : null);
            if (!list) throw new ControllerError('browser controller gave no download list');
            return list;
        },
        fetchDownload,
        deleteDownload: (id, downloadId, sha256) => call('DELETE', `/happy/sessions/${sid(id)}/downloads/${encodeURIComponent(String(downloadId))}?sha256=${encodeURIComponent(String(sha256))}`),
    };
}

/** The page URL of a session record or an observe result. */
export const pageUrl = (rec) => (rec && (rec.current_url || rec.url)) || null;
export const isLive = (rec) => !!rec && !['closed', 'interrupted', 'failed', 'deleted'].includes(String(rec.status || 'active'));

/** Parse "8010,8100-8131" into a Set of ports. */
export function parsePorts(spec) {
    const out = new Set();
    for (const part of String(spec || '').split(',').map((x) => x.trim()).filter(Boolean)) {
        const m = /^(\d{2,5})(?:-(\d{2,5}))?$/.exec(part);
        if (!m) throw new ControllerError(`bad controller port list entry ${part}`, 500);
        const a = Number(m[1]); const b = Number(m[2] ?? m[1]);
        if (a < 1 || b > 65535 || b < a || b - a > 256) throw new ControllerError(`bad controller port range ${part}`, 500);
        for (let p = a; p <= b; p++) out.add(p);
    }
    return out;
}

/**
 * Controllers by port, all on 127.0.0.1 with one token: the shared stack's
 * (defaultPort, used when a request names none) and the per-chat pods'.
 * Returns port -> {port, controller} or null for a port not in the list.
 */
export function controllerSet({ defaultPort, ports, token, fetchImpl }) {
    const allowed = new Set(ports); allowed.add(defaultPort);
    const cache = new Map();
    return (port) => {
        const p = port === null || port === undefined ? defaultPort : port;
        if (!Number.isInteger(p) || !allowed.has(p)) return null;
        if (!cache.has(p)) cache.set(p, { port: p, controller: createController({ baseUrl: `http://127.0.0.1:${p}`, token, fetchImpl }) });
        return cache.get(p);
    };
}
