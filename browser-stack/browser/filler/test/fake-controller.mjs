// A fake auto-browser controller REST API on 127.0.0.1 for filler tests:
// GET /sessions/{id}, GET /sessions/{id}/observe, POST .../actions/type and
// .../actions/press. Each session is a list of pages; pressing Enter moves to
// the next page. Typed text is kept so tests can check what reached the page.
//
// Downloads: addDownload(session, {id, name, bytes, status}) adds one; GET
// /sessions/{id}/downloads lists a session's records, GET
// /artifacts/{id}/downloads/{name} serves the bytes, and DELETE
// /happy/sessions/{id}/downloads/{dl}?sha256= (the controller patch's route)
// deletes one only when the bytes still hash to sha256 (409 otherwise).
// Deletions are in `deleted`, artifact reads in `artifactReads`.
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';

export const loginPages = (host = 'https://github.com') => [
    { url: `${host}/login`, interactables: [
        { element_id: 'u1', tag: 'input', type: 'email', label: 'Username or email address' },
        { element_id: 'p1', tag: 'input', type: 'password', label: 'Password' },
        { element_id: 'b1', tag: 'button', type: 'submit', label: 'Sign in' },
    ] },
    { url: `${host}/sessions/two-factor`, interactables: [
        { element_id: 't1', tag: 'input', type: null, label: 'Authentication code' },
    ] },
    { url: `${host}/dashboard`, interactables: [] },
];

export async function startFakeController({ token = 'controller-token-for-tests', echoTyped = true } = {}) {
    const sessions = new Map();
    const typed = []; const pressed = [];
    const hooks = { afterType: null };
    const downloads = new Map(); // session -> [{rec, bytes}]
    const deleted = []; const artifactReads = [];
    const server = createServer(async (req, res) => {
        const chunks = [];
        for await (const c of req) chunks.push(c);
        const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null;
        const send = (status, obj) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
        if (req.headers.authorization !== `Bearer ${token}`) return send(401, { detail: 'bad token' });
        const u = new URL(req.url, 'http://x');
        const art = /^\/artifacts\/([^/]+)\/downloads\/([^/]+)$/.exec(u.pathname);
        if (art && req.method === 'GET') {
            const sid = decodeURIComponent(art[1]); const name = decodeURIComponent(art[2]);
            artifactReads.push({ session: sid, name });
            const d = (downloads.get(sid) || []).find((x) => x.name === name);
            if (!d) return send(404, { detail: 'no file' });
            res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': d.bytes.length });
            return res.end(d.bytes);
        }
        const del = /^\/happy\/sessions\/([^/]+)\/downloads\/([^/]+)$/.exec(u.pathname);
        if (del && req.method === 'DELETE') {
            const sid = decodeURIComponent(del[1]); const id = decodeURIComponent(del[2]);
            if (!sessions.has(sid)) return send(404, { detail: 'no session' });
            const list = downloads.get(sid) || [];
            const i = list.findIndex((x) => x.rec.id === id);
            if (i < 0) return send(404, { detail: 'no download' });
            const sha = createHash('sha256').update(list[i].bytes).digest('hex');
            if (sha !== u.searchParams.get('sha256')) return send(409, { detail: { code: 'hash_mismatch' } });
            list.splice(i, 1);
            deleted.push({ session: sid, id, sha256: sha });
            return send(200, { deleted: true, download_id: id, sha256: sha, size: 0 });
        }
        const m = /^\/sessions\/([^/?]+)(\/observe|\/actions\/type|\/actions\/press)?/.exec(req.url);
        const s = m && sessions.get(decodeURIComponent(m[1]));
        if (!s) return send(404, { detail: 'no session' });
        if (req.method === 'GET' && u.pathname === `/sessions/${m[1]}/downloads`) return send(200, (downloads.get(decodeURIComponent(m[1])) || []).map((d) => ({ ...d.rec })));
        const page = s.pages[s.at];
        if (!m[2] && req.method === 'GET') return send(200, { id: m[1], status: s.status, current_url: page.url });
        if (m[2] === '/observe') return send(200, { url: page.url, interactables: page.interactables, active_element: null });
        if (m[2] === '/actions/type') {
            typed.push({ session: m[1], element_id: body.element_id, text: body.text, sensitive: body.sensitive });
            if (hooks.afterType) hooks.afterType(s, body);
            // A real controller's after-action OCR may contain visible text; the
            // filler must never pass this body on.
            return send(200, echoTyped ? { ok: true, after: { ocr: body.text } } : { ok: true });
        }
        if (m[2] === '/actions/press') {
            pressed.push({ session: m[1], key: body.key });
            if (body.key === 'Enter' && s.at < s.pages.length - 1) s.at++;
            return send(200, { ok: true });
        }
        send(404, { detail: 'not found' });
    });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    const url = `http://127.0.0.1:${server.address().port}`;
    return {
        url, token, typed, pressed, hooks,
        addSession(id, pages, status = 'active') { sessions.set(id, { pages, at: 0, status }); },
        session: (id) => sessions.get(id),
        deleted, artifactReads,
        /** A download in session sid: bytes (Buffer); returns its record. */
        addDownload(sid, { id, name, bytes, status = 'completed', suggested = name }) {
            const rec = { id, timestamp: '2026-11-15T00:00:00Z', status, filename: name, suggested_filename: suggested, path: `/data/artifacts/${sid}/downloads/${name}`, url: `/artifacts/${sid}/downloads/${encodeURIComponent(name)}`, source_url: `https://files.example.test/${name}?sig=SECRET-QUERY`, failure: null };
            downloads.set(sid, [...(downloads.get(sid) || []), { rec, name, bytes }]);
            return rec;
        },
        /** Replace a download's bytes on "disk" (a changed file). */
        changeDownload(sid, id, bytes) { const d = (downloads.get(sid) || []).find((x) => x.rec.id === id); if (d) d.bytes = bytes; },
        downloadsOf: (sid) => (downloads.get(sid) || []).map((d) => d.rec),
        close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }),
    };
}
