import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFiller, kindsOf } from '../lib/fill.mjs';
import { parseTotp, totpAt } from '../lib/totp.mjs';
import { TOTP_SECRET } from './fake-vaultwarden.mjs';
import { loginPages } from './fake-controller.mjs';
import { parsePolicy, NO_CHAT } from '../lib/policy.mjs';
import { policyFor, setup } from './helpers.mjs';
import { createVault } from '../lib/providers/vaultwarden/vault.mjs';

const auditText = (dir) => readdirSync(join(dir, 'audit')).map((f) => readFileSync(join(dir, 'audit', f), 'utf8')).join('');

test('field kinds come from tag, type and label', () => {
    assert.deepEqual(kindsOf({ tag: 'input', type: 'password' }), ['password']);
    assert.deepEqual(kindsOf({ tag: 'input', type: 'email', label: 'Email' }), ['username']);
    assert.deepEqual(kindsOf({ tag: 'input', type: null, label: 'Authentication code' }), ['totp', 'username']);
    assert.deepEqual(kindsOf({ tag: 'input', type: 'number', label: '2FA code' }), ['totp']);
    assert.deepEqual(kindsOf({ tag: 'input', type: 'search', label: 'Search' }), []);
    assert.deepEqual(kindsOf({ tag: 'textarea', type: null, label: 'Comment' }), []);
    assert.deepEqual(kindsOf({ tag: 'input', type: 'hidden' }), []);
});

test('fill types the password into a password field on an allowed host, and nothing comes back', async () => {
    const t = await setup();
    try {
        const f = createFiller(t.deps);
        t.ctl.addSession('s1', loginPages());
        const r = await f.fill({ chat: 'chat-acme', session_id: 's1', element_id: 'p1', name: 'github.password' });
        assert.deepEqual(r, { ok: true, kind: 'password', host: 'github.com' });
        assert.equal(t.ctl.typed.length, 1);
        assert.equal(t.ctl.typed[0].text, t.v.items['acme-github'].password);
        assert.equal(t.ctl.typed[0].sensitive, true);
        assert.ok(!JSON.stringify(r).includes(t.v.items['acme-github'].password));
        // Tainted, password only: images still allowed.
        assert.deepEqual([!!t.taint.get(t.key('s1')), t.taint.get(t.key('s1')).drop_images], [true, false]);
        const scrubbed = t.scrubber.scrub({ text: `ocr: ${t.v.items['acme-github'].password}` });
        assert.equal(scrubbed.text, 'ocr: [secret:github.password]');
        // Usernames taint with drop_images.
        await f.fill({ chat: 'chat-acme', session_id: 's1', element_id: 'u1', name: 'github.username' });
        assert.equal(t.taint.get(t.key('s1')).drop_images, true);
        const audit = auditText(t.dir);
        assert.match(audit, /"outcome":"filled"/);
        assert.ok(!audit.includes(t.v.items['acme-github'].password) && !audit.includes('acme-bot@example.com'));
        const state = readFileSync(join(t.dir, 'state', 'taint.json'), 'utf8');
        assert.ok(!state.includes(t.v.items['acme-github'].password));
    } finally { await t.close(); }
});

