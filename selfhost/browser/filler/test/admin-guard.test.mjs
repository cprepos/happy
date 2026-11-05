// The account line: admin commands refuse every account but happy-filler, the
// root setup script does only what needs root, and the user unit keeps its
// hardening. Skipped where it cannot mean anything (run as happy-filler).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync, execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const app = join(here, '..');
const selfhost = join(app, '..', '..');
const me = execFileSync('id', ['-un'], { encoding: 'utf8' }).trim();
const skip = me === 'happy-filler' ? 'runs as happy-filler' : false;

const ADMIN_TARGETS = ['filler-install', 'filler-setup', 'filler-init', 'filler-enroll', 'filler-seed-policy',
    'filler-policy-edit', 'filler-up', 'filler-down', 'filler-restart', 'filler-lock', 'filler-logs', 'filler-items',
    'filler-outbox-clear', 'filler-token-issue', 'filler-controller-token-take'];
const ADMIN_COMMANDS = ['init', 'install', 'enroll', 'seed-policy', 'policy-edit', 'up', 'down', 'restart', 'lock',
    'logs', 'unit-status', 'items', 'outbox-clear', 'token-issue', 'controller-token-take', 'setup', 'bogus'];

/** recipe lines (tab-led) of each rule in filler.mk, by target */
function recipes() {
    const out = new Map();
    let cur = [];
    for (const line of readFileSync(join(selfhost, 'filler.mk'), 'utf8').split('\n')) {
        const m = /^([a-z][a-z0-9 -]*):(?!=)/.exec(line);
        if (m) { cur = []; for (const t of m[1].trim().split(/\s+/)) out.set(t, cur); continue; }
        if (line.startsWith('\t') && cur) cur.push(line.slice(1));
    }
    return out;
}

test('filler.mk: every admin target starts with the happy-filler guard', () => {
    const r = recipes();
    for (const t of ADMIN_TARGETS) {
        assert.ok(r.has(t), `${t} is defined`);
        assert.equal(r.get(t)[0], '$(FILLER_AS_ACCOUNT)', `${t} begins with $(FILLER_AS_ACCOUNT)`);
    }
    for (const t of ['filler-token-take', 'filler-controller-token-give', 'filler-account-setup']) {
        assert.equal(r.get(t)[0], '$(FILLER_AS_OPERATOR)', `${t} begins with $(FILLER_AS_OPERATOR)`);
    }
    // sudo appears in exactly one recipe.
    const withSudo = [...r].filter(([, lines]) => lines.some((l) => /\bsudo\b/.test(l))).map(([t]) => t);
    assert.deepEqual([...new Set(withSudo)], ['filler-account-setup']);
});

test('filler-admin.sh refuses every command as another account and names su', { skip }, () => {
    for (const c of ADMIN_COMMANDS) {
        const p = spawnSync('bash', [join(app, 'scripts', 'filler-admin.sh'), c, 'COMMIT=abc1234'], { encoding: 'utf8' });
        assert.equal(p.status, 1, `${c}: exit 1`);
        assert.match(p.stderr, /su - happy-filler/, `${c}: says su - happy-filler`);
        assert.equal(p.stdout, '', `${c}: did nothing`);
    }
});

test('make: admin targets refuse another account and print the su command', { skip }, () => {
    const env = { ...process.env, MAKEFLAGS: '', MFLAGS: '', MAKELEVEL: '' };
    for (const t of ['filler-up', 'filler-install', 'filler-token-issue', 'filler-controller-token-take']) {
        const p = spawnSync('make', ['-s', '-C', selfhost, t, 'COMMIT=abc1234', 'NAME=vault-client'], { encoding: 'utf8', env });
        assert.notEqual(p.status, 0, `${t}: fails`);
        assert.match(p.stderr, /su - happy-filler/, `${t}: says su - happy-filler`);
        assert.match(p.stderr, new RegExp(`make -C \\S+ ${t}`), `${t}: prints the make form`);
    }
});

test('account setup: only account, linger, docker stop, chown; no tokens, no unit, no start', () => {
    const s = readFileSync(join(app, 'scripts', 'filler-account-setup.sh'), 'utf8');
    const code = s.split('\n').filter((l) => !/^\s*(#|echo )/.test(l)).join('\n');
    for (const needed of ['useradd', 'passwd "$ACCT"', 'enable-linger', 'docker stop', 'chown', '/outbox', '/inbox']) {
        assert.ok(code.includes(needed), `does ${needed}`);
    }
    for (const banned of ['systemctl --user', 'handoff-copy', 'filler-admin', 'token-issue', 'urandom', 'git ', ' rm ', 'docker rm', 'restart "$UNIT"']) {
        assert.ok(!code.includes(banned), `does not ${banned.trim()}`);
    }
    assert.doesNotMatch(code, /cat\s+"?\$ROOT\/secrets/, 'never reads secrets/');
});

test('user unit: loopback only, hardened, no test switches', () => {
    const u = readFileSync(join(app, 'systemd', 'happy-filler.service'), 'utf8');
    for (const line of ['Environment=FILLER_HOST=127.0.0.1', 'Restart=always', 'NoNewPrivileges=yes', 'PrivateUsers=yes',
        'PrivateTmp=yes', 'ProtectSystem=strict', 'ProtectHome=yes', 'ReadWritePaths=/srv/happy-filler/state /srv/happy-filler/audit',
        'UMask=0077', 'RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX', 'WantedBy=default.target']) {
        assert.ok(u.split('\n').includes(line), `has ${line}`);
    }
    assert.match(u, /^UnsetEnvironment=.*FILLER_TEST_ALLOW_LOOPBACK_HTTP/m);
    assert.match(u, /^SystemCallFilter=~/m);
    assert.doesNotMatch(u, /^User=|^Environment=FILLER_TEST/m);
});
