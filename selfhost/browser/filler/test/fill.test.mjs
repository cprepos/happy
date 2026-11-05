import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFiller, kindsOf } from '../lib/fill.mjs';
import { parseTotp, totpAt } from '../lib/totp.mjs';
import { TOTP_SECRET } from './fake-vaultwarden.mjs';
import { loginPages } from './fake-controller.mjs';
import { setup } from './helpers.mjs';

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
            [{ ...base, session_id: 'evil' }, /not on a host/],
            [{ ...base, session_id: 'http' }, /not on a host/],
            [{ ...base, session_id: 'closed' }, /not active/],
            [{ ...base, session_id: 'nope' }, /no such browser session/],
            [{ ...base, element_id: 'u1' }, /cannot take a password/],
            [{ ...base, element_id: 'b1' }, /cannot take a password/],
            [{ ...base, element_id: 'zz' }, /element not found/],
            [{ ...base, name: 'foreign.password' }, /no key for this item's organization/],
            // Items in the same vault that the client does not list cannot be named.
            [{ ...base, name: 'unlisted.password' }, /no such secret/],
            [{ ...base, name: 'mismatch.password' }, /no host that both/],
            [{ ...base, name: 'portal.password' }, /not on a host/],
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
        assert.equal((await f.login({ chat: 'chat-acme', session_id: 'off', site: 'github' })).status, 'needs_human');
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
