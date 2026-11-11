// Pod launcher: templates, input validation, the socket protocol and the slot lifecycle, against a
// fake Engine API on a unix socket. No Docker needed.
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { connect } from 'node:net';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, statSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import {
    launcherConfig, composeImages, nodeSpec, controllerSpec, validate, createEngine, createLauncher, serve, ports, HARD_MAX_PODS,
    kioskFlag, viewportHeight, demux, pngSize, CHROME_UI_HEIGHT,
} from '../launcher.mjs';

const BROWSER_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const COMPOSE = readFileSync(join(BROWSER_DIR, 'compose.browser.yml'), 'utf8');
const SECCOMP = JSON.stringify(JSON.parse(readFileSync(join(BROWSER_DIR, 'seccomp', 'chromium-sandbox.json'), 'utf8')));
const SECRETS = { apiToken: 'tok-test', authStateKey: 'key-test', shareTokenSecret: 'share-test' };
const POD = 'a'.repeat(32);
const CHAT = 'b'.repeat(32);

function setup(extra = {}) {
    const home = mkdtempSync(join(tmpdir(), 'launcher-test-'));
    const me = { uid: process.getuid(), gid: process.getgid() };
    const cfg = launcherConfig({
        LAUNCHER_BROWSER_DIR: BROWSER_DIR, LAUNCHER_HOME: home, LAUNCHER_PROJECT: 'hbtest',
        POD_DATA_UID: String(me.uid), POD_DATA_GID: String(me.gid), POD_NODE_UID: String(me.uid + 1), POD_NODE_GID: String(me.gid), ...extra,
    });
    return { home, cfg };
}

// A fake Engine API: containers in memory, every request recorded.
async function fakeEngine(dir) {
    const socketPath = join(dir, 'docker.sock');
    const containers = new Map();
    const calls = [];
    const execs = new Map();
    // What an exec prints and exits with: { stdout, stderr, exitCode }.
    const exec = { stdout: Buffer.alloc(0), stderr: Buffer.alloc(0), exitCode: 0 };
    let n = 0;
    const server = createServer((req, res) => {
        let body = '';
        req.on('data', (c) => { body += c; });
        req.on('end', () => {
            const url = new URL(req.url, 'http://x');
            const path = url.pathname.replace(/^\/v[\d.]+/, '');
            calls.push({ method: req.method, path, query: Object.fromEntries(url.searchParams), body: body ? JSON.parse(body) : undefined });
            const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(obj === undefined ? '' : JSON.stringify(obj)); };
            let m;
            if (req.method === 'GET' && path === '/containers/json') {
                const want = JSON.parse(url.searchParams.get('filters')).label;
                return send(200, [...containers.values()].filter((c) => want.every((l) => { const [k, v] = l.split('='); return c.Labels[k] === v; })));
            }
            if (req.method === 'POST' && path === '/containers/create') {
                const id = `c${++n}`;
                containers.set(id, { Id: id, Names: [`/${url.searchParams.get('name')}`], Labels: JSON.parse(body).Labels, State: 'created', Status: 'Created', Created: n });
                return send(201, { Id: id });
            }
            if (req.method === 'POST' && (m = path.match(/^\/containers\/([^/]+)\/start$/))) {
                const c = containers.get(m[1]); if (!c) return send(404, { message: 'no such container' });
                c.State = 'running'; return send(204);
            }
            if (req.method === 'POST' && (m = path.match(/^\/containers\/([^/]+)\/exec$/))) {
                if (!containers.has(m[1])) return send(404, { message: 'no such container' });
                const id = `e${++n}`;
                execs.set(id, { container: m[1], spec: JSON.parse(body) });
                return send(201, { Id: id });
            }
            if (req.method === 'POST' && (m = path.match(/^\/exec\/([^/]+)\/start$/))) {
                if (!execs.has(m[1])) return send(404, { message: 'no such exec' });
                const frame = (kind, b) => { const h = Buffer.alloc(8); h[0] = kind; h.writeUInt32BE(b.length, 4); return Buffer.concat([h, b]); };
                res.writeHead(200, { 'Content-Type': 'application/vnd.docker.raw-stream' });
                // The stdout in two frames, to check they are joined.
                const half = exec.stdout.length >> 1;
                return res.end(Buffer.concat([frame(1, exec.stdout.subarray(0, half)), frame(2, exec.stderr), frame(1, exec.stdout.subarray(half))]));
            }
            if (req.method === 'GET' && (m = path.match(/^\/exec\/([^/]+)\/json$/))) {
                return send(200, { ExitCode: exec.exitCode, Running: false });
            }
            if (req.method === 'DELETE' && (m = path.match(/^\/containers\/([^/]+)$/))) {
                if (!containers.delete(m[1])) return send(404, { message: 'no such container' });
                return send(204);
            }
            send(404, { message: 'unhandled' });
        });
    });
    await new Promise((r) => server.listen(socketPath, r));
    return { socketPath, containers, calls, execs, exec, close: () => new Promise((r) => server.close(r)) };
}

test('images are the digests pinned in compose.browser.yml', () => {
    const images = composeImages(COMPOSE);
    assert.match(images.node, /^ghcr\.io\/lvcidpsyche\/auto-browser-browser-node:[\d.]+@sha256:[0-9a-f]{64}$/);
    assert.match(images.controller, /^ghcr\.io\/lvcidpsyche\/auto-browser-controller:[\d.]+@sha256:[0-9a-f]{64}$/);
    assert.ok(COMPOSE.includes(`&browser_node_image ${images.node}\n`));
    assert.ok(COMPOSE.includes(`&controller_image ${images.controller}\n`));
    assert.throws(() => composeImages('x-browser-node-image: &a ghcr.io/x:1\n'), /pinned/);
});

