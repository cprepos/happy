// One suite for every vault provider: what lib/providers/index.mjs promises,
// checked the same way on each backend. A harness gives the suite a fresh
// provider over a fake vault and a fixture naming the seed logins:
//
//   harness() -> {provider, close(), fx: {
//       github:  {id, username, password, totp, hosts: [...]}   a login with a TOTP seed
//       portal:  {id, fields: {name: value}}                     hidden custom fields
//       trashed: {id}                                            already in the trash
//       hostMatch: {id, host}                                    a URI with host matching
//       otherId                                                  a well-formed id of no item
//       badId                                                    a string that is not an id
//   }}
//
// Values the suite reads must never appear in listItems or in an error message.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { create, register, types } from '../lib/providers/index.mjs';
import { currentTotp } from '../lib/totp.mjs';

const METHODS = ['checkId', 'status', 'sync', 'listItems', 'readItem', 'createLogin', 'updateLogin', 'trashLogin', 'restoreLogin', 'lock'];

async function rejects(p, status) {
    let e;
    try { await p; } catch (x) { e = x; }
    assert.ok(e, `expected a rejection with status ${status}`);
    assert.equal(e.status, status, `status of: ${e.message}`);
    return e;
}

export function providerConformance(label, harness) {
    const t = (name, fn) => test(`${label}: ${name}`, async () => {
        const h = await harness();
        try { await fn(h.provider, h.fx, h); } finally { await h.close?.(); }
    });

    t('has the contract\'s shape and passes the registry check', async (p) => {
        for (const m of METHODS) assert.equal(typeof p[m], 'function', m);
        assert.ok(['native', 'tag'].includes(p.capabilities.restore));
        for (const k of ['equivalentDomains', 'totp']) assert.equal(typeof p.capabilities[k], 'boolean', k);
        const type = `conf-${p.type}`.slice(0, 32);
        if (!types().includes(type)) register(type, () => ({ ...p, type }));
        assert.equal(create(type, {}).id, p.id);
    });

    t('status never throws and reports sync age', async (p) => {
        const s0 = p.status();
        assert.equal(typeof s0.unlocked, 'boolean');
        await p.sync();
        const s = p.status();
        assert.equal(s.unlocked, true);
        assert.equal(typeof s.sync_age_s, 'number');
        assert.ok(s.sync_age_s >= 0 && s.sync_age_s < 5);
    });

    t('checkId: canonical lower case, null for anything else', async (p, fx) => {
        assert.equal(p.checkId(fx.github.id), fx.github.id);
        assert.equal(p.checkId(fx.github.id.toUpperCase()), fx.github.id);
        for (const bad of [fx.badId, '', null, undefined, 42, {}, '../etc/passwd', `${fx.github.id}x`]) assert.equal(p.checkId(bad), null, String(bad));
        assert.match(fx.github.id, /^[A-Za-z0-9_-]{8,128}$/, 'ids fit policy.mjs ITEM_ID');
    });

    t('listItems: metadata only, sorted, trash hidden unless asked', async (p, fx) => {
        const items = await p.listItems();
        const ids = items.map((i) => i.id);
        assert.ok(ids.includes(fx.github.id) && ids.includes(fx.portal.id));
        assert.ok(!ids.includes(fx.trashed.id), 'trashed login hidden');
        const sorted = [...items].sort((a, b) => String(a.name ?? '').localeCompare(String(b.name ?? '')) || a.id.localeCompare(b.id));
        assert.deepEqual(ids, sorted.map((i) => i.id));
        const text = JSON.stringify(items, (k, v) => (v instanceof Map ? [...v] : v));
        for (const secret of [fx.github.password, fx.github.totp, ...Object.values(fx.portal.fields)]) assert.ok(!text.includes(secret), 'no secret value in a listing');
        const gh = items.find((i) => i.id === fx.github.id);
        assert.equal(gh.username, fx.github.username);
        assert.deepEqual(gh.has, { username: true, password: true, totp: true });
        for (const h of fx.github.hosts) assert.ok(gh.hosts.includes(h), h);
        for (const u of gh.uris) { assert.match(u.url, /^https?:\/\/[^/?#@]+(\/[^?#]*)?$/); assert.ok(['host', 'domain', 'exact', 'never'].includes(u.match)); }
        assert.equal(gh.trashed, false);
        assert.equal(typeof gh.shared, 'boolean');
        assert.ok(gh.revisionDate === null || !Number.isNaN(Date.parse(gh.revisionDate)));
        const portal = items.find((i) => i.id === fx.portal.id);
        for (const name of Object.keys(fx.portal.fields)) assert.deepEqual(portal.fields.find((f) => f.name === name), { name, hidden: true });
        const all = await p.listItems({ trash: true, force: true });
        const tr = all.find((i) => i.id === fx.trashed.id);
        assert.ok(tr, 'trash: true lists the trashed login');
        assert.equal(tr.trashed, true);
    });

    t('URI matching: host match reads as host', async (p, fx) => {
        const items = await p.listItems();
        const it = items.find((i) => i.id === fx.hostMatch.id);
        assert.ok(it.hosts.includes(fx.hostMatch.host));
        assert.ok(it.uris.some((u) => u.match === 'host'));
        const gh = await p.readItem(fx.github.id);
        assert.ok(gh.uris.every((u) => u.match === 'domain'), 'the default match is domain');
    });

    t('readItem: values, TOTP seed, custom fields', async (p, fx) => {
        const gh = await p.readItem(fx.github.id.toUpperCase());
        assert.equal(gh.id, fx.github.id);
        assert.equal(gh.username, fx.github.username);
        assert.equal(gh.password, fx.github.password);
        assert.equal(gh.totp, fx.github.totp);
        assert.match(await currentTotp(gh.totp), /^\d{6}$/, 'totp is a seed the filler can turn into a code');
        assert.ok(Array.isArray(gh.fields) && Array.isArray(gh.uris));
        const portal = await p.readItem(fx.portal.id);
        for (const [name, value] of Object.entries(fx.portal.fields)) assert.deepEqual(portal.fields.find((f) => f.name === name), { name, value, hidden: true });
    });

    t('readItem refuses trashed, unknown and malformed ids, with no value in the error', async (p, fx) => {
        await rejects(p.readItem(fx.trashed.id), 404);
        await rejects(p.readItem(fx.otherId), 404);
        let e;
        try { await p.readItem(fx.badId); } catch (x) { e = x; }
        assert.ok(e && [400, 404].includes(e.status), 'a malformed id is refused');
        assert.ok(!e.message.includes(fx.badId), 'the error does not echo the input');
    });

    t('createLogin then read it back; no value in the listing', async (p) => {
        const id = await p.createLogin({ name: 'conf-new', uris: ['https://new.example.test/login'], username: 'conf-user', password: 'Conf-Pass-123456' });
        assert.equal(p.checkId(id), id);
        const it = await p.readItem(id);
        assert.equal(it.name, 'conf-new');
        assert.equal(it.username, 'conf-user');
        assert.equal(it.password, 'Conf-Pass-123456');
        assert.deepEqual(it.uris.map((u) => u.url), ['https://new.example.test/login']);
        const listed = (await p.listItems()).find((i) => i.id === id);
        assert.ok(listed, 'a new login is listed at once (the write drops the cache)');
        assert.deepEqual(listed.hosts, ['new.example.test']);
        assert.ok(!JSON.stringify(listed).includes('Conf-Pass-123456'));
    });

    t('updateLogin changes only the named fields and returns their names', async (p, fx) => {
        assert.deepEqual(await p.updateLogin(fx.github.id, { password: 'Changed-Pass-987654' }), ['password']);
        let it = await p.readItem(fx.github.id);
        assert.equal(it.password, 'Changed-Pass-987654');
        assert.equal(it.username, fx.github.username);
        assert.equal(it.totp, fx.github.totp);
        const before = it.uris;
        assert.deepEqual((await p.updateLogin(fx.github.id, { name: 'renamed', username: 'new-user' })).sort(), ['name', 'username']);
        it = await p.readItem(fx.github.id);
        assert.equal(it.name, 'renamed');
        assert.equal(it.username, 'new-user');
        assert.deepEqual(it.uris, before, 'URIs kept, with their match');
        assert.deepEqual(await p.updateLogin(fx.github.id, { uris: [...before.map((u) => u.url), 'https://extra.example.test'] }), ['uris']);
        it = await p.readItem(fx.github.id);
        assert.deepEqual(it.uris.slice(0, before.length), before, 'an existing URI keeps its match');
        await rejects(p.updateLogin(fx.github.id, {}), 400);
        await rejects(p.updateLogin(fx.trashed.id, { name: 'x' }), 409);
        await rejects(p.updateLogin(fx.otherId, { name: 'x' }), 404);
    });

    t('trash and restore round trip; never twice', async (p, fx) => {
        await p.trashLogin(fx.portal.id);
        assert.ok(!(await p.listItems()).some((i) => i.id === fx.portal.id));
        await rejects(p.readItem(fx.portal.id), 404);
        await rejects(p.trashLogin(fx.portal.id), 409);
        assert.equal((await p.listItems({ trash: true })).find((i) => i.id === fx.portal.id)?.trashed, true);
        await p.restoreLogin(fx.portal.id);
        await rejects(p.restoreLogin(fx.portal.id), 409);
        const back = await p.readItem(fx.portal.id);
        for (const [name, value] of Object.entries(fx.portal.fields)) assert.equal(back.fields.find((f) => f.name === name)?.value, value, 'restore keeps the values');
        await p.restoreLogin(fx.trashed.id);
        assert.equal((await p.readItem(fx.trashed.id)).id, fx.trashed.id);
    });

    t('lock forgets the cache; the provider works again after', async (p, fx) => {
        await p.sync();
        p.lock();
        assert.equal(p.status().sync_age_s, null);
        assert.equal((await p.readItem(fx.github.id)).id, fx.github.id);
    });
}
