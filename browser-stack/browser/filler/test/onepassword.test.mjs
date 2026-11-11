// The 1Password provider's own rules, beyond the shared conformance suite:
// the token file, config bounds, vault resolution, the tag-only trash (never
// delete, archive only when configured), the rate-limit cooldown, re-sign-in,
// and that no SDK message, token or value reaches an error.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createOnePasswordProvider } from '../lib/providers/onepassword/index.mjs';
import { readToken } from '../lib/providers/onepassword/token.mjs';
import { create } from '../lib/providers/builtin.mjs';
import { fakeOnePassword, newId, VAULT_TITLE } from './fake-onepassword.mjs';

const TOKEN = `ops_${Buffer.from(JSON.stringify({ fake: 'service-account', n: 'x'.repeat(64) })).toString('base64')}`;

function secretsDir(content = TOKEN, mode = 0o400, name = 'onepassword.token') {
    const dir = mkdtempSync(join(tmpdir(), 'op-test-'));
    if (content !== null) { writeFileSync(join(dir, name), content + '\n'); chmodSync(join(dir, name), mode); }
    return { dir, done: () => { try { chmodSync(join(dir, name), 0o600); } catch {} rmSync(dir, { recursive: true, force: true }); } };
}

async function status(p) { try { await p; } catch (e) { return e; } assert.fail('expected a rejection'); }

test('token: missing file means not enrolled, at build time, through the registry', () => {
    const s = secretsDir(null);
    try {
        assert.throws(() => create('onepassword', { type: 'onepassword', id: 'inst', vault: VAULT_TITLE, secretsDir: s.dir }), (e) => e.status === 503 && /not enrolled/.test(e.message));
    } finally { s.done(); }
});

test('token: read once from a 0400 file and handed to createClient; the SDK is not loaded', async () => {
    const s = secretsDir();
    const op = fakeOnePassword();
    const seen = [];
    try {
        const p = createOnePasswordProvider({ id: 'inst', vault: VAULT_TITLE, secretsDir: s.dir }, { createClient: async (t) => { seen.push(t); return op.client; } });
        assert.equal(p.status().unlocked, false);
        await p.sync();
        await p.sync({ force: true });
        assert.deepEqual(seen, [TOKEN], 'one sign-in, with the trimmed token');
        assert.equal(p.status().unlocked, true);
    } finally { s.done(); }
});

test('token: symlink, group/other access, wrong format and bad names are refused without echoing the file', () => {
    const s = secretsDir();
    try {
        const link = join(s.dir, 'link.token');
        symlinkSync(join(s.dir, 'onepassword.token'), link);
        assert.throws(() => readToken(link), (e) => e.status === 500 && /regular file/.test(e.message));
        assert.throws(() => createOnePasswordProvider({ vault: 'v', secretsDir: s.dir, token_file: '../x' }), /plain file name/);
        assert.throws(() => createOnePasswordProvider({ vault: 'v', secretsDir: 'relative' }), /absolute/);
    } finally { s.done(); }
    const open = secretsDir(TOKEN, 0o640);
    try { assert.throws(() => readToken(join(open.dir, 'onepassword.token')), /owner only/); } finally { open.done(); }
    const bad = secretsDir('not-a-token-SECRETVALUE');
    try { assert.throws(() => readToken(join(bad.dir, 'onepassword.token')), (e) => !e.message.includes('SECRETVALUE') && /does not hold/.test(e.message)); } finally { bad.done(); }
});

test('token: a sign-in failure message from the SDK is not passed on', async () => {
    const s = secretsDir();
    try {
        const p = createOnePasswordProvider({ vault: VAULT_TITLE, secretsDir: s.dir }, { createClient: async (t) => { throw new Error(`invalid service account token ${t}`); } });
        const e = await status(p.listItems());
        assert.equal(e.status, 502);
        assert.ok(!e.message.includes('ops_') && !e.message.includes(TOKEN));
        assert.equal(p.status().last_error, 'unavailable');
    } finally { s.done(); }
});

test('config: unknown keys and bad values fail closed', () => {
    const op = fakeOnePassword();
    for (const cfg of [{ vault: 'v', url: 'x' }, { vault: '' }, { vault: 'a'.repeat(300) }, { vault: 'a\nb' }, { vault: 'v', archive: 'yes' }, {}]) {
        assert.throws(() => createOnePasswordProvider(cfg, { client: op.client }), (e) => e.status === 500, JSON.stringify(cfg));
    }
});