test('pod templates: host network, loopback ports per slot, no published ports, no docker socket, private shm', () => {
    const { cfg } = setup();
    const images = composeImages(COMPOSE);
    for (const slot of [0, 3, 7]) {
        const p = ports(cfg, slot);
        assert.deepEqual(p, { novnc: 6100 + slot, api: 8100 + slot, playwright: 9300 + slot });
        const node = nodeSpec(cfg, { slot, podId: POD, vncPassword: 'Abcd1234', image: images.node, seccomp: SECCOMP });
        const ctl = controllerSpec(cfg, { slot, podId: POD, image: images.controller, secrets: SECRETS });
        for (const spec of [node, ctl]) {
            const h = spec.HostConfig;
            assert.equal(h.NetworkMode, 'host');
            assert.equal(spec.ExposedPorts, undefined);
            assert.equal(h.PortBindings, undefined);
            assert.equal(h.PublishAllPorts, undefined);
            assert.equal(h.Privileged, undefined);
            assert.equal(h.IpcMode, undefined, 'no ipc=host or shareable');
            assert.equal(h.Init, true);
            assert.deepEqual(h.RestartPolicy, { Name: 'no' });
            assert.ok(h.SecurityOpt.includes('no-new-privileges:true'));
            assert.ok(h.Binds.every((b) => !/docker\.sock/.test(b)), 'no pod mounts the docker socket');
            assert.ok(h.Binds.every((b) => !/^\/dev\/shm/.test(b) && !/:\/dev\/shm/.test(b)), 'no /dev/shm mount');
            assert.ok(h.Binds.every((b) => !b.includes('/secrets') && !b.includes('/run')), 'no secrets or launcher socket');
            assert.equal(spec.Labels['happy-browser.pod'], '1');
            assert.equal(spec.Labels['happy-browser.slot'], String(slot));
            assert.equal(spec.Labels['happy-browser.pod_id'], POD);
            assert.equal(spec.Labels['happy-browser.project'], 'hbtest');
        }
        assert.equal(node.Image, images.node);
        assert.equal(ctl.Image, images.controller);
        assert.equal(node.HostConfig.ShmSize, 2 * 1024 ** 3);
        assert.equal(node.HostConfig.Memory, 3 * 1024 ** 3);
        assert.equal(ctl.HostConfig.Memory, 1 * 1024 ** 3);
        assert.equal(node.HostConfig.NanoCpus, 2e9);
        assert.equal(node.HostConfig.PidsLimit, 2048);
        assert.deepEqual(node.HostConfig.CapDrop, ['ALL']);
        // Both run as their own non-root uids from the start: no capability, a read-only root, a private /tmp.
        assert.equal(node.HostConfig.CapAdd, undefined);
        assert.equal(node.User, `${cfg.nodeUid}:${cfg.nodeGid}`);
        assert.equal(ctl.User, `${cfg.dataUid}:${cfg.dataGid}`);
        for (const spec of [node, ctl]) {
            assert.deepEqual(spec.HostConfig.CapDrop, ['ALL']);
            assert.equal(spec.HostConfig.ReadonlyRootfs, true);
            assert.deepEqual(Object.keys(spec.HostConfig.Tmpfs), ['/tmp']);
            assert.ok(spec.Env.includes('HOME=/tmp'));
        }
        assert.match(node.HostConfig.Tmpfs['/tmp'], /(^|,)exec(,|$)/, 'the entrypoint runs its patched script from /tmp');
        assert.match(ctl.HostConfig.Tmpfs['/tmp'], /(^|,)noexec(,|$)/);
        assert.equal(node.HostConfig.SecurityOpt.find((s) => s.startsWith('seccomp=')), `seccomp=${SECCOMP}`, 'seccomp is the file content');
        const env = (s) => Object.fromEntries(s.Env.map((e) => [e.slice(0, e.indexOf('=')), e.slice(e.indexOf('=') + 1)]));
        const ne = env(node), ce = env(ctl);
        assert.equal(ne.PLAYWRIGHT_SERVER_HOST, '127.0.0.1');
        assert.equal(ne.NOVNC_PORT, String(p.novnc));
        assert.equal(ne.PLAYWRIGHT_SERVER_PORT, String(p.playwright));
        assert.equal(ne.VNC_PASSWORD, 'Abcd1234');
        // A desktop screen and window by default (BROWSER_WIDTH/HEIGHT override); the page is
        // the screen less the maximized window's tab strip and address bar.
        assert.deepEqual([ne.BROWSER_WIDTH, ne.BROWSER_HEIGHT, ne.BROWSER_KIOSK], ['1920', '1200', '0']);
        assert.deepEqual([ce.DEFAULT_VIEWPORT_WIDTH, ce.DEFAULT_VIEWPORT_HEIGHT], ['1920', '1113']);
        assert.deepEqual(ctl.Cmd, ['uvicorn', 'happy_live_frames:app', '--host', '127.0.0.1', '--port', String(p.api)]);
        assert.equal(ce.PYTHONPATH, '/happy/controller-patch');
        assert.ok(ctl.HostConfig.Binds.includes(`${BROWSER_DIR}/controller-patch/happy_live_frames.py:/happy/controller-patch/happy_live_frames.py:ro`));
        assert.equal(ce.EVIDENCE_TZ, 'America/Toronto', 'the audit zone: Toronto unless EVIDENCE_TZ says');
        assert.equal(ce.SCREENSHOT_TIME_MODE, 'desktop');
        assert.equal(ce.TZ, undefined, 'the controller\'s own zone is left alone');
        assert.equal(ne.TZ, 'America/Toronto', 'the node\'s panel clock shows the evidence zone');
        assert.equal(ce.MAX_SESSIONS, '1');
        assert.equal(ce.ENABLE_TRACING, 'false');
        assert.equal(ce.NETWORK_INSPECTOR_CAPTURE_BODIES, 'false');
        assert.equal(ce.REQUIRE_AUTH_STATE_ENCRYPTION, 'true');
        assert.equal(ce.API_ALLOW_TOKENLESS_LOOPBACK, 'false');
        assert.equal(ce.TAKEOVER_URL, `http://localhost:${p.novnc}/vnc.html?autoconnect=true&resize=scale`);
        assert.ok(ctl.HostConfig.Binds[0].endsWith(`/data/pods/slot-${slot}:/data`));
        assert.ok(node.HostConfig.Binds.includes(`${BROWSER_DIR}/kiosk/fluxbox:/happy/fluxbox:ro`));
    }
});

