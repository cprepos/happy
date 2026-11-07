// make filler-smoke: an end-to-end canary run, against fakes only.
//
// A real filler (createApp on an ephemeral loopback port, its own temp state
// and audit dirs) is wired to a fake Vaultwarden and a fake controller, and
// the real bridge MCP server (with its secret gate) drives it the way an agent
// would: list, login (username, password, TOTP), observe, read-back attempts.
// The fake auto-browser upstream is deliberately leaky: every result echoes
// whatever was typed into the page, as OCR or page text could.
//
// Then a leak sweep: no canary value (or its URL, base64 or JSON escaped form)
// may appear in any MCP message, the audit log, the taint state, or anything
// the processes wrote to stdout/stderr. Exits 0 on a clean run.
//
// The vault routes (/v1/vault/*, the vault-client-token) are driven too:
// create and rotate (passwords the filler generates), compare, a pipe, remove
// and restore. Their generated passwords join the canaries; the pipe answer,
// the one route meant to hand a value to vault-mcp's runner, is checked to
// carry exactly that value and is the only place it may appear.
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { mkdtempSync, readdirSync, readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp, tokenChecker } from '../server.mjs';
import { parsePolicy } from '../lib/policy.mjs';
import { createVault } from '../lib/vault.mjs';
import { controllerSet } from '../lib/controller.mjs';
import { createScrubber, variantsOf } from '../lib/scrub.mjs';
import { createTaint } from '../lib/taint.mjs';
import { createAudit } from '../lib/audit.mjs';
import { startFakeVaultwarden } from './fake-vaultwarden.mjs';
import { startFakeController, loginPages } from './fake-controller.mjs';
import { managePolicy } from './helpers.mjs';
import { decryptKey, decryptSymText } from '../lib/vaultcrypto.mjs';
import { createMcpServer } from '../../bridge/mcp.mjs';
import { createSecretGate } from '../../bridge/lib/secrets.mjs';

const captured = [];
for (const stream of [process.stdout, process.stderr]) {
    const orig = stream.write.bind(stream);
    stream.write = (chunk, ...rest) => { captured.push(String(chunk)); return orig(chunk, ...rest); };
}
const say = (m) => process.stdout.write(`filler-smoke: ${m}\n`);
const failures = [];
const check = (ok, what) => { if (ok) say(`ok   ${what}`); else { failures.push(what); say(`FAIL ${what}`); } };

const dir = mkdtempSync(join(tmpdir(), 'filler-smoke-'));
const TOKEN = createHash('sha256').update(`${Date.now()}-${Math.random()}`).digest('hex');
const tokenPath = join(dir, 'filler-client-token');
writeFileSync(tokenPath, `${TOKEN}\n`, { mode: 0o600 });

const vw = await startFakeVaultwarden();
const ctl = await startFakeController();
const v = vw.vault;
const item = v.items['acme-github'];
const ctlPort = Number(new URL(ctl.url).port);

const controllers = controllerSet({ defaultPort: ctlPort, ports: [], token: ctl.token });
const scrubber = createScrubber();
const taint = createTaint({ statePath: join(dir, 'state', 'taint.json'), scrubber, controllers });
const audit = createAudit(join(dir, 'audit'));
const policy = parsePolicy(JSON.stringify(managePolicy(v)));
const VTOKEN = createHash('sha256').update(`v-${TOKEN}`).digest('hex');
const vault = createVault({ url: vw.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'dev-smoke' });
const handle = createApp({
    checkToken: tokenChecker(createHash('sha256').update(TOKEN).digest('hex')),
    checkVaultToken: tokenChecker(createHash('sha256').update(VTOKEN).digest('hex')),
    getPolicy: () => policy, vault, controllers, scrubber, taint, audit,
    sleep: async () => {}, totpOpts: { minLeftS: 0 },
});
const filler = createServer(handle);
await new Promise((r) => filler.listen(0, '127.0.0.1', r));
const fillerUrl = `http://127.0.0.1:${filler.address().port}`;

