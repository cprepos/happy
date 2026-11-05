import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { allowedHosts, httpsHost, matchHost, normalizeHost } from '../lib/hosts.mjs';
import { checkPolicyFile, itemSlug, loadPolicy, NO_CHAT, parsePolicy, PolicyError } from '../lib/policy.mjs';

const A = '11111111-1111-4111-8111-111111111111';
const B = '22222222-2222-4222-8222-222222222222';
export function samplePolicy(over = {}) {
    return {
        version: 1,
        clients: {
            acme: { secrets: { github: { item_id: A.replace(/1/g, '5'), hosts: ['github.com'], fields: ['username', 'password', 'totp'] } } },
            globex: { secrets: { github: { item_id: B.replace(/2/g, '6'), hosts: ['github.com'], fields: ['password'] } } },
        },
        chats: { 'chat-acme': 'acme', 'chat-globex': 'globex' },
        ...over,
    };
}

test('exact host matching: no suffix, no lookalikes, https on the default port only', () => {
    const allowed = allowedHosts(['https://github.com/login'], ['github.com']);
    assert.deepEqual(allowed, ['github.com']);
    assert.equal(matchHost('https://github.com/session', allowed), 'github.com');
    assert.equal(matchHost('https://GitHub.com./x', allowed), 'github.com');
    for (const bad of [
        'https://evilgithub.com/', 'https://github.com.evil.com/', 'https://github.com@evil.com/', 'https://evil.com@github.com/',
        'http://github.com/', 'https://github.com:8443/', 'https://www.github.com/', 'https://gіthub.com/' /* Cyrillic i */,
        'javascript:alert(1)', 'data:text/html,x', 'about:blank', 'not a url',
    ]) assert.equal(matchHost(bad, allowed), null, bad);
});

test('allowed hosts are the intersection of item URIs and policy hosts', () => {
    assert.deepEqual(allowedHosts(['https://github.com', 'https://gist.github.com'], ['github.com', 'example.com']), ['github.com']);
    assert.deepEqual(allowedHosts(['http://github.com', 'github.com', 'https://u:p@github.com'], ['github.com']), []);
    assert.deepEqual(allowedHosts(['https://xn--bcher-kva.de/'], ['Bücher.de']), ['xn--bcher-kva.de']);
    assert.equal(normalizeHost('github.com/x'), null);
    assert.equal(normalizeHost('github.com:443'), null);
    assert.equal(httpsHost('https://[::1]/'), null);
});

test('chat to client, names, and cross-client refusal', () => {
    const p = parsePolicy(samplePolicy());
    assert.equal(p.clientForChat('chat-acme'), 'acme');
    assert.equal(p.clientForChat('unknown'), null);
    assert.equal(p.clientForChat(undefined), null);
    assert.deepEqual(p.entries('acme').map((e) => e.name), ['github.username', 'github.password', 'github.totp']);
    assert.equal(p.resolve('acme', 'github.password').item_id, A.replace(/1/g, '5'));
    // globex allows only the password field; and a name never crosses clients.
    assert.equal(p.resolve('globex', 'github.username'), null);
    assert.notEqual(p.resolve('globex', 'github.password').item_id, p.resolve('acme', 'github.password').item_id);
    for (const bad of ['github', 'github.notes', '../acme.github.password', 'acme/github.password', '']) assert.equal(p.resolve('acme', bad), null);
});

test('default_client: unmapped chats and callers with no chat id use it; a mapped chat keeps its own client', () => {
    const none = parsePolicy(samplePolicy());
    assert.equal(none.defaultClient(), null);
    assert.equal(none.clientForChat(NO_CHAT), null, 'no default: a caller with no chat id reaches nothing');
    assert.equal(none.scopeOf('unknown'), null);
    assert.deepEqual(none.scopeOf('chat-acme'), { client: 'acme', path: 'mapped' });

    const p = parsePolicy(samplePolicy({ default_client: 'acme' }));
    assert.equal(p.defaultClient(), 'acme');
    assert.equal(p.clientForChat('unknown'), 'acme');
    assert.deepEqual(p.scopeOf('unknown'), { client: 'acme', path: 'default' });
    assert.deepEqual(p.scopeOf(NO_CHAT), { client: 'acme', path: 'default' });
    // A mapped chat overrides the default, even when the default is another client.
    assert.equal(p.clientForChat('chat-globex'), 'globex');
    assert.deepEqual(p.scopeOf('chat-globex'), { client: 'globex', path: 'mapped' });
    assert.deepEqual(p.scopeOf('chat-acme'), { client: 'acme', path: 'mapped' });
    for (const bad of [undefined, null, '', 42]) assert.equal(p.clientForChat(bad), null, String(bad));

    // The shape the README gives for "every chat shares the agent's logins".
    const shared = parsePolicy({ version: 1, default_client: 'agent', clients: { agent: { secrets: { site: { item_id: A, hosts: ['example.com'], fields: ['username', 'password', 'totp'] } } } }, chats: {} });
    assert.equal(shared.clientForChat('any-chat'), 'agent');
    assert.equal(shared.resolve(shared.clientForChat(NO_CHAT), 'site.password').hosts[0], 'example.com');
});