test('pod templates match the shared stack in compose.browser.yml', () => {
    // Every controller env key of the compose service is set on a pod controller too, and the
    // two settings the secret filler depends on have the same values.
    const { cfg } = setup();
    const ctl = controllerSpec(cfg, { slot: 0, podId: POD, image: 'x', secrets: SECRETS });
    const keys = new Set(ctl.Env.map((e) => e.split('=')[0]));
    const block = COMPOSE.split(/^  controller:$/m)[1].split(/^  \S/m)[0].split(/^    environment:$/m)[1].split(/^    volumes:$/m)[0];
    for (const m of block.matchAll(/^      ([A-Z_]+):/gm)) assert.ok(keys.has(m[1]), `pod controller sets ${m[1]}`);
    assert.match(block, /ENABLE_TRACING: "false"/);
    assert.match(block, /NETWORK_INSPECTOR_CAPTURE_BODIES: "false"/);
    // The same controller entry point and patch mount as the shared controller.
    const ctlBlock = COMPOSE.split(/^  controller:$/m)[1].split(/^  \S/m)[0];
    assert.match(ctlBlock, /^    command: \["uvicorn", "happy_live_frames:app", /m);
    for (const m of ctlBlock.matchAll(/^      - \.\/(\S+):(\S+)$/gm)) {
        assert.ok(ctl.HostConfig.Binds.includes(`${BROWSER_DIR}/${m[1]}:${m[2]}`), `pod controller mounts ./${m[1]}`);
    }
    const node = nodeSpec(cfg, { slot: 0, podId: POD, vncPassword: 'Abcd1234', image: 'x', seccomp: SECCOMP });
    const nodeBlock = COMPOSE.split(/^  browser-node:$/m)[1].split(/^  controller:$/m)[0];
    for (const m of nodeBlock.matchAll(/^      - \.\/(\S+):(\S+)$/gm)) {
        assert.ok(node.HostConfig.Binds.includes(`${BROWSER_DIR}/${m[1]}:${m[2]}`), `pod node mounts ./${m[1]}`);
    }
});

// A PNG header with an IHDR of w x h (enough for pngSize).
function fakePng(w, h, pad = 0) {
    const b = Buffer.alloc(33 + pad);
    b.writeUInt32BE(0x89504e47, 0); b.writeUInt32BE(0x0d0a1a0a, 4);
    b.writeUInt32BE(13, 8); b.write('IHDR', 12, 'latin1');
    b.writeUInt32BE(w, 16); b.writeUInt32BE(h, 20);
    return b;
}

test('window mode: BROWSER_KIOSK picks the viewport and reaches the pod node', () => {
    assert.equal(kioskFlag(undefined), false);
    assert.equal(kioskFlag(''), false);
    assert.equal(kioskFlag('0'), false);
    assert.equal(kioskFlag('1'), true);
    for (const v of ['yes', 'true', '2', ' 1']) assert.throws(() => kioskFlag(v), /BROWSER_KIOSK/);
    assert.equal(CHROME_UI_HEIGHT, 87);
    assert.equal(viewportHeight({ kiosk: false, height: 1200 }), 1113);
    assert.equal(viewportHeight({ kiosk: true, height: 1200 }), 1200);
    // The desktop panel above a maximized window takes its height from the page too.
    assert.equal(viewportHeight({ kiosk: false, height: 1200, panelHeight: 28 }), 1085);
    assert.equal(setup({ BROWSER_PANEL_HEIGHT: '28' }).cfg.viewportHeight, 1085);
    assert.equal(setup({ BROWSER_PANEL_HEIGHT: '28', BROWSER_KIOSK: '1' }).cfg.viewportHeight, 1200, 'the kiosk has no panel');

    const envOf = (spec, k) => spec.Env.find((e) => e.startsWith(`${k}=`));
    const win = setup().cfg;
    assert.equal(win.kiosk, false);
    assert.equal(win.viewportHeight, 1113);
    assert.equal(envOf(nodeSpec(win, { slot: 0, podId: POD, vncPassword: 'Abcd1234', image: 'x', seccomp: SECCOMP }), 'BROWSER_KIOSK'), 'BROWSER_KIOSK=0');
    assert.equal(envOf(controllerSpec(win, { slot: 0, podId: POD, image: 'x', secrets: SECRETS }), 'DEFAULT_VIEWPORT_HEIGHT'), 'DEFAULT_VIEWPORT_HEIGHT=1113');

    const kiosk = setup({ BROWSER_KIOSK: '1' }).cfg;
    assert.equal(kiosk.viewportHeight, 1200);
    assert.equal(envOf(nodeSpec(kiosk, { slot: 0, podId: POD, vncPassword: 'Abcd1234', image: 'x', seccomp: SECCOMP }), 'BROWSER_KIOSK'), 'BROWSER_KIOSK=1');
    assert.equal(envOf(controllerSpec(kiosk, { slot: 0, podId: POD, image: 'x', secrets: SECRETS }), 'DEFAULT_VIEWPORT_HEIGHT'), 'DEFAULT_VIEWPORT_HEIGHT=1200');

    // browser.mk's value wins, within the screen.
    assert.equal(setup({ BROWSER_VIEWPORT_HEIGHT: '1100' }).cfg.viewportHeight, 1100);
    assert.throws(() => setup({ BROWSER_VIEWPORT_HEIGHT: '1201' }));
    assert.throws(() => setup({ BROWSER_KIOSK: 'yes' }), /BROWSER_KIOSK/);
});

test('demux and pngSize', () => {
    const frame = (kind, s) => { const b = Buffer.from(s); const h = Buffer.alloc(8); h[0] = kind; h.writeUInt32BE(b.length, 4); return Buffer.concat([h, b]); };
    const d = demux(Buffer.concat([frame(1, 'ab'), frame(2, 'err'), frame(1, 'cd'), frame(1, '')]));
    assert.equal(d.stdout.toString(), 'abcd');
    assert.equal(d.stderr.toString(), 'err');
    // A truncated last frame keeps what arrived.
    assert.equal(demux(frame(1, 'xyz').subarray(0, 10)).stdout.toString(), 'xy');
    assert.deepEqual(demux(Buffer.alloc(0)), { stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) });
    assert.deepEqual(pngSize(fakePng(1920, 1200)), { width: 1920, height: 1200 });
    assert.equal(pngSize(Buffer.from('not a png at all, really not')), null);
    assert.equal(pngSize(Buffer.alloc(10)), null);
});

