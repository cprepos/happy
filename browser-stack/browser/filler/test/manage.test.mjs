// The vault tools' server side (lib/manage.mjs) against the fake vault: every
// action, its permissions and refusals, that writes reach the fake vault as a
// Bitwarden client would make them, and that no value appears in any answer
// or audit line.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createManager } from '../lib/manage.mjs';
import { parsePolicy } from '../lib/policy.mjs';
import { decryptKey, decryptSymText } from '../lib/providers/vaultwarden/vaultcrypto.mjs';
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
        assert.deepEqual(Object.keys(gm).sort(), ['custom_fields', 'fields', 'hosts', 'id', 'name', 'revision_date', 'secret', 'trashed', 'uris', 'username']);
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

// Custom fields: names in list, values only through compare and pipe.
const CUSTOM_VALUES = ['Jira-Api-Token-Zq81xW', 'eu-west', 'Dup-Value-One-111', 'Dup-Value-Two-222', 'Portal-Token-7c1e9a', 'Portal-ApiKey-55d2', 'Shared-Org-Token-31'];
async function mkCustom(opts = {}) {
    const t = await setup();
    const p = managePolicy(t.v);
    // acme's portal secret lets its vault tools use the custom field "token" only (not "api-key").
    p.clients.acme.secrets.portal = { ...p.clients.acme.secrets.portal, custom_fields: ['token'] };
    p.clients.acme.manage.pipe = ['docker-login', 'sha'];
    const policy = parsePolicy(JSON.stringify(p));
    const m = createManager({ getPolicy: () => policy, vault: t.vault, audit: t.audit, ...opts });
    const auditText = () => readdirSync(join(t.dir, 'audit')).map((f) => readFileSync(join(t.dir, 'audit', f), 'utf8')).join('');
    const noValues = (obj) => { const s = JSON.stringify(obj); for (const x of CUSTOM_VALUES) assert.ok(!s.includes(x), `a custom value leaked: ${x}`); };
    return { ...t, m, policy, auditText, noValues };
}

test('custom fields: list and search show names only; explicit secrets only the names their policy lists', async () => {
    const t = await mkCustom();
    try {
        const all = await t.m.list({ chat: D });
        const jira = all.items.find((i) => i.name === 'jira');
        assert.deepEqual(jira.custom_fields, ['token', 'Region', 'enabled', 'dup', 'empty', 'broken']);
        assert.deepEqual(jira.fields, ['username', 'password']);
        assert.deepEqual(all.items.find((i) => i.name === 'gmail').custom_fields, []);
        t.noValues(all);
        t.noValues(await t.m.search({ chat: D, query: 'jira' }));
        const acme = await t.m.list({ chat: 'chat-acme' });
        assert.deepEqual(acme.items.find((i) => i.name === 'acme-portal').custom_fields, ['token']);
        assert.deepEqual(acme.items.find((i) => i.name === 'acme-github').custom_fields, []);
        t.noValues(acme);
        // Without custom_fields in its policy secret, an explicit client sees none.
        const t2 = await mk();
        try { assert.deepEqual((await t2.m.list({ chat: 'chat-acme' })).items.find((i) => i.name === 'acme-portal').custom_fields, []); } finally { await t2.close(); }
    } finally { await t.close(); }
});

