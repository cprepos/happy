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

test('custom fields: decrypted with the item key (none, own, org); linked, unnamed and undecryptable ones skipped', async () => {
    const { fake, v, vault } = await setup();
    try {
        // A personal item under the user key: text, hidden, boolean, a duplicate name kept, an empty value.
        const jira = await vault.readItem(v.items.jira.id);
        assert.deepEqual(jira.custom, [
            { name: 'token', value: 'Jira-Api-Token-Zq81xW' },
            { name: 'Region', value: 'eu-west' },
            { name: 'enabled', value: 'true' },
            { name: 'dup', value: 'Dup-Value-One-111' },
            { name: 'dup', value: 'Dup-Value-Two-222' },
            { name: 'empty', value: null },
        ]);
        assert.equal(jira.password, 'Jira-Pass-8080', 'a bad custom field does not break the item');
        // Under its own item key, and an organization item under the org key.
        assert.deepEqual((await vault.readItem(v.items['acme-portal'].id)).custom, [{ name: 'token', value: 'Portal-Token-7c1e9a' }, { name: 'api-key', value: 'Portal-ApiKey-55d2' }]);
        assert.deepEqual((await vault.readItem(v.items['org-shared'].id)).custom, [{ name: 'token', value: 'Shared-Org-Token-31' }]);
        assert.deepEqual((await vault.readItem(v.items['acme-github'].id)).custom, []);
        // The listing has names only, never a value.
        const items = await vault.listItems();
        const lj = items.find((i) => i.id === v.items.jira.id);
        assert.deepEqual(lj.custom_fields, ['token', 'Region', 'enabled', 'dup', 'dup', 'empty', 'broken']);
        assert.deepEqual(items.find((i) => i.id === v.items['org-shared'].id).custom_fields, ['token']);
        const s = JSON.stringify(items);
        for (const x of ['Jira-Api-Token-Zq81xW', 'eu-west', 'Dup-Value-One-111', 'Portal-Token-7c1e9a', 'Shared-Org-Token-31']) assert.ok(!s.includes(x), x);
        // listLogins (what fill uses) is unchanged: no custom fields at all.
        const ll = (await vault.listLogins()).find((l) => l.id === v.items.jira.id);
        assert.deepEqual(ll.fields, ['username', 'password']);
        assert.ok(!('custom_fields' in ll) && !('custom' in ll));
    } finally { await fake.close(); }
});
