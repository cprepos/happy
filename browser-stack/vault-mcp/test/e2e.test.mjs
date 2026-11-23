// End to end, against fakes only: a real filler (createApp on a loopback port,
// its own temp audit and state) wired to the fake Vaultwarden, whose jira
// login carries a custom field "token", and the real vault-mcp process over
// stdio talking to it with the vault-client token. vault_list shows the
// custom field's name and no value; vault_pipe with custom_field "token"
// into cat, sha256sum and base64 returns output scrubbed to [secret:token],
// and sha256sum's digest, checked here, is that of the stored value.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { createApp, tokenChecker } from '../../browser/filler/server.mjs';
import { parsePolicy } from '../../browser/filler/lib/policy.mjs';
import { createVaultwardenProvider as createVault } from '../../browser/filler/lib/providers/vaultwarden/index.mjs';
import { controllerSet } from '../../browser/filler/lib/controller.mjs';
import { createScrubber } from '../../browser/filler/lib/scrub.mjs';
import { createTaint } from '../../browser/filler/lib/taint.mjs';
import { createAudit } from '../../browser/filler/lib/audit.mjs';
import { startFakeVaultwarden } from '../../browser/filler/test/fake-vaultwarden.mjs';
import { managePolicy } from '../../browser/filler/test/helpers.mjs';
import { startFakeController, loginPages } from '../../browser/filler/test/fake-controller.mjs';
import { chatKeyOf } from '../mcp.mjs';

const sha = (s) => createHash('sha256').update(s).digest('hex');

