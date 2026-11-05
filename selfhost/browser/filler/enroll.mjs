// One-time enrollment of the filler with the agent's vault account. Run by
// `make filler-enroll` in a one-shot container (uid 1990, no other network
// than loopback). Reads, from the terminal only:
//   the agent account's email (default agent@vault.girthbass.duckdns.org) and
//   its master password (hidden, never echoed).
// Derives the master key (PBKDF2-SHA256; other KDFs are refused), logs in with
// the password grant using the master password hash, and reads the account's
// API key (POST /api/accounts/api-key, as the web vault's "View API key"
// does). If that fails (the account has two-step login, say), it asks for the
// API key's client_id and client_secret instead. Then, as before: logs in with
// the API key, decrypts the account's user key and checks it opens the
// account's private key. Writes, 0400, under $FILLER_HOME/secrets:
//   vault-email, vault-client-id, vault-client-secret, vault-user-key,
//   vault-device-id. The master password and its hash are never written anywhere.
// Earlier files are moved to secrets/old-<ts>/ first.
//
//   node enroll.mjs --items   list the account's logins (name, item id, https
//                             hosts) from the enrolled key files; no usernames,
//                             passwords or codes (make filler-items)
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { KDF_PBKDF2, decryptSym, decryptUserKey, masterKey, masterPasswordHash, stretchMasterKey } from './lib/vaultcrypto.mjs';
import { checkVaultUrl, createVault, VaultError } from './lib/vault.mjs';
import { loadConfig, readSecret } from './lib/config.mjs';

export class EnrollError extends Error {}

/** Fetching the API key failed. reason: 'credentials' (wrong email or password), 'two_factor', or 'unavailable'. */
export class ApiKeyError extends EnrollError {
    constructor(message, reason) { super(message); this.reason = reason; }
}

export const DEFAULT_EMAIL = 'agent@vault.girthbass.duckdns.org';
const DEVICE = { deviceType: '14', deviceName: 'happy-secret-filler' };

export const FILES = ['vault-email', 'vault-client-id', 'vault-client-secret', 'vault-user-key', 'vault-device-id'];

async function post(fetchImpl, url, body, form = false) {
    let res;
    try {
        res = await fetchImpl(url, {
            method: 'POST',
            headers: { 'Content-Type': form ? 'application/x-www-form-urlencoded' : 'application/json', Accept: 'application/json' },
            body: form ? new URLSearchParams(body).toString() : JSON.stringify(body),
            signal: AbortSignal.timeout(15_000),
        });
    } catch (err) { throw new EnrollError(`vault unreachable: ${err.name}`); }
    if (!res.ok) { try { await res.body?.cancel(); } catch {} throw new EnrollError(`${new URL(url).pathname} -> HTTP ${res.status}`); }
    return res.json();
}

async function prelogin(fetchImpl, base, email) {
    const pre = await post(fetchImpl, `${base}/identity/accounts/prelogin`, { email });
    const kdf = pre.kdf ?? pre.Kdf;
    const iterations = pre.kdfIterations ?? pre.KdfIterations;
    if (kdf !== KDF_PBKDF2) throw new EnrollError('the agent account uses Argon2id; set its KDF to PBKDF2-SHA256 (Account settings > Security > Keys) and retry');
    return iterations;
}

const normEmail = (email) => {
    const e = String(email || '').trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+$/.test(e)) throw new EnrollError('that is not an email address');
    return e;
};

/**
 * Read the account's API key with its master password, the way the web vault's
 * "View API key" does: a password-grant login with the master password hash,
 * then POST /api/accounts/api-key. Returns {clientId, clientSecret}. Throws an
 * ApiKeyError; its message never repeats a response body or a typed value.
 */
