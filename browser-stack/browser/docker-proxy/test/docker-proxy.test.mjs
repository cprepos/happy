// The Docker socket proxy: its allowlist against the launcher's real pod templates, and the
// launcher driving a fake Engine API through it. No Docker needed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { mkdtempSync, mkdirSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { proxyConfig, checkCreate, checkExec, checkList, podOf, route, createProxy, serve } from '../docker-proxy.mjs';
import { launcherConfig, composeImages, nodeSpec, controllerSpec, createEngine, createLauncher } from '../../launcher/launcher.mjs';

const BROWSER_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const COMPOSE = readFileSync(join(BROWSER_DIR, 'compose.browser.yml'), 'utf8');
const SECCOMP = JSON.stringify(JSON.parse(readFileSync(join(BROWSER_DIR, 'seccomp', 'chromium-sandbox.json'), 'utf8')));
const IMAGES = composeImages(COMPOSE);
const SECRETS = { apiToken: 't', authStateKey: 'k', shareTokenSecret: 's' };
const POD = 'a'.repeat(32);
const quiet = { log() {}, warn() {} };

function setup() {
    const home = mkdtempSync(join(tmpdir(), 'docker-proxy-test-'));
    const me = { uid: process.getuid(), gid: process.getgid() };
    const lcfg = launcherConfig({
        LAUNCHER_BROWSER_DIR: BROWSER_DIR, LAUNCHER_HOME: home, LAUNCHER_PROJECT: 'hbtest',
        POD_DATA_UID: String(me.uid), POD_DATA_GID: String(me.gid), POD_NODE_UID: String(me.uid + 1), POD_NODE_GID: String(me.gid),
    });
    const pcfg = proxyConfig({
        PROXY_PROJECT: 'hbtest', PROXY_IMAGES: `${IMAGES.node},${IMAGES.controller}`,
        PROXY_PODS_DIR: lcfg.podsDir, PROXY_RO_DIR: BROWSER_DIR,
        PROXY_NODE_UID: String(lcfg.nodeUid), PROXY_NODE_GID: String(lcfg.nodeGid),
        PROXY_CONTROLLER_UID: String(lcfg.dataUid), PROXY_CONTROLLER_GID: String(lcfg.dataGid),
    });
    return { home, lcfg, pcfg };
}
const specs = (lcfg, slot = 2) => ({
    node: nodeSpec(lcfg, { slot, podId: POD, vncPassword: 'Abcd1234', image: IMAGES.node, seccomp: SECCOMP }),
    controller: controllerSpec(lcfg, { slot, podId: POD, image: IMAGES.controller, secrets: SECRETS }),
});
const clone = (o) => JSON.parse(JSON.stringify(o));

test('config: pinned images, absolute dirs, no root uids', () => {
    const base = { PROXY_IMAGES: IMAGES.node, PROXY_PODS_DIR: '/h/data/pods', PROXY_RO_DIR: '/r/browser' };
    assert.equal(proxyConfig(base).execUser, '1994');
    assert.equal(proxyConfig(base).controllerUser, '1993:1993');
    assert.throws(() => proxyConfig({ ...base, PROXY_IMAGES: 'node:22' }), /pinned/);
    assert.throws(() => proxyConfig({ ...base, PROXY_PODS_DIR: 'rel' }), /absolute/);
    assert.throws(() => proxyConfig({ ...base, PROXY_RO_DIR: '/r/../etc' }), /absolute/);
    assert.throws(() => proxyConfig({ ...base, PROXY_NODE_UID: '0' }), /never root/);
    assert.throws(() => proxyConfig({ ...base, PROXY_CONTROLLER_GID: '0' }), /never root/);
});

test('create: the launcher\'s own templates pass', () => {
    const { lcfg, pcfg } = setup();
    for (const slot of [0, 2, 7]) {
        const s = specs(lcfg, slot);
        checkCreate(pcfg, `hbtest-pod-${slot}-node`, s.node);
        checkCreate(pcfg, `hbtest-pod-${slot}-controller`, s.controller);
    }
});

