// The secret filler's HTTP API, on 127.0.0.1:6091 only. Callers (the browser
// bridge) authenticate with a bearer token whose SHA-256 is all the filler
// keeps, and name the chat in X-Client-Chat (or the older X-Happy-Chat; a caller with no chat id sends
// "none", which only the policy's default_client serves). No route returns a
// secret value.
//
//   POST /v1/list     {}                                 -> {client, secrets:[{name, hosts, kind}]}
//   POST /v1/fill     {session_id, element_id, name, controller_port?} -> {ok, kind, host}
//   POST /v1/login    {session_id, site, controller_port?}             -> {status, host}
//   POST /v1/session  {session_id?, controller_port?}                  -> {tainted, any_tainted, drop_images}
//
// controller_port picks the browser: omitted, the shared stack's controller
// (8010); otherwise a per-chat pod's, from FILLER_CONTROLLER_PORTS.
//   POST /v1/scrub    {payload}                          -> {payload}
//   GET  /healthz                                        -> {ok, unlocked, sync_age_s, backends}
//
// The policy's backends each get their own provider, built on first use
// (createVaults); a chat reaches only its client's backend. /healthz's
// unlocked and sync_age_s are the shared backend's (the default client's
// backend when the policy has one), and backends has {name: {type, unlocked,
// sync_age_s}} for every backend, so one that fails to start shows there
// without taking the others down.
//
// The vault tools (browser-stack/vault-mcp) use their own token, the
// vault-client-token, whose SHA-256 is secrets/vault-client-token.sha256. It
// reaches only these routes, and the bridge's token never does
// (lib/manage.mjs has the bodies):
//
//   POST /v1/vault/{list,search,create,update,remove,restore,compare,pipe}
//
// Every route answers metadata only, except /v1/vault/pipe, which hands one
// value to vault-mcp's pipe runner for an allowlisted command's stdin.
//
//   node server.mjs --check-policy [path]   validate a policy file and exit
import { createServer as createHttpServer } from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { realpathSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, readSecret, readSecretOrNull } from './lib/config.mjs';
import { loadPolicy, PolicyError, BACKEND_NAME, DEFAULT_BACKEND } from './lib/policy.mjs';
import { createScrubber } from './lib/scrub.mjs';
import { createTaint } from './lib/taint.mjs';
import { createAudit } from './lib/audit.mjs';
import { controllerSet, parsePorts } from './lib/controller.mjs';
import { create as createProvider } from './lib/providers/builtin.mjs';
import { createFiller, FillError, backendVaults } from './lib/fill.mjs';
import { createManager, ACTIONS } from './lib/manage.mjs';

const MAX_BODY = 32 * 1024 * 1024;
const log = (msg) => process.stderr.write(`secret-filler: ${msg}\n`);