test('screen: execs the capture script in that pod\'s node only', async () => {
    const { home, cfg } = setup();
    const eng = await fakeEngine(home);
    const launcher = createLauncher(cfg, { engine: createEngine(eng.socketPath), images: composeImages(COMPOSE), seccomp: SECCOMP, secrets: SECRETS, captureScript: 'print(1)', log: { log() {}, warn() {} } });
    try {
        assert.equal((await launcher.handle({ op: 'screen', slot: 1, pod_id: POD })).error, 'pod is not running');
        await launcher.handle({ op: 'ensure', slot: 1, pod_id: POD, vnc_password: 'Abcd1234' });
        const png = fakePng(1920, 1200, 100);
        const full = { x: 0, y: 0, width: 1920, height: 1200 };
        const meta = (rect, extra = {}) => Buffer.from(`noise\nscreen-capture-meta: ${JSON.stringify({
            captured_at: '2026-11-11T19:32:07.123Z', local: '2026-11-11T14:32:07.123-05:00', tz: 'America/Toronto',
            screen: { width: 1920, height: 1200 }, rect, workarea: { x: 0, y: 28, width: 1920, height: 1172 }, panel_px: 28, ...extra,
        })}\n`);
        eng.exec.stdout = png;
        eng.exec.stderr = meta(full);
        const r = await launcher.handle({ op: 'screen', slot: 1, pod_id: POD });
        assert.equal(r.ok, true, r.error);
        assert.deepEqual(r.result, {
            mime: 'image/png', width: 1920, height: 1200, data: png.toString('base64'),
            raw_sha256: createHash('sha256').update(png).digest('hex'),
            captured_at: '2026-11-11T19:32:07.123Z', local: '2026-11-11T14:32:07.123-05:00', tz: 'America/Toronto',
            screen: { width: 1920, height: 1200 }, capture_rect: full, panel_px: 28,
        });
        const [ex] = [...eng.execs.values()];
        const node = [...eng.containers.values()].find((c) => c.Labels['happy-browser.role'] === 'node');
        assert.equal(ex.container, node.Id, 'runs in the node, not the controller');
        assert.deepEqual(ex.spec.Cmd, ['python3', '-I', '-c', 'print(1)']);
        assert.equal(ex.spec.User, String(cfg.nodeUid), 'as the node\'s own uid');
        assert.deepEqual(ex.spec.Env, ['DISPLAY=:99']);

        // Another pod id on the same slot (a chat that lost it) gets nothing.
        assert.equal((await launcher.handle({ op: 'screen', slot: 1, pod_id: 'c'.repeat(32) })).error, 'pod is not running');
        assert.equal((await launcher.handle({ op: 'screen', slot: 2, pod_id: POD })).error, 'pod is not running');
        assert.equal(eng.execs.size, 1);

        // A rect (the tab view) is handed to the script as XGetImage's x y w h, and the image must be it.
        const win = { x: 0, y: 28, width: 1920, height: 1172 };
        eng.exec.stdout = fakePng(1920, 1172);
        eng.exec.stderr = meta(win);
        const t = await launcher.handle({ op: 'screen', slot: 1, pod_id: POD, rect: win });
        assert.equal(t.ok, true, t.error);
        assert.deepEqual(t.result.capture_rect, win);
        assert.deepEqual([...eng.execs.values()].pop().spec.Cmd, ['python3', '-I', '-c', 'print(1)', '0', '28', '1920', '1172']);
        // An image that is not the rectangle asked for, or no capture time, is refused.
        eng.exec.stdout = fakePng(1920, 1200);
        assert.equal((await launcher.handle({ op: 'screen', slot: 1, pod_id: POD, rect: win })).error, 'screen capture is not the rectangle asked for');
        eng.exec.stdout = fakePng(1920, 1172);
        eng.exec.stderr = meta(full);
        assert.equal((await launcher.handle({ op: 'screen', slot: 1, pod_id: POD, rect: win })).error, 'screen capture is not the rectangle asked for');
        eng.exec.stderr = Buffer.from('no meta\n');
        assert.equal((await launcher.handle({ op: 'screen', slot: 1, pod_id: POD, rect: win })).error, 'screen capture gave no capture time');
        assert.equal((await launcher.handle({ op: 'screen', slot: 1, pod_id: POD, rect: { ...win, height: 1173 } })).error, 'rect is not inside the screen');

        eng.exec.exitCode = 1;
        eng.exec.stdout = Buffer.alloc(0);
        eng.exec.stderr = Buffer.from('Traceback...\nscreen-capture: cannot open the display\n');
        assert.equal((await launcher.handle({ op: 'screen', slot: 1, pod_id: POD })).error, 'screen capture failed: screen-capture: cannot open the display');
        eng.exec.exitCode = 0;
        eng.exec.stderr = Buffer.alloc(0);
        eng.exec.stdout = Buffer.from('garbage that is not a png');
        assert.equal((await launcher.handle({ op: 'screen', slot: 1, pod_id: POD })).error, 'screen capture returned no image');

        const none = createLauncher(cfg, { engine: createEngine(eng.socketPath), images: composeImages(COMPOSE), seccomp: SECCOMP, secrets: SECRETS, log: { log() {}, warn() {} } });
        assert.equal((await none.handle({ op: 'screen', slot: 1, pod_id: POD })).error, 'screen capture is not available');
    } finally { await eng.close(); }
});