// A leaky auto-browser: results carry everything typed so far.
const echo = () => ctl.typed.map((t) => t.text).join(' | ');
const UP = ['browser.observe', 'browser.eval_js', 'browser.get_html', 'browser.execute_action', 'browser.create_session', 'browser.screenshot'];
const upstream = {
    listTools: async () => UP.map((name) => ({ name, description: name, inputSchema: { type: 'object', properties: {} } })),
    async callTool(name, args) {
        const s = ctl.session(args.session_id);
        const page = s ? s.pages[s.at] : null;
        if (name === 'browser.get_html') return { error: { code: -32000, message: `html of ${page?.url}: ${echo()}` } };
        if (name === 'browser.screenshot') return { result: { content: [{ type: 'text', text: `ocr: ${echo()}` }, { type: 'image', mimeType: 'image/png', data: 'iVBORw0KGgo'.padEnd(400, 'A') }] } };
        return { result: { content: [{ type: 'text', text: JSON.stringify({ url: page?.url, interactables: page?.interactables, ocr: echo() }) }], structuredContent: { ocr: echo() } } };
    },
};

const out = [];
const bridgeLogs = [];
const secrets = createSecretGate({ fillerUrl, tokenPath, chat: 'chat-acme', controllerPort: () => ctlPort, timeoutMs: 10_000 });
const mcp = createMcpServer({ bridgeUrl: 'http://127.0.0.1:9', bridgeToken: 'b', write: (m) => out.push(m), upstream, retryMs: 0, secrets, log: (l) => bridgeLogs.push(l) });
let nextId = 1;
const call = async (name, args) => { const id = nextId++; await mcp.handle({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } }); return out.find((m) => m.id === id); };
const textOf = (m) => JSON.stringify(m);