test('create: anything outside the templates is refused', () => {
    const { lcfg, pcfg } = setup();
    const s = specs(lcfg);
    const bad = (name, mutate, why) => {
        const role = name.endsWith('node') ? 'node' : 'controller';
        const b = clone(s[role]);
        mutate(b);
        assert.throws(() => checkCreate(pcfg, name, b), why, `${name}: ${why}`);
    };
    const n = 'hbtest-pod-2-node', c = 'hbtest-pod-2-controller';
    bad('other-pod-2-node', () => {}, /name/);
    bad('hbtest-pod-2-shell', () => {}, /name/);
    bad(n, (b) => { b.Image = 'alpine:3'; }, /pinned/);
    bad(n, (b) => { b.Image = IMAGES.node.replace(/.$/, '0'); }, /pinned/);
    bad(n, (b) => { b.User = '0:0'; }, /User/);
    bad(n, (b) => { delete b.User; }, /User/);
    bad(n, (b) => { b.User = s.controller.User; }, /User/);
    bad(c, (b) => { b.User = 'root'; }, /User/);
    bad(n, (b) => { b.HostConfig.Privileged = true; }, /Privileged/);
    bad(n, (b) => { b.HostConfig.CapAdd = ['SYS_ADMIN']; }, /CapAdd/);
    bad(n, (b) => { b.HostConfig.CapDrop = []; }, /CapDrop/);
    bad(n, (b) => { b.HostConfig.SecurityOpt = [b.HostConfig.SecurityOpt[1]]; }, /no-new-privileges/);
    bad(n, (b) => { b.HostConfig.SecurityOpt.push('seccomp=unconfined'); }, /SecurityOpt/);
    bad(n, (b) => { b.HostConfig.SecurityOpt.push('apparmor=unconfined'); }, /SecurityOpt/);
    bad(c, (b) => { b.HostConfig.ReadonlyRootfs = false; }, /ReadonlyRootfs/);
    bad(c, (b) => { b.HostConfig.PidMode = 'host'; }, /PidMode/);
    bad(c, (b) => { b.HostConfig.IpcMode = 'host'; }, /IpcMode/);
    bad(c, (b) => { b.HostConfig.Devices = [{ PathOnHost: '/dev/sda' }]; }, /Devices/);
    bad(c, (b) => { b.HostConfig.Mounts = [{ Type: 'bind', Source: '/', Target: '/h' }]; }, /Mounts/);
    bad(c, (b) => { b.HostConfig.VolumesFrom = ['x']; }, /VolumesFrom/);
    bad(c, (b) => { b.HostConfig.UsernsMode = 'host'; }, /UsernsMode/);
    bad(c, (b) => { b.HostConfig.NetworkMode = 'container:x'; }, /NetworkMode/);
    bad(c, (b) => { b.HostConfig.RestartPolicy = { Name: 'always' }; }, /RestartPolicy/);
    bad(c, (b) => { b.HostConfig.Tmpfs = { '/etc': '' }; }, /Tmpfs/);
    bad(c, (b) => { b.HostConfig.Binds.push('/var/run/docker.sock:/var/run/docker.sock'); }, /bind/);
    bad(c, (b) => { b.HostConfig.Binds.push('/:/host:ro'); }, /bind/);
    bad(c, (b) => { b.HostConfig.Binds.push(`${lcfg.podsDir}/slot-3:/other`); }, /bind source/);
    bad(c, (b) => { b.HostConfig.Binds.push(`${lcfg.podsDir}/slot-2/../slot-3:/other`); }, /bind path/);
    bad(c, (b) => { b.HostConfig.Binds.push(`${lcfg.home}/secrets:/s:ro`); }, /bind source/);
    bad(c, (b) => { b.HostConfig.Binds.push(`${BROWSER_DIR}/launcher:/l`); }, /bind source/, 'the repo only read-only');
    bad(c, (b) => { b.HostConfig.Binds.push(`${BROWSER_DIR}/x:/x:ro,z`); }, /bind options/);
    bad(c, (b) => { b.HostConfig.Binds.push(`${BROWSER_DIR}:/x:ro`); }, /bind source/, 'not the repo root itself');
    bad(c, (b) => { b.Labels['happy-browser.slot'] = '3'; }, /labels/);
    bad(c, (b) => { b.Labels['happy-browser.project'] = 'happy-browser'; }, /labels/);
    bad(c, (b) => { b.Volumes = { '/x': {} }; }, /Volumes/);
    bad(c, (b) => { b.Privileged = true; }, /Privileged/);
});