test('config: slots and port bases are bounded', () => {
    assert.throws(() => setup({ MAX_PODS: String(HARD_MAX_PODS + 1) }), /MAX_PODS/);
    assert.throws(() => setup({ MAX_PODS: '0' }), /MAX_PODS/);
    assert.throws(() => setup({ POD_API_BASE: '80' }), /out of range/);
    assert.throws(() => launcherConfig({}), /required/);
    for (const k of ['POD_DATA_UID', 'POD_DATA_GID', 'POD_NODE_UID', 'POD_NODE_GID']) assert.throws(() => setup({ [k]: '0' }), /must not be root/);
});

test('config: the Docker socket comes from DOCKER_SOCKET or DOCKER_HOST (the proxy), never TCP', () => {
    const base = { LAUNCHER_BROWSER_DIR: '/b', LAUNCHER_HOME: '/h' };
    assert.equal(launcherConfig(base).dockerSocket, '/var/run/docker.sock');
    assert.equal(launcherConfig({ ...base, DOCKER_HOST: 'unix:///proxy/docker.sock' }).dockerSocket, '/proxy/docker.sock');
    assert.equal(launcherConfig({ ...base, DOCKER_SOCKET: '/p/d.sock', DOCKER_HOST: 'unix:///x' }).dockerSocket, '/p/d.sock');
    assert.throws(() => launcherConfig({ ...base, DOCKER_HOST: 'tcp://127.0.0.1:2375' }), /unix/);
    const d = launcherConfig(base);
    assert.deepEqual([d.dataUid, d.dataGid, d.nodeUid, d.nodeGid, d.socketGid], [1993, 1993, 1994, 1994, 1996]);
});

test('validation: only the seven ops, with exact fields', () => {
    const { cfg } = setup({ MAX_PODS: '4' });
    const ok = (r) => assert.doesNotThrow(() => validate(cfg, r));
    const bad = (r, re) => assert.throws(() => validate(cfg, r), re);
    ok({ op: 'ensure', slot: 0, pod_id: POD, vnc_password: 'Abcd1234' });
    ok({ op: 'stop', slot: 3 });
    ok({ op: 'list' });
    ok({ op: 'adopt_auth', slot: 1, chat_hash: CHAT });
    ok({ op: 'stash_auth', slot: 1, chat_hash: CHAT, keep: true });
    ok({ op: 'copy_auth', from_chat_hash: 'e'.repeat(32), chat_hash: CHAT });
    ok({ op: 'screen', slot: 0, pod_id: POD });
    ok({ op: 'screen', slot: 0, pod_id: POD, rect: { x: 0, y: 28, width: 1920, height: 1172 } });
    for (const rect of [null, [], 'x', { x: 0, y: 0, width: 10 }, { x: 0, y: 0, width: 10, height: 10, z: 1 },
        { x: '0', y: 0, width: 10, height: 10 }, { x: 0.5, y: 0, width: 10, height: 10 }, { x: -1, y: 0, width: 10, height: 10 },
        { x: 0, y: 0, width: 0, height: 10 }, { x: 1, y: 0, width: 1920, height: 10 }, { x: 0, y: 1, width: 10, height: 1200 }]) {
        bad({ op: 'screen', slot: 0, pod_id: POD, rect }, /rect/);
    }
    bad({ op: 'ensure', slot: 0, pod_id: POD, vnc_password: 'Abcd1234', rect: { x: 0, y: 0, width: 1, height: 1 } }, /unexpected field rect/);
    bad({ op: 'screen', slot: 0 }, /bad pod_id/);
    bad({ op: 'screen', slot: 4, pod_id: POD }, /bad slot/);
    bad({ op: 'screen', slot: 0, pod_id: POD, cmd: 'id' }, /unexpected field cmd/);
    bad({ op: 'copy_auth', from_chat_hash: CHAT, chat_hash: CHAT }, /must differ/);
    bad({ op: 'copy_auth', from_chat_hash: '../' + 'e'.repeat(29), chat_hash: CHAT }, /bad from_chat_hash/);
    bad({ op: 'copy_auth', from_chat_hash: 'E'.repeat(32), chat_hash: CHAT }, /bad from_chat_hash/);
    bad({ op: 'copy_auth', chat_hash: CHAT }, /bad from_chat_hash/);
    bad({ op: 'copy_auth', from_chat_hash: 'e'.repeat(32), chat_hash: 'x' }, /bad chat_hash/);
    bad({ op: 'copy_auth', from_chat_hash: 'e'.repeat(32), chat_hash: CHAT, slot: 0 }, /unexpected field slot/);
    bad({ op: 'stash_auth', slot: 0, chat_hash: CHAT, from_chat_hash: 'e'.repeat(32) }, /unexpected field from_chat_hash/);
    bad({ op: 'exec', slot: 0 }, /unknown op/);
    bad({ op: 'ensure', slot: 4, pod_id: POD, vnc_password: 'Abcd1234' }, /bad slot/);
    bad({ op: 'ensure', slot: -1, pod_id: POD, vnc_password: 'Abcd1234' }, /bad slot/);
    bad({ op: 'ensure', slot: '0', pod_id: POD, vnc_password: 'Abcd1234' }, /bad slot/);
    bad({ op: 'ensure', slot: 0.5, pod_id: POD, vnc_password: 'Abcd1234' }, /bad slot/);
    bad({ op: 'ensure', slot: 0, pod_id: 'A'.repeat(32), vnc_password: 'Abcd1234' }, /bad pod_id/);
    bad({ op: 'ensure', slot: 0, pod_id: POD, vnc_password: 'Abcd123' }, /bad vnc_password/);
    bad({ op: 'ensure', slot: 0, pod_id: POD, vnc_password: 'Abcd-234' }, /bad vnc_password/);
    bad({ op: 'ensure', slot: 0, pod_id: POD, vnc_password: 'Abcd1234', image: 'evil' }, /unexpected field image/);
    bad({ op: 'adopt_auth', slot: 0, chat_hash: '../../etc/passwd' }, /bad chat_hash/);
    bad({ op: 'stop', slot: 0, keep: true }, /unexpected field keep/);
    bad({ op: 'stash_auth', slot: 0, chat_hash: CHAT, keep: 'yes' }, /bad keep/);
    bad(null, /bad request/);
    bad([], /bad request/);
});

