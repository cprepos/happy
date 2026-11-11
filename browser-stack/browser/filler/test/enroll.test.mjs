// Enrollment with the master password only: the API key is read from the vault
// (password grant + /api/accounts/api-key), with the typed client_id and
// client_secret as the fallback. And the login listing for writing the policy.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { enrollCore, fetchApiKey, formatItems, obtainApiKey, DEFAULT_EMAIL } from '../lib/providers/vaultwarden/enroll.mjs';
import { createVault } from '../lib/providers/vaultwarden/vault.mjs';
import { startFakeVaultwarden, TOTP_SECRET } from './fake-vaultwarden.mjs';

const never = async () => { throw new Error('the fallback must not be asked'); };

test('the API key is read with the master password alone, and enrollment goes on with it', async () => {
    const fake = await startFakeVaultwarden();
    const v = fake.vault;
    try {
        const logs = [];
        const k = await obtainApiKey({ vaultUrl: fake.url, email: ` ${v.email.toUpperCase()} `, password: v.password, deviceId: 'dev-1', askFallback: never, log: (m) => logs.push(m) });
        assert.deepEqual(k, { clientId: v.clientId, clientSecret: v.clientSecret, fetched: true });
        assert.equal(fake.calls.passwordGrant, 1);
        assert.equal(fake.calls.apiKey, 1);
        // The master password itself never leaves; only its hash does.
        assert.ok(fake.calls.bodies.every((b) => !b.includes(v.password) && !b.includes(encodeURIComponent(v.password))));
        assert.ok(fake.calls.bodies.some((b) => b.includes(v.passwordHash) || b.includes(encodeURIComponent(v.passwordHash))));
        assert.ok(!logs.join('\n').includes(v.clientSecret), 'the key is never logged');
        const r = await enrollCore({ vaultUrl: fake.url, email: v.email, password: v.password, clientId: k.clientId, clientSecret: k.clientSecret, deviceId: 'dev-1' });
        assert.ok(r.userKey.equals(v.userKey));
    } finally { await fake.close(); }
});

test('two-step login on the account: falls back to the typed API key', async () => {
    const fake = await startFakeVaultwarden(undefined, { twoFactor: true });
    const v = fake.vault;
    try {
        await assert.rejects(fetchApiKey({ vaultUrl: fake.url, email: v.email, password: v.password }), (e) => e.reason === 'two_factor');
        let asked = 0; const logs = [];
        const k = await obtainApiKey({
            vaultUrl: fake.url, email: v.email, password: v.password, deviceId: 'dev-2', log: (m) => logs.push(m),
            askFallback: async () => { asked++; return { clientId: ` ${v.clientId} `, clientSecret: `${v.clientSecret}\n` }; },
        });
        assert.equal(asked, 1);
        assert.deepEqual(k, { clientId: v.clientId, clientSecret: v.clientSecret, fetched: false });
        assert.match(logs.join('\n'), /two-step login/);
        const r = await enrollCore({ vaultUrl: fake.url, email: v.email, password: v.password, clientId: k.clientId, clientSecret: k.clientSecret, deviceId: 'dev-2' });
        assert.ok(r.userKey.equals(v.userKey));
        assert.equal(fake.calls.apiKey, 0);
    } finally { await fake.close(); }
});

test('the api-key call failing, or the vault being down, also falls back', async () => {
    const fake = await startFakeVaultwarden(undefined, { apiKeyStatus: 500 });
    const v = fake.vault;
    try {
        let asked = 0;
        const k = await obtainApiKey({ vaultUrl: fake.url, email: v.email, password: v.password, askFallback: async () => { asked++; return { clientId: v.clientId, clientSecret: v.clientSecret }; } });
        assert.equal(asked, 1);
        assert.equal(k.fetched, false);
    } finally { await fake.close(); }
    // A server that answers nothing useful.
    const dead = createServer((req, res) => { res.writeHead(502); res.end(); });
    await new Promise((r) => dead.listen(0, '127.0.0.1', r));
    try {
        await assert.rejects(fetchApiKey({ vaultUrl: `http://127.0.0.1:${dead.address().port}`, email: DEFAULT_EMAIL, password: 'x' }), /HTTP 502/);
    } finally { await new Promise((r) => dead.close(r)); }
});

