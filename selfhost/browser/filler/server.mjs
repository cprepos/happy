// The secret filler's HTTP API, on 127.0.0.1:6091 only. Callers (the browser
// bridge) authenticate with a bearer token whose SHA-256 is all the filler
// keeps, and name the chat in X-Happy-Chat. No route returns a secret value.
//
//   POST /v1/list     {}                                 -> {client, secrets:[{name, hosts, kind}]}
//   POST /v1/fill     {session_id, element_id, name, controller_port?} -> {ok, kind, host}
//   POST /v1/login    {session_id, site, controller_port?}             -> {status, host}
//   POST /v1/session  {session_id?, controller_port?}                  -> {tainted, any_tainted, drop_images}
//
// controller_port picks the browser: omitted, the shared stack's controller
// (8010); otherwise a per-chat pod's, from FILLER_CONTROLLER_PORTS.
//   POST /v1/scrub    {payload}                          -> {payload}
//   GET  /healthz                                        -> {ok, unlocked, sync_age_s}
//
//   node server.mjs --check-policy [path]   validate a policy file and exit
import { createServer as createHttpServer } from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { loadConfig, readSecret, readSecretOrNull } from './lib/config.mjs';
import { loadPolicy, PolicyError } from './lib/policy.mjs';
import { createScrubber } from './lib/scrub.mjs';
import { createTaint } from './lib/taint.mjs';
import { createAudit } from './lib/audit.mjs';
import { controllerSet, parsePorts } from './lib/controller.mjs';
import { createVault } from './lib/vault.mjs';
import { createFiller, FillError } from './lib/fill.mjs';

const MAX_BODY = 4 * 1024 * 1024;
const log = (msg) => process.stderr.write(`secret-filler: ${msg}\n`);

/** Reload the policy when its mtime changes; while the file is bad, every call fails closed. */
export function policyLoader(path, { requireRoot = true, logFn = log } = {}) {
    let cur = null; let stamp = null; let error = null;
    return function getPolicy() {
        let st;
        try { st = statSync(path); } catch { cur = null; stamp = null; error = 'policy file missing'; throw new FillError('the filler policy is missing', 503, 'policy'); }
        const s = `${st.mtimeMs}:${st.size}:${st.ino}`;
        if (s !== stamp) {
            stamp = s;
            try { cur = loadPolicy(path, { requireRoot }); error = null; logFn('policy loaded'); } catch (err) {
                cur = null; error = err instanceof PolicyError ? err.message : (err.code || 'unreadable');
                logFn(`policy rejected: ${error}`);
            }
        }
        if (!cur) throw new FillError(`the filler policy is invalid (${error}); fix it with make filler-policy-edit`, 503, 'policy');
        return cur;
    };
}

export function tokenChecker(sha256Hex) {
    const want = sha256Hex ? Buffer.from(sha256Hex.trim().toLowerCase(), 'hex') : null;
    return (header) => {
        if (!want || want.length !== 32) return false;
        const m = /^Bearer ([A-Za-z0-9._~+/=-]{16,512})$/.exec(String(header || ''));
        if (!m) return false;
        const got = createHash('sha256').update(m[1]).digest();
        return timingSafeEqual(got, want);
    };
}

/**
 * The request handler, with every dependency injected (tests build it
 * directly). vault may be null: not enrolled, list/fill/login answer 503.
 */
