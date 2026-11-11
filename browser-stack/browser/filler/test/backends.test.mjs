// More than one vault backend in one filler: each client uses its own
// backend, and no chat reaches an item of another backend, by name, by an id
// it guesses, or through a policy entry that names another backend's id.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createManager } from '../lib/manage.mjs';
import { NO_CHAT } from '../lib/policy.mjs';
import { loginPages } from './fake-controller.mjs';
import { setup2, SHARED_ONLY, INST_ONLY, SHARED_TOKEN, INST_TOKEN } from './two-backends.mjs';

const notReachable = /no login with that id is reachable|not found|no such/i;

test('list: each chat sees only its own backend\'s logins, whatever their names', async () => {
    const t = await setup2();
    try {
        const shIds = t.idsSh(); const inIds = t.idsIn();
        for (const id of shIds) assert.ok(!inIds.has(id), 'the two fakes share no id');
        t.reset();
        const inst = await t.m.list({ chat: 'chat-inst', include_trash: true });
        assert.equal(inst.client, 'instimate');
        assert.ok(inst.items.length > 3);
        for (const it of inst.items) { assert.ok(inIds.has(it.id), it.name); assert.ok(!shIds.has(it.id), it.name); }
        assert.ok(inst.items.some((i) => i.name === 'inst-only'));
        assert.ok(!inst.items.some((i) => i.name === 'shared-only'));
        assert.equal(t.calls.shared.length, 0, 'the instimate chat never reached the shared backend');
        t.reset();
        for (const chat of ['chat-unmapped', NO_CHAT]) {
            const sh = await t.m.list({ chat, include_trash: true });
            assert.equal(sh.client, 'agent');
            for (const it of sh.items) assert.ok(shIds.has(it.id) && !inIds.has(it.id), it.name);
            assert.ok(sh.items.some((i) => i.name === 'shared-only'));
            assert.ok(!sh.items.some((i) => i.name === 'inst-only'));
        }
        assert.equal(t.calls.instimate.length, 0, 'unmapped chats never reached the instimate backend');
        // An all_items login in the other backend is not hidden by the other backend's listed ids:
        // acme lists shared's acme-github; instimate's own acme-github (another id) stays its own.
        assert.ok(inst.items.some((i) => i.name === 'acme-github'));
        assert.ok(!(await t.m.list({ chat: 'chat-unmapped' })).items.some((i) => i.name === 'acme-github'));
        // search goes through the same view.
        const s = await t.m.search({ chat: 'chat-inst', query: 'only' });
        assert.deepEqual(s.items.map((i) => i.name), ['inst-only']);
        // The filler's list for the browser.
        const fl = await t.f.list({ chat: 'chat-inst' });
        assert.ok(fl.secrets.some((x) => x.name === 'inst-only.password'));
        assert.ok(!fl.secrets.some((x) => x.name.startsWith('shared-only')));
    } finally { await t.close(); }
});