test('refusals: unbound chat, wrong name, wrong host, wrong field kind, wrong element, other client', async () => {
    const t = await setup();
    try {
        const f = createFiller(t.deps);
        t.ctl.addSession('s1', loginPages());
        t.ctl.addSession('evil', loginPages('https://github.com.evil.test'));
        t.ctl.addSession('http', loginPages('http://github.com'));
        t.ctl.addSession('closed', loginPages(), 'closed');
        const base = { chat: 'chat-acme', session_id: 's1', element_id: 'p1', name: 'github.password' };
        const cases = [
            [{ ...base, chat: 'chat-unknown' }, /not bound/],
            [{ ...base, name: 'github.secret' }, /no such secret/],
            [{ ...base, name: 'gitlab.password' }, /no such secret/],
            [{ ...base, name: 'portal.username' }, /no such secret/], // field not in the policy
            [{ ...base, session_id: 'evil' }, /on https:\/\/github\.com\.evil\.test, which is not a host this secret is allowed on \(allowed: https:\/\/github\.com\)/],
            [{ ...base, session_id: 'http' }, /on http:\/\/github\.com, which is not a host.*only https pages can be filled/],
            [{ ...base, session_id: 'closed' }, /not active/],
            [{ ...base, session_id: 'nope' }, /no such browser session/],
            [{ ...base, element_id: 'u1' }, /cannot take a password/],
            [{ ...base, element_id: 'b1' }, /cannot take a password/],
            [{ ...base, element_id: 'zz' }, /element not found/],
            [{ ...base, name: 'foreign.password' }, /no key for this item's organization/],
            // Items in the same vault that the client does not list cannot be named.
            [{ ...base, name: 'unlisted.password' }, /no such secret/],
            [{ ...base, name: 'mismatch.password' }, /no host that both/],
            [{ ...base, name: 'portal.password' }, /which is not a host this secret is allowed on/],
        ];
        for (const [args, re] of cases) await assert.rejects(f.fill(args), re, JSON.stringify(args));
        assert.equal(t.ctl.typed.length, 0, 'nothing was typed');
        // A session holding acme secrets refuses a globex chat, and another acme chat.
        await f.fill(base);
        await assert.rejects(f.fill({ ...base, chat: 'chat-globex' }), /another chat or client/);
        await assert.rejects(f.fill({ ...base, chat: 'chat-acme-2' }), /another chat or client/);
        assert.equal(t.ctl.typed.length, 1);
        assert.match(auditText(t.dir), /refused_binding/);
    } finally { await t.close(); }
});

test('a page that leaves the host while typing is an error and stays tainted', async () => {
    const t = await setup();
    try {
        const f = createFiller(t.deps);
        t.ctl.addSession('s1', [...loginPages().slice(0, 1), { url: 'https://evil.test/', interactables: [] }]);
        t.ctl.hooks.afterType = (s) => { s.at = 1; };
        await assert.rejects(f.fill({ chat: 'chat-acme', session_id: 's1', element_id: 'p1', name: 'github.password' }), /left the allowed host/);
        assert.ok(t.taint.get(t.key('s1')));
        assert.match(auditText(t.dir), /host_changed/);
    } finally { await t.close(); }
});

test('login: username, password, Enter, then the TOTP page', async () => {
    const t = await setup();
    try {
        let now = 1_700_000_000_000;
        const f = createFiller({ ...t.deps, totpOpts: { now: () => now, minLeftS: 0 } });
        t.ctl.addSession('s1', loginPages());
        const r = await f.login({ chat: 'chat-acme', session_id: 's1', site: 'github' });
        assert.deepEqual(r, { status: 'totp_submitted', host: 'github.com' });
        const code = totpAt(parseTotp(TOTP_SECRET), now / 1000);
        assert.deepEqual(t.ctl.typed.map((x) => [x.element_id, x.text]), [['u1', 'acme-bot@example.com'], ['p1', t.v.items['acme-github'].password], ['t1', code]]);
        assert.deepEqual(t.ctl.pressed.map((x) => x.key), ['Enter', 'Enter']);
        assert.equal(t.taint.get(t.key('s1')).drop_images, true);
        assert.equal(t.scrubber.scrubString(`code ${code}`), 'code [secret:github.totp]');
    } finally { await t.close(); }
});

test('login: username-first pages, sites without TOTP, and pages with nothing to fill', async () => {
    const t = await setup();
    try {
        const f = createFiller(t.deps);
        t.ctl.addSession('two-step', [
            { url: 'https://github.com/login', interactables: [{ element_id: 'u', tag: 'input', type: 'text', label: 'Email' }] },
            { url: 'https://github.com/password', interactables: [{ element_id: 'p', tag: 'input', type: 'password', label: 'Password' }] },
            { url: 'https://github.com/home', interactables: [] },
        ]);
        assert.equal((await f.login({ chat: 'chat-acme', session_id: 'two-step', site: 'github' })).status, 'submitted');
        assert.deepEqual(t.ctl.typed.map((x) => x.element_id), ['u', 'p']);
        t.ctl.addSession('empty', [{ url: 'https://github.com/', interactables: [{ element_id: 'q', tag: 'input', type: 'search', label: 'Search' }] }]);
        assert.equal((await f.login({ chat: 'chat-acme', session_id: 'empty', site: 'github' })).status, 'needs_human');
        t.ctl.addSession('off', loginPages('https://example.test'));
        await assert.rejects(f.login({ chat: 'chat-acme', session_id: 'off', site: 'github' }), (err) => {
            // Names the page's host and the login's hosts, so the user can be told which URI to add; no value.
            assert.equal(err.outcome, 'refused_host');
            assert.match(err.message, /the page is on https:\/\/example\.test, which is not a host this login is allowed on \(allowed: https:\/\/github\.com\)/);
            assert.match(err.message, /add https:\/\/example\.test as a URI on the vault item/);
            for (const v of [t.v.items['acme-github'].password, 'acme-bot@example.com', TOTP_SECRET]) assert.ok(!err.message.includes(v));
            return true;
        });
        assert.ok(auditLines(t.dir).some((l) => l.outcome === 'refused_host' && l.name === 'github' && l.host === 'example.test'));
        await assert.rejects(f.login({ chat: 'chat-acme', session_id: 'off', site: 'nope' }), /no such site/);
        // globex: password and totp only (no username field allowed).
        t.ctl.addSession('g', loginPages());
        const r = await f.login({ chat: 'chat-globex', session_id: 'g', site: 'github' });
        assert.equal(r.status, 'totp_submitted');
        assert.deepEqual(t.ctl.typed.filter((x) => x.session === 'g').map((x) => x.element_id), ['p1', 't1']);
        assert.equal(t.ctl.typed.find((x) => x.session === 'g' && x.element_id === 't1').text.length, 8);
    } finally { await t.close(); }
});

test('list returns names, hosts and kinds for the chat\'s client only', async () => {
    const t = await setup();
    try {
        const f = createFiller(t.deps);
        const r = await f.list({ chat: 'chat-globex' });
        assert.equal(r.client, 'globex');
        assert.deepEqual(r.secrets.map((s) => s.name), ['github.password', 'github.totp']);
        assert.ok(!JSON.stringify(r).includes(t.v.items['globex-github'].id));
        await assert.rejects(f.list({ chat: 'x' }), /not bound/);
        // Only listed controller ports are reached.
        await assert.rejects(f.fill({ chat: 'chat-acme', session_id: 's1', element_id: 'p1', name: 'github.password', controller_port: 22 }), /not one the filler may use/);
        await assert.rejects(f.fill({ chat: 'chat-acme', session_id: 's1', element_id: 'p1', name: 'github.password', controller_port: '8010' }), /not one the filler may use/);
    } finally { await t.close(); }
});

const auditLines = (dir) => auditText(dir).trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));

