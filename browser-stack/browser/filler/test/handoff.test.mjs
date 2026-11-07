import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, linkSync, mkdirSync, mkdtempSync, readFileSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { copyHandoff, HandoffError, readHandoff } from '../scripts/handoff-copy.mjs';

const TOKEN = 'a'.repeat(64);
// Files a test creates are its own; pretending the reader is someone else makes them "the other side's".
const other = { selfUid: process.getuid() + 1 };

function scratch() { return mkdtempSync(join(tmpdir(), 'filler-handoff-')); }

test('handoff: a token from the other side is copied, trailing newline dropped, mode as asked, never overwriting', () => {
    const d = scratch();
    writeFileSync(join(d, 'tok'), `${TOKEN}\n`);
    assert.equal(readHandoff(join(d, 'tok'), other), TOKEN);
    copyHandoff(join(d, 'tok'), join(d, 'out'), { mode: 0o600, ...other });
    assert.equal(readFileSync(join(d, 'out'), 'utf8'), TOKEN);
    assert.equal(statSync(join(d, 'out')).mode & 0o777, 0o600);
    assert.throws(() => copyHandoff(join(d, 'tok'), join(d, 'out'), other), /EEXIST/);
});

test('handoff: a file of the reader\'s own is refused', () => {
    const d = scratch();
    writeFileSync(join(d, 'tok'), TOKEN);
    assert.throws(() => readHandoff(join(d, 'tok')), /owned by the reader/);
});

test('handoff: symlinks, hard links, directories, oversize and non-token content are refused', () => {
    const d = scratch();
    writeFileSync(join(d, 'secret'), TOKEN);
    symlinkSync(join(d, 'secret'), join(d, 'link'));
    assert.throws(() => readHandoff(join(d, 'link'), other), (e) => e instanceof HandoffError && /symlink/.test(e.message));
    linkSync(join(d, 'secret'), join(d, 'hard'));
    assert.throws(() => readHandoff(join(d, 'hard'), other), /more than one link/);
    mkdirSync(join(d, 'dir'));
    assert.throws(() => readHandoff(join(d, 'dir'), other), /not a regular file/);
    writeFileSync(join(d, 'big'), 'a'.repeat(2000));
    assert.throws(() => readHandoff(join(d, 'big'), other), /too large/);
    writeFileSync(join(d, 'bad'), 'not a token; rm -rf /');
    assert.throws(() => readHandoff(join(d, 'bad'), other), /does not hold a token/);
    writeFileSync(join(d, 'short'), 'abc');
    assert.throws(() => readHandoff(join(d, 'short'), other), /does not hold a token/);
    assert.throws(() => readHandoff(join(d, 'missing'), other), /missing/);
    writeFileSync(join(d, 'locked'), TOKEN); chmodSync(join(d, 'locked'), 0o000);
    if (process.getuid() !== 0) assert.throws(() => readHandoff(join(d, 'locked'), other), /unreadable/);
});

test('handoff: no error message carries the value', () => {
    const d = scratch();
    const v = 'Zz9'.repeat(10);
    writeFileSync(join(d, 'x'), `${v} trailing junk`);
    try { readHandoff(join(d, 'x'), other); assert.fail('expected a refusal'); } catch (err) { assert.ok(!String(err.message).includes(v)); }
});
