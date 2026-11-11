// A live smoke test of the 1Password provider against a real service account.
// Skipped unless both are set:
//   OP_TEST_TOKEN_FILE  a service account token file (mode 0400)
//   OP_TEST_VAULT       a vault name or id the account can write, used only
//                       for this test
// It lists, creates one login, reads it, updates it, trashes and restores it,
// and leaves it tagged happy-trashed (the provider never deletes). Values are
// never printed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { basename, dirname, resolve } from 'node:path';
import { createOnePasswordProvider } from '../lib/providers/onepassword/index.mjs';
import { generatePassword } from '../lib/generate.mjs';

const tokenFile = process.env.OP_TEST_TOKEN_FILE;
const vault = process.env.OP_TEST_VAULT;
const skip = !(tokenFile && vault) && 'set OP_TEST_TOKEN_FILE and OP_TEST_VAULT to run';

test('1Password live: list, create, read, update, trash, restore', { skip, timeout: 120_000 }, async () => {
    const p = createOnePasswordProvider({ id: 'live', vault, secretsDir: dirname(resolve(tokenFile)), token_file: basename(tokenFile) });
    const before = await p.listItems({ trash: true });
    assert.ok(Array.isArray(before));
    assert.equal(p.status().unlocked, true);
    const name = `happy-filler-live-${Date.now()}`;
    const pw = generatePassword();
    const id = await p.createLogin({ name, uris: ['https://live-test.example.com/login'], username: 'live-user', password: pw });
    assert.equal(p.checkId(id), id);
    const it = await p.readItem(id);
    assert.equal(it.name, name);
    assert.ok(it.password === pw, 'password round trip');
    assert.deepEqual(await p.updateLogin(id, { username: 'live-user-2' }), ['username']);
    assert.equal((await p.readItem(id)).username, 'live-user-2');
    await p.trashLogin(id);
    assert.ok(!(await p.listItems()).some((i) => i.id === id));
    await p.restoreLogin(id);
    assert.ok((await p.listItems()).some((i) => i.id === id));
    await p.trashLogin(id);
    p.lock();
});
