// The secret filler's admin commands, run inside the filler image as uid 1990
// with $FILLER_HOME (/filler, the host's /srv/happy-filler) mounted read-write.
// The make targets in selfhost/vault.mk call it through the compose service
// filler-admin (profile admin), for example:
//
//   docker compose -p happy-vault --profile admin run --rm filler-admin token-issue NAME=vault-client
//
//   init                       directories and an empty policy (fresh install)
//   token-issue NAME=bridge-client|vault-client [ROTATE=1]
//                              a new client token: its SHA-256 to secrets/, the
//                              plaintext once to outbox/<NAME>-token (0640, the
//                              outbox's group) for the operator's make vault-tokens
//   tokens-missing             names of the client tokens not issued yet (one a line)
//   controller-token-take      inbox/controller-token -> secrets/controller-token (0400)
//   enroll                     (terminal) enroll with the agent's vault account
//   items                      the agent account's logins (no values)
//   seed-policy [CLIENT=agent] seed an empty policy
//   policy-edit                (terminal) back up, edit a copy, validate, swap it in
//   policy-upgrade             once: give an older policy (no pipe_targets) manage
//                              rights for all_items clients and empty pipe_targets
//   check-policy               validate policy.json
//   outbox-clear               move tokens nobody took to trash/
//
// Nothing is deleted: replaced files go to secrets/old-<ts>/ or trash/<ts>/.
// Prints no secrets.
import { createHash, randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import {
    chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync,
    writeFileSync,
} from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { copyHandoff, HandoffError } from './handoff-copy.mjs';
import { upgradePolicy } from './policy-upgrade.mjs';

const APP = join(dirname(fileURLToPath(import.meta.url)), '..');
const ROOT = process.env.FILLER_HOME || '/filler';
const SECRETS = join(ROOT, 'secrets');
const TS = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
const TOKENS = { 'bridge-client': 'client-token.sha256', 'vault-client': 'vault-client-token.sha256' };
const EMPTY_POLICY = '{\n  "version": 1,\n  "clients": {},\n  "chats": {}\n}\n';

export class AdminError extends Error {}
let cmd = '';
const out = (m) => process.stdout.write(`filler-admin ${cmd}: ${m}\n`);

function trashDir() {
    const d = join(ROOT, 'trash', TS);
    mkdirSync(d, { recursive: true, mode: 0o700 });
    return d;
}

function needLayout() {
    for (const d of ['secrets', 'state', 'audit']) {
        if (!existsSync(join(ROOT, d))) throw new AdminError(`${ROOT}/${d} is missing; run make vault-init first`);
    }
}

/** Run fn with secrets/ writable (0700), then back to 0500. */
function withSecretsOpen(fn) {
    chmodSync(SECRETS, 0o700);
    try { return fn(); } finally { chmodSync(SECRETS, 0o500); }
}

/** secrets/<name> = value (0400); a different old one moves to secrets/old-<ts>/. Returns true when written. */
function put(name, value) {
    const dst = join(SECRETS, name);
    if (existsSync(dst)) {
        if (readFileSync(dst, 'utf8') === value) return false;
        const old = join(SECRETS, `old-${TS}`);
        mkdirSync(old, { recursive: true, mode: 0o700 });
        renameSync(dst, join(old, name));
    }
    writeFileSync(dst, value, { mode: 0o400, flag: 'wx' });
    out(`wrote secrets/${name}`);
    return true;
}

function readOr(path, dflt = '') { try { return readFileSync(path, 'utf8').trim(); } catch { return dflt; } }

function checkPolicy(path) {
    const r = spawnSync(process.execPath, [join(APP, 'server.mjs'), '--check-policy', path], { stdio: 'inherit' });
    return r.status === 0;
}

function init() {
    for (const d of ['secrets', 'audit', 'outbox', 'inbox']) {
        if (!existsSync(join(ROOT, d))) throw new AdminError(`${ROOT}/${d} is missing; make vault-init creates it (as root, once)`);
    }
    for (const d of ['state', 'policy-backups', 'trash']) mkdirSync(join(ROOT, d), { recursive: true, mode: 0o700 });
    const pol = join(ROOT, 'policy.json');
    if (!existsSync(pol)) {
        const t = join(ROOT, `.policy.${TS}`);
        writeFileSync(t, EMPTY_POLICY, { mode: 0o640, flag: 'wx' });
        chmodSync(t, 0o640);
        renameSync(t, pol);
        out(`wrote an empty policy.json (fill it with make filler-seed-policy or make filler-policy-edit)`);
    }
    for (const f of ['controller-token', ...Object.values(TOKENS)]) {
        if (!readOr(join(SECRETS, f))) out(`secrets/${f} missing; make vault-tokens issues it`);
    }
    if (!readOr(join(SECRETS, 'vault-user-key'))) out('not enrolled yet; make vault-enroll BACKEND=shared');
    out(`${ROOT} ready`);
}

function tokenIssue(args) {
    needLayout();
    const name = args.NAME || '';
    const sha = TOKENS[name];
    if (!sha) throw new AdminError('NAME=bridge-client or NAME=vault-client');
    if (!existsSync(join(ROOT, 'outbox'))) throw new AdminError('outbox/ is missing; run make vault-init');
    if (readOr(join(SECRETS, sha)) && args.ROTATE !== '1') {
        throw new AdminError(`${name} already has a token (secrets/${sha}); ROTATE=1 replaces it, and the old one stops working`);
    }
    const tok = randomBytes(32).toString('hex');
    const hash = createHash('sha256').update(tok).digest('hex');
    // Made inside outbox/ so its setgid bit gives the file the operator's group.
    const ht = join(ROOT, 'outbox', `.${name}.${TS}`);
    writeFileSync(ht, tok, { mode: 0o640, flag: 'wx' });
    chmodSync(ht, 0o640);
    withSecretsOpen(() => put(sha, `${hash}\n`));
    const dst = join(ROOT, 'outbox', `${name}-token`);
    if (existsSync(dst)) renameSync(dst, join(trashDir(), `outbox-${name}-token`));
    renameSync(ht, dst);
    if (readOr(join(SECRETS, TOKENS['bridge-client'])) === readOr(join(SECRETS, TOKENS['vault-client']))) {
        process.stderr.write('filler-admin token-issue: WARNING: the two client tokens are the same; issue one again with ROTATE=1\n');
    }
    out(`wrote outbox/${name}-token`);
}

function tokensMissing() {
    for (const [name, sha] of Object.entries(TOKENS)) if (!readOr(join(SECRETS, sha))) process.stdout.write(`${name}\n`);
}

function controllerTokenTake() {
    needLayout();
    const src = join(ROOT, 'inbox', 'controller-token');
    try { lstatSync(src); } catch { throw new AdminError('nothing in inbox/; make vault-tokens drops it there first'); }
    const work = mkdtempSync(join(ROOT, 'trash', '.take-'));
    const tmp = join(work, 'controller-token');
    try { copyHandoff(src, tmp, { mode: 0o400 }); } catch (err) {
        throw new AdminError(`inbox/controller-token refused: ${err instanceof HandoffError ? err.message : (err.code || 'failed')}`);
    }
    const changed = withSecretsOpen(() => put('controller-token', readFileSync(tmp, 'utf8')));
    const t = trashDir();
    renameSync(src, join(t, 'inbox-controller-token'));
    renameSync(work, join(t, 'take-controller-token'));
    out(changed ? 'secrets/controller-token updated; restart the filler to use it' : 'secrets/controller-token unchanged');
}

function enroll() {
    needLayout();
    if (!process.stdin.isTTY) throw new AdminError('needs a terminal (docker compose run -it)');
    const r = withSecretsOpen(() => spawnSync(process.execPath, [join(APP, 'lib/providers/vaultwarden/enroll.mjs')], { stdio: 'inherit' }));
    if (r.status !== 0) throw new AdminError(`enroll exited ${r.status}`);
    out('restart the filler to use the new keys: make filler-restart');
}

function items() {
    needLayout();
    const r = spawnSync(process.execPath, [join(APP, 'lib/providers/vaultwarden/enroll.mjs'), '--items'], { stdio: 'inherit' });
    if (r.status !== 0) throw new AdminError(`items exited ${r.status}`);
}

function seedPolicy(args) {
    needLayout();
    const pol = join(ROOT, 'policy.json');
    const client = args.CLIENT || 'agent';
    if (!/^[a-z0-9][a-z0-9_-]{0,62}$/.test(client)) throw new AdminError('bad client name');
    const norm = readOr(pol).replace(/\s/g, '');
    if (norm && norm !== '{"version":1,"clients":{},"chats":{}}') { out('policy.json already has content; left as is'); return; }
    mkdirSync(join(ROOT, 'policy-backups'), { recursive: true, mode: 0o700 });
    if (existsSync(pol)) copyFileSync(pol, join(ROOT, 'policy-backups', `policy.${TS}.json`));
    const body = { version: 1, default_client: client, clients: { [client]: { all_items: true, secrets: {}, manage: { create: true, update: true, remove: true, compare: true, pipe: [] } } }, chats: {}, pipe_targets: {} };
    const t = join(ROOT, `.policy.${TS}`);
    writeFileSync(t, `${JSON.stringify(body)}\n`, { mode: 0o640, flag: 'wx' });
    chmodSync(t, 0o640);
    renameSync(t, pol);
    out(`wrote policy.json: default_client "${client}" with all_items and manage`);
    checkPolicy(pol);
}

function policyUpgrade() {
    needLayout();
    const pol = join(ROOT, 'policy.json');
    if (!existsSync(pol)) throw new AdminError('no policy; run make vault-init first');
    let up;
    try { up = upgradePolicy(JSON.parse(readFileSync(pol, 'utf8'))); } catch (err) { throw new AdminError(`policy not upgraded: ${err.message}`); }
    if (!up) { out('policy.json already has pipe_targets; left as is'); return; }
    mkdirSync(join(ROOT, 'policy-backups'), { recursive: true, mode: 0o700 });
    copyFileSync(pol, join(ROOT, 'policy-backups', `policy.${TS}.json`));
    const t = join(ROOT, `.policy.${TS}`);
    writeFileSync(t, `${JSON.stringify(up, null, 2)}\n`, { mode: 0o640, flag: 'wx' });
    chmodSync(t, 0o640);
    renameSync(t, pol);
    out('upgraded policy.json (backup in policy-backups/)');
    checkPolicy(pol);
}

function policyEdit() {
    needLayout();
    if (!process.stdin.isTTY) throw new AdminError('needs a terminal (docker compose run -it)');
    const pol = join(ROOT, 'policy.json');
    if (!existsSync(pol)) throw new AdminError('no policy; run make vault-init first');
    mkdirSync(join(ROOT, 'policy-backups'), { recursive: true, mode: 0o700 });
    const backup = join(ROOT, 'policy-backups', `policy.${TS}.json`);
    copyFileSync(pol, backup);
    const t = join(ROOT, `.policy-edit.${TS}.json`);
    copyFileSync(pol, t);
    chmodSync(t, 0o640);
    const ed = process.env.VISUAL || process.env.EDITOR || 'vi';
    spawnSync(ed, [t], { stdio: 'inherit' });
    if (readFileSync(t, 'utf8') === readFileSync(pol, 'utf8')) {
        renameSync(t, join(trashDir(), 'policy-edit-unchanged.json'));
        out('unchanged');
        return;
    }
    chmodSync(t, 0o640);
    if (!checkPolicy(t)) {
        const keep = join(trashDir(), 'policy-edit-invalid.json');
        renameSync(t, keep);
        throw new AdminError(`the edit is invalid and was not saved; policy.json unchanged (your edit: ${keep})`);
    }
    renameSync(t, pol);
    out(`saved (the old one is policy-backups/${basename(backup)}); the running filler reloads it on its own`);
}

function outboxClear() {
    const dir = join(ROOT, 'outbox');
    let n = 0;
    let d = null;
    for (const f of readdirSync(dir)) {
        d = d || join(trashDir(), 'outbox');
        mkdirSync(d, { recursive: true, mode: 0o700 });
        renameSync(join(dir, f), join(d, f));
        n += 1;
    }
    out(`moved ${n} file(s)${d ? ` to ${d}` : ''}`);
}

export const COMMANDS = {
    init, 'token-issue': tokenIssue, 'tokens-missing': tokensMissing, 'controller-token-take': controllerTokenTake,
    enroll, items, 'seed-policy': seedPolicy, 'policy-edit': policyEdit, 'policy-upgrade': policyUpgrade,
    'check-policy': () => { if (!checkPolicy(join(ROOT, 'policy.json'))) throw new AdminError('policy invalid'); },
    'outbox-clear': outboxClear,
};

export function parseArgs(argv) {
    const args = {};
    for (const a of argv) {
        const m = /^(NAME|ROTATE|CLIENT)=(.*)$/.exec(a);
        if (!m) throw new AdminError(`unknown argument ${a.split('=')[0].slice(0, 40)}`);
        args[m[1]] = m[2];
    }
    return args;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
    process.umask(0o077);
    cmd = process.argv[2] || '';
    try {
        const fn = COMMANDS[cmd];
        if (!fn) throw new AdminError(`unknown command; one of: ${Object.keys(COMMANDS).join(', ')}`);
        fn(parseArgs(process.argv.slice(3)));
    } catch (err) {
        process.stderr.write(`filler-admin${cmd ? ` ${cmd}` : ''}: ${err instanceof AdminError ? err.message : (err.code || err.message)}\n`);
        process.exit(1);
    }
}