export async function fetchApiKey({ vaultUrl, email, password, deviceId = randomUUID(), fetchImpl = fetch }) {
    const base = checkVaultUrl(vaultUrl);
    email = normEmail(email);
    if (!password) throw new EnrollError('master password is empty');
    const iterations = await prelogin(fetchImpl, base, email);
    const mk = masterKey(password, email, iterations);
    let hash = masterPasswordHash(mk, password);
    mk.fill(0);
    try {
        let res;
        try {
            res = await fetchImpl(`${base}/identity/connect/token`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
                body: new URLSearchParams({ grant_type: 'password', scope: 'api offline_access', client_id: 'web', username: email, password: hash, deviceIdentifier: deviceId, ...DEVICE }).toString(),
                signal: AbortSignal.timeout(15_000),
            });
        } catch (err) { throw new ApiKeyError(`vault unreachable: ${err.name}`, 'unavailable'); }
        let tok = null;
        try { tok = await res.json(); } catch {}
        if (!res.ok) {
            if (tok && (tok.TwoFactorProviders || tok.TwoFactorProviders2 || tok.twoFactorProviders || tok.twoFactorProviders2)) {
                throw new ApiKeyError('the agent account has two-step login, so its API key cannot be read with the password alone', 'two_factor');
            }
            if (res.status === 400 && tok?.error === 'invalid_grant') throw new ApiKeyError('wrong email or master password for the agent account', 'credentials');
            throw new ApiKeyError(`password login -> HTTP ${res.status}`, 'unavailable');
        }
        if (typeof tok?.access_token !== 'string') throw new ApiKeyError('password login returned no token', 'unavailable');
        const auth = { Authorization: `Bearer ${tok.access_token}`, Accept: 'application/json' };
        const get = async (path, init = {}) => {
            let r;
            try { r = await fetchImpl(`${base}${path}`, { ...init, headers: { ...auth, ...(init.headers || {}) }, signal: AbortSignal.timeout(15_000) }); } catch (err) { throw new ApiKeyError(`vault unreachable: ${err.name}`, 'unavailable'); }
            if (!r.ok) { try { await r.body?.cancel(); } catch {} throw new ApiKeyError(`${path} -> HTTP ${r.status}`, 'unavailable'); }
            try { return await r.json(); } catch { throw new ApiKeyError(`${path} returned no JSON`, 'unavailable'); }
        };
        const profile = await get('/api/accounts/profile');
        if (String(profile.email ?? profile.Email ?? '').toLowerCase() !== email) throw new ApiKeyError('the vault answered for a different account', 'unavailable');
        const userId = String(profile.id ?? profile.Id ?? '');
        const key = await get('/api/accounts/api-key', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ masterPasswordHash: hash }) });
        const clientSecret = key.apiKey ?? key.ApiKey;
        const clientId = `user.${userId}`;
        if (!/^user\.[0-9a-f-]{36}$/i.test(clientId) || typeof clientSecret !== 'string' || !clientSecret) throw new ApiKeyError('the vault returned no API key', 'unavailable');
        return { clientId, clientSecret };
    } finally { hash = null; }
}

/**
 * The API key: fetched with the master password, or, if that fails for any
 * reason but a wrong password, from askFallback() (the client_id and
 * client_secret typed by hand). Returns {clientId, clientSecret, fetched}.
 */
export async function obtainApiKey({ vaultUrl, email, password, deviceId, fetchImpl = fetch, askFallback, log = () => {} }) {
    try {
        const k = await fetchApiKey({ vaultUrl, email, password, deviceId, fetchImpl });
        log('Read the account\'s API key from the vault.');
        return { ...k, fetched: true };
    } catch (err) {
        if (!(err instanceof ApiKeyError) || err.reason === 'credentials') throw err;
        log(`Could not read the API key (${err.message}). Type it instead: web vault > Settings > Security > Keys > View API key.`);
        const k = await askFallback();
        return { clientId: String(k.clientId || '').trim(), clientSecret: String(k.clientSecret || '').trim(), fetched: false };
    }
}