/** Reload the policy when its mtime changes; while the file is bad, every call fails closed. */
export function policyLoader(path, { requireOwner = true, logFn = log } = {}) {
    let cur = null; let stamp = null; let error = null;
    return function getPolicy() {
        let st;
        try { st = statSync(path); } catch { cur = null; stamp = null; error = 'policy file missing'; throw new FillError('the filler policy is missing', 503, 'policy'); }
        const s = `${st.mtimeMs}:${st.size}:${st.ino}`;
        if (s !== stamp) {
            stamp = s;
            try { cur = loadPolicy(path, { requireOwner }); error = null; logFn('policy loaded'); } catch (err) {
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
 * One provider per policy backend, built on first use by build(name, config)
 * (a provider, or null when that backend is not enrolled) and rebuilt when
 * the backend's config in the policy changes (the old one is locked). A
 * backend that fails to build is retried on its next use and never affects
 * another. get(name) -> provider or null; status() -> {name: {type, unlocked,
 * sync_age_s}} for the current policy's backends.
 */
export function createVaults({ getPolicy, build, logFn = log }) {
    const cache = new Map(); // name -> {key, provider, error}
    function get(name) {
        const cfg = getPolicy().backend(name);
        if (!cfg) return null;
        const key = JSON.stringify(cfg);
        const hit = cache.get(name);
        if (hit && hit.key === key && hit.provider) return hit.provider;
        if (hit?.provider) { try { hit.provider.lock(); } catch {} }
        let provider = null; let error = null;
        try { provider = build(name, cfg) || null; if (!provider) error = 'not enrolled'; } catch (err) { error = err?.message || 'failed'; }
        if (error && hit?.error !== error) logFn(`backend ${name}: ${error === 'not enrolled' ? 'not enrolled (make vault-enroll)' : `not usable: ${error}`}`);
        cache.set(name, { key, provider, error });
        return provider;
    }
    function status() {
        let policy;
        try { policy = getPolicy(); } catch { return {}; }
        const out = {};
        for (const name of policy.backends()) {
            const p = get(name);
            const st = p ? p.status() : null;
            out[name] = { type: policy.backend(name).type, unlocked: !!p, sync_age_s: st ? st.sync_age_s : null };
        }
        return out;
    }
    const lock = () => { for (const { provider } of cache.values()) { try { provider?.lock(); } catch {} } };
    return { get, status, lock };
}

/**
 * The request handler, with every dependency injected (tests build it
 * directly). vaults is createVaults(...) (one provider per policy backend);
 * vault, a lone provider (lib/providers/index.mjs) or null, is the older form:
 * it serves the shared backend only. A chat whose backend has no provider (not
 * enrolled) gets 503 from list/fill/login and the vault routes.
 */
export function createApp({ checkToken, checkVaultToken = () => false, getPolicy, vault = null, vaults = null, controllers, scrubber, taint, audit, allowLoopbackHttp = false, sleep, totpOpts, now }) {
    const getVault = vaults ? vaults.get : (name) => (name === DEFAULT_BACKEND ? vault : null);
    const vaultOf = backendVaults({ vaults: getVault });
    const filler = createFiller({ getPolicy, vaults: getVault, controllers, taint, audit, allowLoopbackHttp, sleep, totpOpts });
    const manager = createManager({ getPolicy, vaults: getVault, audit, ...(now ? { now } : {}) });
    // Before a vault or fill route reads its body: 503 when the chat's backend has no provider.
    const needVault = (chat) => {
        const policy = getPolicy();
        const sc = policy.scopeOf(chat);
        if (sc) vaultOf(policy.backendOf(sc.client));
    };
    function health() {
        const backends = vaults ? vaults.status() : { [DEFAULT_BACKEND]: { type: vault?.type ?? 'vaultwarden', unlocked: !!vault, sync_age_s: vault ? vault.status().sync_age_s : null } };
        let main = DEFAULT_BACKEND;
        try { const p = getPolicy(); const d = p.defaultClient(); if (d) main = p.backendOf(d); } catch {}
        const m = backends[main];
        return { ok: true, unlocked: !!m?.unlocked, sync_age_s: m ? m.sync_age_s : null, backends };
    }

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
                return send(res, 200, health());
            }
            // Two tokens, two route sets: the vault token only for /v1/vault/*, the bridge's for the rest.
            const vaultRoute = url.pathname.startsWith('/v1/vault/');
            if (!(vaultRoute ? checkVaultToken : checkToken)(req.headers.authorization)) return send(res, 401, { error: 'unauthorized' });
            if (req.method !== 'POST') return send(res, 405, { error: 'method not allowed' });
            // X-Client-Chat, or the older X-Happy-Chat. Both, and not the same: refused.
            const hdr = (n) => (typeof req.headers[n] === 'string' ? req.headers[n].trim() : '');
            const newChat = hdr('x-client-chat');
            const oldChat = hdr('x-happy-chat');
            if (newChat && oldChat && newChat !== oldChat) return send(res, 400, { error: 'X-Client-Chat and X-Happy-Chat differ' });
            const chat = newChat || oldChat;
            const body = await readJson(req);
            if (vaultRoute) {
                const fn = url.pathname.slice('/v1/vault/'.length);
                if (!ACTIONS.includes(fn)) return send(res, 404, { error: 'not found' });
                if (!chat) return send(res, 400, { error: 'X-Client-Chat is required' });
                needVault(chat);
                return send(res, 200, await manager[fn]({ ...body, chat }));
            }
            switch (url.pathname) {
                case '/v1/scrub': {
                    // Every tainted session's values are scrubbed, whichever session the payload came from.
                    // Images are withheld only for the chat that typed a username or TOTP (any chat's, without a chat id).
                    const dropImages = taint.dropImagesForChat(chat);
                    return send(res, 200, { payload: scrubber.size ? scrubber.scrub(body.payload, { dropImages }) : body.payload });
                }
                case '/v1/session': {
                    const sid = typeof body.session_id === 'string' && body.session_id ? body.session_id : null;
                    const c = controllers(body.controller_port ?? null);
                    if (!c) return send(res, 403, { error: 'that browser controller is not one the filler may use' });
                    const s = sid ? taint.get(`${c.port}/${sid}`) : null;
                    return send(res, 200, { tainted: !!s, any_tainted: taint.anyTainted(), drop_images: s ? !!s.drop_images : taint.dropImagesForChat(chat) });
                }
                case '/v1/list': case '/v1/fill': case '/v1/login': {
                    if (!chat) return send(res, 400, { error: 'X-Client-Chat is required' });
                    needVault(chat);
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

/** A backend's secrets directory: secrets/ itself for shared (today's layout), else secrets/<name>/. */
export function backendSecretsDir(cfg, name) {
    if (!BACKEND_NAME.test(String(name ?? ''))) throw new Error('bad backend name');
    return name === DEFAULT_BACKEND ? cfg.secretsDir : join(cfg.secretsDir, name);
}

/**
 * Build one backend's provider from the policy's config and its secret files,
 * or null when it is not enrolled. vaultwarden: the enrollment's key files
 * (vault-client-id, vault-client-secret, vault-user-key, vault-device-id) in
 * its secrets dir, and url from the policy or else VAULT_URL.
 */
export function buildBackend(cfg, name, bcfg, { createFn = createProvider } = {}) {
    const dir = backendSecretsDir(cfg, name);
    if (bcfg.type === 'vaultwarden') {
        const extra = Object.keys(bcfg).filter((k) => !['type', 'url'].includes(k));
        if (extra.length) throw new Error(`unknown vaultwarden setting ${extra[0]}`);
        const rd = (f) => readSecretOrNull(join(dir, f));
        const userKeyB64 = rd('vault-user-key');
        const clientId = rd('vault-client-id');
        const clientSecret = rd('vault-client-secret');
        const deviceId = rd('vault-device-id');
        if (!userKeyB64 || !clientId || !clientSecret || !deviceId) return null;
        return createFn('vaultwarden', { id: name, url: typeof bcfg.url === 'string' ? bcfg.url : cfg.vaultUrl, clientId, clientSecret, userKey: Buffer.from(userKeyB64, 'base64'), deviceId });
    }
    // Other provider types read their own files from secretsDir.
    return createFn(bcfg.type, { ...bcfg, id: name, secretsDir: dir });
}

async function main(argv) {
    const cfg = loadConfig();
    if (argv[0] === '--check-policy') {
        const path = argv[1] || cfg.policyPath;
        try {
            const p = loadPolicy(path, { requireOwner: !cfg.testLoopback });
            const n = p.clients().reduce((a, c) => a + p.entries(c).length, 0);
            const d = p.defaultClient();
            process.stdout.write(`policy ok: ${p.backends().length} backend(s) (${p.backends().map((b) => `${b}: ${p.backend(b).type}`).join(', ')}), ${p.clients().length} client(s), ${n} fillable name(s), ${d ? `default_client ${d} (every chat without its own entry uses it)` : 'no default_client'}${p.clients().filter((c) => p.allItems(c)).map((c) => `, ${c} uses all_items (every vault login, on its own URIs' hosts${p.equivalentDomains(c) ? ' and their equivalent domains' : ' only: equivalent_domains is off'})`).join('')}\n`);
            for (const c of p.clients()) {
                const m = p.manage(c);
                if (!m) continue;
                const on = ['create', 'update', 'remove', 'compare'].filter((f) => m[f]);
                process.stdout.write(`  ${c} may ${on.length ? on.join(', ') : 'not change'} vault logins${m.pipe.length ? `, and pipe into ${m.pipe.join(', ')}` : ''}\n`);
            }
            if (p.pipeTargets().length) process.stdout.write(`  pipe targets: ${p.pipeTargets().map((t) => `${t} (${p.pipeTarget(t).argv[0]})`).join(', ')}\n`);
            return 0;
        } catch (err) {
            process.stderr.write(`policy invalid: ${err.message}\n`);
            return 1;
        }
    }
    const checkToken = tokenChecker(readSecretOrNull(cfg.files.clientTokenSha256));
    const vaultTokenSha = readSecretOrNull(cfg.files.vaultClientTokenSha256);
    // The same token for both would let the bridge reach the vault routes: refuse.
    const checkVaultToken = vaultTokenSha && vaultTokenSha.trim().toLowerCase() === String(readSecretOrNull(cfg.files.clientTokenSha256) || '').trim().toLowerCase()
        ? (log('vault-client-token equals the bridge token: the vault tools stay off (make filler-token-issue NAME=vault-client FILLER_ROTATE=1)'), () => false)
        : tokenChecker(vaultTokenSha);
    if (!vaultTokenSha) log('no vault-client-token.sha256: the vault tools (/v1/vault/*) are off until make filler-token-issue NAME=vault-client');
    const controllers = controllerSet({ defaultPort: cfg.controllerPort, ports: parsePorts(cfg.controllerPorts), token: readSecret(cfg.files.controllerToken) });
    const scrubber = createScrubber();
    const taint = createTaint({ statePath: cfg.statePath, scrubber, controllers, log });
    const audit = createAudit(cfg.auditDir);
    const getPolicy = policyLoader(cfg.policyPath, { requireOwner: !cfg.testLoopback });
    try { getPolicy(); } catch (err) { log(err.message); }
    const vaults = createVaults({ getPolicy, build: (name, bcfg) => buildBackend(cfg, name, bcfg) });
    try { vaults.status(); } catch {}
    const handle = createApp({ checkToken, checkVaultToken, getPolicy, vaults, controllers, scrubber, taint, audit, allowLoopbackHttp: cfg.testLoopback });
    const server = createHttpServer(handle);
    server.requestTimeout = 120_000;
    await new Promise((r, j) => { server.once('error', j); server.listen(cfg.port, cfg.host, r); });
    log(`listening on ${cfg.host}:${server.address().port}${cfg.testLoopback ? ' (TEST: loopback http fills allowed)' : ''}`);
    const sweep = setInterval(() => { taint.sweep().catch(() => {}); }, 30_000);
    const stop = () => { clearInterval(sweep); vaults.lock(); server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 3000).unref(); };
    process.on('SIGTERM', stop); process.on('SIGINT', stop);
    return null;
}

// Through a symlink (current -> releases/<sha>) argv[1] is the link path and
// import.meta.url the real one, so compare real paths.
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
    main(process.argv.slice(2)).then((code) => { if (code !== null) process.exit(code); }, (err) => { log(`fatal: ${err.message}`); process.exit(1); });
}
