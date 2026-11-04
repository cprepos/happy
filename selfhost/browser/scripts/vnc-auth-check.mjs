// RFB handshake against noVNC's websockify: the server must offer only VNC
// authentication (type 2), and must refuse a client that picks "None" (type 1).
// Needs a WebSocket global (Node 22+, or Node 20 with --experimental-websocket;
// re-executes itself with that flag when it is missing).
import { spawnSync } from 'node:child_process';

if (typeof WebSocket === 'undefined') {
    const r = spawnSync(process.execPath, ['--experimental-websocket', '--no-warnings', ...process.argv.slice(1)], { stdio: 'inherit' });
    process.exit(r.status ?? 1);
}

const url = process.argv[2] || 'ws://localhost:6080/websockify';
const origin = url.replace(/^ws/, 'http').replace(/\/websockify.*$/, '');
// Node's WebSocket sends no Origin; noVNC's origin guard needs one. The Node
// (undici) constructor takes headers through its second argument.
const ws = new WebSocket(url, { protocols: ['binary'], headers: { Origin: origin } });
ws.binaryType = 'arraybuffer';
let buf = Buffer.alloc(0);
let stage = 'version';
const done = (ok, msg) => { console.log(`${ok ? 'ok  ' : 'FAIL'} noVNC: ${msg}`); try { ws.close(); } catch {} process.exit(ok ? 0 : 1); };
const timer = setTimeout(() => done(false, `no answer at stage ${stage}`), 8000);
ws.onerror = (e) => done(false, `websocket error ${e.message || ''}`);
ws.onclose = () => { if (stage === 'picked-none') done(true, 'server closed the connection after "None" was picked'); };
ws.onmessage = (ev) => {
    buf = Buffer.concat([buf, Buffer.from(ev.data)]);
    if (stage === 'version' && buf.length >= 12) {
        buf = buf.subarray(12);
        ws.send(Buffer.from('RFB 003.008\n'));
        stage = 'types';
    }
    if (stage === 'types' && buf.length >= 1) {
        const n = buf[0];
        if (n === 0) return done(false, 'server sent no security types');
        if (buf.length < 1 + n) return;
        const types = [...buf.subarray(1, 1 + n)];
        buf = buf.subarray(1 + n);
        if (types.includes(1)) return done(false, `security types ${types.join(',')} include None: no password required`);
        if (!types.includes(2)) return done(false, `security types ${types.join(',')} lack VNC auth`);
        console.log(`ok   noVNC: offers security types [${types.join(',')}] (2 = VNC password, no None)`);
        ws.send(Buffer.from([1]));
        stage = 'picked-none';
    }
    if (stage === 'picked-none' && buf.length >= 4) {
        const result = buf.readUInt32BE(0);
        clearTimeout(timer);
        done(result !== 0, result !== 0 ? `picking "None" was refused (SecurityResult ${result})` : 'picking "None" was ACCEPTED');
    }
};