test('exec: python3 as the node uid only', () => {
    const { lcfg, pcfg } = setup();
    const ok = { AttachStdin: false, AttachStdout: true, AttachStderr: true, Tty: false, User: String(lcfg.nodeUid), Env: ['DISPLAY=:99'], Cmd: ['python3', '-I', '-c', 'x'] };
    checkExec(pcfg, ok);
    assert.throws(() => checkExec(pcfg, { ...ok, User: '0' }), /User/);
    assert.throws(() => checkExec(pcfg, { ...ok, User: undefined }), /User/);
    assert.throws(() => checkExec(pcfg, { ...ok, Cmd: ['sh', '-c', 'x'] }), /Cmd/);
    assert.throws(() => checkExec(pcfg, { ...ok, Privileged: true }), /Privileged/);
    assert.throws(() => checkExec(pcfg, { ...ok, AttachStdin: true }), /AttachStdin/);
});

test('list needs the pod label filters; routes outside the allowlist are refused', () => {
    const { pcfg } = setup();
    const q = (f) => new URLSearchParams({ filters: JSON.stringify(f) });
    checkList(pcfg, q({ label: ['happy-browser.pod=1', 'happy-browser.project=hbtest'] }));
    assert.throws(() => checkList(pcfg, q({ label: ['happy-browser.pod=1'] })), /filters/);
    assert.throws(() => checkList(pcfg, new URLSearchParams()), /filters/);
    assert.equal(route('GET', '/v1.43/containers/json?all=1').kind, 'list');
    assert.equal(route('GET', `/v1.43/images/${encodeURIComponent(IMAGES.node)}/json`).ref, IMAGES.node);
    for (const [m, u] of [['GET', '/v1.43/containers/x/json'], ['POST', '/v1.43/containers/x/kill'], ['GET', '/v1.43/containers/x/archive'],
        ['PUT', '/v1.43/containers/x/archive'], ['POST', '/v1.43/images/create'], ['POST', '/v1.43/build'], ['GET', '/v1.43/info'],
        ['POST', '/v1.43/volumes/create'], ['POST', '/v1.43/networks/create'], ['GET', '/v1.43/events'], ['POST', '/session'],
        ['POST', '/v1.43/containers/x/attach'], ['POST', '/v1.43/containers/x/update'], ['DELETE', '/v1.43/images/x'],
        ['POST', '/v1.43/containers/a%2F..%2Fb/start'], ['POST', '/v1.43/exec/x/resize']]) {
        assert.throws(() => route(m, u), /./, `${m} ${u}`);
    }
});

test('podOf: only this project\'s pod containers, by their real id', () => {
    const { pcfg } = setup();
    const id = 'f'.repeat(64);
    const info = (name, labels) => ({ Id: id, Name: name, Config: { Labels: labels } });
    const L = { 'happy-browser.pod': '1', 'happy-browser.project': 'hbtest', 'happy-browser.role': 'node' };
    assert.deepEqual(podOf(pcfg, info('/hbtest-pod-1-node', L)), { id, role: 'node' });
    assert.throws(() => podOf(pcfg, info('/hbtest-bridge-1', L)), /pod/);
    assert.throws(() => podOf(pcfg, info('/hbtest-pod-1-node', { ...L, 'happy-browser.project': 'x' })), /pod/);
    assert.throws(() => podOf(pcfg, info('/hbtest-pod-1-node', { ...L, 'happy-browser.role': 'controller' })), /pod/);
    assert.throws(() => podOf(pcfg, info('/hbtest-pod-1-node', {})), /pod/);
});