/** Derive and verify the user key. Returns {userKey: Buffer(64), deviceId}. */
export async function enrollCore({ vaultUrl, email, password, clientId, clientSecret, deviceId = randomUUID(), fetchImpl = fetch }) {
    const base = checkVaultUrl(vaultUrl);
    email = normEmail(email);
    if (!/^user\.[0-9a-f-]{36}$/i.test(clientId || '')) throw new EnrollError('client_id must look like user.<uuid> (Account settings > Security > Keys > View API key)');
    if (!clientSecret) throw new EnrollError('client_secret is empty');
    if (!password) throw new EnrollError('master password is empty');

    const iterations = await prelogin(fetchImpl, base, email);
    const stretched = stretchMasterKey(masterKey(password, email, iterations));

    const tok = await post(fetchImpl, `${base}/identity/connect/token`, {
        grant_type: 'client_credentials', scope: 'api', client_id: clientId, client_secret: clientSecret,
        deviceIdentifier: deviceId, ...DEVICE,
    }, true);
    if (typeof tok.access_token !== 'string') throw new EnrollError('API key login returned no token');

    let res;
    try {
        res = await fetchImpl(`${base}/api/sync?excludeDomains=true`, { headers: { Authorization: `Bearer ${tok.access_token}`, Accept: 'application/json' }, signal: AbortSignal.timeout(30_000) });
    } catch (err) { throw new EnrollError(`vault unreachable: ${err.name}`); }
    if (!res.ok) throw new EnrollError(`/api/sync -> HTTP ${res.status}`);
    const sync = await res.json();
    const profile = sync.profile || sync.Profile || {};
    if (String(profile.email || '').toLowerCase() !== email) throw new EnrollError('the API key belongs to a different account than that email');
    const protectedKey = profile.key || tok.Key || tok.key;
    if (!protectedKey) throw new EnrollError('the vault returned no account key');
    let userKey;
    try { userKey = decryptUserKey(protectedKey, stretched); } catch { throw new EnrollError('wrong master password for that account (or the account key is unusable)'); }
    if (profile.privateKey) {
        try { decryptSym(profile.privateKey, userKey); } catch { throw new EnrollError('the user key does not open the account private key'); }
    }
    const ciphers = sync.ciphers || sync.Ciphers || [];
    const logins = ciphers.filter((c) => c && c.type === 1 && !c.deletedDate && !c.organizationId).length;
    return { userKey, deviceId, email, logins, orgs: (profile.organizations || []).length };
}

/** Write the enrollment files 0400, moving any earlier ones aside first. */
export function writeEnrollment(dir, { email, clientId, clientSecret, userKey, deviceId }, { now = new Date() } = {}) {
    mkdirSync(dir, { recursive: true });
    const present = FILES.filter((f) => existsSync(join(dir, f)));
    if (present.length) {
        const old = join(dir, `old-${now.toISOString().replace(/[:.]/g, '-')}`);
        mkdirSync(old, { mode: 0o700 });
        for (const f of present) renameSync(join(dir, f), join(old, f));
    }
    const vals = { 'vault-email': email, 'vault-client-id': clientId, 'vault-client-secret': clientSecret, 'vault-user-key': userKey.toString('base64'), 'vault-device-id': deviceId };
    for (const f of FILES) writeFileSync(join(dir, f), vals[f] + '\n', { mode: 0o400, flag: 'wx' });
}

function ask(prompt, { hidden = false } = {}) {
    const input = process.stdin; const out = process.stderr;
    if (!input.isTTY) throw new EnrollError('enroll needs a terminal (run make filler-enroll)');
    return new Promise((resolve, reject) => {
        out.write(prompt);
        let buf = '';
        input.setRawMode(true); input.resume(); input.setEncoding('utf8');
        const done = (err) => { input.setRawMode(false); input.pause(); input.removeListener('data', onData); out.write('\n'); err ? reject(err) : resolve(buf); };
        const onData = (chunk) => {
            for (const ch of chunk) {
                if (ch === '\r' || ch === '\n') return done();
                if (ch === '\u0003' || ch === '\u0004') return done(new EnrollError('cancelled'));
                if (ch === '\u007f' || ch === '\b') { if (buf.length) { buf = buf.slice(0, -1); if (!hidden) out.write('\b \b'); } continue; }
                if (ch < ' ') continue;
                buf += ch;
                if (!hidden) out.write(ch);
            }
        };
        input.on('data', onData);
    });
}

