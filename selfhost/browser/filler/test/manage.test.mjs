// The vault tools' server side (lib/manage.mjs) against the fake vault: every
// action, its permissions and refusals, that writes reach the fake vault as a
// Bitwarden client would make them, and that no value appears in any answer
// or audit line.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createManager } from '../lib/manage.mjs';
import { parsePolicy } from '../lib/policy.mjs';
import { decryptKey, decryptSymText } from '../lib/vaultcrypto.mjs';
import { bcryptHash } from '../lib/hashes.mjs';
import { managePolicy, setup } from './helpers.mjs';

async function mk(opts = {}) {
    const t = await setup();
    const policy = parsePolicy(JSON.stringify(managePolicy(t.v)));
    const m = createManager({ getPolicy: () => policy, vault: t.vault, audit: t.audit, ...opts });
    const secrets = Object.values(t.v.items).flatMap((i) => [i.password, i.totp]).filter((x) => x && x.length > 3);
    const auditText = () => readdirSync(join(t.dir, 'audit')).map((f) => readFileSync(join(t.dir, 'audit', f), 'utf8')).join('');
    const noValues = (obj, extra = []) => {
        const s = JSON.stringify(obj);
        for (const x of [...secrets, ...extra]) assert.ok(!s.includes(x), 'a value leaked');
    };
    const stored = (id) => {
        const c = t.v.sync.ciphers.find((x) => x.id === id);
        const ik = c.key ? decryptKey(c.key, { symKey: t.v.userKey }) : t.v.userKey;
        return { c, dec: (s) => decryptSymText(s, ik), password: decryptSymText(c.login.password, ik) };
    };
    return { ...t, m, policy, noValues, auditText, stored };
}
const D = 'none'; // default_client: agent (all_items)

test('list: each client sees only the logins it reaches, as metadata', async () => {
    const t = await mk();
    try {
        const all = await t.m.list({ chat: D });
        assert.equal(all.client, 'agent');
        const names = all.items.map((i) => i.name);
        for (const n of ['gmail', 'unlisted', 'apple']) assert.ok(names.includes(n), n);
        for (const n of ['acme-github', 'globex-github', 'org-shared', 'acme-trashed']) assert.ok(!names.includes(n), n);
        const gm = all.items.find((i) => i.name === 'gmail');
        assert.deepEqual(Object.keys(gm).sort(), ['fields', 'hosts', 'id', 'name', 'revision_date', 'secret', 'trashed', 'uris', 'username']);
        assert.equal(gm.username, 'agent@gmail.test');
        assert.deepEqual(gm.fields, ['username', 'password']);
        t.noValues(all);
        const acme = await t.m.list({ chat: 'chat-acme' });
        assert.deepEqual(acme.items.map((i) => i.name).sort(), ['acme-github', 'acme-gitlab', 'acme-portal']);
        assert.deepEqual(acme.items.find((i) => i.name === 'acme-portal').fields, ['password']);
        t.noValues(acme);
        const s = await t.m.search({ chat: D, query: 'GMAIL' });
        assert.deepEqual(s.items.map((i) => i.name).sort(), ['gmail', 'gmail-host']);
        await assert.rejects(t.m.list({ chat: 'chat-unknown-but-default-ok', extra: 1 }), /unknown key/);
        await assert.rejects(t.m.search({ chat: D, query: '' }), /query must be/);
    } finally { await t.close(); }
});

test('create: the filler generates the password; it is stored encrypted, never returned', async () => {
    const t = await mk();
    try {
        const r = await t.m.create({ chat: D, name: 'Test Vault MCP', uris: ['https://example.com/login'], username: 'bot@example.com' });
        assert.equal(r.secret, 'test-vault-mcp');
        assert.equal(r.username, 'bot@example.com');
        assert.deepEqual(r.hosts, ['example.com']);
        const { c, password, dec } = t.stored(r.id);
        assert.equal(password.length, 32);
        assert.equal(dec(c.name), 'Test Vault MCP');
        assert.equal(c.organizationId, null);
        // Vaultwarden 1.37 refuses a cipher body without encryptedFor (the user id).
        const cw = t.vw.calls.writes.find((w) => w.op === 'create' && w.id === r.id);
        assert.equal(cw.body.encryptedFor, t.v.userId);
        assert.deepEqual(t.vw.calls.noClientVersion, [], 'every API call carries Bitwarden-Client-Version');
        t.noValues(r, [password]);
        const r2 = await t.m.create({ chat: D, name: 'Short one', uris: ['https://short.example'], username: 'u', password: { length: 20, classes: ['lower', 'digits'] } });
        assert.ok(/^[a-z0-9]{20}$/.test(t.stored(r2.id).password));
        // Refusals: a name that is already a fill name, http, a supplied value, extra keys, an explicit client.
        await assert.rejects(t.m.create({ chat: D, name: 'GMAIL', uris: ['https://x.example'], username: 'u' }), (e) => e.status === 409);
        await assert.rejects(t.m.create({ chat: D, name: 'n1', uris: ['http://x.example'], username: 'u' }), /https/);
        await assert.rejects(t.m.create({ chat: D, name: 'n1', uris: ['https://a:b@x.example'], username: 'u' }), /user name or password/);
        await assert.rejects(t.m.create({ chat: D, name: 'n1', uris: ['https://x.example'], username: 'u', password: 'hunter2hunter2hunter2' }), /object/);
        await assert.rejects(t.m.create({ chat: D, name: 'n1', uris: ['https://x.example'], username: 'u', totp: 'JBSWY3DPEHPK3PXP' }), /unknown key "totp"/);
        await assert.rejects(t.m.create({ chat: D, name: 'x'.repeat(101), uris: ['https://x.example'], username: 'u' }), /1\.\.100/);
        await assert.rejects(t.m.create({ chat: 'chat-acme', name: 'n1', uris: ['https://x.example'], username: 'u' }), (e) => e.status === 403 && e.outcome === 'refused_manage');
        const a = t.auditText();
        assert.ok(a.includes('"action":"create"') && a.includes(`"item_id":"${r.id}"`) && a.includes('"changed":"name,uris,username,password"'));
        assert.ok(!a.includes(password));
    } finally { await t.close(); }
});

