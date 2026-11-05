import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { createHash } from 'node:crypto';
import { mkdtempSync, readdirSync, readFileSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp, policyLoader, tokenChecker } from '../server.mjs';
import { enrollCore, writeEnrollment, FILES } from '../enroll.mjs';
import { loginPages } from './fake-controller.mjs';
import { startFakeVaultwarden } from './fake-vaultwarden.mjs';
import { policyFor, setup } from './helpers.mjs';

const TOKEN = 'filler-client-token-abcdefghijklmnop';
const sha = (s) => createHash('sha256').update(s).digest('hex');

function call(port, method, path, body, headers = {}) {
    return new Promise((resolve, reject) => {
        const data = body === undefined ? null : JSON.stringify(body);
        const req = request({ host: '127.0.0.1', port, method, path, headers: { Host: '127.0.0.1', Authorization: `Bearer ${TOKEN}`, 'X-Happy-Chat': 'chat-acme', ...(data ? { 'Content-Type': 'application/json' } : {}), ...headers } }, async (res) => {
            const chunks = []; for await (const c of res) chunks.push(c);
            const text = Buffer.concat(chunks).toString('utf8');
            resolve({ status: res.statusCode, text, json: text ? JSON.parse(text) : null });
        });
        req.on('error', reject);
        if (data) req.write(data);
        req.end();
    });
}

async function startApp(t, { enrolled = true, policyPath = null } = {}) {
    const logs = [];
    const getPolicy = policyPath ? policyLoader(policyPath, { requireOwner: false, logFn: (m) => logs.push(m) }) : t.deps.getPolicy;
    const handle = createApp({ checkToken: tokenChecker(sha(TOKEN)), ...t.deps, getPolicy, vault: enrolled ? t.vault : null, scrubber: t.scrubber });
    const server = createServer(handle);
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    return { port: server.address().port, logs, close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }) };
}

test('auth, Host and chat header checks', async () => {
    const t = await setup(); const app = await startApp(t);
    try {
        assert.equal((await call(app.port, 'POST', '/v1/list', {}, { Host: 'evil.test' })).status, 421);
        assert.equal((await call(app.port, 'POST', '/v1/list', {}, { Host: '127.0.0.1.evil.test' })).status, 421);
        assert.equal((await call(app.port, 'POST', '/v1/list', {}, { Authorization: 'Bearer wrong-token-0123456789' })).status, 401);
        assert.equal((await call(app.port, 'POST', '/v1/list', {}, { Authorization: '' })).status, 401);
        assert.equal((await call(app.port, 'POST', '/v1/list', {}, { 'X-Happy-Chat': '' })).status, 400);
        assert.equal((await call(app.port, 'GET', '/v1/list')).status, 405);
        const h = await call(app.port, 'GET', '/healthz', undefined, { Authorization: '' });
        assert.deepEqual([h.status, h.json.ok, h.json.unlocked], [200, true, true]);
        assert.ok(!/acme|globex|github/.test(h.text));
        const l = await call(app.port, 'POST', '/v1/list', {});
        assert.equal(l.json.client, 'acme');
        assert.equal((await call(app.port, 'POST', '/v1/list', {}, { 'X-Happy-Chat': 'chat-nobody' })).status, 403);
        assert.equal(tokenChecker(null)(`Bearer ${TOKEN}`), false);
    } finally { await app.close(); await t.close(); }
});