test('vault: by exact title or id; missing or ambiguous is refused', async () => {
    const id1 = newId(), id2 = newId();
    const op = fakeOnePassword({ vaults: [{ id: id1, title: 'Twin' }, { id: id2, title: 'Twin' }], items: {} });
    const byId = createOnePasswordProvider({ vault: id2.toUpperCase() }, { client: op.client });
    assert.deepEqual(await byId.listItems(), []);
    assert.deepEqual(op.calls.filter((c) => c.name === 'items.list').map((c) => c.args[0]), [id2]);
    assert.equal((await status(createOnePasswordProvider({ vault: 'Twin' }, { client: op.client }).listItems())).status, 503);
    assert.equal((await status(createOnePasswordProvider({ vault: 'twin' }, { client: op.client }).listItems())).status, 503, 'title match is exact');
    assert.equal((await status(createOnePasswordProvider({ vault: 'Other' }, { client: op.client }).listItems())).status, 503);
});

test('list: logins only, getAll in batches, cached for the ttl', async () => {
    const op = fakeOnePassword();
    let t = 1_000_000;
    const p = createOnePasswordProvider({ vault: VAULT_TITLE }, { client: op.client, batchSize: 2, now: () => t });
    const items = await p.listItems({ trash: true });
    assert.ok(!items.some((i) => i.name === 'a-note'), 'a secure note is not a login');
    assert.equal(items.length, 5);
    const n = op.calls.length;
    assert.equal(op.calls.filter((c) => c.name === 'items.getAll').length, 3, '5 logins in batches of 2');
    assert.ok(op.calls.filter((c) => c.name === 'items.getAll').every((c) => c.args[1].length <= 2));
    await p.listItems(); t += 14_000; await p.listItems();
    assert.equal(op.calls.length, n, 'no SDK call inside the 15 s cache');
    t += 2_000; await p.listItems();
    assert.ok(op.calls.length > n);
    const never = items.find((i) => i.name === 'never-site');
    assert.deepEqual(never.uris.map((u) => u.match), ['never']);
});

test('trash is a tag: never items.delete, no archive unless configured', async () => {
    const op = fakeOnePassword();
    const p = createOnePasswordProvider({ vault: VAULT_TITLE }, { client: op.client });
    const id = op.byLabel('acme-portal');
    await p.trashLogin(id);
    assert.ok(op.store.get(id).item.tags.includes('happy-trashed'));
    assert.equal(op.store.get(id).state, 'active');
    await p.restoreLogin(id);
    assert.ok(!op.store.get(id).item.tags.includes('happy-trashed'));
    assert.ok(!op.calls.some((c) => /delete|archive/i.test(c.name)), 'no delete, no archive');
});

test('archive: true archives on remove; restore waits for a manual unarchive', async () => {
    const op = fakeOnePassword();
    const p = createOnePasswordProvider({ vault: VAULT_TITLE, archive: true }, { client: op.client });
    const id = op.byLabel('acme-portal');
    await p.trashLogin(id);
    assert.equal(op.store.get(id).state, 'archived');
    assert.equal((await p.listItems({ trash: true })).find((i) => i.id === id)?.trashed, true);
    assert.equal((await status(p.readItem(id))).status, 404);
    assert.equal((await status(p.restoreLogin(id))).status, 409);
    op.unarchive(id);
    await p.restoreLogin(id);
    assert.equal((await p.readItem(id)).id, id);
    assert.ok(!op.calls.some((c) => /delete/i.test(c.name)));
});

test('rate limit: cooldown that fails fast, doubles, shows in status, then clears', async () => {
    const op = fakeOnePassword();
    let t = 5_000_000;
    const p = createOnePasswordProvider({ vault: VAULT_TITLE }, { client: op.client, now: () => t });
    await p.sync();
    op.rateLimit(1);
    assert.equal((await status(p.sync({ force: true }))).status, 503);
    assert.equal(p.status().rate_limited_s, 5);
    assert.equal(p.status().last_error, 'rate_limited');
    const n = op.calls.length;
    assert.equal((await status(p.listItems({ force: true }))).status, 503);
    assert.equal(op.calls.length, n, 'no SDK call during the cooldown');
    t += 5_001;
    op.rateLimit(1);
    await status(p.sync({ force: true }));
    assert.equal(p.status().rate_limited_s, 10, 'the cooldown doubles');
    t += 10_001;
    await p.sync({ force: true });
    assert.equal(p.status().rate_limited_s, undefined);
    assert.equal(p.status().last_error, undefined);
    assert.doesNotThrow(() => p.status());
});