test('default_client: an unmapped chat and a caller with no chat id fill the default client\'s secrets; the audit says default', async () => {
    const t = await setup();
    try {
        const policy = parsePolicy(policyFor(t.v, { default_client: 'acme' }));
        const f = createFiller({ ...t.deps, getPolicy: () => policy });
        t.ctl.addSession('s1', loginPages());
        t.ctl.addSession('s2', loginPages());
        assert.equal((await f.list({ chat: 'chat-unknown' })).client, 'acme');
        assert.equal((await f.list({ chat: NO_CHAT })).client, 'acme');
        assert.deepEqual(await f.fill({ chat: 'chat-unknown', session_id: 's1', element_id: 'p1', name: 'github.password' }), { ok: true, kind: 'password', host: 'github.com' });
        assert.deepEqual(await f.fill({ chat: NO_CHAT, session_id: 's2', element_id: 'p1', name: 'github.password' }), { ok: true, kind: 'password', host: 'github.com' });
        assert.equal(t.ctl.typed[0].text, t.v.items['acme-github'].password);
        const filled = auditLines(t.dir).filter((l) => l.outcome === 'filled');
        assert.deepEqual(filled.map((l) => [l.chat, l.client, l.path]), [['chat-unknown', 'acme', 'default'], [NO_CHAT, 'acme', 'default']]);
        assert.ok(!auditText(t.dir).includes(t.v.items['acme-github'].password));
        // Taint and the session binding work as before: the session holds a default-path secret for chat-unknown.
        assert.ok(t.taint.get(t.key('s1')));
        await assert.rejects(f.fill({ chat: 'chat-other', session_id: 's1', element_id: 'p1', name: 'github.password' }), /another chat or client/);
    } finally { await t.close(); }
});