// A fake Engine API with inspect, on a unix socket; every request it sees is recorded.
async function fakeEngine(dir) {
    const socketPath = join(dir, 'engine.sock');
    const containers = new Map();
    const execs = new Map();
    const seen = [];
    let n = 0;
    const hex = (i) => i.toString(16).padStart(64, '0');
    const server = createServer((req, res) => {
        let body = '';
        req.on('data', (c) => { body += c; });
        req.on('end', () => {
            const url = new URL(req.url, 'http://x');
            const path = url.pathname.replace(/^\/v[\d.]+/, '');
            seen.push(`${req.method} ${path}`);
            const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(obj === undefined ? '' : JSON.stringify(obj)); };
            const find = (ref) => containers.get(ref) || [...containers.values()].find((c) => c.Name === `/${ref}`);
            let m;
            if (req.method === 'GET' && path === '/containers/json') return send(200, [...containers.values()].map((c) => ({ Id: c.Id, Labels: c.Config.Labels, State: c.State, Status: c.State, Created: 1 })));
            if (req.method === 'POST' && path === '/containers/create') {
                const id = hex(++n);
                const b = JSON.parse(body);
                containers.set(id, { Id: id, Name: `/${url.searchParams.get('name')}`, Config: { Labels: b.Labels }, State: 'created' });
                return send(201, { Id: id });
            }
            if (req.method === 'GET' && (m = path.match(/^\/containers\/([^/]+)\/json$/))) { const c = find(m[1]); return c ? send(200, c) : send(404, { message: 'No such container' }); }
            if (req.method === 'POST' && (m = path.match(/^\/containers\/([^/]+)\/start$/))) { const c = find(m[1]); c.State = 'running'; return send(204); }
            if (req.method === 'DELETE' && (m = path.match(/^\/containers\/([^/]+)$/))) { containers.delete(m[1]); return send(204); }
            if (req.method === 'POST' && (m = path.match(/^\/containers\/([^/]+)\/exec$/))) { const id = hex(1000 + ++n); execs.set(id, m[1]); return send(201, { Id: id }); }
            if (req.method === 'POST' && (m = path.match(/^\/exec\/([^/]+)\/start$/))) {
                const png = Buffer.alloc(33); png.writeUInt32BE(0x89504e47, 0); png.write('IHDR', 12, 'latin1'); png.writeUInt32BE(1920, 16); png.writeUInt32BE(1200, 20);
                const h = Buffer.alloc(8); h[0] = 1; h.writeUInt32BE(png.length, 4);
                // The capture's meta line on stderr, as scripts/screen-capture.py prints it.
                const meta = Buffer.from(`screen-capture-meta: ${JSON.stringify({ captured_at: '2026-11-11T15:00:00.000Z', local: '2026-11-11T10:00:00.000-05:00', tz: 'America/Toronto', screen: { width: 1920, height: 1200 }, rect: { x: 0, y: 0, width: 1920, height: 1200 }, workarea: null, panel_px: 0 })}\n`);
                const e = Buffer.alloc(8); e[0] = 2; e.writeUInt32BE(meta.length, 4);
                res.writeHead(200, { 'Content-Type': 'application/vnd.docker.raw-stream' });
                return res.end(Buffer.concat([h, png, e, meta]));
            }
            if (req.method === 'GET' && (m = path.match(/^\/exec\/([^/]+)\/json$/))) return send(200, { ExitCode: 0 });
            if (req.method === 'GET' && (m = path.match(/^\/images\/(.+)\/json$/))) return send(200, { Id: 'sha256:x' });
            send(404, { message: 'unhandled' });
        });
    });
    await new Promise((r) => server.listen(socketPath, r));
    return { socketPath, containers, seen, close: () => new Promise((r) => server.close(r)) };
}