test('auth expiry drops the client and signs in again on the next call', async () => {
    const s = secretsDir();
    const op = fakeOnePassword();
    let signIns = 0;
    try {
        const p = createOnePasswordProvider({ vault: VAULT_TITLE, secretsDir: s.dir }, { createClient: async () => { signIns++; return op.client; } });
        await p.sync();
        op.expireAuth();
        assert.equal((await status(p.sync({ force: true }))).status, 503);
        assert.equal(p.status().unlocked, false);
        await p.sync({ force: true });
        assert.equal(signIns, 2);
    } finally { s.done(); }
});

test('errors carry no SDK message, id echo or value', async () => {
    const op = fakeOnePassword();
    const p = createOnePasswordProvider({ vault: VAULT_TITLE }, { client: op.client });
    const id = op.byLabel('acme-github');
    await p.sync();
    op.client.items.get = async (vid, iid) => { throw new Error(`item ${iid} in ${vid}: password gh-pass`); };
    const e = await status(p.readItem(id));
    assert.equal(e.status, 502);
    assert.ok(!e.message.includes(id) && !e.message.includes('gh-pass') && !e.message.includes(op.vaultId), e.message);
    for (const bad of [{ name: 'x', uris: ['javascript:alert(1)'] }, { name: 'x', uris: ['https://u:p@h.test'] }, { name: '' }, { name: 'x', password: 'p'.repeat(5000) }, { name: 'x', uris: Array(40).fill('https://a.test') }]) {
        const err = await status(p.createLogin(bad));
        assert.equal(err.status, 400, JSON.stringify(bad).slice(0, 60));
        assert.ok(!err.message.includes('alert') && !err.message.includes('u:p'));
    }
});

test('an item from another vault is refused, never mapped', async () => {
    const op = fakeOnePassword();
    const p = createOnePasswordProvider({ vault: VAULT_TITLE }, { client: op.client });
    const id = op.byLabel('acme-github');
    op.store.get(id).item.vaultId = op.vaultId; // list still sees it in our vault
    const getAll = op.client.items.getAll;
    op.client.items.getAll = async (...a) => { const r = await getAll(...a); for (const x of r.individualResponses) if (x.content?.id === id) x.content.vaultId = newId(); return r; };
    assert.equal((await status(p.listItems())).status, 502);
});

test('writes: create puts username and password in the built-in fields; update keeps a site\'s autofill behaviour', async () => {
    const op = fakeOnePassword();
    const p = createOnePasswordProvider({ vault: VAULT_TITLE }, { client: op.client });
    const id = await p.createLogin({ name: 'n', uris: ['https://a.test'], username: 'u', password: 'P-123' });
    const it = op.store.get(id).item;
    assert.equal(it.category, 'Login');
    assert.equal(it.vaultId, op.vaultId);
    assert.deepEqual(it.fields.map((f) => [f.id, f.fieldType, f.value]), [['username', 'Text', 'u'], ['password', 'Concealed', 'P-123']]);
    assert.deepEqual(it.websites, [{ url: 'https://a.test', label: 'website', autofillBehavior: 'AnywhereOnWebsite' }]);
    const gm = op.byLabel('gmail-host');
    await p.updateLogin(gm, { uris: ['https://mail.google.com', 'https://b.test'] });
    assert.deepEqual(op.store.get(gm).item.websites.map((w) => w.autofillBehavior), ['ExactDomain', 'AnywhereOnWebsite']);
    const note = op.byLabel('a-note');
    assert.equal((await status(p.readItem(note))).status, 404, 'a non-login is not reachable');
});

test('reads of guessed ids cost no SDK calls inside the cache', async () => {
    const op = fakeOnePassword();
    const p = createOnePasswordProvider({ vault: VAULT_TITLE }, { client: op.client });
    await p.sync();
    const n = op.calls.length;
    for (let i = 0; i < 20; i++) assert.equal((await status(p.readItem(newId()))).status, 404);
    assert.equal(op.calls.length, n);
});