test('update: renames, changes uris, rotates the password into history; refuses org items and collisions', async () => {
    const t = await mk();
    try {
        const id = t.v.items.unlisted.id;
        const oldEnc = t.stored(id).c.login.password;
        const r = await t.m.update({ chat: D, id, name: 'Unlisted renamed', uris: ['https://github.com', 'https://gist.github.com'], rotate_password: {} });
        assert.deepEqual(r.changed, ['name', 'uris', 'password']);
        assert.equal(r.name, 'Unlisted renamed');
        const after = t.stored(id);
        assert.notEqual(after.password, t.v.items.unlisted.password);
        assert.equal(after.password.length, 32);
        assert.equal(after.c.passwordHistory[0].password, oldEnc);
        assert.equal(after.dec(after.c.passwordHistory[0].password), t.v.items.unlisted.password);
        assert.equal(after.dec(after.c.login.username), 'boss');
        const w = t.vw.calls.writes.at(-1);
        assert.equal(w.op, 'update');
        assert.equal(w.body.lastKnownRevisionDate, '2026-01-01T00:00:00.000Z'); // the revision it was read at
        assert.equal(w.body.encryptedFor, t.v.userId);
        assert.equal(w.body.organizationId, null);
        t.noValues(r, [after.password]);
        await assert.rejects(t.m.update({ chat: D, id }), /at least one/);
        await assert.rejects(t.m.update({ chat: D, id, name: 'gmail' }), (e) => e.status === 409);
        await assert.rejects(t.m.update({ chat: D, id, password: 'x' }), /unknown key "password"/);
        // Another client's login, an org login, and a login no client reaches here.
        await assert.rejects(t.m.update({ chat: D, id: t.v.items['acme-github'].id, name: 'x' }), (e) => e.status === 404);
        await assert.rejects(t.m.update({ chat: 'chat-acme', id: t.v.items['gmail'].id, name: 'x' }), (e) => e.status === 404);
        // acme may update its own listed login (it keeps its policy name and hosts).
        const ra = await t.m.update({ chat: 'chat-acme', id: t.v.items['acme-portal'].id, username: 'acme-ops-2' });
        assert.deepEqual(ra.changed, ['username']);
        assert.ok(t.auditText().includes('"changed":"name,uris,password"'));
    } finally { await t.close(); }
});

test('remove is a soft delete to the trash, restore brings it back; nothing is ever purged', async () => {
    const t = await mk();
    try {
        const id = t.v.items.apple.id;
        assert.deepEqual(await t.m.remove({ chat: D, id }), { id, trashed: true, note: 'moved to the vault trash; vault_restore brings it back' });
        assert.ok(!(await t.m.list({ chat: D })).items.some((i) => i.id === id));
        const trash = await t.m.list({ chat: D, include_trash: true });
        assert.equal(trash.items.find((i) => i.id === id).trashed, true);
        await assert.rejects(t.m.remove({ chat: D, id }), (e) => e.status === 404);
        const r = await t.m.restore({ chat: D, id });
        assert.equal(r.trashed, false);
        await assert.rejects(t.m.restore({ chat: D, id }), (e) => e.status === 409);
        assert.deepEqual(t.vw.calls.writes.map((w) => w.op), ['trash', 'restore']);
        assert.deepEqual(t.vw.calls.refusedWrites, []);
        assert.deepEqual(t.vw.calls.noClientVersion, []);
        assert.ok(t.v.sync.ciphers.some((c) => c.id === id));
        // acme has no remove permission.
        await assert.rejects(t.m.remove({ chat: 'chat-acme', id: t.v.items['acme-github'].id }), (e) => e.outcome === 'refused_manage');
    } finally { await t.close(); }
});