test('fill, session and scrub over HTTP; no value is ever in a response, the audit or the logs', async () => {
    const t = await setup(); const app = await startApp(t);
    try {
        t.ctl.addSession('s1', loginPages());
        const pw = t.v.items['acme-github'].password;
        let s = await call(app.port, 'POST', '/v1/session', { session_id: 's1' });
        assert.deepEqual(s.json, { tainted: false, any_tainted: false, drop_images: false });
        const passthrough = await call(app.port, 'POST', '/v1/scrub', { payload: { a: 'x' } });
        assert.deepEqual(passthrough.json.payload, { a: 'x' });
        const f = await call(app.port, 'POST', '/v1/fill', { session_id: 's1', element_id: 'p1', name: 'github.password' });
        assert.deepEqual(f.json, { ok: true, kind: 'password', host: 'github.com' });
        const bad = await call(app.port, 'POST', '/v1/fill', { session_id: 's1', element_id: 'u1', name: 'github.password' });
        assert.equal(bad.status, 422);
        s = await call(app.port, 'POST', '/v1/session', { session_id: 's1' });
        assert.deepEqual(s.json, { tainted: true, any_tainted: true, drop_images: false });
        const leak = { content: [{ type: 'text', text: `typed ${pw} and ${encodeURIComponent(pw)} and ${Buffer.from(`u:${pw}`).toString('base64')}` }, { type: 'image', data: 'x'.repeat(300) }] };
        const sc = await call(app.port, 'POST', '/v1/scrub', { payload: leak, session_id: 's1' });
        assert.ok(!sc.text.includes(pw) && !sc.text.includes(encodeURIComponent(pw)));
        assert.match(sc.json.payload.content[0].text, /\[secret:github\.password\]/);
        assert.equal(sc.json.payload.content[1].type, 'image', 'password-only taint keeps images');
        const l = await call(app.port, 'POST', '/v1/login', { session_id: 's1', site: 'github' });
        assert.equal(l.json.status, 'totp_submitted');
        const sc2 = await call(app.port, 'POST', '/v1/scrub', { payload: leak });
        assert.equal(sc2.json.payload.content[1].type, 'text', 'username/TOTP taint withholds images');
        for (const r of [f, bad, s, l]) assert.ok(!r.text.includes(pw) && !r.text.includes('acme-bot@example.com'));
        const audit = readdirSync(join(t.dir, 'audit')).map((x) => readFileSync(join(t.dir, 'audit', x), 'utf8')).join('');
        const state = readFileSync(join(t.dir, 'state', 'taint.json'), 'utf8');
        for (const blob of [audit, state, app.logs.join('\n')]) {
            assert.ok(!t.scrubber.leaks(blob), 'no filled value in audit, state or logs');
        }
        assert.equal((statSync(join(t.dir, 'audit', readdirSync(join(t.dir, 'audit'))[0])).mode & 0o777), 0o640);
    } finally { await app.close(); await t.close(); }
});

test('not enrolled: list, fill and login answer 503; scrub still works', async () => {
    const t = await setup(); const app = await startApp(t, { enrolled: false });
    try {
        for (const p of ['/v1/list', '/v1/fill', '/v1/login']) assert.equal((await call(app.port, 'POST', p, {})).status, 503, p);
        assert.equal((await call(app.port, 'POST', '/v1/scrub', { payload: 'x' })).status, 200);
        assert.equal((await call(app.port, 'GET', '/healthz')).json.unlocked, false);
    } finally { await app.close(); await t.close(); }
});

test('the policy reloads on change and fails closed while it is bad', async () => {
    const t = await setup();
    const dir = mkdtempSync(join(tmpdir(), 'filler-policy-'));
    const path = join(dir, 'policy.json');
    writeFileSync(path, JSON.stringify(policyFor(t.v)), { mode: 0o640 });
    const app = await startApp(t, { policyPath: path });
    try {
        assert.equal((await call(app.port, 'POST', '/v1/list', {})).json.client, 'acme');
        writeFileSync(path, '{"version":1,"clients":', { mode: 0o640 });
        utimesSync(path, new Date(), new Date(Date.now() + 5000));
        const r = await call(app.port, 'POST', '/v1/list', {});
        assert.equal(r.status, 503);
        assert.match(r.json.error, /policy is invalid/);
        const p = policyFor(t.v); p.chats = { 'chat-acme': 'globex' };
        writeFileSync(path, JSON.stringify(p), { mode: 0o640 });
        utimesSync(path, new Date(), new Date(Date.now() + 10000));
        assert.equal((await call(app.port, 'POST', '/v1/list', {})).json.client, 'globex');
    } finally { await app.close(); await t.close(); }
});