test('custom fields: pipe and compare by exact name; unknown 404 lists names, duplicate 409, both or neither refused', async () => {
    const t = await mkCustom();
    try {
        const id = t.v.items.jira.id;
        const sha = (s) => createHash('sha256').update(s).digest('hex');
        const r = await t.m.pipe({ chat: D, id, custom_field: 'token', target: 'sha' });
        assert.deepEqual(r, { target: 'sha', argv: ['sha256sum'], value: 'Jira-Api-Token-Zq81xW' });
        assert.equal((await t.m.pipe({ chat: D, id, custom_field: 'enabled', target: 'sha' })).value, 'true');
        assert.deepEqual(await t.m.compare({ chat: D, id, custom_field: 'token', algo: 'sha256', digest: sha('Jira-Api-Token-Zq81xW') }), { match: true });
        assert.deepEqual(await t.m.compare({ chat: D, id, custom_field: 'Region', algo: 'sha256', digest: sha('eu-west') }), { match: true });
        assert.deepEqual(await t.m.compare({ chat: D, id, custom_field: 'token', algo: 'sha256', digest: sha('nope') }), { match: false });
        // Case-sensitive, exact: "Token" and "region" are unknown, and the refusal lists the names.
        await assert.rejects(t.m.pipe({ chat: D, id, custom_field: 'Token', target: 'sha' }), (e) => e.status === 404 && /"token", "Region", "enabled", "dup", "empty", "broken"/.test(e.message) && /case-sensitive/.test(e.message));
        await assert.rejects(t.m.compare({ chat: D, id, custom_field: 'region', algo: 'sha256', digest: sha('eu-west') }), (e) => e.status === 404);
        await assert.rejects(t.m.pipe({ chat: D, id, custom_field: 'linked-user', target: 'sha' }), (e) => e.status === 404, 'a linked field has no value');
        await assert.rejects(t.m.pipe({ chat: D, id, custom_field: 'dup', target: 'sha' }), (e) => e.status === 409 && e.outcome === 'refused_ambiguous');
        await assert.rejects(t.m.compare({ chat: D, id, custom_field: 'dup', algo: 'sha256', digest: sha('Dup-Value-One-111') }), (e) => e.status === 409);
        await assert.rejects(t.m.pipe({ chat: D, id, custom_field: 'empty', target: 'sha' }), (e) => e.status === 404 && /no custom field "empty" value/.test(e.message));
        await assert.rejects(t.m.pipe({ chat: D, id, custom_field: 'broken', target: 'sha' }), (e) => e.status === 404);
        // Exactly one of field and custom_field, and a well-formed name.
        await assert.rejects(t.m.pipe({ chat: D, id, field: 'password', custom_field: 'token', target: 'sha' }), (e) => e.status === 400 && /exactly one/.test(e.message));
        await assert.rejects(t.m.pipe({ chat: D, id, target: 'sha' }), /exactly one/);
        await assert.rejects(t.m.compare({ chat: D, id, field: 'password', custom_field: 'token', algo: 'sha256', digest: 'x' }), /exactly one/);
        for (const bad of ['', 'x'.repeat(65), 'to/ken', 'tok\nen', 42, null]) await assert.rejects(t.m.pipe({ chat: D, id, custom_field: bad, target: 'sha' }), (e) => e.status === 400, String(bad));
        // An org item is never reached; another client's custom field is not either.
        await assert.rejects(t.m.pipe({ chat: D, id: t.v.items['org-shared'].id, custom_field: 'token', target: 'sha' }), (e) => e.status === 404);
        await assert.rejects(t.m.pipe({ chat: 'chat-acme', id, custom_field: 'token', target: 'sha' }), (e) => e.status === 404);
        // acme's explicit secret lists "token" only.
        const portal = t.v.items['acme-portal'].id;
        assert.equal((await t.m.pipe({ chat: 'chat-acme', id: portal, custom_field: 'token', target: 'sha' })).value, 'Portal-Token-7c1e9a');
        await assert.rejects(t.m.pipe({ chat: 'chat-acme', id: portal, custom_field: 'api-key', target: 'sha' }), (e) => e.status === 404 && /its custom fields: "token"/.test(e.message));
        // {username} in argv still comes from the login.
        const dl = await t.m.pipe({ chat: 'chat-acme', id: portal, custom_field: 'token', target: 'docker-login', args: { registry: 'ghcr.io' } });
        assert.deepEqual(dl.argv, ['docker', 'login', '--username', 'acme-ops', '--password-stdin', 'ghcr.io']);
        // The audit names the custom field, never a value.
        const a = t.auditText();
        assert.ok(a.includes('"field_kind":"custom:token"') && a.includes('"field_kind":"custom:dup"') && a.includes('"target":"sha"'));
        for (const x of CUSTOM_VALUES) assert.ok(!a.includes(x) && !a.includes(sha(x)), x);
    } finally { await t.close(); }
});

test('custom fields: every value read is nulled once pipe or compare is done', async () => {
    const t0 = await setup();
    const recs = [];
    const vault = { ...t0.vault, readItem: async (id) => { const r = await t0.vault.readItem(id); recs.push(r); return r; } };
    const policy = parsePolicy(JSON.stringify(managePolicy(t0.v)));
    const m = createManager({ getPolicy: () => policy, vault, audit: t0.audit });
    try {
        const id = t0.v.items.jira.id;
        const r = await m.pipe({ chat: D, id, custom_field: 'token', target: 'sha' });
        assert.equal(r.value, 'Jira-Api-Token-Zq81xW', 'the answer keeps its own copy for the runner');
        await m.compare({ chat: D, id, custom_field: 'Region', algo: 'sha256', digest: 'a'.repeat(64) });
        await m.compare({ chat: D, id, field: 'password', algo: 'sha256', digest: 'a'.repeat(64) });
        await assert.rejects(m.pipe({ chat: D, id, custom_field: 'empty', target: 'sha' }), (e) => e.status === 404);
        assert.equal(recs.length, 4);
        for (const rec of recs) {
            assert.equal(rec.fields, null);
            assert.equal(rec.password, null);
            assert.equal(rec.totp, null);
        }
        assert.equal(recs[0].username, 'agent@jira.test', 'pipe keeps the username for argv');
        assert.equal(recs[1].username, null);
    } finally { await t0.close(); }
});

