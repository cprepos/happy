// A fake Vaultwarden on 127.0.0.1 for tests: prelogin, connect/token
// (client_credentials, and the password grant with the master password hash),
// /api/accounts/profile, /api/accounts/api-key, /api/sync. twoFactor: true
// makes the password grant answer as for an account with two-step login. Its vault is built here with node:crypto,
// the way a Bitwarden client would encrypt it: a user key under the stretched
// master key, an RSA key pair, and login items in the account's personal vault
// (under the user key), with and without their own item key. There is no
// organization in the setup the filler is used with; one organization the
// account is a member of, and an item of one it is not, check that org
// ciphers are read with their org key and nothing else.
//
// The sync carries equivalent domains as Vaultwarden sends them (domains:
// equivalentDomains, the account's own groups, and globalEquivalentDomains),
// or null when the client asks with excludeDomains=true: Google's group,
// Apple's group excluded by the account, a group listing the public suffix
// net.cn, and a custom group [foo.co.uk, foo-shop.com].
//
// Writes, as Vaultwarden answers them: POST /api/ciphers (create), PUT
// /api/ciphers/<id> (update, refused with 400 on a stale
// lastKnownRevisionDate), PUT /api/ciphers/<id>/delete (soft delete: sets
// deletedDate, answers an empty 200) and PUT /api/ciphers/<id>/restore. Each is
// recorded in calls.writes; any other cipher write (DELETE, a purge) answers
// 404 and is recorded in calls.refusedWrites.
import { createServer } from 'node:http';
import { generateKeyPairSync, randomBytes, randomUUID } from 'node:crypto';
import { encryptRsa, encryptSym, masterKey, masterPasswordHash, stretchMasterKey } from '../lib/vaultcrypto.mjs';

export const TOTP_SECRET = 'JBSWY3DPEHPK3PXP';

