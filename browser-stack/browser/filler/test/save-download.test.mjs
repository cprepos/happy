// save_download (lib/manage.mjs): a file the chat's browser downloaded goes
// into the vault as an encrypted attachment, is read back and compared, and
// only then is the browser's copy deleted. Checks the success paths (a new
// secure note, an existing item by name and by id), a verify mismatch (nothing
// deleted), a file changed on disk before the delete (kept), a download id from
// another session (refused before any byte is read), the size cap, the policy
// flag, and that no byte, file name or source URL reaches the result or audit.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createManager } from '../lib/manage.mjs';
import { parsePolicy } from '../lib/policy.mjs';
import { decryptKey, decryptSymText } from '../lib/providers/vaultwarden/vaultcrypto.mjs';
import { createOnePasswordProvider } from '../lib/providers/onepassword/index.mjs';
import { managePolicy, setup } from './helpers.mjs';
import { loginPages } from './fake-controller.mjs';
import { fakeOnePassword, VAULT_TITLE } from './fake-onepassword.mjs';

const D = 'none'; // default_client: agent (all_items)
const sha = (b) => createHash('sha256').update(b).digest('hex');

async function mk(opts = {}, { agentFlag = true, acmeFlag = false } = {}) {
    const t = await setup();
    const raw = managePolicy(t.v);
    raw.clients.agent.manage.save_download = agentFlag;
    raw.clients.acme.manage.save_download = acmeFlag;
    const policy = parsePolicy(JSON.stringify(raw));
    const m = createManager({ getPolicy: () => policy, vault: t.vault, audit: t.audit, controllers: t.controllers, ...opts });
    t.ctl.addSession('sess-a', loginPages());
    t.ctl.addSession('sess-b', loginPages());
    const auditText = () => readdirSync(join(t.dir, 'audit')).map((f) => readFileSync(join(t.dir, 'audit', f), 'utf8')).join('');
    const body = (over = {}) => ({ chat: D, session_id: 'sess-a', controller_port: t.port, ...over });
    return { ...t, m, policy, auditText, body };
}

/** An attachment of a stored cipher, decrypted the way a Bitwarden client would. */
function readBack(t, itemId, attId) {
    const c = t.v.sync.ciphers.find((x) => x.id === itemId);
    const ik = c.key ? decryptKey(c.key, { symKey: t.v.userKey }) : t.v.userKey;
    const a = c.attachments.find((x) => x.id === attId);
    return { c, name: decryptSymText(a.fileName, ik), bytes: t.vw.files.get(`${itemId}/${attId}`), key: decryptKey(a.key, { symKey: ik }) };
}

