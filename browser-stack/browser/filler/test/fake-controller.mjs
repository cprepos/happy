// A fake auto-browser controller REST API on 127.0.0.1 for filler tests:
// GET /sessions/{id}, GET /sessions/{id}/observe, POST .../actions/type and
// .../actions/press. Each session is a list of pages; pressing Enter moves to
// the next page. Typed text is kept so tests can check what reached the page.
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
    const server = createServer(async (req, res) => {
        const chunks = [];
        for await (const c of req) chunks.push(c);
        const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : null;
        const send = (status, obj) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
        if (req.headers.authorization !== `Bearer ${token}`) return send(401, { detail: 'bad token' });
        const m = /^\/sessions\/([^/?]+)(\/observe|\/actions\/type|\/actions\/press)?/.exec(req.url);
        const s = m && sessions.get(decodeURIComponent(m[1]));
        if (!s) return send(404, { detail: 'no session' });
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
        close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }),
    };
}
