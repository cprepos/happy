// The vault providers that ship with the filler, registered by type. Import
// this once (server.mjs does) before calling create() from index.mjs.
import { register, create, types } from './index.mjs';
import { createVaultwardenProvider } from './vaultwarden/index.mjs';
import { createOnePasswordProvider } from './onepassword/index.mjs';

register('vaultwarden', createVaultwardenProvider);
register('onepassword', createOnePasswordProvider);

export { create, types };