export function createApp({ checkToken, getPolicy, vault, controllers, scrubber, taint, audit, allowLoopbackHttp = false, sleep, totpOpts }) {
    const filler = vault ? createFiller({ getPolicy, vault, controllers, taint, audit, allowLoopbackHttp, sleep, totpOpts }) : null;

    const send = (res, status, obj) => {
        const body = JSON.stringify(obj);
        res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Content-Length': Buffer.byteLength(body) });
        res.end(body);
    };

    async function readJson(req) {
        const chunks = []; let n = 0;
        for await (const c of req) { n += c.length; if (n > MAX_BODY) throw new FillError('request too large', 413, 'bad_request'); chunks.push(c); }
        if (!n) return {};
        try {
            const v = JSON.parse(Buffer.concat(chunks).toString('utf8'));
            if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error();
            return v;
        } catch { throw new FillError('body must be a JSON object', 400, 'bad_request'); }
    }

    return async function handle(req, res) {
        try {
            const host = String(req.headers.host || '').replace(/:\d+$/, '');
            if (host !== '127.0.0.1' && host !== 'localhost') return send(res, 421, { error: 'misdirected request' });
            const url = new URL(req.url, 'http://127.0.0.1');
            if (req.method === 'GET' && url.pathname === '/healthz') {
                return send(res, 200, { ok: true, unlocked: !!vault, sync_age_s: vault ? vault.status().sync_age_s : null });
            }
            if (!checkToken(req.headers.authorization)) return send(res, 401, { error: 'unauthorized' });
            if (req.method !== 'POST') return send(res, 405, { error: 'method not allowed' });
            const chat = typeof req.headers['x-happy-chat'] === 'string' ? req.headers['x-happy-chat'].trim() : '';
            const body = await readJson(req);
            switch (url.pathname) {
                case '/v1/scrub': {
                    // Every tainted session's values are scrubbed, whichever session the payload came from.
                    const dropImages = taint.anyDropImages();
                    return send(res, 200, { payload: scrubber.size ? scrubber.scrub(body.payload, { dropImages }) : body.payload });
                }
                case '/v1/session': {
                    const sid = typeof body.session_id === 'string' && body.session_id ? body.session_id : null;
                    const c = controllers(body.controller_port ?? null);
                    if (!c) return send(res, 403, { error: 'that browser controller is not one the filler may use' });
                    const s = sid ? taint.get(`${c.port}/${sid}`) : null;
                    return send(res, 200, { tainted: !!s, any_tainted: taint.anyTainted(), drop_images: s ? !!s.drop_images : taint.anyDropImages() });
                }
                case '/v1/list': case '/v1/fill': case '/v1/login': {
                    if (!chat) return send(res, 400, { error: 'X-Happy-Chat is required' });
                    if (!filler) return send(res, 503, { error: 'the filler is not enrolled with the vault (make filler-enroll)' });
                    const fn = url.pathname.slice(4);
                    const out = await filler[fn]({ ...body, chat });
                    return send(res, 200, out);
                }
                default:
                    return send(res, 404, { error: 'not found' });
            }
        } catch (err) {
            if (err instanceof FillError) return send(res, err.status, { error: err.message, outcome: err.outcome });
            log(`internal error: ${err?.name || 'Error'}`);
            return send(res, 500, { error: 'internal error' });
        }
    };
}

function buildVaultFromFiles(cfg) {
    const f = cfg.files;
    const userKeyB64 = readSecretOrNull(f.vaultUserKey);
    const clientId = readSecretOrNull(f.vaultClientId);
    const clientSecret = readSecretOrNull(f.vaultClientSecret);
    const deviceId = readSecretOrNull(f.vaultDeviceId);
    if (!userKeyB64 || !clientId || !clientSecret || !deviceId) return null;
    return createVault({ url: cfg.vaultUrl, clientId, clientSecret, userKey: Buffer.from(userKeyB64, 'base64'), deviceId });
}

async function main(argv) {
    const cfg = loadConfig();
    if (argv[0] === '--check-policy') {
        const path = argv[1] || cfg.policyPath;
        try {
            const p = loadPolicy(path, { requireRoot: !cfg.testLoopback });
            const n = p.clients().reduce((a, c) => a + p.entries(c).length, 0);
            process.stdout.write(`policy ok: ${p.clients().length} client(s), ${n} fillable name(s)\n`);
            return 0;
        } catch (err) {
            process.stderr.write(`policy invalid: ${err.message}\n`);
            return 1;
        }
    }
    const checkToken = tokenChecker(readSecretOrNull(cfg.files.clientTokenSha256));
    const controllers = controllerSet({ defaultPort: cfg.controllerPort, ports: parsePorts(cfg.controllerPorts), token: readSecret(cfg.files.controllerToken) });
    const scrubber = createScrubber();
    const taint = createTaint({ statePath: cfg.statePath, scrubber, controllers, log });
    const audit = createAudit(cfg.auditDir);
    const getPolicy = policyLoader(cfg.policyPath, { requireRoot: !cfg.testLoopback });
    try { getPolicy(); } catch (err) { log(err.message); }
    let vault = null;
    try { vault = buildVaultFromFiles(cfg); } catch (err) { log(`vault not usable: ${err.message}`); }
    if (!vault) log('not enrolled: list, fill and login answer 503 until make filler-enroll');
    const handle = createApp({ checkToken, getPolicy, vault, controllers, scrubber, taint, audit, allowLoopbackHttp: cfg.testLoopback });
    const server = createHttpServer(handle);
    server.requestTimeout = 120_000;
    await new Promise((r, j) => { server.once('error', j); server.listen(cfg.port, cfg.host, r); });
    log(`listening on ${cfg.host}:${server.address().port}${cfg.testLoopback ? ' (TEST: loopback http fills allowed)' : ''}`);
    const sweep = setInterval(() => { taint.sweep().catch(() => {}); }, 30_000);
    const stop = () => { clearInterval(sweep); vault?.lock(); server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 3000).unref(); };
    process.on('SIGTERM', stop); process.on('SIGINT', stop);
    return null;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
    main(process.argv.slice(2)).then((code) => { if (code !== null) process.exit(code); }, (err) => { log(`fatal: ${err.message}`); process.exit(1); });
}
