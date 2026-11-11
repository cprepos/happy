#!/usr/bin/env node
// The Docker socket proxy: the pod launcher's only way to the Docker daemon.
//
// It listens on a unix socket (PROXY_LISTEN, 0660, its own group, which only the launcher is
// given) in a directory only the launcher mounts, and forwards to the daemon's socket
// (PROXY_UPSTREAM) exactly the Engine API calls the launcher makes, each checked first:
//
//   GET    /containers/json        only with the label filters happy-browser.pod=1 and this project
//   POST   /containers/create      only <project>-pod-<slot>-(node|controller), with a body built
//                                  from the launcher's templates: a pinned image, host network, a
//                                  non-root user per role, every capability dropped and none added,
//                                  no-new-privileges, a read-only root, binds only of that slot's
//                                  directory and of the repo (read-only), and the pod labels
//   POST   /containers/{id}/start  only a pod container of this project
//   DELETE /containers/{id}        the same
//   POST   /containers/{id}/exec   only python3, as the browser node's user, in a pod's node
//   POST   /exec/{id}/start        only an exec this proxy created (output streamed back)
//   GET    /exec/{id}/json         the same
//   GET    /images/{ref}/json      only the pinned images
//
// Everything else (any other path or method, a body field it does not know, a name, mount, user
// or option outside the above) is refused with 403 before the daemon sees it. Bodies are never
// logged. A container named by id or name is resolved to its id through the daemon first, and
// the call is forwarded with that id, so a name cannot change between the check and the call.
import { createServer, request as httpRequest } from 'node:http';
import { chmodSync, existsSync, statSync, unlinkSync } from 'node:fs';
import { normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

export const MAX_BODY = 1024 * 1024;
const VERSION_RE = /^\/v1\.\d{1,3}(?=\/)/;
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;

export function proxyConfig(env = process.env) {
    const list = (k) => (env[k] || '').split(',').map((s) => s.trim()).filter(Boolean);
    const uid = (k, d) => {
        const v = env[k] === undefined || env[k] === '' ? d : Number(env[k]);
        if (!Number.isInteger(v) || v <= 0 || v > 65535) throw new Error(`${k} must be a uid in 1..65535 (never root)`);
        return v;
    };
    const cfg = {
        listen: env.PROXY_LISTEN || '/proxy/docker.sock',
        upstream: env.PROXY_UPSTREAM || '/var/run/docker.sock',
        project: env.PROXY_PROJECT || 'happy-browser',
        // compose.browser.yml passes its two pinned image anchors here, so a pod runs what the stack runs.
        images: [...list('PROXY_IMAGES'), env.PROXY_NODE_IMAGE, env.PROXY_CONTROLLER_IMAGE].filter(Boolean),
        podsDir: env.PROXY_PODS_DIR || '',
        roDir: env.PROXY_RO_DIR || '',
        nodeUser: `${uid('PROXY_NODE_UID', 1994)}:${uid('PROXY_NODE_GID', 1994)}`,
        controllerUser: `${uid('PROXY_CONTROLLER_UID', 1993)}:${uid('PROXY_CONTROLLER_GID', 1993)}`,
        execUser: String(uid('PROXY_NODE_UID', 1994)),
    };
    if (!/^[a-z0-9][a-z0-9_-]*$/.test(cfg.project)) throw new Error('PROXY_PROJECT must be a compose project name');
    if (!cfg.images.length || !cfg.images.every((i) => /@sha256:[0-9a-f]{64}$/.test(i))) throw new Error('PROXY_IMAGES must list pinned images');
    for (const k of ['podsDir', 'roDir']) {
        if (!cfg[k].startsWith('/') || normalize(cfg[k]) !== cfg[k] || cfg[k] === '/') throw new Error(`PROXY_${k === 'podsDir' ? 'PODS' : 'RO'}_DIR must be an absolute, normal path`);
    }
    cfg.nameRe = new RegExp(`^${cfg.project}-pod-(\\d{1,2})-(node|controller)$`);
    return cfg;
}

class Denied extends Error {}
const deny = (why) => { throw new Denied(why); };
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const onlyKeys = (o, keys, what) => { for (const k of Object.keys(o)) if (!keys.includes(k)) deny(`${what}.${k} is not allowed`); };
const strList = (v, what) => { if (!Array.isArray(v) || !v.every((s) => typeof s === 'string')) deny(`${what} must be a list of strings`); return v; };

// The body of POST /containers/create?name=<name>: the launcher's nodeSpec or controllerSpec only.
export function checkCreate(cfg, name, body) {
    const m = typeof name === 'string' ? name.match(cfg.nameRe) : null;
    if (!m) deny('container name');
    const [slot, role] = [m[1], m[2]];
    if (!isObj(body)) deny('body');
    onlyKeys(body, ['Image', 'Entrypoint', 'Cmd', 'Env', 'Labels', 'User', 'HostConfig'], 'create');
    if (!cfg.images.includes(body.Image)) deny('image is not one of the pinned images');
    if (body.Entrypoint !== undefined) strList(body.Entrypoint, 'Entrypoint');
    if (body.Cmd !== undefined) strList(body.Cmd, 'Cmd');
    if (body.Env !== undefined) strList(body.Env, 'Env');
    const want = role === 'node' ? cfg.nodeUser : cfg.controllerUser;
    if (body.User !== want) deny(`User must be ${want} for a ${role}`);
    const L = body.Labels;
    if (!isObj(L) || L['happy-browser.pod'] !== '1' || L['happy-browser.project'] !== cfg.project
        || L['happy-browser.slot'] !== slot || L['happy-browser.role'] !== role) deny('pod labels');
    const h = body.HostConfig;
    if (!isObj(h)) deny('HostConfig');
    onlyKeys(h, ['NetworkMode', 'ShmSize', 'CapDrop', 'CapAdd', 'SecurityOpt', 'PidsLimit', 'Memory', 'MemorySwap', 'NanoCpus',
        'Init', 'RestartPolicy', 'Binds', 'ReadonlyRootfs', 'Tmpfs'], 'HostConfig');
    if (h.NetworkMode !== 'host') deny('NetworkMode');
    if (!strList(h.CapDrop ?? [], 'CapDrop').includes('ALL')) deny('CapDrop must include ALL');
    if (h.CapAdd !== undefined && strList(h.CapAdd, 'CapAdd').length) deny('CapAdd');
    const so = strList(h.SecurityOpt ?? [], 'SecurityOpt');
    if (!so.includes('no-new-privileges:true')) deny('no-new-privileges');
    for (const s of so) {
        if (s === 'no-new-privileges:true') continue;
        if (!s.startsWith('seccomp=') || s === 'seccomp=unconfined') deny('SecurityOpt');
        try { if (!isObj(JSON.parse(s.slice(8)))) deny('seccomp'); } catch (e) { if (e instanceof Denied) throw e; deny('seccomp must be a profile'); }
    }
    if (h.ReadonlyRootfs !== true) deny('ReadonlyRootfs');
    if (!isObj(h.RestartPolicy) || h.RestartPolicy.Name !== 'no' || Object.keys(h.RestartPolicy).length !== 1) deny('RestartPolicy');
    for (const k of ['ShmSize', 'PidsLimit', 'Memory', 'MemorySwap', 'NanoCpus']) {
        if (h[k] !== undefined && !(Number.isInteger(h[k]) && h[k] > 0)) deny(k);
    }
    if (h.Init !== undefined && typeof h.Init !== 'boolean') deny('Init');
    if (h.Tmpfs !== undefined) {
        if (!isObj(h.Tmpfs)) deny('Tmpfs');
        for (const [p, o] of Object.entries(h.Tmpfs)) if (p !== '/tmp' || typeof o !== 'string') deny('Tmpfs');
    }
    const slotDir = `${cfg.podsDir}/slot-${slot}`;
    for (const b of strList(h.Binds ?? [], 'Binds')) {
        const parts = b.split(':');
        if (parts.length < 2 || parts.length > 3) deny('bind');
        const [src, dst, opt = ''] = parts;
        if (!src.startsWith('/') || normalize(src) !== src || !dst.startsWith('/') || normalize(dst) !== dst) deny('bind path');
        if (dst === '/' || /docker\.sock/.test(src + dst)) deny('bind target');
        const opts = opt ? opt.split(',') : [];
        if (!opts.every((o) => ['ro', 'rw'].includes(o))) deny('bind options');
        if (src === slotDir || src.startsWith(`${slotDir}/`)) continue;
        if (src.startsWith(`${cfg.roDir}/`) && opts.includes('ro')) continue;
        deny('bind source');
    }
}

// POST /containers/{id}/exec, once the container is known to be a pod node.
export function checkExec(cfg, body) {
    if (!isObj(body)) deny('body');
    onlyKeys(body, ['AttachStdin', 'AttachStdout', 'AttachStderr', 'Tty', 'User', 'Env', 'Cmd'], 'exec');
    if (body.User !== cfg.execUser) deny(`exec User must be ${cfg.execUser}`);
    const cmd = strList(body.Cmd, 'Cmd');
    if (cmd[0] !== 'python3') deny('exec Cmd');
    if (body.Env !== undefined) strList(body.Env, 'Env');
    if (body.AttachStdin) deny('AttachStdin');
}

// GET /containers/json?filters=...: the launcher's own label filter, nothing wider.
export function checkList(cfg, query) {
    let f;
    try { f = JSON.parse(query.get('filters') || 'null'); } catch { deny('filters'); }
    const labels = isObj(f) && Array.isArray(f.label) ? f.label : [];
    if (!labels.includes('happy-browser.pod=1') || !labels.includes(`happy-browser.project=${cfg.project}`)) deny('list needs the pod label filters');
}

// A container the daemon knows, as a pod container of this project: its id and role.
export function podOf(cfg, info) {
    const name = String(info?.Name || '').replace(/^\//, '');
    const m = name.match(cfg.nameRe);
    const L = info?.Config?.Labels || {};
    if (!m || L['happy-browser.pod'] !== '1' || L['happy-browser.project'] !== cfg.project || L['happy-browser.role'] !== m[2]) deny('not a pod container');
    if (typeof info.Id !== 'string' || !/^[0-9a-f]{64}$/.test(info.Id)) deny('container id');
    return { id: info.Id, role: m[2] };
}

// The route of a request: { kind, ... } or a Denied error.
export function route(method, rawUrl) {
    let url;
    try { url = new URL(rawUrl, 'http://docker'); } catch { deny('url'); }
    if (/%2f|%2e|\.\./i.test(url.pathname.replace(/^\/v1\.\d+\/images\/[^/]+\/json$/, '')) || url.pathname.includes('//')) deny('path');
    const version = (url.pathname.match(VERSION_RE) || [''])[0];
    const path = url.pathname.slice(version.length);
    const q = url.searchParams;
    let m;
    if (method === 'GET' && path === '/containers/json') return { kind: 'list', version, q };
    if (method === 'POST' && path === '/containers/create') return { kind: 'create', version, q };
    if (method === 'POST' && (m = path.match(/^\/containers\/([^/]+)\/start$/))) return { kind: 'start', version, ref: m[1], q };
    if (method === 'DELETE' && (m = path.match(/^\/containers\/([^/]+)$/))) return { kind: 'remove', version, ref: m[1], q };
    if (method === 'POST' && (m = path.match(/^\/containers\/([^/]+)\/exec$/))) return { kind: 'exec', version, ref: m[1], q };
    if (method === 'POST' && (m = path.match(/^\/exec\/([^/]+)\/start$/))) return { kind: 'exec_start', version, ref: m[1], q };
    if (method === 'GET' && (m = path.match(/^\/exec\/([^/]+)\/json$/))) return { kind: 'exec_json', version, ref: m[1], q };
    if (method === 'GET' && (m = path.match(/^\/images\/([^/]+)\/json$/))) return { kind: 'image', version, ref: decodeURIComponent(m[1]), q };
    deny(`${method} ${path.replace(/[0-9a-f]{12,}/g, '<id>')}`);
}

export function createProxy(cfg, { log = console } = {}) {
    const execs = new Map(); // exec id -> expiry (ms)
    const EXEC_TTL = 5 * 60_000;
    const upstream = (method, path, body, headers = {}) => httpRequest({ socketPath: cfg.upstream, method, path, headers: { ...headers, Host: 'docker' } });
    const call = (method, path) => new Promise((resolve, reject) => {
        const req = upstream(method, path);
        req.on('response', (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => {
                let json = null;
                try { json = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { json = null; }
                resolve({ status: res.statusCode, json });
            });
            res.on('error', reject);
        });
        req.on('error', reject);
        req.end();
    });
    const inspectPod = async (version, ref) => {
        if (!ID_RE.test(ref)) deny('container ref');
        const r = await call('GET', `${version}/containers/${encodeURIComponent(ref)}/json`);
        if (r.status === 404) return null;
        if (r.status !== 200) throw new Error(`inspect -> ${r.status}`);
        return podOf(cfg, r.json);
    };
    const readBody = (req) => new Promise((resolve, reject) => {
        const chunks = [];
        let n = 0;
        req.on('data', (c) => {
            n += c.length;
            if (n > MAX_BODY) { reject(new Denied('body too large')); req.destroy(); return; }
            chunks.push(c);
        });
        req.on('end', () => resolve(Buffer.concat(chunks)));
        req.on('error', reject);
    });
    const parse = (buf) => { if (!buf.length) return undefined; try { return JSON.parse(buf.toString('utf8')); } catch { deny('body is not JSON'); } };
    const send = (res, status, obj) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
    const sweep = () => { const now = Date.now(); for (const [id, t] of execs) if (t < now) execs.delete(id); };

    // Forwards with the body (already read and checked); the reply is streamed back unchanged.
    const forward = (res, method, path, buf, { onJson } = {}) => new Promise((resolve) => {
        const headers = buf && buf.length ? { 'Content-Type': 'application/json', 'Content-Length': buf.length } : {};
        const up = upstream(method, path, buf, headers);
        up.on('response', (ur) => {
            const h = {};
            for (const k of ['content-type', 'content-length', 'api-version', 'docker-experimental', 'ostype']) if (ur.headers[k] !== undefined) h[k] = ur.headers[k];
            if (onJson && ur.statusCode < 300) {
                const chunks = [];
                ur.on('data', (c) => chunks.push(c));
                ur.on('end', () => {
                    const raw = Buffer.concat(chunks);
                    try { onJson(JSON.parse(raw.toString('utf8'))); } catch { /* the caller sees the reply as is */ }
                    res.writeHead(ur.statusCode, h); res.end(raw); resolve();
                });
                return;
            }
            res.writeHead(ur.statusCode, h);
            ur.pipe(res);
            ur.on('end', resolve);
            ur.on('error', () => { res.destroy(); resolve(); });
        });
        up.on('error', (err) => { if (!res.headersSent) send(res, 502, { message: `docker-proxy: upstream: ${err.code || err.message}` }); else res.destroy(); resolve(); });
        res.on('close', () => up.destroy());
        up.end(buf && buf.length ? buf : undefined);
    });

    async function handle(req, res) {
        let r;
        try {
            r = route(req.method, req.url);
            const buf = await readBody(req);
            const body = parse(buf);
            const v = r.version;
            sweep();
            switch (r.kind) {
                case 'list':
                    checkList(cfg, r.q);
                    return await forward(res, 'GET', `${v}/containers/json?all=1&filters=${encodeURIComponent(r.q.get('filters'))}`);
                case 'image':
                    if (!cfg.images.includes(r.ref)) deny('image is not one of the pinned images');
                    return await forward(res, 'GET', `${v}/images/${encodeURIComponent(r.ref)}/json`);
                case 'create': {
                    const name = r.q.get('name');
                    checkCreate(cfg, name, body);
                    log.log(`docker-proxy: create ${name}`);
                    return await forward(res, 'POST', `${v}/containers/create?name=${encodeURIComponent(name)}`, buf);
                }
                case 'start': case 'remove': {
                    const pod = await inspectPod(v, r.ref);
                    if (!pod) return send(res, 404, { message: 'No such container' });
                    log.log(`docker-proxy: ${r.kind} ${pod.id.slice(0, 12)}`);
                    return r.kind === 'start'
                        ? await forward(res, 'POST', `${v}/containers/${pod.id}/start`)
                        : await forward(res, 'DELETE', `${v}/containers/${pod.id}?force=true&v=true`);
                }
                case 'exec': {
                    const pod = await inspectPod(v, r.ref);
                    if (!pod) return send(res, 404, { message: 'No such container' });
                    if (pod.role !== 'node') deny('exec only in a pod node');
                    checkExec(cfg, body);
                    return await forward(res, 'POST', `${v}/containers/${pod.id}/exec`, buf, {
                        onJson: (j) => { if (typeof j?.Id === 'string' && /^[0-9a-f]{64}$/.test(j.Id)) execs.set(j.Id, Date.now() + EXEC_TTL); },
                    });
                }
                case 'exec_start': case 'exec_json': {
                    if (!execs.has(r.ref)) deny('exec is not one this proxy created');
                    if (r.kind === 'exec_json') return await forward(res, 'GET', `${v}/exec/${r.ref}/json`);
                    if (!isObj(body) || body.Detach !== false || body.Tty !== false || Object.keys(body).length !== 2) deny('exec start body');
                    return await forward(res, 'POST', `${v}/exec/${r.ref}/start`, Buffer.from(JSON.stringify({ Detach: false, Tty: false })));
                }
                default: deny('route');
            }
        } catch (err) {
            if (err instanceof Denied) {
                log.warn(`docker-proxy: denied ${req.method} ${(r?.kind) || '?'}: ${err.message}`);
                if (!res.headersSent) send(res, 403, { message: `docker-proxy: denied: ${err.message}` });
            } else {
                log.warn(`docker-proxy: ${req.method} ${(r?.kind) || '?'} failed: ${err.message}`);
                if (!res.headersSent) send(res, 502, { message: 'docker-proxy: upstream error' });
            }
        }
    }
    return { handle };
}

export function serve(proxy, path, { log = console } = {}) {
    if (existsSync(path)) {
        if (!statSync(path).isSocket()) throw new Error(`${path} exists and is not a socket`);
        unlinkSync(path);
    }
    const server = createServer((req, res) => { proxy.handle(req, res); });
    const oldMask = process.umask(0o117);
    return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(path, () => {
            process.umask(oldMask);
            chmodSync(path, 0o660);
            log.log(`docker-proxy: listening on ${path}`);
            resolve(server);
        });
    });
}

async function main() {
    if (typeof process.getuid === 'function' && process.getuid() === 0) throw new Error('refusing to run as root');
    const cfg = proxyConfig();
    const server = await serve(createProxy(cfg), cfg.listen);
    for (const s of ['SIGINT', 'SIGTERM']) process.on(s, () => { server.close(); process.exit(0); });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
    main().catch((err) => { console.error(`docker-proxy: ${err.message}`); process.exit(1); });
}
