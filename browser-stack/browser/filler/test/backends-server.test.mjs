// The server with more than one backend: one provider per policy backend,
// built on first use, each from its own secrets; one that fails shows in
// /healthz and answers 503 to its own chats only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parsePolicy } from '../lib/policy.mjs';
import { createApp, createVaults, buildBackend, backendSecretsDir, tokenChecker } from '../server.mjs';
import { setup2, call, TOKEN } from './two-backends.mjs';

test('server: one lazily built provider per backend; a failing one shows in /healthz and harms no other', async () => {
    const t = await setup2();
    try {
        const built = [];
        const logs = [];
        let instFails = true;
        const vaults = createVaults({
            getPolicy: () => t.policy, logFn: (m) => logs.push(m),
            build: (name) => { built.push(name); if (name === 'instimate' && instFails) throw new Error('cannot reach'); return t.providers[name]; },
        });
        const sha = createHash('sha256').update(TOKEN).digest('hex');
        const handle = createApp({ checkToken: tokenChecker(sha), checkVaultToken: tokenChecker(sha), ...t.deps, vaults, scrubber: t.scrubber });
        const server = createServer(handle);
        await new Promise((r) => server.listen(0, '127.0.0.1', r));
        const port = server.address().port;
        try {
            assert.deepEqual(built, [], 'nothing is built before it is needed');
            const h = await call(port, 'GET', '/healthz', undefined, { Authorization: '' });
            assert.equal(h.status, 200);
            assert.equal(h.json.unlocked, true, 'top-level unlocked is the default client\'s backend (shared)');
            assert.deepEqual(Object.keys(h.json.backends).sort(), ['instimate', 'shared']);
            assert.equal(h.json.backends.shared.unlocked, true);
            assert.equal(h.json.backends.instimate.unlocked, false);
            assert.ok(!/cannot reach/.test(h.text), 'no error text on the open health route');
            assert.equal(logs.filter((l) => /instimate/.test(l)).length, 1, 'logged once');
            // The shared chat works; the instimate chat gets 503, on the browser routes and the vault routes.
            assert.equal((await call(port, 'POST', '/v1/vault/list', {}, { 'X-Client-Chat': 'chat-unmapped' })).json.client, 'agent');
            assert.equal((await call(port, 'POST', '/v1/list', {}, { 'X-Client-Chat': 'chat-unmapped' })).json.client, 'agent');
            for (const p of ['/v1/vault/list', '/v1/list', '/v1/fill', '/v1/login']) {
                const r = await call(port, 'POST', p, {}, { 'X-Client-Chat': 'chat-inst' });
                assert.equal(r.status, 503, p);
            }
            // Retried on next use; once it builds, it is cached.
            instFails = false;
            const n = built.length;
            assert.equal((await call(port, 'POST', '/v1/vault/list', {}, { 'X-Client-Chat': 'chat-inst' })).json.client, 'instimate');
            await call(port, 'POST', '/v1/vault/list', {}, { 'X-Client-Chat': 'chat-inst' });
            assert.deepEqual(built.slice(n), ['instimate']);
            assert.equal((await call(port, 'GET', '/healthz')).json.backends.instimate.unlocked, true);
        } finally { server.closeAllConnections?.(); await new Promise((r) => server.close(r)); }
    } finally { await t.close(); }
});

test('createVaults rebuilds a backend when its config changes, and locks the old provider', () => {
    let policy = parsePolicy({ version: 1, backends: { shared: { type: 'vaultwarden', url: 'http://127.0.0.1:1' } }, clients: { a: { backend: 'shared' } }, chats: {} });
    const locked = [];
    let n = 0;
    const vaults = createVaults({ getPolicy: () => policy, logFn: () => {}, build: (name, cfg) => { const id = ++n; return { id, cfg, status: () => ({ sync_age_s: null }), lock: () => locked.push(id) }; } });
    const a = vaults.get('shared');
    assert.equal(vaults.get('shared'), a);
    assert.equal(vaults.get('nope'), null);
    policy = parsePolicy({ version: 1, backends: { shared: { type: 'vaultwarden', url: 'http://127.0.0.1:2' } }, clients: { a: { backend: 'shared' } }, chats: {} });
    const b = vaults.get('shared');
    assert.notEqual(a, b);
    assert.equal(b.cfg.url, 'http://127.0.0.1:2');
    assert.deepEqual(locked, [1]);
    vaults.lock();
    assert.deepEqual(locked, [1, 2]);
});

test('buildBackend: shared keeps today\'s secrets/ layout; another backend reads secrets/<name>/ only', () => {
    const home = mkdtempSync(join(tmpdir(), 'filler-home-'));
    const secretsDir = join(home, 'secrets');
    const files = (dir, tag) => {
        mkdirSync(dir, { recursive: true });
        writeFileSync(join(dir, 'vault-client-id'), `user.${tag}`);
        writeFileSync(join(dir, 'vault-client-secret'), `secret-${tag}`);
        writeFileSync(join(dir, 'vault-user-key'), Buffer.alloc(64, tag === 'sh' ? 1 : 2).toString('base64'));
        writeFileSync(join(dir, 'vault-device-id'), `dev-${tag}`);
    };
    const cfg = { secretsDir, vaultUrl: 'http://127.0.0.1:8222' };
    const seen = [];
    const createFn = (type, c) => { seen.push({ type, ...c }); return { type, id: c.id }; };
    // Not enrolled yet: null, never another backend's files.
    files(secretsDir, 'sh');
    assert.equal(buildBackend(cfg, 'instimate', { type: 'vaultwarden' }, { createFn }), null);
    files(join(secretsDir, 'instimate'), 'in');
    buildBackend(cfg, 'shared', { type: 'vaultwarden' }, { createFn });
    buildBackend(cfg, 'instimate', { type: 'vaultwarden', url: 'http://127.0.0.1:9' }, { createFn });
    assert.deepEqual(seen.map((s) => [s.id, s.clientId, s.deviceId, s.url]), [
        ['shared', 'user.sh', 'dev-sh', 'http://127.0.0.1:8222'],
        ['instimate', 'user.in', 'dev-in', 'http://127.0.0.1:9'],
    ]);
    assert.equal(backendSecretsDir(cfg, 'shared'), secretsDir);
    assert.equal(backendSecretsDir(cfg, 'instimate'), join(secretsDir, 'instimate'));
    for (const bad of ['..', '../x', 'a/b', '', 'X']) assert.throws(() => backendSecretsDir(cfg, bad), /bad backend name/);
    assert.throws(() => buildBackend(cfg, 'shared', { type: 'vaultwarden', clientSecret: 'x' }, { createFn }), /unknown vaultwarden setting/);
    // Another type gets its config, its name and its own secrets dir, nothing else.
    buildBackend(cfg, 'instimate', { type: 'other', vault: 'V' }, { createFn });
    assert.deepEqual(seen.at(-1), { type: 'other', vault: 'V', id: 'instimate', secretsDir: join(secretsDir, 'instimate') });
});
