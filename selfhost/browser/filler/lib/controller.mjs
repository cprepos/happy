// The filler's REST client for the auto-browser controller, with its own copy
// of the controller token. Typing always sends sensitive:true, and the type
// response (whose after-action OCR can hold a visible value) is discarded.

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
    return {
        getSession: (id) => call('GET', `/sessions/${sid(id)}`),
        observe: (id) => call('GET', `/sessions/${sid(id)}/observe?preset=text&limit=120`),
        type: (id, elementId, text) => call('POST', `/sessions/${sid(id)}/actions/type`, { element_id: elementId, text, clear_first: true, sensitive: true }, { discard: true }),
        press: (id, key) => call('POST', `/sessions/${sid(id)}/actions/press`, { key }, { discard: true }),
    };
}

/** The page URL of a session record or an observe result. */
export const pageUrl = (rec) => (rec && (rec.current_url || rec.url)) || null;
export const isLive = (rec) => !!rec && !['closed', 'interrupted', 'failed', 'deleted'].includes(String(rec.status || 'active'));