test('default_client: a mapped chat keeps its own client, and the audit says mapped', async () => {
    const t = await setup();
    try {
        const policy = parsePolicy(policyFor(t.v, { default_client: 'acme' }));
        const f = createFiller({ ...t.deps, getPolicy: () => policy });
        t.ctl.addSession('g', loginPages());
        assert.equal((await f.list({ chat: 'chat-globex' })).client, 'globex');
        // globex allows no username, though the default client (acme) would.
        await assert.rejects(f.fill({ chat: 'chat-globex', session_id: 'g', element_id: 'u1', name: 'github.username' }), /no such secret/);
        await f.fill({ chat: 'chat-globex', session_id: 'g', element_id: 'p1', name: 'github.password' });
        assert.equal(t.ctl.typed[0].text, t.v.items['globex-github'].password);
        const lines = auditLines(t.dir);
        assert.deepEqual(lines.map((l) => [l.client, l.path, l.outcome]), [['globex', 'mapped', 'refused_name'], ['globex', 'mapped', 'filled']]);
    } finally { await t.close(); }
});

test('a caller with no chat id is refused without default_client', async () => {
    const t = await setup();
    try {
        const f = createFiller(t.deps);
        t.ctl.addSession('s1', loginPages());
        await assert.rejects(f.list({ chat: NO_CHAT }), /no chat id, and the filler policy has no default_client/);
        await assert.rejects(f.fill({ chat: NO_CHAT, session_id: 's1', element_id: 'p1', name: 'github.password' }), /no default_client/);
        await assert.rejects(f.login({ chat: NO_CHAT, session_id: 's1', site: 'github' }), /no default_client/);
        assert.equal(t.ctl.typed.length, 0);
    } finally { await t.close(); }
});

test('default_client: host, field and element restrictions still hold', async () => {
    const t = await setup();
    try {
        const policy = parsePolicy(policyFor(t.v, { default_client: 'acme' }));
        const f = createFiller({ ...t.deps, getPolicy: () => policy });
        t.ctl.addSession('s1', loginPages());
        t.ctl.addSession('evil', loginPages('https://github.com.evil.test'));
        t.ctl.addSession('http', loginPages('http://github.com'));
        t.ctl.addSession('off', loginPages('https://example.test'));
        for (const chat of [NO_CHAT, 'chat-unknown']) {
            const base = { chat, session_id: 's1', element_id: 'p1', name: 'github.password' };
            for (const [args, re] of [
                [{ ...base, session_id: 'evil' }, /which is not a host this secret is allowed on/],
                [{ ...base, session_id: 'http' }, /which is not a host this secret is allowed on/],
                [{ ...base, name: 'portal.password' }, /which is not a host this secret is allowed on/],
                [{ ...base, name: 'mismatch.password' }, /no host that both/],
                [{ ...base, element_id: 'u1' }, /cannot take a password/],
                [{ ...base, name: 'github.secret' }, /no such secret/],
            ]) await assert.rejects(f.fill(args), re, JSON.stringify(args));
            await assert.rejects(f.login({ chat, session_id: 'off', site: 'github' }), /on https:\/\/example\.test.*allowed: https:\/\/github\.com/);
        }
        assert.equal(t.ctl.typed.length, 0, 'nothing was typed');
        assert.ok(auditLines(t.dir).filter((l) => l.outcome === 'refused_host').every((l) => l.path === 'default'));
    } finally { await t.close(); }
});

const ALL = { version: 1, default_client: 'agent', clients: { agent: { all_items: true, secrets: {} } }, chats: {} };

