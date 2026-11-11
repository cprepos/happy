#!/usr/bin/env node
// The pod launcher: the only process in the live-browser stack that holds the Docker socket.
//
// Each chat gets a pod of two host-network containers built from fixed templates here: a
// browser-node (noVNC 127.0.0.1:NOVNC_BASE+slot, Playwright 127.0.0.1:PLAYWRIGHT_BASE+slot)
// and its own auto-browser controller (127.0.0.1:API_BASE+slot, MAX_SESSIONS=1, /data is
// data/pods/slot-N). See docs/per-chat-pods-plan.md.
//
// It runs as its own non-root uid (POD_DATA_UID, which owns every slot directory and runs each pod's
// controller) with no network (network_mode: none) and no capabilities, reaches Docker only
// through the allowlisting socket proxy (docker-proxy/, DOCKER_SOCKET or DOCKER_HOST=unix://..),
// and listens only on a unix socket (LAUNCHER_SOCKET, 0660, group LAUNCHER_SOCKET_GID, which only
// the bridge is given) speaking newline-delimited JSON:
//
//   {"id":1,"op":"ensure","slot":0,"pod_id":"<32 hex>","vnc_password":"<8 alnum>"}
//   {"id":2,"op":"stop","slot":0}
//   {"id":3,"op":"list"}
//   {"id":4,"op":"adopt_auth","slot":0,"chat_hash":"<32 hex>"}
//   {"id":5,"op":"stash_auth","slot":0,"chat_hash":"<32 hex>","keep":false}
//   {"id":6,"op":"copy_auth","from_chat_hash":"<32 hex>","chat_hash":"<32 hex>"}
//   {"id":7,"op":"screen","slot":0,"pod_id":"<32 hex>","rect":{"x":0,"y":28,"width":1920,"height":1172}}
//
// screen is the one op that runs something inside a pod: scripts/screen-capture.py, read from
// this repo when the launcher starts, run as the node's uid in that slot's node container
// (only if it still carries that pod_id), which prints the X screen as a PNG: the whole root
// window, or with rect (four integers, validated here and again by the script against the
// screen) only that rectangle, read as such by XGetImage, never cropped afterwards. The reply is
// {"mime":"image/png","width":..,"height":..,"data":"<base64>","raw_sha256":"<hex>",
// "captured_at":"<UTC ISO>","local":"..","tz":"..","screen":{..},"capture_rect":{..},"panel_px":N}:
// raw_sha256 is the sha256 of exactly the PNG bytes the capture printed, taken here, where the
// capture ran; the controller recomputes it before it files the image.
//
// Every reply is {"id":..,"ok":true,"result":..} or {"id":..,"ok":false,"error":".."}. Nothing
// else is accepted: no image, mount, port, env or command comes from a caller. Image digests are
// read from compose.browser.yml (the node's from LAUNCHER_NODE_IMAGE, which compose sets to
// browser-node's own), so a pod runs exactly what the shared stack runs.
//
// Paths: LAUNCHER_BROWSER_DIR (this repo's browser-stack/browser) and LAUNCHER_HOME (the host's
// HAPPY_BROWSER_HOME) are host paths, mounted at the same paths in this container, because the
// bind sources it hands the Engine API are resolved on the host.
import { createHash } from 'node:crypto';
import { createServer, request as httpRequest } from 'node:http';
import { createServer as createNetServer } from 'node:net';
import { chmodSync, chownSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, unlinkSync, cpSync, lstatSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

export const HARD_MAX_PODS = 32;
export const ID_RE = /^[0-9a-f]{32}$/;
export const VNC_RE = /^[A-Za-z0-9]{8}$/;
export const OPS = new Set(['ensure', 'stop', 'list', 'adopt_auth', 'stash_auth', 'copy_auth', 'screen']);
// The height of Chromium's tab strip and toolbar in a maximized window (measured on the pinned
// image at 1920x1200). With BROWSER_KIOSK=0 the page gets the screen less this and less the
// desktop panel (BROWSER_PANEL_HEIGHT, browser.mk reads it from kiosk/fluxbox/init.window), so
// Playwright's window and the maximized one agree and nothing is clipped.
export const CHROME_UI_HEIGHT = 87;
export const SCREENSHOT_VIEWS = new Set(['desktop', 'tab']);
export const SCREEN_MAX_BYTES = 16 * 1024 * 1024;
const GiB = 1024 ** 3;

export function launcherConfig(env = process.env) {
    const num = (k, d) => { const v = env[k] === undefined || env[k] === '' ? d : Number(env[k]); if (!Number.isInteger(v) || v < 0) throw new Error(`${k} must be a non-negative integer`); return v; };
    const browserDir = env.LAUNCHER_BROWSER_DIR;
    const home = env.LAUNCHER_HOME;
    if (!browserDir || !home) throw new Error('LAUNCHER_BROWSER_DIR and LAUNCHER_HOME are required');
    const maxPods = num('MAX_PODS', 8);
    if (maxPods < 1 || maxPods > HARD_MAX_PODS) throw new Error(`MAX_PODS must be 1..${HARD_MAX_PODS}`);
    const cfg = {
        browserDir,
        home,
        podsDir: join(home, 'data', 'pods'),
        chatsDir: join(home, 'data', 'chats'),
        secretsDir: env.LAUNCHER_SECRETS_DIR || join(home, 'secrets'),
        socketPath: env.LAUNCHER_SOCKET || join(home, 'run', 'launcher.sock'),
        dockerSocket: dockerSocket(env),
        project: env.LAUNCHER_PROJECT || 'happy-browser',
        maxPods,
        novncBase: num('POD_NOVNC_BASE', 6100),
        apiBase: num('POD_API_BASE', 8100),
        playwrightBase: num('POD_PLAYWRIGHT_BASE', 9300),
        width: num('BROWSER_WIDTH', 1920),
        height: num('BROWSER_HEIGHT', 1200),
        kiosk: kioskFlag(env.BROWSER_KIOSK),
        // The controller's uid and gid (each pod's, and the owner of every slot directory: the
        // launcher's own), and the browser node's. Never root.
        dataUid: num('POD_DATA_UID', 1993),
        dataGid: num('POD_DATA_GID', 1993),
        nodeUid: num('POD_NODE_UID', 1994),
        nodeGid: num('POD_NODE_GID', 1994),
        socketGid: num('LAUNCHER_SOCKET_GID', 1996),
        maxSessions: 1,
        rateLimit: num('REQUEST_RATE_LIMIT_REQUESTS', 1200),
        logLevel: env.LOG_LEVEL || 'INFO',
        piiScrub: env.PII_SCRUB_SCREENSHOT || 'true',
        // The zone of the desktop panel's clock (the node's TZ) and of the controller's screenshot
        // audit; the controller refuses a bad one.
        evidenceTz: env.EVIDENCE_TZ || 'America/Toronto',
        // browser_screenshot's default view: desktop (the whole screen, panel and clock) or tab.
        screenshotTimeMode: env.SCREENSHOT_TIME_MODE || 'desktop',
        mcpProfile: env.MCP_TOOL_PROFILE || 'curated',
    };
    if (!/^[A-Za-z0-9_+-]+(\/[A-Za-z0-9_+-]+)*$/.test(cfg.evidenceTz)) throw new Error('EVIDENCE_TZ must be an IANA zone name');
    if (!SCREENSHOT_VIEWS.has(cfg.screenshotTimeMode)) throw new Error('SCREENSHOT_TIME_MODE must be desktop or tab');
    // The desktop panel above the window; the kiosk has none.
    cfg.panelHeight = cfg.kiosk ? 0 : num('BROWSER_PANEL_HEIGHT', 0);
    cfg.viewportHeight = num('BROWSER_VIEWPORT_HEIGHT', viewportHeight(cfg));
    if (cfg.viewportHeight < 1 || cfg.viewportHeight > cfg.height) throw new Error('BROWSER_VIEWPORT_HEIGHT must be 1..BROWSER_HEIGHT');
    if (!/^[a-z0-9][a-z0-9_-]*$/.test(cfg.project)) throw new Error('LAUNCHER_PROJECT must be a compose project name');
    for (const k of ['dataUid', 'dataGid', 'nodeUid', 'nodeGid']) if (cfg[k] === 0) throw new Error(`${k} must not be root`);
    for (const base of ['novncBase', 'apiBase', 'playwrightBase']) {
        if (cfg[base] < 1024 || cfg[base] + HARD_MAX_PODS > 65535) throw new Error(`${base} out of range`);
    }
    return cfg;
}

// The Engine API socket: DOCKER_SOCKET, else DOCKER_HOST's unix:// path, else the default.
export function dockerSocket(env) {
    if (env.DOCKER_SOCKET) return env.DOCKER_SOCKET;
    const h = env.DOCKER_HOST || '';
    if (h.startsWith('unix://')) return h.slice('unix://'.length);
    if (h) throw new Error('DOCKER_HOST must be a unix:// socket');
    return '/var/run/docker.sock';
}

export function kioskFlag(v) {
    const s = v === undefined ? '' : String(v); // exactly as the entrypoint takes it
    if (s === '' || s === '0') return false;
    if (s === '1') return true;
    throw new Error('BROWSER_KIOSK must be 0 or 1');
}
// The page's height: the whole screen in kiosk mode, the screen less the desktop panel and
// Chromium's own UI otherwise.
export const viewportHeight = ({ kiosk, height, panelHeight = 0 }) => (kiosk ? height : height - panelHeight - CHROME_UI_HEIGHT);

// A pinned image reference: a registry digest (name@sha256:<64 hex>), or a local image id
// (sha256:<64 hex>, the BROWSER_NODE_CHROME=1 build, which has no registry digest).
export const PINNED_IMAGE_RE = /^(\S+@sha256:[0-9a-f]{64}|sha256:[0-9a-f]{64})$/;

// The two image references in compose.browser.yml (x-browser-node-image, x-controller-image). The
// node's may be written ${BROWSER_NODE_IMAGE:-<default>}; compose hands the launcher the resolved
// one as LAUNCHER_NODE_IMAGE, which then wins, so a pod runs what browser-node runs.
export function composeImages(composeText, env = {}) {
    const pick = (key) => {
        const m = composeText.match(new RegExp(`^x-${key}-image: &\\w+ (?:\\$\\{[A-Z_]+:-(\\S+@sha256:[0-9a-f]{64})\\}|(\\S+@sha256:[0-9a-f]{64}))\\s*$`, 'm'));
        if (!m) throw new Error(`compose.browser.yml has no pinned x-${key}-image`);
        return m[1] || m[2];
    };
    const node = env.LAUNCHER_NODE_IMAGE || pick('browser-node');
    if (!PINNED_IMAGE_RE.test(node)) throw new Error('LAUNCHER_NODE_IMAGE must be a pinned image (name@sha256:<digest> or sha256:<image id>)');
    return { node, controller: pick('controller') };
}

export function ports(cfg, slot) {
    return { novnc: cfg.novncBase + slot, api: cfg.apiBase + slot, playwright: cfg.playwrightBase + slot };
}

export const names = (cfg, slot) => ({ node: `${cfg.project}-pod-${slot}-node`, controller: `${cfg.project}-pod-${slot}-controller` });
export const slotDir = (cfg, slot) => join(cfg.podsDir, `slot-${slot}`);

export function validate(cfg, req) {
    if (!req || typeof req !== 'object' || Array.isArray(req)) throw new Error('bad request');
    if (!OPS.has(req.op)) throw new Error('unknown op');
    const allowed = { ensure: ['slot', 'pod_id', 'vnc_password'], stop: ['slot'], list: [], adopt_auth: ['slot', 'chat_hash'], stash_auth: ['slot', 'chat_hash', 'keep'], copy_auth: ['from_chat_hash', 'chat_hash'], screen: ['slot', 'pod_id', 'rect'] }[req.op];
    for (const k of Object.keys(req)) if (k !== 'id' && k !== 'op' && !allowed.includes(k)) throw new Error(`unexpected field ${k}`);
    if (allowed.includes('slot') && !(Number.isInteger(req.slot) && req.slot >= 0 && req.slot < cfg.maxPods)) throw new Error('bad slot');
    if (allowed.includes('pod_id') && (typeof req.pod_id !== 'string' || !ID_RE.test(req.pod_id))) throw new Error('bad pod_id');
    if (req.op === 'ensure') {
        if (typeof req.vnc_password !== 'string' || !VNC_RE.test(req.vnc_password)) throw new Error('bad vnc_password');
    }
    if (allowed.includes('chat_hash') && (typeof req.chat_hash !== 'string' || !ID_RE.test(req.chat_hash))) throw new Error('bad chat_hash');
    if (allowed.includes('from_chat_hash')) {
        if (typeof req.from_chat_hash !== 'string' || !ID_RE.test(req.from_chat_hash)) throw new Error('bad from_chat_hash');
        if (req.from_chat_hash === req.chat_hash) throw new Error('from_chat_hash and chat_hash must differ');
    }
    if ('keep' in req && typeof req.keep !== 'boolean') throw new Error('bad keep');
    if ('rect' in req) req.rect = screenRect(cfg, req.rect);
    return req;
}

// A screen op's rect: {x, y, width, height}, integers, inside the screen, nothing else.
export function screenRect(cfg, rect) {
    if (!rect || typeof rect !== 'object' || Array.isArray(rect)) throw new Error('bad rect');
    const keys = ['x', 'y', 'width', 'height'];
    if (Object.keys(rect).length !== 4 || !keys.every((k) => Number.isInteger(rect[k]))) throw new Error('bad rect');
    const { x, y, width, height } = rect;
    if (x < 0 || y < 0 || width < 1 || height < 1 || x + width > cfg.width || y + height > cfg.height) throw new Error('rect is not inside the screen');
    return { x, y, width, height };
}

const META_PREFIX = 'screen-capture-meta: ';
// The capture's meta line (scripts/screen-capture.py), or null.
export function captureMeta(stderr) {
    const line = stderr.toString('utf8').split('\n').find((l) => l.startsWith(META_PREFIX));
    if (!line) return null;
    try {
        const m = JSON.parse(line.slice(META_PREFIX.length));
        return m && typeof m === 'object' && !Array.isArray(m) ? m : null;
    } catch { return null; }
}

const labels = (cfg, slot, podId, role) => ({
    'happy-browser.pod': '1',
    'happy-browser.project': cfg.project,
    'happy-browser.slot': String(slot),
    'happy-browser.pod_id': podId,
    'happy-browser.role': role,
});

// The browser-node: compose.browser.yml's browser-node service, per-slot ports, plus memory
// and CPU caps. Its own private /dev/shm (ShmSize); no IPC or /dev/shm shared with anything.
// Its own uid from the start (no root setup step), no capabilities, a read-only root and a
// private /tmp (exec: the entrypoint runs its patched script from there).
export function nodeSpec(cfg, { slot, podId, vncPassword, image, seccomp }) {
    const p = ports(cfg, slot);
    const dir = slotDir(cfg, slot);
    const b = cfg.browserDir;
    return {
        Image: image,
        Entrypoint: ['/happy/browser-node-entrypoint.sh'],
        Env: [
            `BROWSER_WIDTH=${cfg.width}`,
            `BROWSER_HEIGHT=${cfg.height}`,
            `BROWSER_KIOSK=${cfg.kiosk ? 1 : 0}`,
            // The desktop panel's clock shows this zone.
            `TZ=${cfg.evidenceTz}`,
            'BROWSER_URL=about:blank',
            'BROWSER_WS_ENDPOINT_FILE=/data/profile/browser-ws-endpoint.txt',
            'PLAYWRIGHT_SERVER_HOST=127.0.0.1',
            `PLAYWRIGHT_SERVER_PORT=${p.playwright}`,
            'PLAYWRIGHT_SERVER_ADVERTISED_HOST=127.0.0.1',
            `NOVNC_PORT=${p.novnc}`,
            'BROWSER_SANDBOX=auto',
            'BROWSER_SECCOMP_PROFILE=auto-browser',
            `VNC_PASSWORD=${vncPassword}`,
            'NOVNC_ALLOWED_HOSTS=',
            'NOVNC_ALLOWED_ORIGINS=',
            'HOME=/tmp',
        ],
        User: `${cfg.nodeUid}:${cfg.nodeGid}`,
        Labels: labels(cfg, slot, podId, 'node'),
        HostConfig: {
            NetworkMode: 'host',
            ShmSize: 2 * GiB,
            CapDrop: ['ALL'],
            SecurityOpt: ['no-new-privileges:true', `seccomp=${seccomp}`],
            ReadonlyRootfs: true,
            Tmpfs: { '/tmp': TMPFS_NODE },
            PidsLimit: 2048,
            Memory: 3 * GiB,
            MemorySwap: 3 * GiB,
            NanoCpus: 2e9,
            Init: true,
            RestartPolicy: { Name: 'no' },
            Binds: [
                `${dir}/browser-profile:/data/profile`,
                `${dir}/downloads:/data/downloads`,
                `${b}/scripts/browser-node-entrypoint.sh:/happy/browser-node-entrypoint.sh:ro`,
                `${b}/kiosk/happy-kiosk.mjs:/opt/browser-node/happy-kiosk.mjs:ro`,
                `${b}/kiosk/policy.json:/etc/chromium/policies/managed/happy-kiosk.json:ro`,
                `${b}/kiosk/policy.json:/etc/opt/chrome_for_testing/policies/managed/happy-kiosk.json:ro`,
                `${b}/kiosk/policy.json:/etc/opt/chrome/policies/managed/happy-kiosk.json:ro`,
                `${b}/kiosk/fluxbox:/happy/fluxbox:ro`,
            ],
        },
    };
}

// The controller: compose.browser.yml's controller service with this pod's port, takeover URL
// and /data, one session, and a fast reconnect while the node is still starting. It serves the
// app through controller-patch/happy_live_frames.py (live frames while an action runs, and the
// screen and page screenshots with their audit), which refuses to start on any controller but the 1.14.0 it was written against.
export const CONTROLLER_PATCH_DIR = '/happy/controller-patch';
export const TMPFS_NODE = 'rw,exec,nosuid,nodev,size=512m,mode=1777';
export const TMPFS_CONTROLLER = 'rw,noexec,nosuid,nodev,size=256m,mode=1777';
export function controllerSpec(cfg, { slot, podId, image, secrets }) {
    const p = ports(cfg, slot);
    return {
        Image: image,
        Cmd: ['uvicorn', 'happy_live_frames:app', '--host', '127.0.0.1', '--port', String(p.api)],
        Env: [
            `PYTHONPATH=${CONTROLLER_PATCH_DIR}`,
            'APP_ENV=development',
            `API_BEARER_TOKEN=${secrets.apiToken}`,
            'API_BIND_SCOPE=loopback',
            'API_TOKEN_FILE=/data/api-token',
            'API_ALLOW_TOKENLESS_LOOPBACK=false',
            'CONTROLLER_ALLOWED_HOSTS=localhost,127.0.0.1,::1',
            `LOG_LEVEL=${cfg.logLevel}`,
            'BROWSER_WS_ENDPOINT_FILE=/data/browser-profile/browser-ws-endpoint.txt',
            'BROWSER_SANDBOX=auto',
            'CONTROLLER_RUN_AS=auto',
            `TAKEOVER_URL=http://localhost:${p.novnc}/vnc.html?autoconnect=true&resize=scale`,
            'ARTIFACT_ROOT=/data/artifacts',
            'UPLOAD_ROOT=/data/uploads',
            'AUTH_ROOT=/data/auth',
            'APPROVAL_ROOT=/data/approvals',
            'AUDIT_ROOT=/data/audit',
            'JOB_STORE_ROOT=/data/jobs',
            'SESSION_STORE_ROOT=/data/sessions',
            'MEMORY_ROOT=/data/memory',
            'CLI_HOME=/data/cli-home',
            `AUTH_STATE_ENCRYPTION_KEY=${secrets.authStateKey}`,
            'REQUIRE_AUTH_STATE_ENCRYPTION=true',
            `SHARE_TOKEN_SECRET=${secrets.shareTokenSecret}`,
            'ALLOWED_HOSTS=*',
            `MAX_SESSIONS=${cfg.maxSessions}`,
            `MCP_TOOL_PROFILE=${cfg.mcpProfile}`,
            `DEFAULT_VIEWPORT_WIDTH=${cfg.width}`,
            `DEFAULT_VIEWPORT_HEIGHT=${cfg.viewportHeight}`,
            `REQUEST_RATE_LIMIT_REQUESTS=${cfg.rateLimit}`,
            'REQUEST_RATE_LIMIT_WINDOW_SECONDS=60',
            `PII_SCRUB_SCREENSHOT=${cfg.piiScrub}`,
            `EVIDENCE_TZ=${cfg.evidenceTz}`,
            `SCREENSHOT_TIME_MODE=${cfg.screenshotTimeMode}`,
            // As the shared controller: the secret filler's keystrokes are never recorded.
            'ENABLE_TRACING=false',
            'NETWORK_INSPECTOR_CAPTURE_BODIES=false',
            'CONNECT_RETRY_DELAY_SECONDS=0.2',
            'HOME=/tmp',
        ],
        User: `${cfg.dataUid}:${cfg.dataGid}`,
        Labels: labels(cfg, slot, podId, 'controller'),
        HostConfig: {
            NetworkMode: 'host',
            CapDrop: ['ALL'],
            SecurityOpt: ['no-new-privileges:true'],
            ReadonlyRootfs: true,
            Tmpfs: { '/tmp': TMPFS_CONTROLLER },
            Memory: 1 * GiB,
            MemorySwap: 1 * GiB,
            Init: true,
            RestartPolicy: { Name: 'no' },
            Binds: [
                `${slotDir(cfg, slot)}:/data`,
                `${cfg.browserDir}/controller-patch/happy_live_frames.py:${CONTROLLER_PATCH_DIR}/happy_live_frames.py:ro`,
            ],
        },
    };
}

// Docker's multiplexed exec stream: frames of [stream, 0, 0, 0, size (u32 BE)] + payload.
export function demux(buf) {
    const out = { stdout: [], stderr: [] };
    let i = 0;
    while (i + 8 <= buf.length) {
        const size = buf.readUInt32BE(i + 4);
        const end = Math.min(buf.length, i + 8 + size);
        (buf[i] === 2 ? out.stderr : out.stdout).push(buf.subarray(i + 8, end));
        i = end;
    }
    return { stdout: Buffer.concat(out.stdout), stderr: Buffer.concat(out.stderr) };
}

// A minimal Engine API client over the unix socket.
export function createEngine(socketPath, { timeoutMs = 60000 } = {}) {
    // An exec's output, raw, up to maxBytes (the call fails past that).
    const stream = (path, body, { maxBytes, timeout }) => new Promise((resolve, reject) => {
        const data = Buffer.from(JSON.stringify(body));
        const req = httpRequest({ socketPath, method: 'POST', path: `/v1.43${path}`, timeout, headers: { 'Content-Type': 'application/json', 'Content-Length': data.length } }, (res) => {
            const chunks = [];
            let n = 0;
            res.on('data', (c) => {
                n += c.length;
                if (n > maxBytes) { req.destroy(new Error('exec output too large')); return; }
                chunks.push(c);
            });
            res.on('end', () => {
                if (res.statusCode >= 400) reject(new Error(`engine exec start -> ${res.statusCode}`));
                else resolve(Buffer.concat(chunks));
            });
            res.on('error', reject);
        });
        req.on('timeout', () => req.destroy(new Error('engine exec timed out')));
        req.on('error', reject);
        req.end(data);
    });
    const call = (method, path, body) => new Promise((resolve, reject) => {
        const data = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
        const req = httpRequest({ socketPath, method, path: `/v1.43${path}`, timeout: timeoutMs, headers: data ? { 'Content-Type': 'application/json', 'Content-Length': data.length } : {} }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => {
                const text = Buffer.concat(chunks).toString('utf8');
                let json = null;
                try { json = text ? JSON.parse(text) : null; } catch { json = null; }
                if (res.statusCode >= 400) {
                    const err = new Error(`engine ${method} ${path.split('?')[0]} -> ${res.statusCode}: ${(json && json.message) || text.slice(0, 200)}`);
                    err.status = res.statusCode;
                    reject(err);
                } else resolve(json);
            });
        });
        req.on('timeout', () => req.destroy(new Error(`engine ${method} timed out`)));
        req.on('error', reject);
        if (data) req.write(data);
        req.end();
    });
    return {
        list: (project) => call('GET', `/containers/json?all=1&filters=${encodeURIComponent(JSON.stringify({ label: ['happy-browser.pod=1', `happy-browser.project=${project}`] }))}`),
        create: (name, spec) => call('POST', `/containers/create?name=${encodeURIComponent(name)}`, spec),
        start: (id) => call('POST', `/containers/${encodeURIComponent(id)}/start`),
        remove: (id) => call('DELETE', `/containers/${encodeURIComponent(id)}?force=true&v=true`).catch((e) => { if (e.status !== 404) throw e; }),
        image: (ref) => call('GET', `/images/${encodeURIComponent(ref)}/json`),
        // Runs cmd in a running container and returns { exitCode, stdout, stderr } (Buffers).
        async exec(id, { cmd, user, env = [] }, { maxBytes = SCREEN_MAX_BYTES + 65536, timeout = 20000 } = {}) {
            const ex = await call('POST', `/containers/${encodeURIComponent(id)}/exec`, { AttachStdin: false, AttachStdout: true, AttachStderr: true, Tty: false, User: user, Env: env, Cmd: cmd });
            const raw = await stream(`/exec/${encodeURIComponent(ex.Id)}/start`, { Detach: false, Tty: false }, { maxBytes, timeout });
            const info = await call('GET', `/exec/${encodeURIComponent(ex.Id)}/json`);
            return { exitCode: info.ExitCode, ...demux(raw) };
        },
    };
}