test('guessed ids: a chat cannot update, remove, restore, compare or pipe an item of the other backend', async () => {
    const t = await setup2();
    try {
        const sha = (s) => createHash('sha256').update(s).digest('hex');
        const shId = t.sh.vault.sync.ciphers.find((c) => t.sh.vault.items['shared-only'].id === c.id).id;
        const inId = t.inst.vault.items['inst-only'].id;
        const shTrashed = t.sh.vault.items['acme-trashed'].id;
        const inTrashed = t.inst.vault.items['acme-trashed'].id;
        const attempts = (id, trashedId) => [
            ['update', { id, name: 'pwned' }],
            ['update', { id, rotate_password: {} }],
            ['remove', { id }],
            ['restore', { id: trashedId }],
            ['compare', { id, field: 'password', algo: 'sha256', digest: sha(SHARED_ONLY) }],
            ['compare', { id, custom_field: 'token', algo: 'sha256', digest: sha(SHARED_TOKEN) }],
            ['pipe', { id, field: 'password', target: 'sha' }],
            ['pipe', { id, custom_field: 'token', target: 'sha' }],
        ];
        // instimate chats (all_items, and an explicit-secrets client whose policy names a shared id) -> shared items.
        for (const chat of ['chat-inst', 'chat-instx']) {
            for (const [fn, body] of attempts(shId, shTrashed)) {
                await assert.rejects(t.m[fn]({ chat, ...body }), (e) => e.status === 404 && notReachable.test(e.message), `${chat} ${fn}`);
            }
            // The shared id the instx policy lists is looked up in instimate only.
            const acmeGh = t.sh.vault.items['acme-github'].id;
            for (const [fn, body] of attempts(acmeGh, shTrashed)) {
                await assert.rejects(t.m[fn]({ chat, ...body }), (e) => e.status === 404, `${chat} ${fn} listed id`);
            }
        }
        // shared chats -> instimate items.
        for (const chat of ['chat-unmapped', NO_CHAT, 'chat-acme']) {
            for (const [fn, body] of attempts(inId, inTrashed)) {
                await assert.rejects(t.m[fn]({ chat, ...body }), (e) => [403, 404].includes(e.status), `${chat} ${fn}`);
            }
        }
        assert.deepEqual(t.sh.calls.writes, [], 'no write reached the shared vault');
        assert.deepEqual(t.inst.calls.writes, [], 'no write reached the instimate vault');
        assert.ok(!t.calls.shared.some(([k]) => k === 'readItem'), 'no shared item was read');
        assert.ok(!t.calls.instimate.some(([k, id]) => k === 'readItem' && id === inId), 'no instimate item was read');
        // Every audit line names the backend of the chat's client, and no value.
        const audit = t.auditText();
        for (const line of audit.trim().split('\n').map((l) => JSON.parse(l))) {
            if (!line.client) continue;
            assert.equal(line.backend, ['instimate', 'instx'].includes(line.client) ? 'instimate' : 'shared', JSON.stringify(line));
        }
        for (const v of [SHARED_ONLY, INST_ONLY, SHARED_TOKEN, INST_TOKEN]) assert.ok(!audit.includes(v));
        // Own items still work.
        const piped = await t.m.pipe({ chat: 'chat-inst', id: inId, field: 'password', target: 'sha' });
        assert.equal(piped.value, INST_ONLY);
        assert.deepEqual(await t.m.compare({ chat: 'chat-unmapped', id: shId, field: 'password', algo: 'sha256', digest: sha(SHARED_ONLY) }), { match: true });
    } finally { await t.close(); }
});

test('create, update, remove and restore land in the chat\'s own backend only', async () => {
    const t = await setup2();
    try {
        const made = await t.m.create({ chat: 'chat-inst', name: 'Inst New', uris: ['https://new.instimate.test'], username: 'n' });
        assert.ok(t.idsIn().has(made.id) && !t.idsSh().has(made.id));
        assert.deepEqual(t.sh.calls.writes, []);
        assert.deepEqual(t.inst.calls.writes.map((w) => w.op), ['create']);
        // The shared chat cannot see or touch it.
        assert.ok(!(await t.m.list({ chat: 'chat-unmapped' })).items.some((i) => i.id === made.id));
        await assert.rejects(t.m.remove({ chat: 'chat-unmapped', id: made.id }), (e) => e.status === 404);
        await t.m.update({ chat: 'chat-inst', id: made.id, rotate_password: {} });
        await t.m.remove({ chat: 'chat-inst', id: made.id });
        await t.m.restore({ chat: 'chat-inst', id: made.id });
        assert.deepEqual(t.inst.calls.writes.map((w) => w.op), ['create', 'update', 'trash', 'restore']);
        assert.deepEqual(t.sh.calls.writes, []);
        // The same fill name in both backends is two different logins.
        const shMade = await t.m.create({ chat: NO_CHAT, name: 'Inst New', uris: ['https://new.instimate.test'], username: 'n' });
        assert.notEqual(shMade.id, made.id);
        assert.ok(t.idsSh().has(shMade.id));
    } finally { await t.close(); }
});

