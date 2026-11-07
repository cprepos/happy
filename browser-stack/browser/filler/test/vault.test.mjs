import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createVault, checkVaultUrl } from '../lib/vault.mjs';
import { startFakeVaultwarden } from './fake-vaultwarden.mjs';

async function setup() {
    const fake = await startFakeVaultwarden();
    const { vault: v } = fake;
    const vault = createVault({ url: fake.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'dev-1' });
    return { fake, v, vault };
}

test('reads personal items with and without an item key, and org items only with a held org key', async () => {
    const { fake, v, vault } = await setup();
    try {
        const gh = await vault.readItem(v.items['acme-github'].id);
        assert.equal(gh.password, v.items['acme-github'].password);
        assert.equal(gh.username, 'acme-bot@example.com');
        assert.equal(gh.totp, v.items['acme-github'].totp);
        assert.deepEqual(gh.uris, v.items['acme-github'].uris);
        const portal = await vault.readItem(v.items['acme-portal'].id);
        assert.equal(portal.password, v.items['acme-portal'].password);
        // The account can decrypt an item of an organization it is a confirmed member of...
        assert.equal((await vault.readItem(v.items['org-shared'].id)).password, v.items['org-shared'].password);
        // ...and nothing of one it holds no key for.
        await assert.rejects(vault.readItem(v.items['org-foreign'].id), /no key for this item's organization/);
        await assert.rejects(vault.readItem(v.items['acme-trashed'].id), /trash/);
        await assert.rejects(vault.readItem(v.items['acme-note'].id), /not a login/);
        await assert.rejects(vault.readItem(v.items['acme-badtype'].id), /unsupported EncString type/);
        await assert.rejects(vault.readItem('00000000-0000-4000-8000-000000000000'), /not found/);
    } finally { await fake.close(); }
});

test('syncs are cached for 15 s and the token is reused', async () => {
    const fake = await startFakeVaultwarden();
    let t = 1_000_000;
    const v = fake.vault;
    const vault = createVault({ url: fake.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'd', now: () => t });
    try {
        await vault.readItem(v.items['acme-github'].id);
        await vault.readItem(v.items['acme-github'].id);
        assert.equal(fake.calls.sync, 1);
        t += 16_000;
        await vault.readItem(v.items['acme-github'].id);
        assert.deepEqual([fake.calls.sync, fake.calls.token], [2, 1]);
    } finally { await fake.close(); }
});

test('a wrong user key or API key fails without echoing anything', async () => {
    const fake = await startFakeVaultwarden();
    const v = fake.vault;
    try {
        const wrongKey = createVault({ url: fake.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: Buffer.alloc(64, 7), deviceId: 'd' });
        await assert.rejects(wrongKey.sync(), /re-run make filler-enroll/);
        const wrongSecret = createVault({ url: fake.url, clientId: v.clientId, clientSecret: 'nope-wrong-secret', userKey: v.userKey, deviceId: 'd' });
        await assert.rejects(wrongSecret.sync(), (err) => !err.message.includes('nope-wrong-secret') && /HTTP 400/.test(err.message));
    } finally { await fake.close(); }
    assert.throws(() => checkVaultUrl('http://vault.example.com'), /https/);
    assert.equal(checkVaultUrl('http://127.0.0.1:8222/'), 'http://127.0.0.1:8222');
});
