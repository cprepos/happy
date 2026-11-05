// Shared setup for fill and server tests: a fake Vaultwarden, a fake
// controller, and a policy that binds chat-acme to acme and chat-globex to globex.
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parsePolicy } from '../lib/policy.mjs';
import { createVault } from '../lib/vault.mjs';
import { createController } from '../lib/controller.mjs';
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
                org_id: v.orgs.acme.id, collection_id: v.orgs.acme.agents,
                secrets: {
                    github: { item_id: v.items['acme-github'].id, hosts: ['github.com'], fields: ['username', 'password', 'totp'] },
                    portal: { item_id: v.items['acme-portal'].id, hosts: ['portal.acme.test'], fields: ['password'] },
                    private: { item_id: v.items['acme-private'].id, hosts: ['github.com'], fields: ['password'] },
                    // Policy says gitlab.com, the item says github.com: no host survives the intersection.
                    mismatch: { item_id: v.items['acme-gitlab'].id, hosts: ['gitlab.com'], fields: ['password'] },
                },
            },
            globex: {
                org_id: v.orgs.globex.id, collection_id: v.orgs.globex.agents,
                secrets: { github: { item_id: v.items['globex-github'].id, hosts: ['github.com'], fields: ['password', 'totp'] } },
            },
        },
        chats: { 'chat-acme': 'acme', 'chat-acme-2': 'acme', 'chat-globex': 'globex' },
        ...over,
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
    const controller = createController({ baseUrl: ctl.url, token: ctl.token });
    const scrubber = createScrubber();
    const taint = createTaint({ statePath: join(dir, 'state', 'taint.json'), scrubber, controller });
    const audit = createAudit(join(dir, 'audit'));
    return {
        vw, ctl, v, dir, policy, vault, controller, scrubber, taint, audit,
        deps: { getPolicy: () => policy, vault, controller, taint, audit, sleep: async () => {}, totpOpts: { minLeftS: 0 } },
        async close() { await vw.close(); await ctl.close(); },
    };
}