test('compare: match or no match only, every algo, rate limited, within the client', async () => {
    let clock = 1_000_000;
    const t = await mk({ now: () => clock });
    try {
        const id = t.v.items.gmail.id; const pw = t.v.items.gmail.password;
        const sha = (s) => createHash('sha256').update(s).digest('hex');
        assert.deepEqual(await t.m.compare({ chat: D, id, field: 'password', algo: 'sha256', digest: sha(pw) }), { match: true });
        assert.deepEqual(await t.m.compare({ chat: D, id, field: 'password', algo: 'sha256', digest: sha('wrong') }), { match: false });
        assert.deepEqual(await t.m.compare({ chat: D, id, field: 'password', algo: 'sha256', digest: sha(`s1${pw}`), salt: 's1' }), { match: true });
        assert.deepEqual(await t.m.compare({ chat: D, id, field: 'username', algo: 'sha512', digest: createHash('sha512').update('agent@gmail.test').digest('hex') }), { match: true });
        assert.deepEqual(await t.m.compare({ chat: D, id, field: 'password', algo: 'bcrypt', digest: bcryptHash(pw, '$2b$04$abcdefghijklmnopqrstuu') }), { match: true });
        await assert.rejects(t.m.compare({ chat: D, id, field: 'totp', algo: 'sha256', digest: sha('x') }), (e) => e.status === 404);
        await assert.rejects(t.m.compare({ chat: D, id, field: 'password', algo: 'md5', digest: 'x' }), /algo/);
        await assert.rejects(t.m.compare({ chat: 'chat-acme', id, field: 'password', algo: 'sha256', digest: sha(pw) }), (e) => e.status === 404);
        // acme's portal item lists only the password field.
        await assert.rejects(t.m.compare({ chat: 'chat-acme', id: t.v.items['acme-portal'].id, field: 'username', algo: 'sha256', digest: sha('acme-ops') }), (e) => e.status === 404);
        for (let i = 0; i < 15; i++) await t.m.compare({ chat: D, id, field: 'password', algo: 'sha256', digest: sha(`g${i}`) });
        await assert.rejects(t.m.compare({ chat: D, id, field: 'password', algo: 'sha256', digest: sha(pw) }), (e) => e.status === 429);
        clock += 11 * 60_000;
        assert.deepEqual(await t.m.compare({ chat: D, id, field: 'password', algo: 'sha256', digest: sha(pw) }), { match: true });
        const a = t.auditText();
        assert.ok(a.includes('"action":"compare"') && a.includes('"algo":"sha256"') && a.includes('"field_kind":"password"'));
        assert.ok(!a.includes(pw) && !a.includes(sha(pw)));
    } finally { await t.close(); }
});

test('pipe: only allowlisted targets and args; the value comes back only for the runner', async () => {
    const t = await mk();
    try {
        const id = t.v.items['acme-github'].id;
        const r = await t.m.pipe({ chat: 'chat-acme', id, field: 'password', target: 'docker-login', args: { registry: 'ghcr.io' } });
        assert.deepEqual(r.argv, ['docker', 'login', '--username', 'acme-bot@example.com', '--password-stdin', 'ghcr.io']);
        assert.equal(r.value, t.v.items['acme-github'].password);
        assert.ok(!r.argv.includes(r.value));
        await assert.rejects(t.m.pipe({ chat: 'chat-acme', id, field: 'password', target: 'sha' }), (e) => e.outcome === 'refused_target');
        await assert.rejects(t.m.pipe({ chat: 'chat-acme', id, field: 'password', target: 'docker-login', args: { registry: 'ghcr.io; id' } }), /does not match/);
        await assert.rejects(t.m.pipe({ chat: 'chat-acme', id, field: 'password', target: 'docker-login', args: {} }), /takes args/);
        await assert.rejects(t.m.pipe({ chat: 'chat-acme', id, field: 'password', target: 'docker-login', args: { registry: 'ghcr.io', extra: 'x' } }), /takes args/);
        await assert.rejects(t.m.pipe({ chat: 'chat-acme', id, field: 'password', target: 'docker-login', args: { registry: 'ghcr.io' }, argv: ['sh'] }), /unknown key/);
        const s = await t.m.pipe({ chat: D, id: t.v.items.gmail.id, field: 'password', target: 'sha' });
        assert.deepEqual(s.argv, ['sha256sum']);
        assert.ok(!t.auditText().includes(t.v.items['acme-github'].password));
        assert.ok(t.auditText().includes('"target":"docker-login"'));
    } finally { await t.close(); }
});