export function buildVault({ email = 'agent@vault.test', password = 'correct horse battery staple', iterations = 100_000 } = {}) {
    const userKey = randomBytes(64);
    const mk = masterKey(password, email, iterations);
    const stretched = stretchMasterKey(mk);
    const passwordHash = masterPasswordHash(mk, password);
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
    function addLogin(label, { org = null, itemKey = false, type = 1, username, password: pw, totp = null, uris, deleted = false, encType, match = null } = {}) {
        const o = org ? orgs[org] : null;
        const base = o ? o.key : userKey;
        const ik = itemKey ? randomBytes(64) : null;
        const k = ik || base;
        const enc = (v) => (v == null ? null : encryptSym(v, k));
        const c = {
            id: randomUUID(), organizationId: o ? o.id : null, collectionIds: [], type,
            key: ik ? encryptSym(ik, base) : null,
            name: enc(label),
            login: type !== 1 ? null : { username: enc(username), password: enc(pw), totp: enc(totp), uris: uris.map((u) => ({ uri: enc(u), match })) },
            deletedDate: deleted ? new Date().toISOString() : null,
            revisionDate: new Date(Date.UTC(2026, 0, 1)).toISOString(),
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
    // Equivalent domains: gmail.com is in Google's group, apple.com in an excluded group, foo.co.uk in a custom one.
    addLogin('gmail', { username: 'agent@gmail.test', password: 'Gmail-Pass-2468', uris: ['https://www.gmail.com/'] });
    addLogin('gmail-host', { username: 'agent2@gmail.test', password: 'GmailHost-Pass-1357', uris: ['https://www.gmail.com/'], match: 1 });
    addLogin('apple', { username: 'agent@apple.test', password: 'Apple-Pass-9753', uris: ['https://www.apple.com/'] });
    addLogin('foo-uk', { username: 'foo', password: 'FooUk-Pass-8642', uris: ['https://www.foo.co.uk/login'] });
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
        domains: {
            equivalentDomains: [['foo.co.uk', 'foo-shop.com']],
            globalEquivalentDomains: [
                { type: 0, domains: ['youtube.com', 'google.com', 'gmail.com'], excluded: false },
                { type: 1, domains: ['apple.com', 'icloud.com'], excluded: true },
                { type: 41, domains: ['shop-cn.test', 'net.cn'], excluded: false },
            ],
            object: 'domains',
        },
        collections: [],
        folders: [],
    };
    // addLogin stays usable after start: a login added later shows in the next /api/sync.
    return { addLogin, email, password, passwordHash, userId, iterations, userKey, clientId, clientSecret, orgs, items, sync };
}

export async function startFakeVaultwarden(vault = buildVault(), { twoFactor = false, apiKeyStatus = 200 } = {}) {
    const calls = { token: 0, sync: 0, prelogin: 0, passwordGrant: 0, apiKey: 0, bodies: [], writes: [], refusedWrites: [] };
    let rev = 0;
    const stamp = () => new Date(Date.UTC(2026, 1, 1) + (++rev) * 1000).toISOString();
    const tokens = new Set();
    const webTokens = new Set();
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
            calls.bodies.push(body);
            if (p.get('grant_type') === 'password') {
                calls.passwordGrant++;
                if (!p.get('client_id') || !p.get('deviceIdentifier') || !p.get('deviceName') || !p.get('deviceType')) return send(400, { error: 'invalid_request' });
                if (p.get('username') !== vault.email || p.get('password') !== vault.passwordHash) return send(400, { error: 'invalid_grant', error_description: 'Username or password is incorrect. Try again', echo: p.get('password') });
                if (twoFactor) return send(400, { error: 'invalid_grant', error_description: 'Two factor required.', TwoFactorProviders: ['0'], TwoFactorProviders2: { 0: null } });
                const t = randomBytes(16).toString('hex');
                webTokens.add(t);
                return send(200, { access_token: t, expires_in: 3600, token_type: 'Bearer', refresh_token: 'r', Key: vault.sync.profile.key });
            }
            if (p.get('grant_type') !== 'client_credentials' || p.get('client_id') !== vault.clientId || p.get('client_secret') !== vault.clientSecret || !p.get('deviceIdentifier')) {
                return send(400, { error: 'invalid_client', echo: p.get('client_secret') });
            }
            const t = randomBytes(16).toString('hex');
            tokens.add(t);
            return send(200, { access_token: t, expires_in: 7200, token_type: 'Bearer', Key: vault.sync.profile.key, PrivateKey: vault.sync.profile.privateKey, Kdf: 0, KdfIterations: vault.iterations });
        }
        const web = () => webTokens.has((req.headers.authorization || '').replace(/^Bearer /, ''));
        if (req.method === 'GET' && url.pathname === '/api/accounts/profile') {
            if (!web()) return send(401, { error: 'unauthorized' });
            return send(200, { id: vault.userId, email: vault.email, object: 'profile' });
        }
        if (req.method === 'POST' && url.pathname === '/api/accounts/api-key') {
            calls.apiKey++;
            calls.bodies.push(body);
            if (!web()) return send(401, { error: 'unauthorized' });
            if (apiKeyStatus !== 200) return send(apiKeyStatus, { message: 'nope' });
            let b = {};
            try { b = JSON.parse(body); } catch {}
            if (b.masterPasswordHash !== vault.passwordHash) return send(400, { message: 'Invalid password' });
            return send(200, { apiKey: vault.clientSecret, revisionDate: new Date().toISOString(), object: 'apiKey' });
        }
        if (req.method === 'GET' && url.pathname === '/api/sync') {
            calls.sync++;
            const t = (req.headers.authorization || '').replace(/^Bearer /, '');
            if (!tokens.has(t)) return send(401, { error: 'unauthorized' });
            calls.syncUrls = [...(calls.syncUrls || []), req.url];
            return send(200, url.searchParams.get('excludeDomains') === 'true' ? { ...vault.sync, domains: null } : vault.sync);
        }
        const cm = /^\/api\/ciphers(?:\/([0-9a-f-]{36}))?(?:\/(delete|restore))?$/.exec(url.pathname);
        if (cm && req.method !== 'GET') {
            const t = (req.headers.authorization || '').replace(/^Bearer /, '');
            if (!tokens.has(t)) return send(401, { error: 'unauthorized' });
            const [, id, op] = cm;
            const find = () => vault.sync.ciphers.find((c) => c.id === id);
            if (req.method === 'POST' && !id) {
                let b; try { b = JSON.parse(body); } catch { return send(400, { message: 'bad json' }); }
                if (b.type !== 1 || !b.name || !b.login) return send(400, { message: 'bad cipher' });
                const c = { ...b, id: randomUUID(), collectionIds: [], deletedDate: null, revisionDate: stamp(), creationDate: stamp() };
                delete c.lastKnownRevisionDate;
                vault.sync.ciphers.push(c);
                calls.writes.push({ op: 'create', id: c.id, body: b });
                res.writeHead(200, { 'Content-Type': 'application/json' }); return res.end(JSON.stringify({ ...c, object: 'cipherDetails' }));
            }
            if (req.method === 'PUT' && id && !op) {
                const c = find(); if (!c) return send(404, { message: 'not found' });
                let b; try { b = JSON.parse(body); } catch { return send(400, { message: 'bad json' }); }
                if (b.lastKnownRevisionDate && b.lastKnownRevisionDate !== c.revisionDate) return send(400, { message: 'The client copy of this cipher is out of date.' });
                const { lastKnownRevisionDate, ...rest } = b;
                Object.assign(c, rest, { id, revisionDate: stamp() });
                calls.writes.push({ op: 'update', id, body: b });
                return send(200, { ...c, object: 'cipherDetails' });
            }
            if (req.method === 'PUT' && id && op) {
                const c = find(); if (!c) return send(404, { message: 'not found' });
                c.deletedDate = op === 'delete' ? stamp() : null;
                c.revisionDate = stamp();
                calls.writes.push({ op: op === 'delete' ? 'trash' : 'restore', id });
                res.writeHead(200); return res.end();
            }
            calls.refusedWrites.push({ method: req.method, path: url.pathname });
            return send(404, { error: 'not found' });
        }
        send(404, { error: 'not found' });
    });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    const url = `http://127.0.0.1:${server.address().port}`;
    return { url, vault, calls, close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }) };
}