test('all_items: a vault login is filled by its name, on the hosts of its own URIs', async () => {
    const t = await setup();
    try {
        const policy = parsePolicy(ALL);
        const f = createFiller({ ...t.deps, getPolicy: () => policy });
        const names = (await f.list({ chat: NO_CHAT })).secrets.map((x) => x.name);
        for (const n of ['acme-github.username', 'acme-github.password', 'acme-github.totp', 'acme-portal.password', 'globex-github.totp', 'unlisted.password']) assert.ok(names.includes(n), n);
        assert.ok(!names.includes('acme-portal.totp'), 'only the fields the item has are listed');
        for (const gone of ['acme-trashed', 'acme-note', 'org-shared', 'org-foreign']) assert.ok(!names.some((n) => n.startsWith(`${gone}.`)), gone);
        assert.deepEqual((await f.list({ chat: NO_CHAT })).secrets.find((x) => x.name === 'acme-github.password').hosts, ['github.com', 'www.github.com']);
        t.ctl.addSession('s1', loginPages());
        t.ctl.addSession('www', loginPages('https://www.github.com'));
        assert.deepEqual(await f.fill({ chat: NO_CHAT, session_id: 's1', element_id: 'p1', name: 'acme-github.password' }), { ok: true, kind: 'password', host: 'github.com' });
        assert.deepEqual(await f.fill({ chat: 'chat-anything', session_id: 'www', element_id: 'p1', name: 'acme-github.password' }), { ok: true, kind: 'password', host: 'www.github.com' });
        assert.deepEqual(t.ctl.typed.map((x) => x.text), [t.v.items['acme-github'].password, t.v.items['acme-github'].password]);
        t.ctl.addSession('login', loginPages());
        assert.equal((await f.login({ chat: NO_CHAT, session_id: 'login', site: 'acme-github' })).status, 'totp_submitted');
        assert.ok(t.taint.get(t.key('s1')));
        assert.ok(!auditText(t.dir).includes(t.v.items['acme-github'].password));
    } finally { await t.close(); }
});

test('all_items: a wrong host and a login without URIs are refused', async () => {
    const t = await setup();
    try {
        t.v.addLogin('no-uris', { username: 'nobody', password: 'NoUris-Pass-0001', uris: [] });
        t.v.addLogin('http-only', { username: 'nobody', password: 'HttpOnly-Pass-0002', uris: ['http://plain.example.test/login'] });
        const policy = parsePolicy(ALL);
        const f = createFiller({ ...t.deps, getPolicy: () => policy });
        const names = (await f.list({ chat: NO_CHAT })).secrets.map((x) => x.name);
        assert.ok(!names.some((n) => n.startsWith('no-uris.') || n.startsWith('http-only.')), 'unusable logins are not listed');
        t.ctl.addSession('s1', loginPages());
        t.ctl.addSession('gist', loginPages('https://gist.github.com'));
        t.ctl.addSession('evil', loginPages('https://github.com.evil.test'));
        t.ctl.addSession('plain', loginPages('http://plain.example.test'));
        const base = { chat: NO_CHAT, session_id: 's1', element_id: 'p1' };
        for (const [args, re] of [
            [{ ...base, name: 'no-uris.password' }, /no host that both/],
            [{ ...base, session_id: 'plain', name: 'http-only.password' }, /no host that both/],
            [{ ...base, name: 'acme-portal.password' }, /which is not a host this secret is allowed on/],
            [{ ...base, session_id: 'gist', name: 'acme-github.password' }, /which is not a host this secret is allowed on/],
            [{ ...base, session_id: 'evil', name: 'acme-github.password' }, /which is not a host this secret is allowed on/],
            [{ ...base, name: 'acme-github.notes' }, /no such secret/],
            [{ ...base, name: 'nothing-like-it.password' }, /no such secret/],
        ]) await assert.rejects(f.fill(args), re, JSON.stringify(args));
        await assert.rejects(f.login({ chat: NO_CHAT, session_id: 's1', site: 'no-uris' }), /no host that both/);
        assert.equal(t.ctl.typed.length, 0, 'nothing was typed');
        assert.match(auditText(t.dir), /refused_no_hosts/);
    } finally { await t.close(); }
});

test('all_items: a login added to the vault after start-up appears after the next sync', async () => {
    const t = await setup();
    try {
        let now = 1_700_000_000_000;
        const vault = createVault({ url: t.vw.url, clientId: t.v.clientId, clientSecret: t.v.clientSecret, userKey: t.v.userKey, deviceId: 'dev-late', now: () => now });
        const policy = parsePolicy(ALL);
        const f = createFiller({ ...t.deps, vault, getPolicy: () => policy });
        const has = async (n) => (await f.list({ chat: NO_CHAT })).secrets.some((x) => x.name === n);
        assert.equal(await has('late-login.password'), false);
        t.v.addLogin('Late Login', { username: 'late', password: 'Late-Login-Pass-77', uris: ['https://late.example.test/'] });
        now += 5_000;
        assert.equal(await has('late-login.password'), false, 'the cached sync is reused within its 15 s');
        now += 11_000;
        assert.equal(await has('late-login.password'), true, 'the next sync sees it; no restart');
        t.ctl.addSession('late', loginPages('https://late.example.test'));
        assert.deepEqual(await f.fill({ chat: NO_CHAT, session_id: 'late', element_id: 'p1', name: 'late-login.password' }), { ok: true, kind: 'password', host: 'late.example.test' });
        assert.equal(t.ctl.typed[0].text, 'Late-Login-Pass-77');
    } finally { await t.close(); }
});

