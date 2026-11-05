// Test helpers for noVNC through the bridge: a fake websockify (static files plus /websockify)
// on a random port, and a raw websocket handshake client.
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { connect } from 'node:net';

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** A websockify stand-in named `name`: files answer `vnc:<name>:<path>`, the socket says hello:<name> and echoes. */
export async function fakeNovnc(name) {
    const seen = { http: [], ws: [], sockets: new Set() };
    const server = createServer((req, res) => {
        seen.http.push({ method: req.method, url: req.url, headers: req.headers });
        res.writeHead(200, { 'Content-Type': 'text/html', 'Set-Cookie': 'up=1', 'WWW-Authenticate': 'Basic', Location: '/elsewhere' });
        res.end(`vnc:${name}:${req.url}`);
    });
    server.on('upgrade', (req, socket) => {
        seen.ws.push({ url: req.url, headers: req.headers });
        seen.sockets.add(socket);
        socket.on('close', () => seen.sockets.delete(socket));
        socket.on('error', () => {});
        // Like websockify: a missing or foreign Origin gets 403 Invalid Origin.
        if (req.headers.origin !== `http://${req.headers.host}`) { socket.end('HTTP/1.1 403 Invalid Origin\r\n\r\n'); return; }
        const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + WS_GUID).digest('base64');
        socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n`
            + `${req.headers['sec-websocket-protocol'] ? 'Sec-WebSocket-Protocol: binary\r\n' : ''}Set-Cookie: up=1\r\n\r\nhello:${name}`);
        socket.on('data', (d) => socket.write(d));
    });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    return {
        name, seen, port: server.address().port,
        close: () => new Promise((r) => { for (const s of seen.sockets) s.destroy(); server.closeAllConnections?.(); server.close(r); }),
    };
}

/** A websocket handshake to `port` for `path`: {status, headers, socket, data()} once the response head arrives. */
export function wsHandshake(port, path, { host = `127.0.0.1:${port}`, extra = {} } = {}) {
    return new Promise((resolve, reject) => {
        const socket = connect(port, '127.0.0.1');
        const key = Buffer.from('0123456789abcdef').toString('base64');
        const headers = { Host: host, Upgrade: 'websocket', Connection: 'Upgrade', 'Sec-WebSocket-Key': key, 'Sec-WebSocket-Version': '13',
            'Sec-WebSocket-Protocol': 'binary', Cookie: 'secret=1', Authorization: 'Bearer leak', ...extra };
        socket.write(`GET ${path} HTTP/1.1\r\n${Object.entries(headers).map(([k, v]) => `${k}: ${v}\r\n`).join('')}\r\n`);
        let buf = Buffer.alloc(0);
        let head = null;
        const waiters = [];
        let closed = false;
        const flush = () => { for (const w of waiters.splice(0)) w(); };
        socket.on('data', (d) => {
            buf = Buffer.concat([buf, d]);
            if (!head) {
                const end = buf.indexOf('\r\n\r\n');
                if (end < 0) return;
                const [status, ...lines] = buf.subarray(0, end).toString('latin1').split('\r\n');
                head = { status: Number(status.split(' ')[1]), headers: Object.fromEntries(lines.map((l) => [l.slice(0, l.indexOf(':')).toLowerCase(), l.slice(l.indexOf(':') + 1).trim()])) };
                buf = buf.subarray(end + 4);
                resolve({
                    ...head, socket,
                    get closed() { return closed; },
                    /** Waits until the body holds `text` (or the socket closes) and returns what arrived. */
                    async read(text, ms = 2000) {
                        const t0 = Date.now();
                        while (!buf.toString().includes(text) && !closed && Date.now() - t0 < ms) await new Promise((r) => { waiters.push(r); setTimeout(r, 50); });
                        return buf.toString();
                    },
                    async waitClosed(ms = 2000) {
                        const t0 = Date.now();
                        while (!closed && Date.now() - t0 < ms) await new Promise((r) => { waiters.push(r); setTimeout(r, 50); });
                        return closed;
                    },
                });
            }
            flush();
        });
        socket.on('close', () => { closed = true; flush(); if (!head) reject(new Error('closed before a response')); });
        socket.on('error', () => {});
    });
}
