// Two vault backends for tests: two fake Vaultwardens, "shared" and
// "instimate", behind one filler and one fake controller, with a policy that
// puts agent (default_client, all_items) and acme on shared, and instimate
// (all_items) and instx (explicit secrets naming a shared item's id) on
// instimate. Each provider is wrapped so a test can see every call that
// reached it.
import { mkdtempSync, readdirSync, readFileSync } from 'node:fs';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createFiller } from '../lib/fill.mjs';
import { createManager } from '../lib/manage.mjs';
import { parsePolicy } from '../lib/policy.mjs';
import { createVaultwardenProvider } from '../lib/providers/vaultwarden/index.mjs';
import { controllerSet } from '../lib/controller.mjs';
import { createScrubber } from '../lib/scrub.mjs';
import { createTaint } from '../lib/taint.mjs';
import { createAudit } from '../lib/audit.mjs';
import { buildVault, startFakeVaultwarden } from './fake-vaultwarden.mjs';
import { startFakeController } from './fake-controller.mjs';

export const SHARED_ONLY = 'Shared-Only-Pass-0a1b2c';
export const INST_ONLY = 'Instimate-Only-Pass-9z8y7x';
export const SHARED_TOKEN = 'Shared-Only-Token-5d6e';
export const INST_TOKEN = 'Instimate-Only-Token-3f4g';

/** A provider that records every call (method and first argument) in calls. */
function spy(p, calls) {
    return new Proxy(p, {
        get(target, key) {
            const v = target[key];
            if (typeof v !== 'function') return v;
            return (...args) => { calls.push([key, typeof args[0] === 'string' ? args[0] : null]); return v.apply(target, args); };
        },
    });
}

export function twoBackendPolicy(sh, inst) {
    return {
        version: 1,
        backends: { shared: { type: 'vaultwarden' }, instimate: { type: 'vaultwarden' } },
        clients: {
            agent: { backend: 'shared', all_items: true, manage: { create: true, update: true, remove: true, compare: true, pipe: ['sha'] } },
            acme: { backend: 'shared', secrets: { github: { item_id: sh.items['acme-github'].id, hosts: ['github.com'], fields: ['username', 'password'] } } },
            instimate: { backend: 'instimate', all_items: true, manage: { create: true, update: true, remove: true, compare: true, pipe: ['sha'] } },
            // An instimate client whose policy entry names a shared item's id: it reads that id in its own backend only.
            instx: {
                backend: 'instimate',
                secrets: { github: { item_id: sh.items['acme-github'].id, hosts: ['github.com'], fields: ['password'], custom_fields: ['token'] } },
                manage: { update: true, remove: true, compare: true, pipe: ['sha'] },
            },
        },
        chats: { 'chat-inst': 'instimate', 'chat-instx': 'instx', 'chat-acme': 'acme' },
        default_client: 'agent',
        pipe_targets: { sha: { argv: ['sha256sum'] } },
    };
}

export async function setup2({ instEnrolled = true } = {}) {
    const vSh = buildVault(); const vIn = buildVault({ email: 'agent@instimate.test' });
    vSh.addLogin('shared-only', { username: 'sh-bot', password: SHARED_ONLY, uris: ['https://github.com/login'], fields: [{ name: 'token', value: SHARED_TOKEN, type: 1 }] });
    vIn.addLogin('inst-only', { username: 'in-bot', password: INST_ONLY, uris: ['https://github.com/login'], fields: [{ name: 'token', value: INST_TOKEN, type: 1 }] });
    const sh = await startFakeVaultwarden(vSh); const inst = await startFakeVaultwarden(vIn);
    const ctl = await startFakeController();
    const dir = mkdtempSync(join(tmpdir(), 'filler-backends-'));
    const calls = { shared: [], instimate: [] };
    const mk = (fw, id) => spy(createVaultwardenProvider({ id, url: fw.url, clientId: fw.vault.clientId, clientSecret: fw.vault.clientSecret, userKey: fw.vault.userKey, deviceId: `dev-${id}` }), calls[id]);
    const providers = { shared: mk(sh, 'shared'), instimate: instEnrolled ? mk(inst, 'instimate') : null };
    const policy = parsePolicy(twoBackendPolicy(sh.vault, inst.vault));
    const port = Number(new URL(ctl.url).port);
    const controllers = controllerSet({ defaultPort: port, ports: [], token: ctl.token });
    const scrubber = createScrubber();
    const taint = createTaint({ statePath: join(dir, 'state', 'taint.json'), scrubber, controllers });
    const audit = createAudit(join(dir, 'audit'));
    const vaults = (name) => providers[name] ?? null;
    const deps = { getPolicy: () => policy, vaults, controllers, taint, audit, sleep: async () => {}, totpOpts: { minLeftS: 0 } };
    const f = createFiller(deps);
    const m = createManager({ getPolicy: () => policy, vaults, audit });
    const ids = (fw) => new Set(fw.vault.sync.ciphers.map((c) => c.id));
    const auditText = () => readdirSync(join(dir, 'audit')).map((x) => readFileSync(join(dir, 'audit', x), 'utf8')).join('');
    return {
        sh, inst, ctl, dir, calls, providers, policy, scrubber, taint, audit, f, m, vaults, controllers, deps, auditText,
        idsSh: () => ids(sh), idsIn: () => ids(inst),
        key: (s) => `${port}/${s}`,
        reset() { calls.shared.length = 0; calls.instimate.length = 0; },
        async close() { await sh.close(); await inst.close(); await ctl.close(); },
    };
}

export const TOKEN = 'filler-client-token-abcdefghijklmnop';
export function call(port, method, path, body, headers = {}) {
    return new Promise((resolve, reject) => {
        const data = body === undefined ? null : JSON.stringify(body);
        const req = request({ host: '127.0.0.1', port, method, path, headers: { Host: '127.0.0.1', Authorization: `Bearer ${TOKEN}`, ...(data ? { 'Content-Type': 'application/json' } : {}), ...headers } }, async (res) => {
            const chunks = []; for await (const c of res) chunks.push(c);
            const text = Buffer.concat(chunks).toString('utf8');
            resolve({ status: res.statusCode, text, json: text ? JSON.parse(text) : null });
        });
        req.on('error', reject);
        if (data) req.write(data);
        req.end();
    });
}