test('e2e: filler + fake vault + vault-mcp stdio: custom field "token" listed by name, piped, scrubbed', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'vault-e2e-'));
    const vw = await startFakeVaultwarden();
    const v = vw.vault;
    const TOKEN = sha(`b-${Math.random()}`); const VTOKEN = sha(`v-${Math.random()}`);
    const p = managePolicy(v);
    // Targets that show what reached stdin, so the scrub has something to do.
    p.pipe_targets = { ...p.pipe_targets, cat: { argv: ['cat'] }, b64: { argv: ['base64', '-w0'] } };
    p.clients.agent.manage.pipe = ['sha', 'cat', 'b64'];
    const policy = parsePolicy(JSON.stringify(p));
    const controllers = controllerSet({ defaultPort: 9, ports: [], token: 'x' });
    const scrubber = createScrubber();
    const audit = createAudit(join(dir, 'audit'));
    const handle = createApp({
        checkToken: tokenChecker(sha(TOKEN)), checkVaultToken: tokenChecker(sha(VTOKEN)),
        getPolicy: () => policy,
        vault: createVault({ url: vw.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'dev-e2e' }),
        controllers, scrubber, taint: createTaint({ statePath: join(dir, 'state', 'taint.json'), scrubber, controllers }), audit,
        sleep: async () => {}, totpOpts: { minLeftS: 0 },
    });
    const filler = createServer(handle);
    await new Promise((r) => filler.listen(0, '127.0.0.1', r));
    const home = join(dir, 'mcp-home');
    mkdirSync(join(home, 'secrets'), { recursive: true });
    writeFileSync(join(home, 'secrets', 'vault-client-token'), `${VTOKEN}\n`, { mode: 0o600 });
    const env = { ...process.env, HAPPY_VAULT_MCP_HOME: home, HAPPY_VAULT_FILLER_URL: `http://127.0.0.1:${filler.address().port}` };
    for (const k of ['HAPPY_SESSION_ID', 'BROWSER_CHAT_FROM_META', 'BROWSER_VAULT_MCP_HOME', 'BROWSER_VAULT_FILLER_URL']) delete env[k];
    const child = spawn(process.execPath, [fileURLToPath(new URL('../mcp.mjs', import.meta.url))], { env, stdio: ['pipe', 'pipe', 'pipe'] });
    const wire = []; // every line the MCP process wrote
    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d; });
    const waiters = new Map();
    createInterface({ input: child.stdout }).on('line', (l) => { wire.push(l); const m = JSON.parse(l); waiters.get(m.id)?.(m); });
    let n = 0;
    const ask = (method, params) => new Promise((r) => { const id = ++n; waiters.set(id, r); child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n'); });
    const tool = async (name, args) => { const m = await ask('tools/call', { name, arguments: args }); return { isError: !!m.result.isError, text: m.result.content[0].text }; };
    const value = v.items.jira.fields.find((f) => f.name === 'token').value;
    const report = [];
    try {
        await ask('initialize', { protocolVersion: '2025-06-18' });
        const list = await tool('vault_list', {});
        assert.equal(list.isError, false, list.text);
        const jira = JSON.parse(list.text).items.find((i) => i.name === 'jira');
        assert.deepEqual(jira.custom_fields, ['token', 'Region', 'enabled', 'dup', 'empty', 'broken']);
        assert.ok(!list.text.includes(value), 'no custom field value in vault_list');
        report.push(`vault_list jira.custom_fields=${JSON.stringify(jira.custom_fields)}`);

        const sum = await tool('vault_pipe', { id: jira.id, custom_field: 'token', target: 'sha' });
        assert.equal(sum.isError, false, sum.text);
        const so = JSON.parse(sum.text);
        assert.equal(so.exit_code, 0);
        assert.deepEqual(so.argv, ['sha256sum']);
        assert.equal(so.stdout.trim(), `${sha(value)}  -`, 'sha256sum of what reached stdin is the stored token\'s');
        report.push(`sha: exit ${so.exit_code} stdout ${JSON.stringify(so.stdout.trim())}`);

        const cat = JSON.parse((await tool('vault_pipe', { id: jira.id, custom_field: 'token', target: 'cat' })).text);
        assert.equal(cat.exit_code, 0);
        assert.equal(cat.stdout, '[secret:token]');
        report.push(`cat: exit ${cat.exit_code} stdout ${JSON.stringify(cat.stdout)}`);
        const b64 = JSON.parse((await tool('vault_pipe', { id: jira.id, custom_field: 'token', target: 'b64' })).text);
        assert.equal(b64.stdout, '[secret:token]', 'the base64 form is scrubbed too');
        report.push(`b64: exit ${b64.exit_code} stdout ${JSON.stringify(b64.stdout)}`);

        const cmp = JSON.parse((await tool('vault_compare', { id: jira.id, custom_field: 'token', algo: 'sha256', digest: sha(value) })).text);
        assert.deepEqual(cmp, { match: true });
        const unknown = await tool('vault_pipe', { id: jira.id, custom_field: 'Token', target: 'cat' });
        assert.ok(unknown.isError && /no custom field "Token".*"token"/.test(unknown.text), unknown.text);
        const dup = await tool('vault_pipe', { id: jira.id, custom_field: 'dup', target: 'cat' });
        assert.ok(dup.isError && /ambiguous/.test(dup.text), dup.text);
        const both = await tool('vault_pipe', { id: jira.id, field: 'password', custom_field: 'token', target: 'cat' });
        assert.ok(both.isError && /exactly one/.test(both.text), both.text);
        report.push(`compare=${JSON.stringify(cmp)}; Token -> ${unknown.text.slice(0, 80)}...; dup -> ${dup.text}; both -> ${both.text}`);

        // The leak sweep: the token in no MCP line, no audit line, nothing on stderr.
        const auditText = readdirSync(join(dir, 'audit')).map((f) => readFileSync(join(dir, 'audit', f), 'utf8')).join('');
        assert.match(auditText, /"field_kind":"custom:token"/);
        for (const [where, blob] of [['MCP wire', wire.join('\n')], ['audit', auditText], ['stderr', stderr]]) {
            for (const form of [value, Buffer.from(value).toString('base64'), JSON.stringify(value).slice(1, -1)]) assert.ok(!blob.includes(form), `token in ${where}`);
        }
        report.push(`sweep: ${wire.length} MCP lines, ${auditText.trim().split('\n').length} audit lines, no token`);
        if (process.env.VAULT_E2E_REPORT) process.stderr.write(report.map((l) => `vault-e2e: ${l}\n`).join(''));
    } finally {
        child.stdin.end();
        filler.closeAllConnections?.();
        await new Promise((r) => filler.close(r));
        await vw.close();
    }
});