test('default_client must name an existing client; "none" is never a chat key', () => {
    for (const d of ['nobody', '', 42, null, ['acme'], { acme: true }]) {
        assert.throws(() => parsePolicy(samplePolicy({ default_client: d })), /default_client .* is not a client/, JSON.stringify(d));
    }
    assert.throws(() => parsePolicy(samplePolicy({ chats: { [NO_CHAT]: 'acme' } })), /reserved/);
    // A misspelt option is refused rather than silently meaning "no default".
    assert.throws(() => parsePolicy(samplePolicy({ default: 'acme' })), /unknown top-level key/);
    assert.throws(() => parsePolicy(samplePolicy({ defaultClient: 'acme' })), /unknown top-level key/);
});

test('all_items: one client at most, a boolean, and listed item ids are known', () => {
    const seed = parsePolicy({ version: 1, default_client: 'agent', clients: { agent: { all_items: true, secrets: {} } }, chats: {} });
    assert.equal(seed.allItems('agent'), true);
    assert.deepEqual(seed.entries('agent'), []);
    const p = parsePolicy(samplePolicy({ clients: { ...samplePolicy().clients, agent: { all_items: true } } }));
    assert.equal(p.allItems('agent'), true);
    assert.equal(p.allItems('acme'), false);
    assert.equal(p.isListed(A.replace(/1/g, '5').toUpperCase()), true);
    assert.equal(p.isListed(B), false);
    assert.throws(() => parsePolicy(samplePolicy({ clients: { a: { all_items: true }, b: { all_items: true } } })), /only one client/);
    for (const bad of ['yes', 1, null, {}]) assert.throws(() => parsePolicy(samplePolicy({ clients: { a: { all_items: bad } } })), /all_items must be true or false/, JSON.stringify(bad));
    assert.equal(itemSlug('GitHub (work)'), 'github-work');
    assert.equal(itemSlug('github.com'), 'github-com');
    assert.equal(itemSlug('Bücher.de'), 'bucher-de');
    assert.equal(itemSlug('  --x__ '), 'x');
    for (const bad of ['', '---', '日本', null, 42]) assert.equal(itemSlug(bad), null, String(bad));
    assert.equal(itemSlug('a'.repeat(100)).length, 63);
});

test('malformed policies fail the whole load', () => {
    const cases = [
        { version: 2 },
        samplePolicy({ chats: { 'c': 'nobody' } }),
        (() => { const x = samplePolicy(); x.clients.globex.secrets.github.item_id = x.clients.acme.secrets.github.item_id; return x; })(),
        // The organization fields of the earlier design are refused, not ignored.
        (() => { const x = samplePolicy(); x.clients.globex.org_id = A; return x; })(),
        (() => { const x = samplePolicy(); x.clients.acme.collection_id = A; return x; })(),
        (() => { const x = samplePolicy(); x.clients.acme.folder = 'x'; return x; })(),
        (() => { const x = samplePolicy(); x.clients.acme = null; return x; })(),
        (() => { const x = samplePolicy(); x.clients.acme.secrets = []; return x; })(),
        (() => { const x = samplePolicy(); x.clients.acme.secrets.github.hosts = ['*.github.com']; return x; })(),
        (() => { const x = samplePolicy(); x.clients.acme.secrets.github.hosts = []; return x; })(),
        (() => { const x = samplePolicy(); x.clients.acme.secrets.github.fields = ['notes']; return x; })(),
        (() => { const x = samplePolicy(); x.clients['Bad Slug'] = x.clients.acme; delete x.clients.acme; return x; })(),
    ];
    for (const c of cases) assert.throws(() => parsePolicy(c), PolicyError);
    assert.throws(() => parsePolicy('{not json'), PolicyError);
    assert.throws(() => parsePolicy(cases[3]), /org_id and collection_id are no longer used/);
});

