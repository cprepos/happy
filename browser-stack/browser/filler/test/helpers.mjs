// Shared setup for fill and server tests: a fake Vaultwarden, a fake
// controller, and a policy that binds chat-acme to acme and chat-globex to globex.
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parsePolicy } from '../lib/policy.mjs';
import { createVaultwardenProvider as createVault } from '../lib/providers/vaultwarden/index.mjs';
import { controllerSet } from '../lib/controller.mjs';
import { createScrubber } from '../lib/scrub.mjs';
import { createTaint } from '../lib/taint.mjs';
import { createAudit } from '../lib/audit.mjs';
import { startFakeVaultwarden } from './fake-vaultwarden.mjs';
import { startFakeController } from './fake-controller.mjs';

export function policyFor(v, over = {}) {
    return {
        version: 1,
        clients: {
            acme: {
                secrets: {
                    github: { item_id: v.items['acme-github'].id, hosts: ['github.com'], fields: ['username', 'password', 'totp'] },
                    portal: { item_id: v.items['acme-portal'].id, hosts: ['portal.acme.test'], fields: ['password'] },
                    // An item of an organization the agent account is not in: never decryptable.
                    foreign: { item_id: v.items['org-foreign'].id, hosts: ['github.com'], fields: ['password'] },
                    // Policy says gitlab.com, the item says github.com: no host survives the intersection.
                    mismatch: { item_id: v.items['acme-gitlab'].id, hosts: ['gitlab.com'], fields: ['password'] },
                },
            },
            globex: {
                secrets: { github: { item_id: v.items['globex-github'].id, hosts: ['github.com'], fields: ['password', 'totp'] } },
            },
        },
        chats: { 'chat-acme': 'acme', 'chat-acme-2': 'acme', 'chat-globex': 'globex' },
        ...over,
    };
}

// The vault tools' test policy: acme may update, compare and pipe into docker-login;
// agent (default_client, all_items) may do everything and pipe into sha.
export const PIPE_TARGETS = {
    'docker-login': { argv: ['docker', 'login', '--username', '{username}', '--password-stdin', '{arg:registry}'], args: { registry: '^[a-z0-9.-]+(:[0-9]+)?$' } },
    sha: { argv: ['sha256sum'] },
};
export function managePolicy(v) {
    const base = policyFor(v);
    return {
        ...base,
        default_client: 'agent',
        clients: {
            ...base.clients,
            acme: { ...base.clients.acme, manage: { update: true, compare: true, pipe: ['docker-login'] } },
            agent: { all_items: true, manage: { create: true, update: true, remove: true, compare: true, pipe: ['sha'] } },
        },
        pipe_targets: PIPE_TARGETS,
    };
}

export async function setup() {
    const vw = await startFakeVaultwarden();
    const ctl = await startFakeController();
    const v = vw.vault;
    const dir = mkdtempSync(join(tmpdir(), 'filler-test-'));
    let policy;
    try { policy = parsePolicy(JSON.stringify(policyFor(v))); } catch (err) { await vw.close(); await ctl.close(); throw err; }
    const vault = createVault({ url: vw.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'dev-test' });
    const port = Number(new URL(ctl.url).port);
    const controllers = controllerSet({ defaultPort: port, ports: [], token: ctl.token });
    const controller = controllers(null).controller;
    const scrubber = createScrubber();
    const taint = createTaint({ statePath: join(dir, 'state', 'taint.json'), scrubber, controllers });
    const audit = createAudit(join(dir, 'audit'));
    return {
        vw, ctl, v, dir, port, policy, vault, controller, controllers, scrubber, taint, audit,
        deps: { getPolicy: () => policy, vault, controllers, taint, audit, sleep: async () => {}, totpOpts: { minLeftS: 0 } },
        key: (session) => `${port}/${session}`,
        async close() { await vw.close(); await ctl.close(); },
    };
}