export function readSecrets(dir) {
    const f = (n) => readFileSync(join(dir, n), 'utf8').trim();
    return { apiToken: f('api-token'), authStateKey: f('auth-state-key'), shareTokenSecret: f('share-token-secret') };
}

// A PNG's size, from its IHDR; null if buf is not a PNG.
export function pngSize(buf) {
    if (buf.length < 24 || buf.readUInt32BE(0) !== 0x89504e47 || buf.toString('latin1', 12, 16) !== 'IHDR') return null;
    return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

export function createLauncher(cfg, { engine, images, seccomp, secrets, captureScript = '', log = console } = {}) {
    const locks = new Map();
    const serial = (slot, fn) => {
        const prev = locks.get(slot) || Promise.resolve();
        const next = prev.catch(() => {}).then(fn);
        locks.set(slot, next.finally(() => { if (locks.get(slot) === next) locks.delete(slot); }));
        return next;
    };
    // Locks on a chat's saved login (data/chats/<hash>/auth), separate from the slot locks: a
    // stash or adopt takes its slot's lock and then its chat's, and copy_auth takes only chat
    // locks (both, in sorted order), so no two callers ever wait on each other in a cycle.
    const chatLock = (hash, fn) => serial(`chat:${hash}`, fn);
    const containersFor = async (slot) => (await engine.list(cfg.project)).filter((c) => c.Labels?.['happy-browser.slot'] === String(slot));

    const wipe = (slot) => {
        const dir = slotDir(cfg, slot);
        if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
    };
    const freshDir = (slot) => {
        wipe(slot);
        const dir = slotDir(cfg, slot);
        mkdirSync(cfg.podsDir, { recursive: true });
        // As browser-init.sh does for the shared stack: the node (its own uid) writes browser-profile
        // and downloads through their group, the controller (the owner, as the whole slot) reads the
        // endpoint file there, and the launcher can still wipe both; the rest stays 700.
        for (const [d, mode, gid] of [['', 0o700, cfg.dataGid], ['browser-profile', 0o775, cfg.nodeGid], ['downloads', 0o775, cfg.nodeGid], ['auth', 0o700, cfg.dataGid]]) {
            mkdirSync(join(dir, d), { recursive: true });
            chownSync(join(dir, d), cfg.dataUid, gid);
            chmodSync(join(dir, d), mode);
        }
        return dir;
    };
    const removeAll = async (cs) => { await Promise.all(cs.map((c) => engine.remove(c.Id))); };

    const ops = {
        async ensure({ slot, pod_id: podId, vnc_password: vncPassword }) {
            return serial(slot, async () => {
                const t0 = Date.now();
                const cs = await containersFor(slot);
                const mine = cs.filter((c) => c.Labels['happy-browser.pod_id'] === podId);
                if (mine.length === 2 && mine.every((c) => c.State === 'running') && cs.length === 2) {
                    return { slot, pod_id: podId, ports: ports(cfg, slot), existing: true };
                }
                await removeAll(cs);
                freshDir(slot);
                const n = names(cfg, slot);
                const [node, ctl] = await Promise.all([
                    engine.create(n.node, nodeSpec(cfg, { slot, podId, vncPassword, image: images.node, seccomp })),
                    engine.create(n.controller, controllerSpec(cfg, { slot, podId, image: images.controller, secrets })),
                ]);
                const created = Date.now() - t0;
                await Promise.all([engine.start(node.Id), engine.start(ctl.Id)]);
                return { slot, pod_id: podId, ports: ports(cfg, slot), existing: false, timings: { created_ms: created, started_ms: Date.now() - t0 } };
            });
        },
        async stop({ slot }) {
            return serial(slot, async () => {
                await removeAll(await containersFor(slot));
                wipe(slot);
                return { slot };
            });
        },
        async list() {
            const cs = await engine.list(cfg.project);
            const pods = new Map();
            for (const c of cs) {
                const slot = Number(c.Labels['happy-browser.slot']);
                const key = `${slot}:${c.Labels['happy-browser.pod_id']}`;
                const pod = pods.get(key) || { slot, pod_id: c.Labels['happy-browser.pod_id'], containers: {} };
                pod.containers[c.Labels['happy-browser.role']] = { state: c.State, status: c.Status, created: c.Created };
                pods.set(key, pod);
            }
            const out = [];
            for (const pod of pods.values()) {
                // A pod whose slot directory is gone has nothing left to serve; remove it.
                if (!Number.isInteger(pod.slot) || pod.slot >= cfg.maxPods || !existsSync(slotDir(cfg, pod.slot))) {
                    await serial(pod.slot, async () => removeAll(cs.filter((c) => c.Labels['happy-browser.pod_id'] === pod.pod_id)));
                    log.warn(`launcher: removed pod ${pod.pod_id.slice(0, 8)} in slot ${pod.slot} (no slot directory)`);
                    continue;
                }
                out.push({ ...pod, ports: ports(cfg, pod.slot) });
            }
            return { max_pods: cfg.maxPods, pods: out.sort((a, b) => a.slot - b.slot) };
        },
        async adopt_auth({ slot, chat_hash: chatHash }) {
            return serial(slot, () => chatLock(chatHash, async () => {
                const from = join(cfg.chatsDir, chatHash, 'auth', 'profiles');
                const to = join(slotDir(cfg, slot), 'auth', 'profiles');
                if (!existsSync(slotDir(cfg, slot))) throw new Error('slot is not running');
                if (!existsSync(from)) return { adopted: false };
                if (existsSync(to)) rmSync(to, { recursive: true, force: true });
                // Copied, not moved: the chat's saved login stays put until a newer one replaces it,
                // so a pod that crashes before its first stash loses nothing.
                cpSync(from, to, { recursive: true, preserveTimestamps: true });
                chownTree(to, cfg.dataUid, cfg.dataGid);
                return { adopted: true };
            }));
        },
        async stash_auth({ slot, chat_hash: chatHash, keep = false }) {
            return serial(slot, () => chatLock(chatHash, async () => {
                const from = join(slotDir(cfg, slot), 'auth', 'profiles');
                if (!existsSync(from) || readdirSync(from).length === 0) return { stashed: false };
                const dir = join(cfg.chatsDir, chatHash, 'auth');
                mkdirSync(dir, { recursive: true, mode: 0o700 });
                chownSync(join(cfg.chatsDir, chatHash), cfg.dataUid, cfg.dataGid);
                chownSync(dir, cfg.dataUid, cfg.dataGid);
                const to = join(dir, 'profiles');
                const tmp = join(dir, `profiles.new-${process.pid}-${Date.now()}`);
                cpSync(from, tmp, { recursive: true, preserveTimestamps: true });
                chownTree(tmp, cfg.dataUid, cfg.dataGid);
                // The previous login is kept one step back (profiles.prev), never just dropped.
                if (existsSync(to)) {
                    const prev = join(dir, 'profiles.prev');
                    if (existsSync(prev)) rmSync(prev, { recursive: true, force: true });
                    renameSync(to, prev);
                }
                renameSync(tmp, to);
                if (!keep) rmSync(from, { recursive: true, force: true });
                return { stashed: true };
            }));
        },
        // A forked chat's first login: a copy of its parent's saved one. It never replaces a
        // login the chat already has, and the parent's files are only read.
        async copy_auth({ from_chat_hash: fromHash, chat_hash: chatHash }) {
            const [a, b] = [fromHash, chatHash].sort();
            return chatLock(a, () => chatLock(b, async () => {
                const from = join(cfg.chatsDir, fromHash, 'auth', 'profiles');
                const dir = join(cfg.chatsDir, chatHash, 'auth');
                const to = join(dir, 'profiles');
                if (existsSync(to)) return { copied: false, reason: 'exists' };
                if (!existsSync(from) || readdirSync(from).length === 0) return { copied: false, reason: 'no_source' };
                mkdirSync(dir, { recursive: true, mode: 0o700 });
                chmodSync(join(cfg.chatsDir, chatHash), 0o700);
                chmodSync(dir, 0o700);
                chownSync(join(cfg.chatsDir, chatHash), cfg.dataUid, cfg.dataGid);
                chownSync(dir, cfg.dataUid, cfg.dataGid);
                const tmp = join(dir, `profiles.new-${process.pid}-${Date.now()}`);
                try {
                    cpSync(from, tmp, { recursive: true, preserveTimestamps: true });
                    chmodSync(tmp, 0o700);
                    chownTree(tmp, cfg.dataUid, cfg.dataGid);
                    renameSync(tmp, to);
                } catch (err) {
                    if (existsSync(tmp)) rmSync(tmp, { recursive: true, force: true });
                    throw err;
                }
                return { copied: true };
            }));
        },
        // The pod's X screen, or one rectangle of it. Not serialized with the slot: it only reads,
        // and a pod that is removed meanwhile just fails the exec.
        async screen({ slot, pod_id: podId, rect }) {
            if (!captureScript) throw new Error('screen capture is not available');
            const node = (await containersFor(slot)).find((c) => c.Labels['happy-browser.pod_id'] === podId && c.Labels['happy-browser.role'] === 'node');
            if (!node || node.State !== 'running') throw new Error('pod is not running');
            const args = rect ? [rect.x, rect.y, rect.width, rect.height].map(String) : [];
            const r = await engine.exec(node.Id, { cmd: ['python3', '-I', '-c', captureScript, ...args], user: String(cfg.nodeUid), env: ['DISPLAY=:99'] });
            if (r.exitCode !== 0) throw new Error(`screen capture failed: ${r.stderr.toString('utf8').trim().split('\n').pop()?.slice(0, 200) || `exit ${r.exitCode}`}`);
            const size = pngSize(r.stdout);
            if (!size) throw new Error('screen capture returned no image');
            if (r.stdout.length > SCREEN_MAX_BYTES) throw new Error('screen capture too large');
            const meta = captureMeta(r.stderr);
            if (!meta || typeof meta.captured_at !== 'string' || !meta.rect) throw new Error('screen capture gave no capture time');
            const want = rect || { x: 0, y: 0, width: cfg.width, height: cfg.height };
            const got = meta.rect;
            if (got.x !== want.x || got.y !== want.y || got.width !== want.width || got.height !== want.height
                || size.width !== want.width || size.height !== want.height) {
                throw new Error('screen capture is not the rectangle asked for');
            }
            return {
                mime: 'image/png',
                ...size,
                data: r.stdout.toString('base64'),
                raw_sha256: createHash('sha256').update(r.stdout).digest('hex'),
                captured_at: meta.captured_at,
                local: typeof meta.local === 'string' ? meta.local : null,
                tz: typeof meta.tz === 'string' ? meta.tz : null,
                screen: meta.screen ?? null,
                capture_rect: want,
                panel_px: Number.isInteger(meta.panel_px) ? meta.panel_px : 0,
            };
        },
    };

    async function handle(req) {
        try {
            validate(cfg, req);
            return { id: req.id ?? null, ok: true, result: await ops[req.op](req) };
        } catch (err) {
            return { id: req?.id ?? null, ok: false, error: String(err?.message || err).split('\n')[0].slice(0, 300) };
        }
    }
    return { handle, ops };
}

function chownTree(path, uid, gid) {
    const st = lstatSync(path);
    if (st.isSymbolicLink()) return;
    chownSync(path, uid, gid);
    if (st.isDirectory()) for (const e of readdirSync(path)) chownTree(join(path, e), uid, gid);
}

export function serve(launcher, socketPath, { gid, log = console } = {}) {
    if (existsSync(socketPath)) {
        if (!statSync(socketPath).isSocket()) throw new Error(`${socketPath} exists and is not a socket`);
        unlinkSync(socketPath);
    }
    const server = createNetServer((conn) => {
        const rl = createInterface({ input: conn });
        rl.on('line', async (line) => {
            if (line.length > 4096) { conn.end(JSON.stringify({ id: null, ok: false, error: 'line too long' }) + '\n'); return; }
            let req;
            try { req = JSON.parse(line); } catch { conn.write(JSON.stringify({ id: null, ok: false, error: 'bad json' }) + '\n'); return; }
            const res = await launcher.handle(req);
            if (!conn.destroyed) conn.write(JSON.stringify(res) + '\n');
        });
        conn.on('error', () => {});
    });
    const oldMask = process.umask(0o177);
    return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(socketPath, () => {
            process.umask(oldMask);
            // Its group is the bridge's way in (the launcher is a member, so no capability is needed).
            if (gid !== undefined) chownSync(socketPath, process.getuid(), gid);
            chmodSync(socketPath, 0o660);
            log.log(`launcher: listening on ${socketPath}`);
            resolve(server);
        });
    });
}