// Attachments: a file saved in the vault (save_download) piped as text, byte for byte,
// into any target the client may use; read in memory only, the Buffer zeroed after.
const PEM = '-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgPipeAttachmentCanary\n-----END PRIVATE KEY-----\n';
async function mkAttach(opts = {}) {
    const t0 = await setup();
    const reads = [];
    const vault = { ...t0.vault, readAttachment: async (...a) => { const b = await t0.vault.readAttachment(...a); reads.push(b); return b; } };
    const p = managePolicy(t0.v);
    p.clients.acme.manage.pipe = ['docker-login', 'sha'];
    const policy = parsePolicy(JSON.stringify(p));
    const m = createManager({ getPolicy: () => policy, vault, audit: t0.audit, ...opts });
    const auditText = () => readdirSync(join(t0.dir, 'audit')).map((f) => readFileSync(join(t0.dir, 'audit', f), 'utf8')).join('');
    const note = await t0.vault.createNote({ name: 'ASC key' });
    const att = await t0.vault.addAttachment(note, 'AuthKey_TEST.p8', Buffer.from(PEM));
    return { ...t0, m, policy, reads, auditText, note, att };
}

test('pipe attachment: a saved file on a note goes to any allowed target byte for byte; Buffer zeroed; audit names it', async () => {
    const t = await mkAttach();
    try {
        const listed = (await t.m.list({ chat: D })).items.find((i) => i.id === t.note);
        assert.deepEqual(listed.attachments.map((a) => a.id), [t.att]);
        const r = await t.m.pipe({ chat: D, id: t.note, attachment: t.att, target: 'sha' });
        assert.deepEqual(r, { target: 'sha', argv: ['sha256sum'], value: PEM }, 'exact bytes, trailing newline kept');
        assert.equal(t.reads.length, 1);
        assert.ok(t.reads[0].every((b) => b === 0), 'the decrypted Buffer is zeroed');
        // A BOM and CRLF are kept as they are.
        const crlf = await t.vault.addAttachment(t.note, 'crlf.txt', Buffer.from('﻿a\r\nb\r\n'));
        assert.equal((await t.m.pipe({ chat: D, id: t.note, attachment: crlf, target: 'sha' })).value, '﻿a\r\nb\r\n');
        // On a login too, and for an explicit client on its own listed login.
        const gh = t.v.items['acme-github'].id;
        const ghAtt = await t.vault.addAttachment(gh, 'acme.pem', Buffer.from('acme-attached-text'));
        assert.equal((await t.m.pipe({ chat: 'chat-acme', id: gh, attachment: ghAtt, target: 'sha' })).value, 'acme-attached-text');
        const a = t.auditText();
        assert.ok(a.includes(`"field_kind":"attachment:${t.att}"`) && a.includes('"target":"sha"'));
        assert.ok(!a.includes('PipeAttachmentCanary') && !a.includes('acme-attached-text'));
        assert.ok(t.reads.every((b) => b.every((x) => x === 0)), 'every Buffer read is zeroed');
    } finally { await t.close(); }
});