// save_download then pipe: a PEM the browser downloaded goes into the vault
// (a new secure note), vault_list shows its attachment id, and vault_pipe sends
// it into a gh-secret-shaped target (sh -c sha256sum, same arg slots). The
// digest matches, the PEM is in no MCP line, audit line or stderr, and the
// MCP process's and this process's temp dirs stay empty.
test('e2e: vault_save_download a PEM, then vault_pipe it by attachment id; scrubbed, nothing on disk', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'vault-e2e-att-'));
    const tmp = join(dir, 'tmp'); mkdirSync(tmp);
    const oldTmp = process.env.TMPDIR;
    const vw = await startFakeVaultwarden();
    const ctl = await startFakeController();
    const v = vw.vault;
    const TOKEN = sha(`b-${Math.random()}`); const VTOKEN = sha(`v-${Math.random()}`); const BTOKEN = sha(`r-${Math.random()}`);
    const PEM = '-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgE2eAttachCanary0\n-----END PRIVATE KEY-----\n';
    const p = managePolicy(v);
    const slots = { name: '^[A-Za-z_][A-Za-z0-9_]*$', repo: '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' };
    p.pipe_targets = { ...p.pipe_targets, 'secret-sum': { argv: ['sh', '-c', 'sha256sum', '{arg:name}', '{arg:repo}'], args: slots }, cat: { argv: ['cat'] } };
    p.clients.agent.manage = { ...p.clients.agent.manage, save_download: true, pipe: ['sha', 'secret-sum', 'cat'] };
    const policy = parsePolicy(JSON.stringify(p));
    const ctlPort = Number(new URL(ctl.url).port);
    const controllers = controllerSet({ defaultPort: ctlPort, ports: [], token: ctl.token });
    ctl.addSession('sess-e2e', loginPages());
    ctl.addDownload('sess-e2e', { id: 'a1b2c3d4e5f6', name: 'AuthKey_E2E.p8', bytes: Buffer.from(PEM) });
    const scrubber = createScrubber();
    const audit = createAudit(join(dir, 'audit'));
    const handle = createApp({
        checkToken: tokenChecker(sha(TOKEN)), checkVaultToken: tokenChecker(sha(VTOKEN)),
        getPolicy: () => policy,
        vault: createVault({ url: vw.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'dev-e2e' }),
        controllers, scrubber, taint: createTaint({ statePath: join(dir, 'state', 'taint.json'), scrubber, controllers }), audit,
        sleep: async () => {}, totpOpts: { minLeftS: 0 },
    });
    const filler = createServer(handle);
    await new Promise((r) => filler.listen(0, '127.0.0.1', r));
    // The bridge's /api/pod for this chat: its browser is sess-e2e on the fake controller.
    const chat = { source: 'happy', id: 'e2e-chat' };
    const bridge = createServer((req, res) => {
        let b = '';
        req.on('data', (d) => (b += d)).on('end', () => {
            const body = JSON.parse(b || '{}');
            const ok = req.headers.authorization === `Bearer ${BTOKEN}` && body.peek === true && body.chat_key === chatKeyOf(chat);
            res.writeHead(ok ? 200 : 404, { 'Content-Type': 'application/json' }).end(JSON.stringify(ok ? { chat_key: body.chat_key, state: 'running', session_id: 'sess-e2e', api_url: `http://127.0.0.1:${ctlPort}` } : { error: 'no_browser' }));
        });
    });
    await new Promise((r) => bridge.listen(0, '127.0.0.1', r));
    const home = join(dir, 'mcp-home'); const bsecrets = join(dir, 'bridge-secrets');
    mkdirSync(join(home, 'secrets'), { recursive: true }); mkdirSync(bsecrets);
    writeFileSync(join(home, 'secrets', 'vault-client-token'), `${VTOKEN}\n`, { mode: 0o600 });
    writeFileSync(join(bsecrets, 'bridge-token'), `${BTOKEN}\n`, { mode: 0o600 });
    const env = {
        ...process.env, HAPPY_VAULT_MCP_HOME: home, HAPPY_VAULT_FILLER_URL: `http://127.0.0.1:${filler.address().port}`,
        HAPPY_SESSION_ID: chat.id, BRIDGE_URL: `http://127.0.0.1:${bridge.address().port}`, BROWSER_STACK_SECRETS: bsecrets, TMPDIR: tmp,
    };
    for (const k of ['BROWSER_CHAT_FROM_META', 'BROWSER_VAULT_MCP_HOME', 'BROWSER_VAULT_FILLER_URL', 'CLAUDE_CODE_SESSION_ID', 'HAPPY_BROWSER_SECRETS']) delete env[k];
    process.env.TMPDIR = tmp; // the in-process filler's temp dir too
    const child = spawn(process.execPath, [fileURLToPath(new URL('../mcp.mjs', import.meta.url))], { env, stdio: ['pipe', 'pipe', 'pipe'] });
    const wire = [];
    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d; });
    const waiters = new Map();
    createInterface({ input: child.stdout }).on('line', (l) => { wire.push(l); const m = JSON.parse(l); waiters.get(m.id)?.(m); });
    let n = 0;
    const ask = (method, params) => new Promise((r) => { const id = ++n; waiters.set(id, r); child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n'); });
    const tool = async (name, args) => { const m = await ask('tools/call', { name, arguments: args }); return { isError: !!m.result.isError, text: m.result.content[0].text }; };
    try {
        await ask('initialize', { protocolVersion: '2025-06-18' });
        const saved = await tool('vault_save_download', { download_id: 'a1b2c3d4e5f6', new_item: { name: 'ASC key E2E' } });
        assert.equal(saved.isError, false, saved.text);
        const so = JSON.parse(saved.text);
        assert.equal(so.download_deleted, true);
        assert.equal(so.sha256, sha(PEM));
        assert.deepEqual(ctl.downloadsOf('sess-e2e'), [], 'the browser copy is gone');

        const note = JSON.parse((await tool('vault_list', {})).text).items.find((i) => i.id === so.item_id);
        assert.deepEqual(note.attachments.map((a) => a.id), [so.attachment_id]);

        const sum = await tool('vault_pipe', { id: so.item_id, attachment: so.attachment_id, target: 'secret-sum', args: { name: 'ASC_KEY_P8', repo: 'owner/repo' } });
        assert.equal(sum.isError, false, sum.text);
        const out = JSON.parse(sum.text);
        assert.equal(out.exit_code, 0);
        assert.deepEqual(out.argv, ['sh', '-c', 'sha256sum', 'ASC_KEY_P8', 'owner/repo']);
        assert.equal(out.stdout.trim(), `${sha(PEM)}  -`, 'the PEM reached stdin byte for byte');
        const cat = JSON.parse((await tool('vault_pipe', { id: so.item_id, attachment: so.attachment_id, target: 'cat' })).text);
        assert.equal(cat.stdout, '[secret:attachment:AuthKey_E2E.p8]');
        const field = JSON.parse((await tool('vault_pipe', { id: v.items.gmail.id, field: 'password', target: 'sha' })).text);
        assert.equal(field.stdout.trim(), `${sha(v.items.gmail.password)}  -`);

        const auditText = readdirSync(join(dir, 'audit')).map((f) => readFileSync(join(dir, 'audit', f), 'utf8')).join('');
        assert.ok(auditText.includes(`"field_kind":"attachment:${so.attachment_id}"`));
        for (const [where, blob] of [['MCP wire', wire.join('\n')], ['audit', auditText], ['stderr', stderr]]) {
            for (const form of ['E2eAttachCanary0', Buffer.from(PEM).toString('base64'), v.items.gmail.password]) assert.ok(!blob.includes(form), `value in ${where}`);
        }
        assert.deepEqual(readdirSync(tmp), [], 'no temp file from the filler, vault-mcp or the commands');
        // Nothing on disk under the test dir holds the PEM either (audit, state, tokens).
        const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [readFileSync(join(d, e.name), 'latin1')]));
        for (const blob of walk(dir)) assert.ok(!blob.includes('E2eAttachCanary0'), 'no plaintext copy on disk');
    } finally {
        if (oldTmp === undefined) delete process.env.TMPDIR; else process.env.TMPDIR = oldTmp;
        child.stdin.end();
        filler.closeAllConnections?.();
        bridge.closeAllConnections?.();
        await new Promise((r) => filler.close(r));
        await new Promise((r) => bridge.close(r));
        await vw.close();
        await ctl.close();
    }
});