test('enroll derives the user key from the master password and API key, and stores no password', async () => {
    const fake = await startFakeVaultwarden();
    const v = fake.vault;
    try {
        const base = { vaultUrl: fake.url, email: ` ${v.email.toUpperCase()} `, password: v.password, clientId: v.clientId, clientSecret: v.clientSecret, deviceId: 'dev-9' };
        const r = await enrollCore(base);
        assert.ok(r.userKey.equals(v.userKey));
        // Personal, live logins only: not the trashed one, the note, or org items.
        assert.equal(r.logins, 10);
        assert.equal(r.orgs, 1);
        await assert.rejects(enrollCore({ ...base, password: 'wrong' }), /wrong master password/);
        await assert.rejects(enrollCore({ ...base, clientSecret: 'nope-nope' }), (e) => /HTTP 400/.test(e.message) && !e.message.includes('nope-nope'));
        await assert.rejects(enrollCore({ ...base, clientId: 'organization.x' }), /user\.<uuid>/);
        const dir = mkdtempSync(join(tmpdir(), 'filler-enroll-'));
        writeEnrollment(dir, { email: r.email, clientId: v.clientId, clientSecret: v.clientSecret, userKey: r.userKey, deviceId: 'dev-9' });
        writeEnrollment(dir, { email: r.email, clientId: v.clientId, clientSecret: v.clientSecret, userKey: r.userKey, deviceId: 'dev-9' });
        const names = readdirSync(dir).sort();
        assert.deepEqual(names.filter((n) => !n.startsWith('old-')), [...FILES].sort());
        assert.equal(names.filter((n) => n.startsWith('old-')).length, 1, 'earlier files moved aside, not deleted');
        for (const f of FILES) assert.equal(statSync(join(dir, f)).mode & 0o777, 0o400);
        const all = FILES.map((f) => readFileSync(join(dir, f), 'utf8')).join('\n');
        assert.ok(!all.includes(v.password));
        assert.equal(Buffer.from(readFileSync(join(dir, 'vault-user-key'), 'utf8').trim(), 'base64').length, 64);
    } finally { await fake.close(); }
});

test('two tokens, two route sets: the vault token reaches only /v1/vault/*, the bridge token never does', async () => {
    const t = await setup();
    const VTOKEN = 'vault-client-token-qrstuvwxyz012345';
    const { parsePolicy } = await import('../lib/policy.mjs');
    const { managePolicy } = await import('./helpers.mjs');
    const policy = parsePolicy(JSON.stringify(managePolicy(t.v)));
    const handle = createApp({ checkToken: tokenChecker(sha(TOKEN)), checkVaultToken: tokenChecker(sha(VTOKEN)), ...t.deps, getPolicy: () => policy, scrubber: t.scrubber });
    const server = createServer(handle);
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    const port = server.address().port;
    const V = { Authorization: `Bearer ${VTOKEN}` };
    try {
        assert.equal((await call(port, 'POST', '/v1/vault/list', {})).status, 401);
        assert.equal((await call(port, 'POST', '/v1/list', {}, V)).status, 401);
        assert.equal((await call(port, 'POST', '/v1/scrub', { payload: 'x' }, V)).status, 401);
        const ok = await call(port, 'POST', '/v1/vault/list', {}, V);
        assert.equal(ok.status, 200);
        assert.equal(ok.json.client, 'acme');
        assert.equal((await call(port, 'POST', '/v1/vault/purge', { id: t.v.items['acme-github'].id }, V)).status, 404);
        assert.equal((await call(port, 'POST', '/v1/vault/list', {}, { ...V, 'X-Happy-Chat': '' })).status, 400);
        const bad = await call(port, 'POST', '/v1/vault/list', { client_id: 'globex' }, V);
        assert.equal(bad.status, 400);
        assert.match(bad.json.error, /unknown key "client_id"/);
        assert.equal((await call(port, 'POST', '/v1/vault/list', {}, { ...V, 'X-Happy-Chat': 'none' })).json.client, 'agent');
        // Without a vault token configured, the routes are closed.
        const closed = createServer(createApp({ checkToken: tokenChecker(sha(TOKEN)), ...t.deps, getPolicy: () => policy, scrubber: t.scrubber }));
        await new Promise((r) => closed.listen(0, '127.0.0.1', r));
        assert.equal((await call(closed.address().port, 'POST', '/v1/vault/list', {}, V)).status, 401);
        await new Promise((r) => { closed.closeAllConnections?.(); closed.close(r); });
    } finally {
        await new Promise((r) => { server.closeAllConnections?.(); server.close(r); });
        await t.close();
    }
});