test('all_items: explicit secrets take precedence, listed items keep their own limits, and duplicate names are refused', async () => {
    const t = await setup();
    try {
        const policy = parsePolicy({
            version: 1, default_client: 'agent', chats: { 'chat-acme': 'acme' },
            clients: {
                // "acme-github" is this client's own name for the portal item: it wins over the vault login of that name.
                agent: { all_items: true, secrets: { 'acme-github': { item_id: t.v.items['acme-portal'].id, hosts: ['portal.acme.test'], fields: ['password'] } } },
                acme: { secrets: { gh: { item_id: t.v.items['globex-github'].id, hosts: ['github.com'], fields: ['password'] } } },
            },
        });
        const f = createFiller({ ...t.deps, getPolicy: () => policy });
        const list = (await f.list({ chat: NO_CHAT })).secrets;
        const names = list.map((x) => x.name);
        assert.deepEqual(list.filter((x) => x.name.startsWith('acme-github.')), [{ name: 'acme-github.password', hosts: ['portal.acme.test'], kind: 'password' }]);
        assert.ok(!names.some((n) => n.startsWith('acme-portal.')), 'an item the client lists explicitly is not also listed by its vault name');
        assert.ok(!names.some((n) => n.startsWith('globex-github.')), 'an item another client lists is never reached through all_items');
        t.ctl.addSession('s1', loginPages());
        await assert.rejects(f.fill({ chat: NO_CHAT, session_id: 's1', element_id: 'u1', name: 'acme-github.username' }), /no such secret/);
        await assert.rejects(f.fill({ chat: NO_CHAT, session_id: 's1', element_id: 'p1', name: 'acme-github.password' }), /which is not a host this secret is allowed on/);
        await assert.rejects(f.fill({ chat: NO_CHAT, session_id: 's1', element_id: 'p1', name: 'globex-github.password' }), /no such secret/);
        // A mapped chat of a client without all_items sees only its own list.
        assert.deepEqual((await f.list({ chat: 'chat-acme' })).secrets.map((x) => x.name), ['gh.password']);
        // Two vault logins with one name: neither is usable.
        t.v.addLogin('Unlisted', { username: 'twin', password: 'Twin-Pass-0003', uris: ['https://github.com'] });
        await t.vault.sync({ force: true });
        assert.ok(!(await f.list({ chat: NO_CHAT })).secrets.some((x) => x.name.startsWith('unlisted.')));
        await assert.rejects(f.fill({ chat: NO_CHAT, session_id: 's1', element_id: 'p1', name: 'unlisted.password' }), /two vault logins are named "unlisted"/);
        assert.match(auditText(t.dir), /refused_ambiguous/);
        assert.equal(t.ctl.typed.length, 0);
    } finally { await t.close(); }
});