async function main() {
    const home = process.env.FILLER_HOME || '/filler';
    const dir = join(home, 'secrets');
    const vaultUrl = process.env.VAULT_URL || 'http://127.0.0.1:8222';
    const prev = existsSync(join(dir, 'vault-device-id')) ? readFileSync(join(dir, 'vault-device-id'), 'utf8').trim() : null;
    const deviceId = prev || randomUUID();
    const defEmail = process.env.FILLER_AGENT_EMAIL || DEFAULT_EMAIL;
    const log = (m) => process.stderr.write(`${m}\n`);
    log(`Enrolling the secret filler with ${vaultUrl}.\nUse the AGENT account (not your own). Secrets typed here are not echoed; only the API key and the derived user key are stored.`);
    const email = (await ask(`Agent account email [${defEmail}]: `)).trim() || defEmail;
    let password = await ask('Agent master password (hidden): ', { hidden: true });
    let r; let key;
    try {
        key = await obtainApiKey({
            vaultUrl, email, password, deviceId, log,
            askFallback: async () => ({
                clientId: (await ask('API key client_id: ')).trim(),
                clientSecret: (await ask('API key client_secret (hidden): ', { hidden: true })).trim(),
            }),
        });
        r = await enrollCore({ vaultUrl, email, password, clientId: key.clientId, clientSecret: key.clientSecret, deviceId });
    } finally { password = null; }
    writeEnrollment(dir, { email: r.email, clientId: key.clientId, clientSecret: key.clientSecret, userKey: r.userKey, deviceId: r.deviceId });
    r.userKey.fill(0);
    log(`Enrolled. The account's own vault holds ${r.logins} login(s)${r.orgs ? ` (it is also in ${r.orgs} organization(s))` : ''}. List them with make filler-items, put their item ids in the policy (make filler-policy-edit), then restart the filler: make filler-up`);
}

/** The account's logins as text lines: name, item id, https hosts. No usernames, passwords or codes. */
export function formatItems(items) {
    if (!items.length) return 'The agent account has no logins yet. Add them in the web vault (logged in as the agent account).\n';
    const clean = (v) => String(v).replace(/[\u0000-\u001f\u007f]/g, ' ');
    const lines = items.map((i) => [i.name == null ? '(name not decryptable)' : clean(i.name), i.id, i.hosts.length ? i.hosts.join(',') : '(no https URI: the filler cannot type it anywhere)']);
    const w0 = Math.max(4, ...lines.map((l) => l[0].length));
    const out = [`${'name'.padEnd(w0)}  ${'item_id'.padEnd(36)}  hosts`, ...lines.map((l) => `${l[0].padEnd(w0)}  ${l[1].padEnd(36)}  ${l[2]}`)];
    return out.join('\n') + '\n';
}

async function listItems() {
    const cfg = loadConfig();
    const f = cfg.files;
    const vault = createVault({
        url: cfg.vaultUrl, clientId: readSecret(f.vaultClientId), clientSecret: readSecret(f.vaultClientSecret),
        userKey: Buffer.from(readSecret(f.vaultUserKey), 'base64'), deviceId: readSecret(f.vaultDeviceId),
    });
    try {
        process.stdout.write(formatItems(await vault.listLogins()));
    } finally { vault.lock(); }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
    (process.argv[2] === '--items' ? listItems() : main()).catch((err) => { process.stderr.write(`enroll failed: ${err instanceof EnrollError || err instanceof VaultError ? err.message : err.name}\n`); process.exit(1); });
}