async function main() {
    if (typeof process.getuid === 'function' && process.getuid() === 0) throw new Error('refusing to run as root');
    const cfg = launcherConfig();
    const images = composeImages(readFileSync(join(cfg.browserDir, 'compose.browser.yml'), 'utf8'), process.env);
    // The Engine API takes the profile's content, not a path (as `docker run --security-opt seccomp=FILE` does).
    const seccomp = JSON.stringify(JSON.parse(readFileSync(join(cfg.browserDir, 'seccomp', 'chromium-sandbox.json'), 'utf8')));
    const secrets = readSecrets(cfg.secretsDir);
    const engine = createEngine(cfg.dockerSocket);
    for (const ref of Object.values(images)) {
        await engine.image(ref).catch(() => { throw new Error(`image ${ref.split('@')[0]} is not present; run make browser-pull${ref.startsWith('sha256:') ? ' and make browser-node-chrome' : ''}`); });
    }
    mkdirSync(cfg.podsDir, { recursive: true });
    mkdirSync(cfg.chatsDir, { recursive: true, mode: 0o700 });
    const captureScript = readFileSync(join(cfg.browserDir, 'scripts', 'screen-capture.py'), 'utf8');
    const launcher = createLauncher(cfg, { engine, images, seccomp, secrets, captureScript });
    await serve(launcher, cfg.socketPath, { gid: cfg.socketGid });
    for (const s of ['SIGINT', 'SIGTERM']) process.on(s, () => process.exit(0));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
    main().catch((err) => { console.error(`launcher: ${err.message}`); process.exit(1); });
}