test('pipe attachment: refusals (wrong item, other client, shared, not text, too big, two sources, {username}, no attachments)', async () => {
    const t = await mkAttach();
    try {
        const gh = t.v.items['acme-github'].id;
        const ghAtt = await t.vault.addAttachment(gh, 'acme.pem', Buffer.from('acme-attached-text'));
        // The id must be on that item.
        await assert.rejects(t.m.pipe({ chat: D, id: t.v.items.gmail.id, attachment: t.att, target: 'sha' }), (e) => e.status === 404 && /no attachment with that id/.test(e.message));
        // Another client's item, and a shared item, are not reached at all.
        await assert.rejects(t.m.pipe({ chat: D, id: gh, attachment: ghAtt, target: 'sha' }), (e) => e.status === 404);
        await assert.rejects(t.m.pipe({ chat: 'chat-acme', id: t.note, attachment: t.att, target: 'sha' }), (e) => e.status === 404);
        await assert.rejects(t.m.pipe({ chat: D, id: t.v.items['org-shared'].id, attachment: t.att, target: 'sha' }), (e) => e.status === 404);
        // Not UTF-8 text: 422. Over 1 MiB (decrypted, and far over at download): 413.
        const bin = await t.vault.addAttachment(t.note, 'key.der', Buffer.from([0x30, 0x82, 0xff, 0xfe, 0x00, 0xc3]));
        await assert.rejects(t.m.pipe({ chat: D, id: t.note, attachment: bin, target: 'sha' }), (e) => e.status === 422 && /not text/.test(e.message));
        const big = await t.vault.addAttachment(t.note, 'big.txt', Buffer.alloc(1024 * 1024 + 1, 0x61));
        await assert.rejects(t.m.pipe({ chat: D, id: t.note, attachment: big, target: 'sha' }), (e) => e.status === 413 && e.outcome === 'refused_size');
        const huge = await t.vault.addAttachment(t.note, 'huge.txt', Buffer.alloc(1024 * 1024 + 64 * 1024, 0x61));
        await assert.rejects(t.m.pipe({ chat: D, id: t.note, attachment: huge, target: 'sha' }), (e) => e.status === 413);
        // Exactly one source; a well-formed id.
        await assert.rejects(t.m.pipe({ chat: D, id: t.note, field: 'password', attachment: t.att, target: 'sha' }), (e) => e.status === 400 && /exactly one of field.*custom_field.*attachment/.test(e.message));
        await assert.rejects(t.m.pipe({ chat: D, id: t.note, custom_field: 'token', attachment: t.att, target: 'sha' }), /exactly one/);
        await assert.rejects(t.m.pipe({ chat: D, id: t.note, target: 'sha' }), /exactly one/);
        for (const bad of ['', 'a/b', 'x'.repeat(65), 7, null]) await assert.rejects(t.m.pipe({ chat: D, id: t.note, attachment: bad, target: 'sha' }), (e) => e.status === 400, String(bad));
        // compare does not take an attachment.
        await assert.rejects(t.m.compare({ chat: D, id: t.note, attachment: t.att, algo: 'sha256', digest: 'ab' }), /unknown key "attachment"/);
        // A target that needs the login's username: 400, before anything is read.
        const before = t.reads.length;
        await assert.rejects(t.m.pipe({ chat: 'chat-acme', id: gh, attachment: ghAtt, target: 'docker-login', args: { registry: 'ghcr.io' } }), (e) => e.status === 400 && /username/.test(e.message));
        assert.equal(t.reads.length, before);
        assert.ok(t.reads.every((b) => b.every((x) => x === 0)), 'every Buffer read is zeroed, refusals too');
        // A vault with no attachments (1Password): 422.
        const op = createManager({ getPolicy: () => t.policy, vault: { ...t.vault, capabilities: { ...t.vault.capabilities, attach: false } }, audit: t.audit });
        await assert.rejects(op.pipe({ chat: D, id: t.v.items.gmail.id, attachment: t.att, target: 'sha' }), (e) => e.status === 422 && e.outcome === 'refused_unsupported');
    } finally { await t.close(); }
});

test('pipe writes nothing to disk: the temp dir is unchanged after field and attachment pipes', async () => {
    const tmp = mkdtempSync(join(tmpdir(), 'pipe-tmp-'));
    const t = await mkAttach();
    const old = process.env.TMPDIR;
    process.env.TMPDIR = tmp;
    try {
        assert.equal(tmpdir(), tmp);
        assert.equal((await t.m.pipe({ chat: D, id: t.v.items.gmail.id, field: 'password', target: 'sha' })).value, t.v.items.gmail.password);
        assert.equal((await t.m.pipe({ chat: D, id: t.note, attachment: t.att, target: 'sha' })).value, PEM);
        assert.deepEqual(readdirSync(tmp), [], 'nothing in the temp dir');
        // And no copy anywhere in the filler's own directory (audit, state).
        const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [readFileSync(join(d, e.name), 'latin1')]));
        for (const blob of walk(t.dir)) assert.ok(!blob.includes('PipeAttachmentCanary') && !blob.includes(t.v.items.gmail.password), 'no value on disk');
    } finally {
        if (old === undefined) delete process.env.TMPDIR; else process.env.TMPDIR = old;
        await t.close();
    }
});