test('lifecycle over the socket: ensure, idempotent ensure, list, auth round trip, stop', async () => {
    const { home, cfg } = setup();
    const eng = await fakeEngine(home);
    const launcher = createLauncher(cfg, { engine: createEngine(eng.socketPath), images: composeImages(COMPOSE), seccomp: SECCOMP, secrets: SECRETS, log: { log() {}, warn() {} } });
    mkdirSync(join(home, 'run'));
    const sock = join(home, 'run', 'launcher.sock');
    const server = await serve(launcher, sock, { log: { log() {} } });
    assert.equal(statSync(sock).mode & 0o777, 0o660, 'the bridge reaches it through the socket group');
    const conn = connect(sock);
    const lines = createInterface({ input: conn });
    const waiting = [];
    lines.on('line', (l) => waiting.shift()(JSON.parse(l)));
    const call = (req) => new Promise((r) => { waiting.push(r); conn.write(JSON.stringify(req) + '\n'); });
    try {
        const e1 = await call({ id: 1, op: 'ensure', slot: 2, pod_id: POD, vnc_password: 'Abcd1234' });
        assert.equal(e1.ok, true, e1.error);
        assert.equal(e1.id, 1);
        assert.deepEqual(e1.result.ports, { novnc: 6102, api: 8102, playwright: 9302 });
        assert.equal(e1.result.existing, false);
        assert.equal(eng.containers.size, 2);
        const creates = eng.calls.filter((c) => c.path === '/containers/create');
        assert.deepEqual(creates.map((c) => c.query.name).sort(), ['hbtest-pod-2-controller', 'hbtest-pod-2-node']);
        for (const d of ['browser-profile', 'downloads', 'auth']) assert.ok(existsSync(join(home, 'data/pods/slot-2', d)));
        // The node writes browser-profile and downloads through their group; the rest is the controller's alone.
        for (const [d, mode] of [['', 0o700], ['browser-profile', 0o775], ['downloads', 0o775], ['auth', 0o700]]) {
            const st = statSync(join(home, 'data/pods/slot-2', d));
            assert.equal(st.mode & 0o7777, mode, `slot-2/${d} mode`);
            assert.equal(st.uid, cfg.dataUid);
            assert.equal(st.gid, d === 'browser-profile' || d === 'downloads' ? cfg.nodeGid : cfg.dataGid);
        }

        const e2 = await call({ id: 2, op: 'ensure', slot: 2, pod_id: POD, vnc_password: 'Abcd1234' });
        assert.equal(e2.result.existing, true);
        assert.equal(eng.calls.filter((c) => c.path === '/containers/create').length, 2, 'no new containers');

        const ls = await call({ id: 3, op: 'list' });
        assert.equal(ls.result.pods.length, 1);
        assert.equal(ls.result.pods[0].pod_id, POD);
        assert.equal(ls.result.pods[0].containers.node.state, 'running');
        assert.equal(ls.result.pods[0].containers.controller.state, 'running');

        // The controller saved a login into the slot; stash keeps a copy while running, then moves it.
        const prof = join(home, 'data/pods/slot-2/auth/profiles/happy-chat');
        mkdirSync(prof, { recursive: true });
        writeFileSync(join(prof, 'state.enc'), 'v1');
        assert.deepEqual((await call({ id: 4, op: 'stash_auth', slot: 2, chat_hash: CHAT, keep: true })).result, { stashed: true });
        assert.ok(existsSync(join(prof, 'state.enc')), 'keep leaves the running pod its copy');
        writeFileSync(join(prof, 'state.enc'), 'v2');
        assert.deepEqual((await call({ id: 5, op: 'stash_auth', slot: 2, chat_hash: CHAT })).result, { stashed: true });
        assert.ok(!existsSync(join(home, 'data/pods/slot-2/auth/profiles')));
        assert.equal(readFileSync(join(home, 'data/chats', CHAT, 'auth/profiles/happy-chat/state.enc'), 'utf8'), 'v2');
        assert.equal(readFileSync(join(home, 'data/chats', CHAT, 'auth/profiles.prev/happy-chat/state.enc'), 'utf8'), 'v1');

        // A new pod for the chat (new pod id) gets a wiped slot, then adopts the login.
        const POD2 = 'c'.repeat(32);
        writeFileSync(join(home, 'data/pods/slot-2/downloads/left-over'), 'x');
        const e3 = await call({ id: 6, op: 'ensure', slot: 2, pod_id: POD2, vnc_password: 'Zyxw9876' });
        assert.equal(e3.result.existing, false);
        assert.equal(eng.containers.size, 2);
        assert.ok([...eng.containers.values()].every((c) => c.Labels['happy-browser.pod_id'] === POD2), 'old pod removed');
        assert.deepEqual(readdirSync(join(home, 'data/pods/slot-2/downloads')), [], 'slot wiped');
        assert.deepEqual((await call({ id: 7, op: 'adopt_auth', slot: 2, chat_hash: CHAT })).result, { adopted: true });
        assert.equal(readFileSync(join(home, 'data/pods/slot-2/auth/profiles/happy-chat/state.enc'), 'utf8'), 'v2');
        assert.ok(existsSync(join(home, 'data/chats', CHAT, 'auth/profiles/happy-chat/state.enc')), 'chat keeps its copy');
        assert.deepEqual((await call({ id: 8, op: 'adopt_auth', slot: 2, chat_hash: 'd'.repeat(32) })).result, { adopted: false });

        const st = await call({ id: 9, op: 'stop', slot: 2 });
        assert.equal(st.ok, true);
        assert.equal(eng.containers.size, 0);
        assert.ok(!existsSync(join(home, 'data/pods/slot-2')));
        assert.ok(existsSync(join(home, 'data/chats', CHAT, 'auth/profiles')), 'stop never touches the chat');

        const refused = await call({ id: 10, op: 'ensure', slot: 0, pod_id: POD, vnc_password: 'short' });
        assert.equal(refused.ok, false);
        assert.match(refused.error, /vnc_password/);
        const junk = await new Promise((r) => { waiting.push(r); conn.write('not json\n'); });
        assert.deepEqual(junk, { id: null, ok: false, error: 'bad json' });
    } finally {
        conn.destroy();
        server.close();
        await eng.close();
    }
});

