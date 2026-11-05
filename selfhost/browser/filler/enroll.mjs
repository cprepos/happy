// One-time enrollment of the filler with the agent's vault account. Run by
// `make filler-enroll` in a one-shot container (uid 1990, no other network
// than loopback). Reads, from the terminal only:
//   the agent account's email, its API key (client_id, client_secret) and its
//   master password (hidden, never echoed).
// Derives the master key (PBKDF2-SHA256; other KDFs are refused), stretches
// it, logs in with the API key, decrypts the account's user key and checks it
// opens the account's private key. Writes, 0400, under $FILLER_HOME/secrets:
//   vault-email, vault-client-id, vault-client-secret, vault-user-key,
//   vault-device-id. The master password is never written anywhere.
// Earlier files are moved to secrets/old-<ts>/ first.
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { KDF_PBKDF2, decryptSym, decryptUserKey, masterKey, stretchMasterKey } from './lib/vaultcrypto.mjs';
import { checkVaultUrl } from './lib/vault.mjs';

export class EnrollError extends Error {}

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

/** Derive and verify the user key. Returns {userKey: Buffer(64), deviceId}. */
export async function enrollCore({ vaultUrl, email, password, clientId, clientSecret, deviceId = randomUUID(), fetchImpl = fetch }) {
    const base = checkVaultUrl(vaultUrl);
    email = String(email || '').trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+$/.test(email)) throw new EnrollError('that is not an email address');
    if (!/^user\.[0-9a-f-]{36}$/i.test(clientId || '')) throw new EnrollError('client_id must look like user.<uuid> (Account settings > Security > Keys > View API key)');
    if (!clientSecret) throw new EnrollError('client_secret is empty');
    if (!password) throw new EnrollError('master password is empty');

    const pre = await post(fetchImpl, `${base}/identity/accounts/prelogin`, { email });
    const kdf = pre.kdf ?? pre.Kdf;
    const iterations = pre.kdfIterations ?? pre.KdfIterations;
    if (kdf !== KDF_PBKDF2) throw new EnrollError('the agent account uses Argon2id; set its KDF to PBKDF2-SHA256 (Account settings > Security > Keys) and retry');
    const stretched = stretchMasterKey(masterKey(password, email, iterations));

    const tok = await post(fetchImpl, `${base}/identity/connect/token`, {
        grant_type: 'client_credentials', scope: 'api', client_id: clientId, client_secret: clientSecret,
        deviceType: '14', deviceIdentifier: deviceId, deviceName: 'happy-secret-filler',
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
    return { userKey, deviceId, email, orgs: (profile.organizations || []).length };
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
    process.stderr.write(`Enrolling the secret filler with ${vaultUrl}.\nUse the AGENT account (not your own). Nothing typed here is echoed for secrets or stored except the API key and the derived user key.\n`);
    const email = await ask('Agent account email: ');
    const clientId = (await ask('API key client_id: ')).trim();
    const clientSecret = (await ask('API key client_secret (hidden): ', { hidden: true })).trim();
    let password = await ask('Agent master password (hidden): ', { hidden: true });
    let r;
    try {
        r = await enrollCore({ vaultUrl, email, password, clientId, clientSecret, deviceId: prev || randomUUID() });
    } finally { password = null; }
    writeEnrollment(dir, { email: r.email, clientId, clientSecret, userKey: r.userKey, deviceId: r.deviceId });
    r.userKey.fill(0);
    process.stderr.write(`Enrolled. The account is in ${r.orgs} organization(s). Restart the filler: make filler-up\n`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
    main().catch((err) => { process.stderr.write(`enroll failed: ${err instanceof EnrollError ? err.message : err.name}\n`); process.exit(1); });
}
