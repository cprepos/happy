import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createVault, checkVaultUrl } from '../lib/vault.mjs';
import { startFakeVaultwarden } from './fake-vaultwarden.mjs';

async function setup() {
    const fake = await startFakeVaultwarden();
    const { vault: v } = fake;
    const vault = createVault({ url: fake.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'dev-1' });
    return { fake, v, vault, scope: (org) => ({ orgId: v.orgs[org].id, collectionId: v.orgs[org].agents }) };
}

test('reads items with and without an item key, from the right org and collection only', async () => {
    const { fake, v, vault, scope } = await setup();
    try {
        const gh = await vault.readItem(v.items['acme-github'].id, scope('acme'));
        assert.equal(gh.password, v.items['acme-github'].password);
        assert.equal(gh.username, 'acme-bot@example.com');
        assert.deepEqual(gh.uris, v.items['acme-github'].uris);
        const portal = await vault.readItem(v.items['acme-portal'].id, scope('acme'));
        assert.equal(portal.password, v.items['acme-portal'].password);
        // Cross-client: an acme chat never reads a globex item, nor items outside Agents, trashed or odd ones.
        await assert.rejects(vault.readItem(v.items['globex-github'].id, scope('acme')), /organization/);
        await assert.rejects(vault.readItem(v.items['acme-github'].id, scope('globex')), /organization/);
        await assert.rejects(vault.readItem(v.items['acme-private'].id, scope('acme')), /Agents collection/);
        await assert.rejects(vault.readItem(v.items['acme-trashed'].id, scope('acme')), /trash/);
        await assert.rejects(vault.readItem(v.items['acme-badtype'].id, scope('acme')), /unsupported EncString type/);
        await assert.rejects(vault.readItem('00000000-0000-4000-8000-000000000000', scope('acme')), /not found/);
    } finally { await fake.close(); }
});

test('syncs are cached for 15 s and the token is reused', async () => {
    const fake = await startFakeVaultwarden();
    let t = 1_000_000;
    const v = fake.vault;
    const vault = createVault({ url: fake.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'd', now: () => t });
    try {
        const sc = { orgId: v.orgs.acme.id, collectionId: v.orgs.acme.agents };
        await vault.readItem(v.items['acme-github'].id, sc);
        await vault.readItem(v.items['acme-github'].id, sc);
        assert.equal(fake.calls.sync, 1);
        t += 16_000;
        await vault.readItem(v.items['acme-github'].id, sc);
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