test('list removes a labeled pod whose slot directory is gone', async () => {
    const { home, cfg } = setup();
    const eng = await fakeEngine(home);
    const launcher = createLauncher(cfg, { engine: createEngine(eng.socketPath), images: composeImages(COMPOSE), seccomp: SECCOMP, secrets: SECRETS, log: { log() {}, warn() {} } });
    try {
        await launcher.handle({ op: 'ensure', slot: 1, pod_id: POD, vnc_password: 'Abcd1234' });
        // Another project's pods are invisible to this launcher.
        eng.containers.set('other', { Id: 'other', Labels: { 'happy-browser.pod': '1', 'happy-browser.project': 'happy-browser', 'happy-browser.slot': '1', 'happy-browser.pod_id': POD, 'happy-browser.role': 'node' }, State: 'running' });
        const { rmSync } = await import('node:fs');
        rmSync(join(home, 'data/pods/slot-1'), { recursive: true });
        const ls = await launcher.handle({ op: 'list' });
        assert.deepEqual(ls.result.pods, []);
        assert.deepEqual([...eng.containers.keys()], ['other']);
    } finally { await eng.close(); }
});

// A parent chat's saved login, as stash_auth leaves it.
function saveLogin(home, hash, value, mode = 0o700) {
    const prof = join(home, 'data/chats', hash, 'auth/profiles/happy-chat');
    mkdirSync(prof, { recursive: true, mode });
    writeFileSync(join(prof, 'state.enc'), value);
    return prof;
}
const readLogin = (home, hash, which = 'profiles') => readFileSync(join(home, 'data/chats', hash, 'auth', which, 'happy-chat/state.enc'), 'utf8');
const PARENT = 'e'.repeat(32);

test('copy_auth: a fork gets a copy of its parent login, once, and the parent is untouched', async () => {
    const { home, cfg } = setup();
    const launcher = createLauncher(cfg, { engine: {}, images: {}, seccomp: '', secrets: SECRETS, log: { log() {}, warn() {} } });
    const copy = (from, to) => launcher.handle({ op: 'copy_auth', from_chat_hash: from, chat_hash: to });

    // Nothing saved for the parent: nothing to copy, and no directory made for the child.
    assert.deepEqual((await copy(PARENT, CHAT)).result, { copied: false, reason: 'no_source' });
    assert.ok(!existsSync(join(home, 'data/chats', CHAT)));
    mkdirSync(join(home, 'data/chats', PARENT, 'auth/profiles'), { recursive: true });
    assert.deepEqual((await copy(PARENT, CHAT)).result, { copied: false, reason: 'no_source' }, 'an empty profiles dir is no login');

    saveLogin(home, PARENT, 'parent-v1');
    const before = statSync(join(home, 'data/chats', PARENT, 'auth/profiles/happy-chat/state.enc'));
    assert.deepEqual((await copy(PARENT, CHAT)).result, { copied: true });
    assert.equal(readLogin(home, CHAT), 'parent-v1');
    for (const d of [join(home, 'data/chats', CHAT), join(home, 'data/chats', CHAT, 'auth'), join(home, 'data/chats', CHAT, 'auth/profiles')]) {
        assert.equal(statSync(d).mode & 0o777, 0o700, d);
        assert.equal(statSync(d).uid, process.getuid());
    }
    assert.deepEqual(readdirSync(join(home, 'data/chats', CHAT, 'auth')), ['profiles'], 'no temp dir or prev left behind');
    const after = statSync(join(home, 'data/chats', PARENT, 'auth/profiles/happy-chat/state.enc'));
    assert.equal(readLogin(home, PARENT), 'parent-v1');
    assert.equal(after.mtimeMs, before.mtimeMs, 'parent file untouched');
    assert.deepEqual(readdirSync(join(home, 'data/chats', PARENT, 'auth')), ['profiles']);

    // The child's own login is never replaced, even by a newer parent login.
    writeFileSync(join(home, 'data/chats', CHAT, 'auth/profiles/happy-chat/state.enc'), 'child-own');
    saveLogin(home, PARENT, 'parent-v2');
    assert.deepEqual((await copy(PARENT, CHAT)).result, { copied: false, reason: 'exists' });
    assert.equal(readLogin(home, CHAT), 'child-own');

    // Refused before any file is touched.
    const r = await copy(CHAT, CHAT);
    assert.equal(r.ok, false);
    assert.match(r.error, /must differ/);
    const r2 = await launcher.handle({ op: 'copy_auth', from_chat_hash: '..', chat_hash: CHAT });
    assert.equal(r2.ok, false);
    assert.match(r2.error, /bad from_chat_hash/);
});

