import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { upgradePolicy, MANAGE_ALL } from '../scripts/policy-upgrade.mjs';

const SCRIPT = fileURLToPath(new URL('../scripts/policy-upgrade.mjs', import.meta.url));
const OLD = { version: 1, default_client: 'agent', clients: { agent: { all_items: true, secrets: {} } }, chats: {} };

test('policy-upgrade gives the all_items client manage and adds pipe_targets, once', () => {
    const up = upgradePolicy(OLD);
    assert.deepEqual(up, { ...OLD, clients: { agent: { all_items: true, secrets: {}, manage: { ...MANAGE_ALL } } }, pipe_targets: {} });
    assert.equal(OLD.pipe_targets, undefined, 'input left alone');
    assert.equal(upgradePolicy(up), null, 'already upgraded');
    // An operator who removed manage after the upgrade keeps it removed.
    assert.equal(upgradePolicy({ ...OLD, pipe_targets: {} }), null);
    // A client without all_items gets nothing.
    const two = upgradePolicy({ version: 1, clients: { acme: { secrets: {} } }, chats: {} });
    assert.equal(two.clients.acme.manage, undefined);
});

test('policy-upgrade CLI: prints the upgrade, exit 3 when done, exit 1 on bad input', () => {
    const dir = mkdtempSync(join(tmpdir(), 'pu-'));
    const p = join(dir, 'policy.json');
    writeFileSync(p, JSON.stringify(OLD));
    let r = spawnSync(process.execPath, [SCRIPT, p], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(JSON.parse(r.stdout).clients.agent.manage, MANAGE_ALL);
    writeFileSync(p, r.stdout);
    r = spawnSync(process.execPath, [SCRIPT, p], { encoding: 'utf8' });
    assert.equal(r.status, 3);
    assert.equal(r.stdout, '');
    writeFileSync(p, '{"version":1,"clients":{"x":{"bogus":1}},"chats":{}}');
    r = spawnSync(process.execPath, [SCRIPT, p], { encoding: 'utf8' });
    assert.equal(r.status, 1);
    assert.equal(r.stdout, '');
});