const raw = (socketPath, method, path, body) => new Promise((resolve, reject) => {
    const data = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    const req = request({ socketPath, method, path, headers: data ? { 'Content-Type': 'application/json', 'Content-Length': data.length } : {} }, (res) => {
        let t = ''; res.on('data', (c) => { t += c; }); res.on('end', () => resolve({ status: res.statusCode, text: t }));
    });
    req.on('error', reject);
    req.end(data);
});

test('the launcher drives pods through the proxy; nothing else gets to the engine', async () => {
    const { home, lcfg, pcfg } = setup();
    const eng = await fakeEngine(home);
    mkdirSync(join(home, 'proxy'));
    const listen = join(home, 'proxy', 'docker.sock');
    const server = await serve(createProxy({ ...pcfg, upstream: eng.socketPath }, { log: quiet }), listen, { log: quiet });
    try {
        assert.equal(statSync(listen).mode & 0o777, 0o660);
        const launcher = createLauncher(lcfg, { engine: createEngine(listen), images: IMAGES, seccomp: SECCOMP, secrets: SECRETS, captureScript: 'print(1)', log: quiet });
        const e = await launcher.handle({ op: 'ensure', slot: 2, pod_id: POD, vnc_password: 'Abcd1234' });
        assert.equal(e.ok, true, e.error);
        assert.equal(eng.containers.size, 2);
        assert.ok([...eng.containers.values()].every((c) => c.State === 'running'));
        const s = await launcher.handle({ op: 'screen', slot: 2, pod_id: POD });
        assert.equal(s.ok, true, s.error);
        assert.equal(s.result.width, 1920);
        assert.equal(s.result.captured_at, '2026-11-11T15:00:00.000Z');
        assert.equal((await launcher.handle({ op: 'list' })).result.pods.length, 1);
        assert.equal((await launcher.handle({ op: 'stop', slot: 2 })).ok, true);
        assert.equal(eng.containers.size, 0);

        // Straight at the proxy: what the launcher never asks for is refused before the engine sees it.
        const before = eng.seen.length;
        const other = { Image: 'alpine:3', HostConfig: { Binds: ['/:/host'], Privileged: true } };
        for (const [m, p, b] of [
            ['POST', '/v1.43/containers/create?name=evil', other],
            ['POST', '/v1.43/containers/create?name=hbtest-pod-1-node', other],
            ['GET', '/v1.43/containers/json?all=1'],
            ['GET', '/v1.43/info'],
            ['POST', '/v1.43/images/create?fromImage=alpine'],
            ['GET', `/v1.43/exec/${'1'.repeat(64)}/json`],
            ['GET', '/v1.43/images/alpine%3A3/json'],
        ]) {
            const r = await raw(listen, m, p, b);
            assert.equal(r.status, 403, `${m} ${p}: ${r.text}`);
        }
        assert.equal(eng.seen.length, before, 'refused calls never reach the engine');

        // A container that is not a pod: inspected, then refused.
        eng.containers.set('b'.repeat(64), { Id: 'b'.repeat(64), Name: '/hbtest-bridge-1', Config: { Labels: {} }, State: 'running' });
        for (const [m, p, b] of [['POST', '/v1.43/containers/hbtest-bridge-1/start'], ['DELETE', `/v1.43/containers/${'b'.repeat(64)}?force=true`],
            ['POST', '/v1.43/containers/hbtest-bridge-1/exec', { User: String(lcfg.nodeUid), Cmd: ['python3'] }]]) {
            assert.equal((await raw(listen, m, p, b)).status, 403, `${m} ${p}`);
        }
        assert.deepEqual(eng.seen.slice(before), ['GET /containers/hbtest-bridge-1/json', `GET /containers/${'b'.repeat(64)}/json`, 'GET /containers/hbtest-bridge-1/json']);
        assert.equal(eng.containers.get('b'.repeat(64)).State, 'running');
    } finally {
        server.close();
        await eng.close();
    }
});