test('equivalent domains: an all_items login for www.gmail.com fills on accounts.google.com, and the audit says so', async () => {
    const t = await setup();
    try {
        const policy = parsePolicy(ALL);
        const f = createFiller({ ...t.deps, getPolicy: () => policy });
        const list = (await f.list({ chat: NO_CHAT })).secrets;
        assert.deepEqual(list.find((x) => x.name === 'gmail.password'), { name: 'gmail.password', hosts: ['www.gmail.com'], kind: 'password', equivalents: '+ google.com, youtube.com equivalents' });
        assert.equal(list.find((x) => x.name === 'acme-github.password').equivalents, undefined, 'no group, no label');
        t.ctl.addSession('acc', loginPages('https://accounts.google.com'));
        t.ctl.addSession('yt', loginPages('https://www.youtube.com'));
        t.ctl.addSession('mail', loginPages('https://mail.gmail.com'));
        t.ctl.addSession('www', loginPages('https://www.gmail.com'));
        assert.deepEqual(await f.fill({ chat: NO_CHAT, session_id: 'acc', element_id: 'p1', name: 'gmail.password' }), { ok: true, kind: 'password', host: 'accounts.google.com', equivalent_of: 'www.gmail.com' });
        assert.deepEqual(await f.fill({ chat: NO_CHAT, session_id: 'yt', element_id: 'p1', name: 'gmail.password' }), { ok: true, kind: 'password', host: 'www.youtube.com', equivalent_of: 'www.gmail.com' });
        assert.deepEqual(await f.fill({ chat: NO_CHAT, session_id: 'mail', element_id: 'p1', name: 'gmail.password' }), { ok: true, kind: 'password', host: 'mail.gmail.com', equivalent_of: 'www.gmail.com' });
        assert.deepEqual(await f.fill({ chat: NO_CHAT, session_id: 'www', element_id: 'p1', name: 'gmail.password' }), { ok: true, kind: 'password', host: 'www.gmail.com' }, 'an exact host is not marked as equivalence');
        assert.deepEqual(t.ctl.typed.map((x) => x.text), Array(4).fill(t.v.items.gmail.password));
        t.ctl.addSession('login', loginPages('https://accounts.google.com'));
        assert.equal((await f.login({ chat: NO_CHAT, session_id: 'login', site: 'gmail' })).status, 'submitted');
        const filled = auditLines(t.dir).filter((l) => l.outcome === 'filled');
        assert.deepEqual(filled.find((l) => l.host === 'accounts.google.com'), { ...filled.find((l) => l.host === 'accounts.google.com'), via: 'equivalent_domains', equivalent_of: 'www.gmail.com' });
        assert.ok(!('via' in filled.find((l) => l.host === 'www.gmail.com')));
        assert.ok(!auditText(t.dir).includes(t.v.items.gmail.password));
        // A custom group, through a multi-part public suffix.
        t.ctl.addSession('fooshop', loginPages('https://shop.foo-shop.com'));
        assert.equal((await f.fill({ chat: NO_CHAT, session_id: 'fooshop', element_id: 'p1', name: 'foo-uk.password' })).equivalent_of, 'www.foo.co.uk');
    } finally { await t.close(); }
});

test('equivalent domains: unrelated hosts, excluded groups, http, other co.uk sites and Host-match URIs are refused', async () => {
    const t = await setup();
    try {
        const policy = parsePolicy(ALL);
        const f = createFiller({ ...t.deps, getPolicy: () => policy });
        for (const [id, url] of [['other', 'https://accounts.example.com'], ['look', 'https://google.com.evil.test'], ['plain', 'http://accounts.google.com'],
            ['icloud', 'https://www.icloud.com'], ['bar', 'https://bar.co.uk'], ['couk', 'https://co.uk'], ['acc', 'https://accounts.google.com'], ['cn', 'https://evil.net.cn']]) t.ctl.addSession(id, loginPages(url));
        const base = { chat: NO_CHAT, element_id: 'p1' };
        for (const [session_id, name] of [['other', 'gmail.password'], ['look', 'gmail.password'], ['plain', 'gmail.password'],
            ['icloud', 'apple.password'], ['bar', 'foo-uk.password'], ['couk', 'foo-uk.password'], ['acc', 'gmail-host.password'],
            ['acc', 'acme-github.password'], ['cn', 'gmail.password']]) {
            await assert.rejects(f.fill({ ...base, session_id, name }), /which is not a host this secret is allowed on/, `${session_id} ${name}`);
        }
        await assert.rejects(f.fill({ ...base, session_id: 'other', name: 'gmail.password' }), /allowed: https:\/\/www\.gmail\.com \(\+ google\.com, youtube\.com equivalents\)/);
        await assert.rejects(f.login({ chat: NO_CHAT, session_id: 'plain', site: 'gmail' }), /not a host this login is allowed on/);
        const list = (await f.list({ chat: NO_CHAT })).secrets;
        assert.equal(list.find((x) => x.name === 'apple.password').equivalents, undefined, 'an excluded group grants nothing');
        assert.equal(list.find((x) => x.name === 'gmail-host.password').equivalents, undefined, 'a URI with Host match detection stays exact');
        assert.equal(t.ctl.typed.length, 0, 'nothing was typed');
    } finally { await t.close(); }
});