test('save_download into a new secure note: stored, verified, the download deleted; only metadata comes back', async () => {
    const t = await mk();
    try {
        const bytes = Buffer.concat([Buffer.from('SECRET-FILE-CONTENT-'), randomBytes(5000)]);
        t.ctl.addDownload('sess-a', { id: 'a1b2c3d4e5f6', name: 'statement.pdf', bytes });
        const r = await t.m.save_download(t.body({ download_id: 'a1b2c3d4e5f6', new_item: { name: 'test-download-1', uris: ['https://bank.example/'] } }));
        assert.deepEqual(Object.keys(r).sort(), ['attachment_id', 'download_deleted', 'file_name', 'item_id', 'item_name', 'sha256', 'size']);
        assert.equal(r.item_name, 'test-download-1');
        assert.equal(r.file_name, 'statement.pdf');
        assert.equal(r.size, bytes.length);
        assert.equal(r.sha256, sha(bytes));
        assert.equal(r.download_deleted, true);
        assert.deepEqual(t.ctl.deleted, [{ session: 'sess-a', id: 'a1b2c3d4e5f6', sha256: sha(bytes) }]);
        assert.deepEqual(t.ctl.downloadsOf('sess-a'), []);
        // The vault holds a secure note with the encrypted file; its own decrypt gives the bytes back.
        const back = readBack(t, r.item_id, r.attachment_id);
        assert.equal(back.c.type, 2);
        assert.equal(back.c.login, null);
        assert.equal(back.name, 'statement.pdf');
        assert.ok(!back.bytes.includes(Buffer.from('SECRET-FILE-CONTENT-')), 'stored encrypted');
        const dec = await t.vault.readAttachment(r.item_id, r.attachment_id);
        assert.ok(dec.equals(bytes));
        // The attachment download URL's token query never shows up anywhere the agent sees.
        const s = JSON.stringify(r) + t.auditText();
        for (const leak of ['SECRET-FILE-CONTENT', 'SECRET-QUERY', 'files.example.test', 'token=', 'statement.pdf']) assert.ok(!t.auditText().includes(leak), `audit leaks ${leak}`);
        for (const leak of ['SECRET-FILE-CONTENT', 'SECRET-QUERY', 'files.example.test', 'token=']) assert.ok(!s.includes(leak), `leaks ${leak}`);
        const line = JSON.parse(t.auditText().trim().split('\n').pop());
        assert.equal(line.action, 'save_download');
        assert.equal(line.outcome, 'ok');
        assert.equal(line.download_id, 'a1b2c3d4e5f6');
        assert.equal(line.sha256, sha(bytes));
        assert.equal(line.size, String(bytes.length));
        assert.equal(line.item_id, r.item_id);
        // vault_list shows the note, marked as one, with its attachment's metadata.
        const note = (await t.m.list({ chat: D })).items.find((i) => i.id === r.item_id);
        assert.equal(note.kind, 'note');
        assert.equal(note.secret, undefined, 'a note is never a fill name');
        assert.deepEqual(note.attachments, [{ id: r.attachment_id, file_name: 'statement.pdf', size: back.bytes.length }]);
        // A note can be trashed and restored (vault_remove / vault_restore).
        await t.m.remove({ chat: D, id: r.item_id });
        assert.ok(t.v.sync.ciphers.find((x) => x.id === r.item_id).deletedDate);
        await t.m.restore({ chat: D, id: r.item_id });
        assert.equal(t.vw.calls.refusedWrites.length, 0, 'nothing ever hard-deleted in the vault');
    } finally { await t.close(); }
});

test('save_download into an existing item, by name and by id; file_name renames the attachment', async () => {
    const t = await mk();
    try {
        const one = Buffer.from('first file');
        const two = Buffer.from('second file');
        t.ctl.addDownload('sess-a', { id: '000000000001', name: 'one.txt', bytes: one });
        t.ctl.addDownload('sess-a', { id: '000000000002', name: 'two.txt', bytes: two });
        const gm = t.v.items.gmail.id;
        const r1 = await t.m.save_download(t.body({ download_id: '000000000001', item: 'GMAIL' }));
        assert.equal(r1.item_id, gm);
        assert.equal(r1.item_name, 'gmail');
        assert.equal(r1.download_deleted, true);
        const r2 = await t.m.save_download(t.body({ download_id: '000000000002', item: gm.toUpperCase(), file_name: 'renamed.txt' }));
        assert.equal(r2.item_id, gm);
        assert.equal(r2.file_name, 'renamed.txt');
        const c = t.v.sync.ciphers.find((x) => x.id === gm);
        assert.equal(c.attachments.length, 2);
        assert.equal(c.type, 1, 'still a login');
        assert.ok((await t.vault.readAttachment(gm, r2.attachment_id)).equals(two));
        assert.equal(readBack(t, gm, r2.attachment_id).name, 'renamed.txt');
        // The login's password is untouched.
        assert.equal(t.vw.calls.writes.filter((w) => w.op === 'update').length, 0);
    } finally { await t.close(); }
});

