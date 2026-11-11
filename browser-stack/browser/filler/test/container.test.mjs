// The filler as a container: the compose service keeps the old unit's limits
// (loopback only, read-only, no capabilities, only state/ and audit/
// writable), the image runs uid 1990 with the code-generation flag, and the
// admin commands (scripts/admin.mjs) issue tokens the way filler-admin did.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs, AdminError } from '../scripts/admin.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const app = join(here, '..');
const repo = join(app, '..', '..', '..');
const admin = join(app, 'scripts', 'admin.mjs');

/** The lines of one top-level service in compose.vault.yml. */
function service(name) {
    const lines = readFileSync(join(repo, 'selfhost', 'vault', 'compose.vault.yml'), 'utf8').split('\n');
    const start = lines.indexOf(`  ${name}:`);
    assert.ok(start >= 0, `service ${name} is defined`);
    const out = [];
    for (const l of lines.slice(start + 1)) {
        if (/^ {2}\S/.test(l) || /^\S/.test(l)) break;
        if (!/^\s*#/.test(l)) out.push(l);
    }
    return out.join('\n');
}

test('compose: the filler is loopback only, read-only, no capabilities, only state and audit writable', () => {
    const s = service('filler');
    for (const want of [/^ {4}read_only: true$/m, /^ {4}cap_drop: \[ALL\]$/m, /no-new-privileges:true/, /^ {4}network_mode: host$/m,
        /^ {6}FILLER_HOST: 127\.0\.0\.1$/m, /^ {6}FILLER_PORT: "6091"$/m, /^ {4}restart: unless-stopped$/m, /^ {4}healthcheck:$/m]) {
        assert.match(s, want);
    }
    assert.doesNotMatch(s, /FILLER_TEST|FILLER_POLICY|docker\.sock|privileged|cap_add|^ {4}ports:/m);
    const vols = [...s.matchAll(/^ {6}- (.+)$/gm)].map((m) => m[1]);
    assert.deepEqual(vols, [
        '${FILLER_ROOT:-/srv/happy-filler}:/filler:ro',
        '${FILLER_ROOT:-/srv/happy-filler}/state:/filler/state',
        '${FILLER_ROOT:-/srv/happy-filler}/audit:/filler/audit',
    ]);
    const a = service('filler-admin');
    assert.match(a, /^ {4}profiles: \[admin\]$/m, 'the admin service only runs on request');
    assert.match(a, /^ {4}cap_drop: \[ALL\]$/m);
    assert.doesNotMatch(a, /docker\.sock|privileged|cap_add|FILLER_TEST/);
});

test('image: pinned node 22, uid 1990, the code-generation flag', () => {
    const d = readFileSync(join(app, 'Dockerfile'), 'utf8');
    assert.match(d, /^FROM node:22[^\s]*@sha256:[0-9a-f]{64}$/m);
    assert.match(d, /^USER 1990:1990$/m);
    assert.match(d, /^CMD \["node", "--disallow-code-generation-from-strings", "server\.mjs"\]$/m);
});

test('filler.mk: no sudo, admin targets run in the filler image', () => {
    const mk = readFileSync(join(repo, 'browser-stack', 'filler.mk'), 'utf8');
    // Quoted text (a printed hint for the operator) is not a command.
    const recipes = mk.split('\n').filter((l) => l.startsWith('\t')).map((l) => l.replace(/"[^"]*"/g, '""'));
    assert.ok(!recipes.some((l) => /\bsudo\b/.test(l)), 'no recipe runs sudo');
    assert.match(mk, /^filler-init filler-items filler-outbox-clear filler-controller-token-take:\n\t\$\(FILLER_ADMIN_RUN\) -T filler-admin /m);
});

test('admin: unknown arguments and commands are refused', () => {
    assert.throws(() => parseArgs(['FOO=1']), AdminError);
    assert.deepEqual(parseArgs(['NAME=vault-client', 'ROTATE=1']), { NAME: 'vault-client', ROTATE: '1' });
    const r = spawnSync(process.execPath, [admin, 'bogus'], { encoding: 'utf8', env: { ...process.env, FILLER_HOME: tmpdir() } });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /unknown command/);
});

function home() {
    const h = mkdtempSync(join(tmpdir(), 'filler-admin-'));
    for (const d of ['state', 'audit', 'outbox', 'inbox', 'trash']) mkdirSync(join(h, d));
    mkdirSync(join(h, 'secrets'), { mode: 0o500 });
    chmodSync(join(h, 'secrets'), 0o500);
    return h;
}
const run = (h, ...args) => spawnSync(process.execPath, [admin, ...args], { encoding: 'utf8', env: { ...process.env, FILLER_HOME: h } });

test('admin token-issue: hash to secrets (0400), plaintext once to outbox (0640), never twice without ROTATE', () => {
    const h = home();
    assert.equal(run(h, 'tokens-missing').stdout, 'bridge-client\nvault-client\n');
    const r = run(h, 'token-issue', 'NAME=vault-client');
    assert.equal(r.status, 0, r.stderr);
    const tok = readFileSync(join(h, 'outbox', 'vault-client-token'), 'utf8');
    assert.match(tok, /^[0-9a-f]{64}$/);
    assert.ok(!r.stdout.includes(tok) && !r.stderr.includes(tok), 'the token is never printed');
    assert.equal(statSync(join(h, 'outbox', 'vault-client-token')).mode & 0o777, 0o640);
    const sha = join(h, 'secrets', 'vault-client-token.sha256');
    assert.equal(readFileSync(sha, 'utf8'), `${createHash('sha256').update(tok).digest('hex')}\n`);
    assert.equal(statSync(sha).mode & 0o777, 0o400);
    assert.equal(statSync(join(h, 'secrets')).mode & 0o777, 0o500, 'secrets/ is closed again');
    assert.equal(run(h, 'tokens-missing').stdout, 'bridge-client\n');
    assert.equal(run(h, 'token-issue', 'NAME=vault-client').status, 1, 'an existing token needs ROTATE=1');
    assert.equal(run(h, 'token-issue', 'NAME=vault-client', 'ROTATE=1').status, 0);
    assert.notEqual(readFileSync(join(h, 'outbox', 'vault-client-token'), 'utf8'), tok);
});

test('admin controller-token-take: refuses a file of its own uid (not a handoff)', () => {
    const h = home();
    writeFileSync(join(h, 'inbox', 'controller-token'), 'a'.repeat(40));
    const r = run(h, 'controller-token-take');
    assert.equal(r.status, 1);
    assert.match(r.stderr, /owned by the reader/);
});

test('admin init: empty policy, 0640, and what is missing', () => {
    const h = home();
    const r = run(h, 'init');
    assert.equal(r.status, 0, r.stderr);
    assert.equal(statSync(join(h, 'policy.json')).mode & 0o777, 0o640);
    assert.match(r.stdout, /make vault-tokens/);
    assert.match(r.stdout, /make vault-enroll BACKEND=shared/);
});

test('admin policy-upgrade: an older policy gains manage and pipe_targets once, with a backup', () => {
    const h = home();
    writeFileSync(join(h, 'policy.json'), JSON.stringify({ version: 1, default_client: 'agent', clients: { agent: { all_items: true, secrets: {} } }, chats: {} }), { mode: 0o640 });
    const r = run(h, 'policy-upgrade');
    assert.equal(r.status, 0, r.stderr);
    const p = JSON.parse(readFileSync(join(h, 'policy.json'), 'utf8'));
    assert.deepEqual(p.pipe_targets, {});
    assert.equal(p.clients.agent.manage.create, true);
    assert.equal(statSync(join(h, 'policy.json')).mode & 0o777, 0o640);
    assert.match(run(h, 'policy-upgrade').stdout, /already has pipe_targets/);
});
