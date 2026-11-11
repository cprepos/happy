// Vault providers: the one interface the filler reaches a vault through. fill.mjs,
// manage.mjs and server.mjs use only what this file describes; each backend
// (providers/<type>/) keeps its own wire formats, crypto and data shapes to
// itself and hands back the normalized objects below.
//
// A provider is registered by type (register) and built from its config
// (create). builtin.mjs registers the providers that ship with the filler.
//
// The contract, for a provider object p:
//
//   p.id            string: the backend's name (for example "shared")
//   p.type          string: the type it was registered under ("vaultwarden")
//   p.capabilities  {restore, equivalentDomains, totp}:
//                     restore: 'native'  trashLogin/restoreLogin use the vault's own trash
//                              'tag'     they tag the item and hide it (a vault with no trash API)
//                              'manual'  trashLogin hides the item where the API cannot bring
//                                        it back (1Password's archive): restoreLogin refuses
//                                        (409) until a person has undone that in the vault app
//                     equivalentDomains: true when listItems can attach `equivalents`
//                     totp: true when readItem can return a TOTP seed
//   p.checkId(id)   the canonical form of an item id, or null when id is not
//                   one of this vault's ids. Ids are opaque to the filler: it
//                   only bounds them (ITEM_ID in policy.mjs: 8..128 of
//                   A-Z a-z 0-9 _ -) and compares them case-insensitively, so a
//                   canonical id is lower case.
//   p.status()      {unlocked: boolean, sync_age_s: number|null}; never throws
//   p.sync({force}) refresh the provider's cache (force: even when fresh)
//   p.listItems({trash = false, force = false}) -> LoginMeta[], sorted by name
//                   then id. trash: also the trashed logins. force: bypass the cache.
//   p.readItem(id)  -> Login, or throws (status 404 not found or trashed, 422 not
//                   a login or unreadable, 403 not readable by this account)
//   p.createLogin({name, uris, username, password}) -> the new item's id
//   p.updateLogin(id, {name?, uris?, username?, password?}) -> the names of the
//                   fields changed. Fields not named are kept as they are.
//   p.trashLogin(id), p.restoreLogin(id): reversible removal; there is no purge
//   p.lock()        forget tokens and cached data
//
// Errors carry a numeric `status` (HTTP-like); callers map it to their own.
// Writes (create, update, trash, restore) refuse a `shared` item.

/**
 * A URI of a login, with how the vault matches it:
 *   'domain'  the URL's registrable domain (Vaultwarden's default)
 *   'host'    the URL's host
 *   'exact'   the URL itself (also used for any rule stricter than host that
 *             the filler does not model, such as Vaultwarden's "starts with"
 *             and "regular expression")
 *   'never'   never offered for autofill
 * The filler itself fills only on exact https hosts (plus equivalents for
 * all_items logins); match is carried so that rule can stay provider-neutral.
 * @typedef {{url: string, match: 'host'|'domain'|'exact'|'never'}} LoginUri
 */

/**
 * A custom field of a login. Linked fields (a pointer to the login's own
 * username or password, with no value of their own) are never listed.
 * value is null when the field is empty; a boolean's value is "true" or "false".
 * @typedef {{name: string, value: string|null, hidden: boolean}} LoginField
 */

/**
 * One login with its values, from readItem. Every string is null when empty.
 * uris are as stored (full URLs). The caller drops the values when done.
 * @typedef {{
 *   id: string, name: string|null, username: string|null, password: string|null,
 *   totp: string|null, uris: LoginUri[], fields: LoginField[], notes: string|null
 * }} Login
 */

/**
 * One login without its secret values, from listItems. Never a password, TOTP
 * or custom field value.
 *   uris          display-safe: scheme, host and path only (no userinfo, query
 *                 or fragment), http(s) URIs only
 *   hosts         the https hosts of the login's URIs, exact (hosts.httpsHost)
 *   has           which of username, password and totp are set
 *   fields        the custom fields' names, without values ({name, hidden});
 *                 duplicate names are kept so a caller can refuse an ambiguous one
 *   revisionDate  ISO time of the last change, or null
 *   trashed       true when the login is in the trash (only with {trash: true})
 *   shared        true for an item in a space the account does not own (a
 *                 Vaultwarden organization): readable, never written, and never
 *                 reached through all_items
 *   equivalents   optional, only with capabilities.equivalentDomains: Map of
 *                 registrable domain -> the saved host granting it, for the
 *                 login's 'domain'-match URIs. Absent when empty.
 * @typedef {{
 *   id: string, name: string|null, username: string|null, uris: LoginUri[],
 *   hosts: string[], has: {username: boolean, password: boolean, totp: boolean},
 *   fields: {name: string, hidden: boolean}[], revisionDate: string|null,
 *   trashed: boolean, shared: boolean, equivalents?: Map<string, string>
 * }} LoginMeta
 */

export class ProviderError extends Error {
    constructor(message, status = 500) { super(message); this.status = status; }
}

const TYPE = /^[a-z][a-z0-9-]{0,31}$/;
const factories = new Map();

/** Register a provider factory under a type. A type is registered once. */
export function register(type, factory) {
    if (!TYPE.test(String(type ?? ''))) throw new ProviderError(`bad provider type ${JSON.stringify(type)?.slice(0, 40)}`);
    if (typeof factory !== 'function') throw new ProviderError(`provider ${type}: the factory must be a function`);
    if (factories.has(type)) throw new ProviderError(`provider ${type} is already registered`);
    factories.set(type, factory);
}

/** The registered types. */
export const types = () => [...factories.keys()];

/** Build a provider of a registered type from its config. */
export function create(type, config = {}) {
    const factory = factories.get(type);
    if (!factory) throw new ProviderError(`no vault provider of type ${JSON.stringify(type)?.slice(0, 40)} (known: ${types().join(', ') || 'none'})`);
    const p = factory(config);
    for (const m of ['checkId', 'status', 'sync', 'listItems', 'readItem', 'createLogin', 'updateLogin', 'trashLogin', 'restoreLogin', 'lock']) {
        if (typeof p?.[m] !== 'function') throw new ProviderError(`provider ${type} has no ${m}()`);
    }
    if (p.type !== type || typeof p.id !== 'string' || !p.capabilities) throw new ProviderError(`provider ${type}: id, type and capabilities are required`);
    return p;
}
