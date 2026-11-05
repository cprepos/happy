// Pod launcher: templates, input validation, the socket protocol and the slot lifecycle, against a
// fake Engine API on a unix socket. No Docker needed.
import { test } from 'node:test';
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
        POD_DATA_UID: String(me.uid), POD_DATA_GID: String(me.gid), ...extra,
    });
    return { home, cfg };
}

// A fake Engine API: containers in memory, every request recorded.
async function fakeEngine(dir) {
    const socketPath = join(dir, 'docker.sock');
    const containers = new Map();
    const calls = [];
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
            if (req.method === 'DELETE' && (m = path.match(/^\/containers\/([^/]+)$/))) {
                if (!containers.delete(m[1])) return send(404, { message: 'no such container' });
                return send(204);
            }
            send(404, { message: 'unhandled' });
        });
    });
    await new Promise((r) => server.listen(socketPath, r));
    return { socketPath, containers, calls, close: () => new Promise((r) => server.close(r)) };
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
        assert.deepEqual(node.HostConfig.CapAdd, ['CHOWN', 'DAC_OVERRIDE', 'KILL', 'SETGID', 'SETUID']);
        assert.equal(node.HostConfig.SecurityOpt.find((s) => s.startsWith('seccomp=')), `seccomp=${SECCOMP}`, 'seccomp is the file content');
        const env = (s) => Object.fromEntries(s.Env.map((e) => [e.slice(0, e.indexOf('=')), e.slice(e.indexOf('=') + 1)]));
        const ne = env(node), ce = env(ctl);
        assert.equal(ne.PLAYWRIGHT_SERVER_HOST, '127.0.0.1');
        assert.equal(ne.NOVNC_PORT, String(p.novnc));
        assert.equal(ne.PLAYWRIGHT_SERVER_PORT, String(p.playwright));
        assert.equal(ne.VNC_PASSWORD, 'Abcd1234');
        assert.deepEqual(ctl.Cmd, ['uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', String(p.api)]);
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
    const node = nodeSpec(cfg, { slot: 0, podId: POD, vncPassword: 'Abcd1234', image: 'x', seccomp: SECCOMP });
    const nodeBlock = COMPOSE.split(/^  browser-node:$/m)[1].split(/^  controller:$/m)[0];
    for (const m of nodeBlock.matchAll(/^      - \.\/(\S+):(\S+)$/gm)) {
        assert.ok(node.HostConfig.Binds.includes(`${BROWSER_DIR}/${m[1]}:${m[2]}`), `pod node mounts ./${m[1]}`);
    }
});

test('config: slots and port bases are bounded', () => {
    assert.throws(() => setup({ MAX_PODS: String(HARD_MAX_PODS + 1) }), /MAX_PODS/);
    assert.throws(() => setup({ MAX_PODS: '0' }), /MAX_PODS/);
    assert.throws(() => setup({ POD_API_BASE: '80' }), /out of range/);
    assert.throws(() => launcherConfig({}), /required/);
});

test('validation: only the five ops, with exact fields', () => {
    const { cfg } = setup({ MAX_PODS: '4' });
    const ok = (r) => assert.doesNotThrow(() => validate(cfg, r));
    const bad = (r, re) => assert.throws(() => validate(cfg, r), re);
    ok({ op: 'ensure', slot: 0, pod_id: POD, vnc_password: 'Abcd1234' });
    ok({ op: 'stop', slot: 3 });
    ok({ op: 'list' });
    ok({ op: 'adopt_auth', slot: 1, chat_hash: CHAT });
    ok({ op: 'stash_auth', slot: 1, chat_hash: CHAT, keep: true });
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
    assert.equal(statSync(sock).mode & 0o777, 0o600);
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