test('policy file permissions: not writable by group/world, not a symlink, root-owned', () => {
    const d = mkdtempSync(join(tmpdir(), 'filler-policy-'));
    const f = join(d, 'policy.json');
    writeFileSync(f, JSON.stringify(samplePolicy()));
    chmodSync(f, 0o640);
    // Tests run as a normal user: the root-owner check is on in production only.
    assert.equal(loadPolicy(f, { requireRoot: false }).clientForChat('chat-acme'), 'acme');
    if (process.getuid() !== 0) assert.throws(() => checkPolicyFile(f), /owned by root/);
    chmodSync(f, 0o660);
    assert.throws(() => checkPolicyFile(f, { requireRoot: false }), /writable/);
    chmodSync(f, 0o646);
    assert.throws(() => checkPolicyFile(f, { requireRoot: false }), /writable/);
    chmodSync(f, 0o640);
    symlinkSync(f, join(d, 'link.json'));
    assert.throws(() => checkPolicyFile(join(d, 'link.json'), { requireRoot: false }), /symlink/);
});

test('equivalent_domains: a boolean on a client, true unless set to false', () => {
    const on = parsePolicy({ version: 1, clients: { agent: { all_items: true } }, chats: {} });
    assert.equal(on.equivalentDomains('agent'), true);
    const off = parsePolicy({ version: 1, clients: { agent: { all_items: true, equivalent_domains: false } }, chats: {} });
    assert.equal(off.equivalentDomains('agent'), false);
    assert.equal(off.equivalentDomains('nobody'), false);
    for (const bad of ['no', 0, null, {}]) assert.throws(() => parsePolicy({ version: 1, clients: { a: { all_items: true, equivalent_domains: bad } } }), /equivalent_domains must be true or false/, JSON.stringify(bad));
});

test('manage and pipe_targets: strict keys, create needs all_items, pipe names must exist', () => {
    const T = { 'docker-login': { argv: ['docker', 'login', '--username', '{username}', '--password-stdin', '{arg:registry}'], args: { registry: '^[a-z0-9.-]+(:[0-9]+)?$' } }, 'gh-token': { argv: ['gh', 'auth', 'login', '--with-token'] } };
    const p = parsePolicy({ version: 1, default_client: 'agent', clients: { agent: { all_items: true, manage: { create: true, update: true, remove: true, compare: true, pipe: ['docker-login'] } }, acme: { manage: { update: true } } }, chats: {}, pipe_targets: T });
    assert.deepEqual({ ...p.manage('agent') }, { create: true, update: true, remove: true, compare: true, pipe: ['docker-login'] });
    assert.deepEqual({ ...p.manage('acme') }, { create: false, update: true, remove: false, compare: false, pipe: [] });
    assert.equal(p.manage('nobody'), null);
    assert.equal(parsePolicy({ version: 1, clients: { a: {} } }).manage('a'), null);
    const t = p.pipeTarget('docker-login');
    assert.ok(t.args.get('registry').test('ghcr.io') && !t.args.get('registry').test('ghcr.io; rm -rf /'));
    assert.deepEqual(p.pipeTargets(), ['docker-login', 'gh-token']);
    const bad = (over, re) => assert.throws(() => parsePolicy({ version: 1, clients: { agent: { all_items: true, ...over.client } }, pipe_targets: over.targets ?? T }), re, JSON.stringify(over));
    bad({ client: { manage: { purge: true } } }, /manage: unknown key/);
    bad({ client: { manage: { create: 'yes' } } }, /manage.create must be true or false/);
    bad({ client: { manage: { pipe: ['nope'] } } }, /not in pipe_targets/);
    assert.throws(() => parsePolicy({ version: 1, clients: { acme: { manage: { create: true } } } }), /create needs all_items/);
    bad({ targets: { x: { argv: ['{username}'] } } }, /argv\[0\] must be a literal/);
    bad({ targets: { x: { argv: ['sh', '-c', 'echo {username}'] } } }, /must be a literal, "\{username\}"/);
    bad({ targets: { x: { argv: ['cmd', '{password}'] } } }, /must be a literal/);
    bad({ targets: { x: { argv: ['cmd', '{arg:host}'] } } }, /has no regex/);
    bad({ targets: { x: { argv: ['cmd'], args: { host: '.*' } } } }, /not used in argv/);
    bad({ targets: { x: { argv: ['cmd', '{arg:host}'], args: { host: '(' } } } }, /does not compile/);
    bad({ targets: { x: { argv: ['cmd'], env: {} } } }, /unknown key/);
    bad({ targets: { x: { argv: [] } } }, /argv must be/);
});