test('a vault copy that does not match: the download and the attachment both stay, the call fails', async () => {
    const t = await mk();
    try {
        const bytes = Buffer.from('important contract');
        t.ctl.addDownload('sess-a', { id: 'abcdefabcdef', name: 'contract.pdf', bytes });
        t.vw.hooks.tamper = (b) => { b[b.length - 1] ^= 1; return b; };
        await assert.rejects(t.m.save_download(t.body({ download_id: 'abcdefabcdef', item: 'gmail' })), (e) => e.status === 502 && e.outcome === 'verify_failed' && !/important contract/.test(e.message));
        assert.deepEqual(t.ctl.deleted, []);
        assert.equal(t.ctl.downloadsOf('sess-a').length, 1, 'the download is kept');
        assert.equal(t.v.sync.ciphers.find((x) => x.id === t.v.items.gmail.id).attachments.length, 1, 'the attachment is kept');
        assert.equal(t.vw.calls.refusedWrites.length, 0);
        assert.match(t.auditText(), /"outcome":"verify_failed"/);
    } finally { await t.close(); }
});

test('a download that changed on disk before the delete: verified in the vault, the browser copy kept', async () => {
    const t = await mk();
    try {
        const bytes = Buffer.from('original bytes');
        t.ctl.addDownload('sess-a', { id: 'feedfacecafe', name: 'f.bin', bytes });
        // Between the fetch and the delete (while the vault copy is read back), the file changes.
        t.vw.hooks.tamper = (b) => { t.ctl.changeDownload('sess-a', 'feedfacecafe', Buffer.from('changed bytes!')); return b; };
        const r = await t.m.save_download(t.body({ download_id: 'feedfacecafe', item: 'gmail' }));
        assert.equal(r.download_deleted, false);
        assert.match(r.note, /not deleted/);
        assert.equal(r.sha256, sha(bytes));
        assert.deepEqual(t.ctl.deleted, []);
        assert.equal(t.ctl.downloadsOf('sess-a').length, 1);
    } finally { await t.close(); }
});

test('a download id from another session is refused before any byte is read', async () => {
    const t = await mk();
    try {
        t.ctl.addDownload('sess-b', { id: 'bbbbbbbbbbbb', name: 'theirs.txt', bytes: Buffer.from('not yours') });
        await assert.rejects(t.m.save_download(t.body({ download_id: 'bbbbbbbbbbbb', new_item: { name: 'stolen' } })), (e) => e.status === 404);
        assert.deepEqual(t.ctl.artifactReads, []);
        assert.equal(t.vw.calls.writes.length, 0, 'no note created');
        // A session this filler cannot reach, or a controller port not in its list.
        await assert.rejects(t.m.save_download(t.body({ download_id: 'bbbbbbbbbbbb', item: 'gmail', session_id: 'sess-x' })), (e) => e.status === 404);
        await assert.rejects(t.m.save_download(t.body({ download_id: 'bbbbbbbbbbbb', item: 'gmail', controller_port: 1 })), (e) => e.status === 403 && e.outcome === 'refused_controller');
        await assert.rejects(t.m.save_download(t.body({ download_id: 'bbbbbbbbbbbb', item: 'gmail', session_id: '../sess-b' })), (e) => e.status === 400);
        await assert.rejects(t.m.save_download({ chat: D, download_id: 'bbbbbbbbbbbb', item: 'gmail' }), (e) => e.status === 400);
        assert.deepEqual(t.ctl.artifactReads, []);
        assert.equal(t.ctl.downloadsOf('sess-b').length, 1);
    } finally { await t.close(); }
});

test('the size cap: a larger download is refused, nothing is created', async () => {
    const t = await mk({ maxDownload: 1024 });
    try {
        t.ctl.addDownload('sess-a', { id: '0123456789ab', name: 'big.bin', bytes: randomBytes(4096) });
        await assert.rejects(t.m.save_download(t.body({ download_id: '0123456789ab', new_item: { name: 'big' } })), (e) => e.status === 413 && e.outcome === 'refused_size');
        assert.equal(t.vw.calls.writes.length, 0);
        assert.deepEqual(t.ctl.deleted, []);
        assert.equal(t.ctl.downloadsOf('sess-a').length, 1);
    } finally { await t.close(); }
});