test('copy_auth racing stash_auth leaves both chats whole', async () => {
    const { home, cfg } = setup();
    const eng = await fakeEngine(home);
    const launcher = createLauncher(cfg, { engine: createEngine(eng.socketPath), images: composeImages(COMPOSE), seccomp: SECCOMP, secrets: SECRETS, log: { log() {}, warn() {} } });
    const slotLogin = (slot, value) => {
        const prof = join(home, `data/pods/slot-${slot}/auth/profiles/happy-chat`);
        mkdirSync(prof, { recursive: true });
        writeFileSync(join(prof, 'state.enc'), value);
    };
    try {
        for (let i = 0; i < 20; i++) {
            const parent = (i.toString(16).padStart(2, '0') + 'e'.repeat(30));
            const child = (i.toString(16).padStart(2, '0') + 'f'.repeat(30));
            await launcher.handle({ op: 'ensure', slot: 0, pod_id: POD, vnc_password: 'Abcd1234' });
            await launcher.handle({ op: 'ensure', slot: 1, pod_id: 'c'.repeat(32), vnc_password: 'Abcd1234' });
            saveLogin(home, parent, 'parent-old');
            slotLogin(0, 'parent-new');
            slotLogin(1, 'child-own');
            // The parent's pod saves while the fork copies, and the fork's own pod saves too.
            const [s0, c, s1] = await Promise.all([
                launcher.handle({ op: 'stash_auth', slot: 0, chat_hash: parent, keep: true }),
                launcher.handle({ op: 'copy_auth', from_chat_hash: parent, chat_hash: child }),
                launcher.handle({ op: 'stash_auth', slot: 1, chat_hash: child, keep: true }),
            ]);
            assert.equal(s0.ok && c.ok && s1.ok, true, JSON.stringify([s0, c, s1]));
            assert.equal(readLogin(home, parent), 'parent-new');
            assert.equal(readLogin(home, parent, 'profiles.prev'), 'parent-old');
            // Whichever went first, the child ends on its own login, never a half copy.
            assert.equal(readLogin(home, child), 'child-own');
            if (c.result.copied) assert.match(readLogin(home, child, 'profiles.prev'), /^parent-(old|new)$/);
            else assert.equal(c.result.reason, 'exists');
            for (const h of [parent, child]) {
                assert.ok(readdirSync(join(home, 'data/chats', h, 'auth')).every((n) => n === 'profiles' || n === 'profiles.prev'), 'no temp dirs');
            }
        }
    } finally { await eng.close(); }
});

test('EVIDENCE_TZ is the pod node\'s TZ (its panel clock) and every pod controller\'s audit zone', () => {
    const { cfg } = setup({ EVIDENCE_TZ: 'Europe/Paris', SCREENSHOT_TIME_MODE: 'tab' });
    const ctl = controllerSpec(cfg, { slot: 2, podId: POD, image: 'x', secrets: SECRETS });
    const node = nodeSpec(cfg, { slot: 2, podId: POD, vncPassword: 'Abcd1234', image: 'x', seccomp: SECCOMP });
    assert.ok(ctl.Env.includes('EVIDENCE_TZ=Europe/Paris'));
    assert.ok(ctl.Env.includes('SCREENSHOT_TIME_MODE=tab'));
    assert.ok(node.Env.includes('TZ=Europe/Paris'));
    assert.ok(!ctl.Env.some((e) => e.startsWith('TZ=')));
    const patches = ctl.HostConfig.Binds.filter((b) => b.includes('/controller-patch/'));
    assert.deepEqual(patches, [`${BROWSER_DIR}/controller-patch/happy_live_frames.py:/happy/controller-patch/happy_live_frames.py:ro`]);
    assert.throws(() => setup({ SCREENSHOT_TIME_MODE: 'window' }), /SCREENSHOT_TIME_MODE/);
    assert.throws(() => setup({ EVIDENCE_TZ: '../etc/x y' }), /EVIDENCE_TZ/);
    // compose passes them to the launcher, the shared controller and the shared node alike.
    const block = (name) => COMPOSE.split(new RegExp(`^  ${name}:$`, 'm'))[1].split(/^  \S/m)[0];
    for (const name of ['launcher', 'controller']) {
        assert.match(block(name), /^      EVIDENCE_TZ: \$\{EVIDENCE_TZ:-America\/Toronto\}$/m, name);
        assert.match(block(name), /^      SCREENSHOT_TIME_MODE: \$\{SCREENSHOT_TIME_MODE:-desktop\}$/m, name);
    }
    assert.match(block('browser-node'), /^      TZ: \$\{EVIDENCE_TZ:-America\/Toronto\}$/m);
    assert.doesNotMatch(block('controller'), /^      TZ:/m);
});
