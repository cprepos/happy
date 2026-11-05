// A fake Vaultwarden on 127.0.0.1 for tests: prelogin, connect/token
// (client_credentials), /api/sync. Its vault is built here with node:crypto,
// the way a Bitwarden client would encrypt it: a user key under the stretched
// master key, an RSA key pair, and login items in the account's personal vault
// (under the user key), with and without their own item key. There is no
// organization in the setup the filler is used with; one organization the
// account is a member of, and an item of one it is not, check that org
// ciphers are read with their org key and nothing else.
import { createServer } from 'node:http';
import { generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { encryptRsa, encryptSym, masterKey, stretchMasterKey } from '../lib/vaultcrypto.mjs';

export const TOTP_SECRET = 'JBSWY3DPEHPK3PXP';

export function buildVault({ email = 'agent@vault.test', password = 'correct horse battery staple', iterations = 100_000 } = {}) {
    const userKey = randomBytes(64);
    const stretched = stretchMasterKey(masterKey(password, email, iterations));
    const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const pkcs8 = privateKey.export({ format: 'der', type: 'pkcs8' });
    const orgs = {
        shared: { id: randomUUID(), key: randomBytes(64), member: true },
        foreign: { id: randomUUID(), key: randomBytes(64), member: false },
    };
    const userId = randomUUID();
    const clientId = `user.${userId}`;
    const clientSecret = randomBytes(18).toString('base64url');

    const ciphers = [];
    const items = {};
    function addLogin(label, { org = null, itemKey = false, type = 1, username, password: pw, totp = null, uris, deleted = false, encType } = {}) {
        const o = org ? orgs[org] : null;
        const base = o ? o.key : userKey;
        const ik = itemKey ? randomBytes(64) : null;
        const k = ik || base;
        const enc = (v) => (v == null ? null : encryptSym(v, k));
        const c = {
            id: randomUUID(), organizationId: o ? o.id : null, collectionIds: [], type,
            key: ik ? encryptSym(ik, base) : null,
            name: enc(label),
            login: type !== 1 ? null : { username: enc(username), password: enc(pw), totp: enc(totp), uris: uris.map((u) => ({ uri: enc(u), match: null })) },
            deletedDate: deleted ? new Date().toISOString() : null,
        };
        if (encType && c.login) c.login.password = `${encType}.${randomBytes(32).toString('base64')}`;
        ciphers.push(c);
        items[label] = { id: c.id, org, username, password: pw, totp, uris };
        return c;
    }
    addLogin('acme-github', { username: 'acme-bot@example.com', password: 'Acme+Pass/w0rd=1&x', totp: TOTP_SECRET, uris: ['https://github.com/login', 'https://www.github.com'] });
    addLogin('acme-portal', { itemKey: true, username: 'acme-ops', password: 'P0rtal "quoted" <tag> \'apos\'', uris: ['https://portal.acme.test'] });
    addLogin('acme-trashed', { username: 'old', password: 'old-pass-zzz', uris: ['https://github.com'], deleted: true });
    addLogin('acme-gitlab', { username: 'gl', password: 'Gitlab-Pass-4321', uris: ['https://github.com'] });
    addLogin('acme-badtype', { username: 'weird', password: 'x', uris: ['https://github.com'], encType: '0' });
    addLogin('acme-note', { type: 2, uris: [] });
    addLogin('globex-github', { username: 'globex-bot', password: 'Globex-Secret-9876', totp: `otpauth://totp/Globex:bot?secret=${TOTP_SECRET}&algorithm=SHA256&digits=8&period=30`, uris: ['https://github.com'] });
    // Not listed in the test policy at all: the owner's own login, kept in the same vault.
    addLogin('unlisted', { username: 'boss', password: 'not-for-agents-123', uris: ['https://github.com'] });
    addLogin('org-shared', { org: 'shared', itemKey: true, username: 'shared-bot', password: 'Shared-Org-Pass-55', uris: ['https://github.com'] });
    addLogin('org-foreign', { org: 'foreign', username: 'x', password: 'Foreign-Org-Pass-77', uris: ['https://github.com'] });

    const sync = {
        object: 'sync',
        profile: {
            id: userId, email,
            key: encryptSym(userKey, stretched),
            privateKey: encryptSym(pkcs8, userKey),
            organizations: Object.values(orgs).filter((o) => o.member).map((o) => ({ id: o.id, key: encryptRsa(o.key, publicKey), type: 2, status: 2 })),
        },
        ciphers,
        collections: [],
        folders: [],
    };
    return { email, password, iterations, userKey, clientId, clientSecret, orgs, items, sync };
}

export async function startFakeVaultwarden(vault = buildVault()) {
    const calls = { token: 0, sync: 0, prelogin: 0 };
    const tokens = new Set();
    const server = createServer(async (req, res) => {
        const chunks = [];
        for await (const c of req) chunks.push(c);
        const body = Buffer.concat(chunks).toString('utf8');
        const send = (status, obj) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
        const url = new URL(req.url, 'http://x');
        if (req.method === 'POST' && (url.pathname === '/identity/accounts/prelogin' || url.pathname === '/api/accounts/prelogin')) {
            calls.prelogin++;
            return send(200, { kdf: 0, kdfIterations: vault.iterations, kdfMemory: null, kdfParallelism: null });
        }
        if (req.method === 'POST' && url.pathname === '/identity/connect/token') {
            calls.token++;
            const p = new URLSearchParams(body);
            if (p.get('grant_type') !== 'client_credentials' || p.get('client_id') !== vault.clientId || p.get('client_secret') !== vault.clientSecret || !p.get('deviceIdentifier')) {
                return send(400, { error: 'invalid_client', echo: p.get('client_secret') });
            }
            const t = randomBytes(16).toString('hex');
            tokens.add(t);
            return send(200, { access_token: t, expires_in: 7200, token_type: 'Bearer', Key: vault.sync.profile.key, PrivateKey: vault.sync.profile.privateKey, Kdf: 0, KdfIterations: vault.iterations });
        }
        if (req.method === 'GET' && url.pathname === '/api/sync') {
            calls.sync++;
            const t = (req.headers.authorization || '').replace(/^Bearer /, '');
            if (!tokens.has(t)) return send(401, { error: 'unauthorized' });
            return send(200, vault.sync);
        }
        send(404, { error: 'not found' });
    });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    const url = `http://127.0.0.1:${server.address().port}`;
    return { url, vault, calls, close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }) };
}