test('refusals: the policy flag, bad input, an unfinished download, item names, new items, the rate limit', async () => {
    const t = await mk({ saveLimit: { max: 1, windowMs: 60_000 } }, { acmeFlag: true });
    try {
        t.ctl.addDownload('sess-a', { id: '111111111111', name: 'a.txt', bytes: Buffer.from('a') });
        t.ctl.addDownload('sess-a', { id: '222222222222', name: 'b.txt', bytes: Buffer.from('b'), status: 'in_progress' });
        const off = await mk({}, { agentFlag: false });
        try {
            off.ctl.addDownload('sess-a', { id: '111111111111', name: 'a.txt', bytes: Buffer.from('a') });
            await assert.rejects(off.m.save_download(off.body({ download_id: '111111111111', item: 'gmail' })), (e) => e.status === 403 && e.outcome === 'refused_manage' && /manage.save_download/.test(e.message));
            assert.deepEqual(off.ctl.artifactReads, []);
        } finally { await off.close(); }
        const bad = (over, re) => assert.rejects(t.m.save_download(t.body({ download_id: '111111111111', ...over })), re);
        await bad({ download_id: 'xyz' }, /download_id/);
        await bad({}, /exactly one of item/);
        await bad({ item: 'gmail', new_item: { name: 'x' } }, /exactly one of item/);
        await bad({ new_item: { name: 'x', password: 'p' } }, /unknown key/);
        await bad({ new_item: { name: 'x', uris: ['http://x'] } }, /https/);
        await bad({ item: 'gmail', file_name: '../etc/passwd' }, /without slashes/);
        await bad({ item: 'gmail', client_id: 'acme' }, /unknown key/);
        await bad({ item: 'gmail', download_id: '222222222222' }, (e) => e.status === 409);
        await bad({ item: 'no-such-item' }, (e) => e.status === 404);
        await bad({ new_item: { name: 'GMAIL' } }, (e) => e.status === 409);
        // acme reaches only its listed logins, and may not make new items (not all_items).
        await assert.rejects(t.m.save_download(t.body({ chat: 'chat-acme', download_id: '111111111111', item: 'gmail' })), (e) => e.status === 404);
        await assert.rejects(t.m.save_download(t.body({ chat: 'chat-acme', download_id: '111111111111', new_item: { name: 'x' } })), (e) => e.status === 403);
        assert.deepEqual(t.ctl.artifactReads, []);
        assert.equal(t.vw.calls.writes.length, 0);
        // The limit counts transfers per client.
        t.ctl.addDownload('sess-a', { id: '333333333333', name: 'c.txt', bytes: Buffer.from('c') });
        assert.equal((await t.m.save_download(t.body({ download_id: '111111111111', item: 'gmail' }))).download_deleted, true);
        await assert.rejects(t.m.save_download(t.body({ download_id: '333333333333', item: 'gmail' })), (e) => e.status === 429);
        assert.equal(t.ctl.downloadsOf('sess-a').length, 2, 'the limited one is kept');
    } finally { await t.close(); }
});

test('a vault that cannot store files (1Password) refuses save_download clearly', async () => {
    const t = await setup();
    try {
        const op = fakeOnePassword();
        const p = createOnePasswordProvider({ vault: VAULT_TITLE }, { client: op.client });
        assert.equal(p.capabilities.attach, false);
        const raw = managePolicy(t.v);
        raw.clients.agent.manage.save_download = true;
        const policy = parsePolicy(JSON.stringify(raw));
        const m = createManager({ getPolicy: () => policy, vault: p, audit: t.audit, controllers: t.controllers });
        t.ctl.addSession('sess-a', loginPages());
        t.ctl.addDownload('sess-a', { id: '111111111111', name: 'a.txt', bytes: Buffer.from('a') });
        await assert.rejects(m.save_download({ chat: D, session_id: 'sess-a', controller_port: t.port, download_id: '111111111111', new_item: { name: 'x' } }), (e) => e.status === 422 && e.outcome === 'refused_unsupported' && /cannot store files/.test(e.message));
        assert.deepEqual(t.ctl.artifactReads, []);
        assert.ok(!op.calls.some((c) => /put|create/i.test(c.name)));
    } finally { await t.close(); }
});