test('a wrong master password stops enrollment instead of asking for the API key, and echoes nothing', async () => {
    const fake = await startFakeVaultwarden();
    const v = fake.vault;
    try {
        await assert.rejects(
            obtainApiKey({ vaultUrl: fake.url, email: v.email, password: 'wrong-password-xyz', askFallback: never }),
            (e) => e.reason === 'credentials' && /wrong email or master password/.test(e.message) && !e.message.includes('wrong-password-xyz') && !/[A-Za-z0-9+/]{40,}=/.test(e.message),
        );
        assert.equal(fake.calls.apiKey, 0);
    } finally { await fake.close(); }
});

test('the login listing has names, item ids and https hosts, never usernames, passwords or codes', async () => {
    const fake = await startFakeVaultwarden();
    const v = fake.vault;
    try {
        const vault = createVault({ url: fake.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'dev-3' });
        const items = await vault.listLogins();
        const byName = Object.fromEntries(items.map((i) => [i.name, i]));
        assert.deepEqual(byName['acme-github'], { id: v.items['acme-github'].id, name: 'acme-github', hosts: ['github.com', 'www.github.com'], fields: ['username', 'password', 'totp'] });
        assert.deepEqual(byName['acme-portal'].hosts, ['portal.acme.test'], 'items with their own key are read too');
        assert.equal(byName['org-shared'].organization, true);
        for (const gone of ['acme-trashed', 'acme-note', 'org-foreign']) assert.ok(!(gone in byName), `${gone} is not listed`);
        const text = formatItems(items);
        assert.match(text, new RegExp(v.items['globex-github'].id));
        for (const it of Object.values(v.items)) {
            for (const secret of [it.username, it.password]) if (secret && secret.length >= 6) assert.ok(!text.includes(secret), 'no username or password in the listing');
        }
        assert.ok(!text.includes(TOTP_SECRET));
        assert.match(formatItems([]), /no logins yet/);
        assert.match(formatItems([{ id: 'x', name: 'a\u001b[31m', hosts: [] }]), /no https URI/);
        assert.ok(!formatItems([{ id: 'x', name: 'a\u001b[31m', hosts: [] }]).includes('\u001b'), 'control characters in names are not passed to the terminal');
    } finally { await fake.close(); }
});

test('the sync asks for equivalent domains, and the listing shows them short', async () => {
    const fake = await startFakeVaultwarden();
    const v = fake.vault;
    try {
        const vault = createVault({ url: fake.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'dev-eq' });
        const items = await vault.listLogins();
        assert.ok(fake.calls.syncUrls.every((u) => u.includes('excludeDomains=false')), 'domains are requested');
        const byName = Object.fromEntries(items.map((i) => [i.name, i]));
        assert.deepEqual(Object.fromEntries(byName.gmail.equivalents), { 'gmail.com': 'www.gmail.com', 'google.com': 'www.gmail.com', 'youtube.com': 'www.gmail.com' });
        for (const n of ['gmail-host', 'apple', 'acme-github']) assert.equal(byName[n].equivalents, undefined, n);
        const text = formatItems(items);
        assert.match(text, /www\.gmail\.com \(\+ google\.com, youtube\.com equivalents\)/);
        assert.match(text, /www\.foo\.co\.uk \(\+ foo-shop\.com equivalents\)/);
        assert.match(text, /"equivalent_domains": false/);
        assert.doesNotMatch(formatItems([{ id: 'x', name: 'a', hosts: ['github.com'] }]), /equivalents/);
    } finally { await fake.close(); }
});
