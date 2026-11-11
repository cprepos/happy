// The provider conformance suite (provider-conformance.mjs) on each provider:
// Vaultwarden over fake-vaultwarden.mjs, 1Password over fake-onepassword.mjs
// in both remove modes (archive: restore is 'manual'; tag: restore is 'tag').
import { createVaultwardenProvider } from '../lib/providers/vaultwarden/index.mjs';
import { createOnePasswordProvider } from '../lib/providers/onepassword/index.mjs';
import { startFakeVaultwarden, buildVault, TOTP_SECRET } from './fake-vaultwarden.mjs';
import { fakeOnePassword, VAULT_TITLE } from './fake-onepassword.mjs';
import { providerConformance } from './provider-conformance.mjs';

providerConformance('vaultwarden', async () => {
    const vw = await startFakeVaultwarden(buildVault());
    const v = vw.vault;
    const provider = createVaultwardenProvider({ id: 'conf', url: vw.url, clientId: v.clientId, clientSecret: v.clientSecret, userKey: v.userKey, deviceId: 'dev-conf' });
    const it = (label) => v.items[label];
    return {
        provider,
        close: () => vw.close(),
        fx: {
            github: { id: it('acme-github').id, username: it('acme-github').username, password: it('acme-github').password, totp: TOTP_SECRET, hosts: ['github.com', 'www.github.com'] },
            portal: { id: it('acme-portal').id, fields: Object.fromEntries(it('acme-portal').fields.map((f) => [f.name, f.value])) },
            trashed: { id: it('acme-trashed').id },
            hostMatch: { id: it('gmail-host').id, host: 'www.gmail.com' },
            otherId: '00000000-0000-4000-8000-000000000000',
            badId: 'not-an-id',
        },
    };
});

for (const remove of ['archive', 'tag']) providerConformance(`onepassword (remove: ${remove})`, async () => {
    const op = fakeOnePassword();
    const provider = createOnePasswordProvider({ type: 'onepassword', id: 'conf', vault: VAULT_TITLE, remove }, { client: op.client });
    const item = (label) => op.store.get(op.byLabel(label)).item;
    const val = (label, fid) => item(label).fields.find((f) => f.id === fid).value;
    return {
        provider,
        undoRemove: (id) => op.unarchive(id),
        close: () => { if (op.calls.some((c) => /delete/i.test(c.name))) throw new Error('the provider called items.delete'); },
        fx: {
            github: { id: op.byLabel('acme-github'), username: val('acme-github', 'username'), password: val('acme-github', 'password'), totp: TOTP_SECRET, hosts: ['github.com', 'www.github.com'] },
            portal: { id: op.byLabel('acme-portal'), fields: Object.fromEntries(item('acme-portal').fields.filter((f) => f.sectionId).map((f) => [f.title, f.value])) },
            trashed: { id: op.byLabel('acme-trashed') },
            hostMatch: { id: op.byLabel('gmail-host'), host: 'mail.google.com' },
            otherId: 'a'.repeat(26),
            badId: 'not-an-id',
        },
    };
});