test('equivalent domains: explicit secrets stay exact, and "equivalent_domains": false turns it off', async () => {
    const t = await setup();
    try {
        t.ctl.addSession('acc', loginPages('https://accounts.google.com'));
        t.ctl.addSession('www', loginPages('https://www.gmail.com'));
        const explicit = parsePolicy({ version: 1, default_client: 'agent', chats: {},
            clients: { agent: { all_items: true, secrets: { mail: { item_id: t.v.items.gmail.id, hosts: ['www.gmail.com'], fields: ['password'] } } } } });
        const f1 = createFiller({ ...t.deps, getPolicy: () => explicit });
        assert.deepEqual((await f1.list({ chat: NO_CHAT })).secrets.find((x) => x.name === 'mail.password'), { name: 'mail.password', hosts: ['www.gmail.com'], kind: 'password' });
        await assert.rejects(f1.fill({ chat: NO_CHAT, session_id: 'acc', element_id: 'p1', name: 'mail.password' }), /which is not a host this secret is allowed on \(allowed: https:\/\/www\.gmail\.com\)/);
        assert.deepEqual(await f1.fill({ chat: NO_CHAT, session_id: 'www', element_id: 'p1', name: 'mail.password' }), { ok: true, kind: 'password', host: 'www.gmail.com' });

        const off = parsePolicy({ ...ALL, clients: { agent: { all_items: true, equivalent_domains: false, secrets: {} } } });
        assert.equal(off.equivalentDomains('agent'), false);
        const f2 = createFiller({ ...t.deps, getPolicy: () => off });
        assert.equal((await f2.list({ chat: NO_CHAT })).secrets.find((x) => x.name === 'gmail.password').equivalents, undefined);
        await assert.rejects(f2.fill({ chat: NO_CHAT, session_id: 'acc', element_id: 'p1', name: 'gmail.password' }), /which is not a host this secret is allowed on \(allowed: https:\/\/www\.gmail\.com\)/);
        await assert.rejects(f2.login({ chat: NO_CHAT, session_id: 'acc', site: 'gmail' }), /not a host this login is allowed on/);
        assert.deepEqual(await f2.fill({ chat: NO_CHAT, session_id: 'www', element_id: 'p1', name: 'gmail.password' }), { ok: true, kind: 'password', host: 'www.gmail.com' });
        assert.equal(t.ctl.typed.length, 2);
    } finally { await t.close(); }
});

test('custom fields are never fillable: not listed, not resolvable, never typed by login', async () => {
    const t = await setup();
    try {
        const custom = ['Jira-Api-Token-Zq81xW', 'eu-west', 'Portal-Token-7c1e9a'];
        // all_items: the jira login fills its username and password only.
        const policy = parsePolicy(ALL);
        const f = createFiller({ ...t.deps, getPolicy: () => policy });
        const names = (await f.list({ chat: NO_CHAT })).secrets.map((x) => x.name);
        assert.deepEqual(names.filter((n) => n.startsWith('jira.')), ['jira.username', 'jira.password']);
        t.ctl.addSession('j', loginPages('https://team.atlassian.net'));
        for (const name of ['jira.token', 'jira.Region', 'jira.custom:token']) await assert.rejects(f.fill({ chat: NO_CHAT, session_id: 'j', element_id: 'p1', name }), /no such secret/, name);
        await f.login({ chat: NO_CHAT, session_id: 'j', site: 'jira' }).catch(() => {});
        assert.ok(t.ctl.typed.length >= 1);
        for (const x of t.ctl.typed) assert.ok(!custom.includes(x.text), 'a custom field value was typed');
        // An explicit secret that lists custom_fields: still only its fields are fill names.
        const p = policyFor(t.v);
        p.clients.acme.secrets.portal = { ...p.clients.acme.secrets.portal, custom_fields: ['token'] };
        const pol2 = parsePolicy(p);
        const f2 = createFiller({ ...t.deps, getPolicy: () => pol2 });
        assert.deepEqual((await f2.list({ chat: 'chat-acme' })).secrets.filter((s) => s.name.startsWith('portal.')).map((s) => s.name), ['portal.password']);
        t.ctl.addSession('p', loginPages('https://portal.acme.test'));
        await assert.rejects(f2.fill({ chat: 'chat-acme', session_id: 'p', element_id: 'p1', name: 'portal.token' }), /no such secret/);
        for (const x of t.ctl.typed) assert.ok(!custom.includes(x.text));
        assert.ok(!custom.some((x) => auditText(t.dir).includes(x)));
    } finally { await t.close(); }
});
