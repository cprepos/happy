// The unit runs /srv/happy-filler/current/app/server.mjs, where current is a
// symlink to releases/<sha>. Each entry point must still run its main when
// started through such a link (a silent exit 0 looped the unit on 2026-11-05).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const APP = dirname(dirname(fileURLToPath(import.meta.url)));
const dir = mkdtempSync(join(tmpdir(), 'filler-entry-'));
const link = join(dir, 'current');
symlinkSync(APP, link);

test('policy-upgrade runs through a symlinked release', () => {
    const pol = join(dir, 'policy.json');
    writeFileSync(pol, JSON.stringify({ version: 1, default_client: 'agent', clients: { agent: { all_items: true } } }));
    const out = execFileSync(process.execPath, [join(link, 'scripts/policy-upgrade.mjs'), pol], { encoding: 'utf8' });
    assert.match(out, /"pipe_targets"/);
});

for (const entry of ['server.mjs', 'lib/providers/vaultwarden/enroll.mjs', 'scripts/handoff-copy.mjs']) {
    test(`${entry} does not exit silently through a symlinked release`, () => {
        const r = spawnSync(process.execPath, [join(link, entry), '--no-such-flag'], {
            encoding: 'utf8', timeout: 5000, env: { PATH: process.env.PATH, FILLER_HOME: join(dir, 'nohome') },
        });
        assert.ok(r.status !== 0 || r.stdout || r.stderr, `${entry} exited 0 with no output`);
    });
}