try {
    ctl.addSession('s1', loginPages());
    await mcp.handle({ jsonrpc: '2.0', id: nextId++, method: 'tools/list', params: {} });
    const names = out.at(-1).result.tools.map((t) => t.name);
    check(['browser_list_secrets', 'browser_fill_secret', 'browser_login'].every((n) => names.includes(n)), 'secret tools are listed');

    const list = await call('browser_list_secrets', {});
    check(/github\.password/.test(textOf(list)) && !list.result.isError, 'list names the acme secrets');
    const obs0 = await call('browser_observe', { session_id: 's1' });
    check(!obs0.result.isError, 'observe before any fill');

    const login = await call('browser_login', { session_id: 's1', site: 'github' });
    check(/totp_submitted/.test(textOf(login)), 'login typed username, password and TOTP and submitted');
    check(ctl.typed.some((t) => t.text === item.password) && ctl.typed.some((t) => t.text === item.username), 'the values reached the page');

    const obs = await call('browser_observe', { session_id: 's1' });
    check(/\[secret:github\.password\]/.test(textOf(obs)) && /\[secret:github\.username\]/.test(textOf(obs)), 'leaky observe comes back scrubbed');
    const shot = await call('browser_screenshot', { session_id: 's1' });
    check(!shot.result?.content?.some((c) => c.type === 'image'), 'screenshot image withheld after a username/TOTP fill');
    const html = await call('browser_get_html', { session_id: 's1', text_only: true });
    check(/\[secret:/.test(textOf(html)), 'upstream error text scrubbed');
    const ev = await call('browser_eval_js', { session_id: 's1', script: 'document.forms[0].password.value' });
    check(ev.result?.isError && /Refused/.test(textOf(ev)), 'eval_js refused on a tainted session');
    const raw = await call('browser_get_html', { session_id: 's1' });
    check(raw.result?.isError && /Refused/.test(textOf(raw)), 'raw HTML refused on a tainted session');
    const copy = await call('browser_execute_action', { session_id: 's1', action: { action: 'press', key: 'Control+C' } });
    check(copy.result?.isError && /Refused/.test(textOf(copy)), 'copy key refused on a tainted session');
    const totpArg = await call('browser_create_session', { totp_secret: 'JBSWY3DPEHPK3PXP' });
    check(totpArg.result?.isError && /totp_secret/.test(textOf(totpArg)), 'totp_secret argument refused');
    const wrongHost = await call('browser_fill_secret', { session_id: 's1', element_id: 'u1', name: 'portal.password' });
    check(wrongHost.result?.isError, 'a secret for another host is refused');

    // The vault routes.
    const vcall = async (fn, body, token = VTOKEN) => {
        const r = await fetch(`${fillerUrl}/v1/vault/${fn}`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'X-Happy-Chat': 'none', 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
        return { status: r.status, json: await r.json() };
    };
    const vaultOut = [];
    const stored = (id) => {
        const c = v.sync.ciphers.find((x) => x.id === id);
        const k = c.key ? decryptKey(c.key, { symKey: v.userKey }) : v.userKey;
        return decryptSymText(c.login.password, k);
    };
    check((await vcall('list', {}, TOKEN)).status === 401, 'the bridge token cannot reach the vault routes');
    const created = await vcall('create', { name: 'Smoke Created', uris: ['https://smoke.example/login'], username: 'smoke-bot' });
    vaultOut.push(created);
    check(created.status === 200 && created.json.secret === 'smoke-created', 'create made a login');
    const gen1 = created.status === 200 ? stored(created.json.id) : null;
    check(gen1?.length === 32, 'create generated a 32-character password');
    const rotated = await vcall('update', { id: created.json.id, rotate_password: { length: 40 } });
    vaultOut.push(rotated);
    const gen2 = rotated.status === 200 ? stored(created.json.id) : null;
    check(rotated.status === 200 && gen2?.length === 40 && gen2 !== gen1, 'update rotated the password');
    const sha = (x) => createHash('sha256').update(x).digest('hex');
    const yes = await vcall('compare', { id: created.json.id, field: 'password', algo: 'sha256', digest: sha(gen2 || '') });
    const no = await vcall('compare', { id: created.json.id, field: 'password', algo: 'sha256', digest: sha(gen1 || '') });
    vaultOut.push(yes, no);
    check(yes.json.match === true && no.json.match === false, 'compare answers match / no match');
    const piped = await vcall('pipe', { id: created.json.id, field: 'password', target: 'sha' });
    check(piped.status === 200 && piped.json.value === gen2 && !piped.json.argv.includes(gen2), 'pipe hands the value to the runner, outside argv');
    const evil = await vcall('pipe', { id: created.json.id, field: 'password', target: 'docker-login', args: { registry: 'x' } });
    vaultOut.push(evil);
    check(evil.status === 403, 'a pipe target outside the client\'s list is refused');
    const rm = await vcall('remove', { id: created.json.id });
    const back = await vcall('restore', { id: created.json.id });
    vaultOut.push(rm, back);
    check(rm.json.trashed === true && back.json.trashed === false && vw.calls.refusedWrites.length === 0, 'remove is a soft delete and restore brings it back');
    vaultOut.push(await vcall('list', { include_trash: true }));
    out.push(...vaultOut.map((x) => ({ vault: x })));

    // The leak sweep.
    // The username and password in every encoded form; the TOTP code as typed, as a whole digit run.
    const forms = [...new Set([item.password, item.username, gen1, gen2].filter(Boolean).flatMap((c) => [c, ...variantsOf(c)]))];
    const code = ctl.typed.find((t) => t.element_id === 't1')?.text;
    check(/^\d{6,10}$/.test(code || ''), 'a TOTP code was typed');
    const codeRe = code ? new RegExp(`(?<!\\d)${code}(?!\\d)`) : null;
    const leaksIn = (blob) => forms.filter((f) => blob.includes(f)).length + (codeRe && codeRe.test(blob) ? 1 : 0);
    check(leaksIn(echo()) >= 3, 'the sweep detects the raw values (negative control)');
    const files = (d) => (existsSync(d) ? readdirSync(d).filter((f) => statSync(join(d, f)).isFile()).map((f) => readFileSync(join(d, f), 'utf8')).join('\n') : '');
    const sweep = {
        'MCP messages': out.map(textOf).join('\n'),
        'audit log': files(join(dir, 'audit')),
        'taint state': files(join(dir, 'state')),
        'bridge log': bridgeLogs.join('\n'),
        'stdout/stderr': captured.join(''),
    };
    check(sweep['audit log'].length > 0 && sweep['taint state'].length > 0, 'audit and state were written');
    for (const [where, blob] of Object.entries(sweep)) check(leaksIn(blob) === 0, `no canary in ${where}`);
} catch (err) {
    failures.push(`crashed: ${err.message}`);
    say(`FAIL crashed: ${err.stack}`);
} finally {
    filler.closeAllConnections?.();
    await new Promise((r) => filler.close(r));
    await vw.close(); await ctl.close();
}

if (failures.length) { say(`${failures.length} check(s) failed`); process.exit(1); }
say(`clean: no canary value left the filler (temp dir ${dir})`);