test('fill and login: a chat types only its own backend\'s values; both are scrubbed', async () => {
    const t = await setup2();
    try {
        t.ctl.addSession('si', loginPages()); t.ctl.addSession('ss', loginPages()); t.ctl.addSession('sx', loginPages());
        // The instimate chat cannot fill a shared login by name, and the shared chat cannot fill an instimate one.
        await assert.rejects(t.f.fill({ chat: 'chat-inst', session_id: 'si', element_id: 'p1', name: 'shared-only.password' }), (e) => e.outcome === 'refused_name');
        await assert.rejects(t.f.login({ chat: 'chat-inst', session_id: 'si', site: 'shared-only' }), (e) => e.outcome === 'refused_name');
        await assert.rejects(t.f.fill({ chat: 'chat-unmapped', session_id: 'ss', element_id: 'p1', name: 'inst-only.password' }), (e) => e.outcome === 'refused_name');
        await assert.rejects(t.f.login({ chat: NO_CHAT, session_id: 'ss', site: 'inst-only' }), (e) => e.outcome === 'refused_name');
        // instx's policy entry names a shared item's id: read in instimate, where it does not exist.
        await assert.rejects(t.f.fill({ chat: 'chat-instx', session_id: 'sx', element_id: 'p1', name: 'github.password' }), (e) => e.status === 404 && e.outcome === 'vault');
        await assert.rejects(t.f.login({ chat: 'chat-instx', session_id: 'sx', site: 'github' }), (e) => e.status === 404);
        assert.equal(t.ctl.typed.length, 0, 'nothing was typed');
        assert.ok(!t.calls.shared.some(([k]) => k === 'readItem'), 'no shared item was read for an instimate chat');
        // A login present in both backends under one name (acme-github, from the same fake seed) fills
        // each chat with its own backend's item: the instimate chat reads only the instimate id.
        t.reset();
        await t.f.fill({ chat: 'chat-inst', session_id: 'si', element_id: 'p1', name: 'acme-github.password' });
        assert.deepEqual(t.calls.instimate.filter(([k]) => k === 'readItem').map(([, id]) => id), [t.inst.vault.items['acme-github'].id]);
        assert.equal(t.calls.shared.length, 0);
        // Own values fill, and both backends' values are scrubbed afterwards.
        await t.f.fill({ chat: 'chat-inst', session_id: 'si', element_id: 'p1', name: 'inst-only.password' });
        await t.f.fill({ chat: 'chat-unmapped', session_id: 'ss', element_id: 'p1', name: 'shared-only.password' });
        const typed = t.ctl.typed.map((x) => x.text);
        assert.ok(typed.includes(INST_ONLY) && typed.includes(SHARED_ONLY));
        const s = t.scrubber.scrub({ a: `x ${INST_ONLY} y`, b: `z ${SHARED_ONLY}` });
        assert.ok(!JSON.stringify(s).includes(INST_ONLY) && !JSON.stringify(s).includes(SHARED_ONLY), JSON.stringify(s));
        assert.ok(t.taint.get(t.key('si')) && t.taint.get(t.key('ss')));
        // A session one chat typed into stays bound to it: the other backend's chat cannot use it.
        await assert.rejects(t.f.fill({ chat: 'chat-unmapped', session_id: 'si', element_id: 'p1', name: 'shared-only.password' }), (e) => e.outcome === 'refused_binding');
        await assert.rejects(t.f.fill({ chat: 'chat-inst', session_id: 'ss', element_id: 'p1', name: 'inst-only.password' }), (e) => e.outcome === 'refused_binding');
        const audit = t.auditText();
        for (const v of [SHARED_ONLY, INST_ONLY]) assert.ok(!audit.includes(v));
        assert.match(audit, /"client":"instimate","backend":"instimate"/);
        assert.match(audit, /"client":"agent","backend":"shared"/);
    } finally { await t.close(); }
});

test('a backend that is not enrolled answers 503 for its chats only', async () => {
    const t = await setup2({ instEnrolled: false });
    try {
        t.ctl.addSession('s', loginPages());
        await assert.rejects(t.m.list({ chat: 'chat-inst' }), (e) => e.status === 503 && /instimate/.test(e.message));
        await assert.rejects(t.f.list({ chat: 'chat-inst' }), (e) => e.status === 503);
        await assert.rejects(t.f.fill({ chat: 'chat-inst', session_id: 's', element_id: 'p1', name: 'acme-github.password' }), (e) => e.status === 503);
        // Never a fallback to another backend.
        assert.equal(t.calls.shared.length, 0);
        assert.equal((await t.m.list({ chat: 'chat-unmapped' })).client, 'agent');
        // A vaults() that throws is the same as not enrolled: fail closed.
        const m = createManager({ getPolicy: () => t.policy, vaults: (n) => { if (n === 'instimate') throw new Error('boom'); return t.providers.shared; }, audit: t.audit });
        await assert.rejects(m.list({ chat: 'chat-inst' }), (e) => e.status === 503 && !/boom/.test(e.message));
        // A lone vault (the older form) serves shared only, never another backend.
        const lone = createManager({ getPolicy: () => t.policy, vault: t.providers.shared, audit: t.audit });
        await assert.rejects(lone.list({ chat: 'chat-inst' }), (e) => e.status === 503);
    } finally { await t.close(); }
});
