// The vault tools' server side (/v1/vault/*, vault-client-token only): one
// strict function per action, each checking its whole body (no key it does
// not name, every value typed and bounded) before anything reaches the vault.
//
//   list    {include_trash?}                      -> {client, items:[meta]}
//   search  {query, include_trash?}               -> {client, items:[meta]}
//   create  {name, uris, username, password?:spec} -> meta (password generated here)
//   update  {id, name?, uris?, username?, rotate_password?:spec} -> meta + changed
//   remove  {id}                                  -> {id, trashed: true} (soft delete)
//   restore {id}                                  -> meta
//   compare {id, field | custom_field, algo, digest, salt?} -> {match}
//   pipe    {id, field | custom_field, target, args?}      -> {target, argv, value}
//
// meta is {id, name, secret?, username, uris, hosts, fields, custom_fields,
// revision_date, trashed}: never a password or TOTP value, only whether one is
// set, and only the names of custom fields.

// compare and pipe take exactly one of field (username, password, totp) and
// custom_field (the exact, case-sensitive name of one of the login's Bitwarden
// custom fields, as vault_list shows it). A custom field is reachable only by
// all_items clients and by explicit secrets whose policy lists it in
// custom_fields. Two custom fields with the same name are refused as
// ambiguous, so only one value is ever chosen. The audit names it
// "custom:<name>", never its value. A new or
// rotated password is always random (generate.mjs), made here; an agent never
// supplies one. compare answers match or no match, never a hash. pipe is the
// one route that hands a value back: to vault-mcp's pipe runner, which writes
// it to an allowlisted command's stdin and returns only the command's scrubbed
// output (see README, "Known limit").
//
// Which logins a client reaches: the item ids its secrets list, and for an
// all_items client every personal login no client lists. Writes go to the
// agent account's personal vault only. Every call is audited: action, item id,
// the names of the fields changed, outcome; never a value.
import { FillError } from './fill.mjs';
import { itemSlug, FIELDS, NO_CHAT, CUSTOM_FIELD_NAME } from './policy.mjs';
import { compareValue, ALGOS, HashError } from './hashes.mjs';
import { generatePassword, checkSpec, GenerateError } from './generate.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f]/;
export const ACTIONS = ['list', 'search', 'create', 'update', 'remove', 'restore', 'compare', 'pipe'];
const KEYS = {
    list: ['include_trash'],
    search: ['query', 'include_trash'],
    create: ['name', 'uris', 'username', 'password'],
    update: ['id', 'name', 'uris', 'username', 'rotate_password'],
    remove: ['id'],
    restore: ['id'],
    compare: ['id', 'field', 'custom_field', 'algo', 'digest', 'salt'],
    pipe: ['id', 'field', 'custom_field', 'target', 'args'],
};
const bad = (msg) => new FillError(msg, 400, 'bad_request');

function onlyKeys(action, body) {
    const extra = Object.keys(body).filter((k) => k !== 'chat' && !KEYS[action].includes(k));
    if (extra.length) throw bad(`${action}: unknown key ${JSON.stringify(extra[0]).slice(0, 40)} (allowed: ${KEYS[action].join(', ') || 'none'})`);
}
function text(v, what, { min = 1, max }) {
    if (typeof v !== 'string' || CONTROL.test(v)) throw bad(`${what} must be a string without control characters`);
    const t = v.trim();
    if (t.length < min || t.length > max) throw bad(`${what} must be ${min}..${max} characters`);
    return t;
}
export function checkUris(v) {
    if (!Array.isArray(v) || v.length < 1 || v.length > 10) throw bad('uris must be a list of 1..10 https URLs');
    return v.map((u) => {
        if (typeof u !== 'string' || u.length > 2048 || CONTROL.test(u)) throw bad('each uri must be an https URL of at most 2048 characters');
        let x;
        try { x = new URL(u); } catch { throw bad('each uri must be an https URL'); }
        if (x.protocol !== 'https:' || !x.hostname) throw bad('each uri must be an https URL');
        if (x.username || x.password) throw bad('a uri may not carry a user name or password');
        return x.toString();
    });
}
const checkId = (v) => { if (typeof v !== 'string' || !UUID.test(v)) throw bad('id must be an item id (uuid) from vault_list'); return v.toLowerCase(); };
const checkBool = (v, what) => { if (v !== undefined && typeof v !== 'boolean') throw bad(`${what} must be true or false`); return v === true; };
const checkField = (v) => { if (!FIELDS.includes(v)) throw bad(`field must be one of ${FIELDS.join(', ')}`); return v; };
/** compare/pipe: {field} or {custom}, from exactly one of body.field and body.custom_field. */
function checkWhich(body) {
    const hasField = body.field !== undefined; const hasCustom = body.custom_field !== undefined;
    if (hasField === hasCustom) throw bad('give exactly one of field (username, password, totp) and custom_field (a custom field name from vault_list)');
    if (hasField) return { field: checkField(body.field) };
    if (typeof body.custom_field !== 'string' || !CUSTOM_FIELD_NAME.test(body.custom_field)) throw bad('custom_field must be 1..64 of A-Z a-z 0-9 space _ . - (a name from vault_list custom_fields)');
    return { custom: body.custom_field };
}
const kindOf = (w) => (w.custom !== undefined ? `custom:${w.custom}` : w.field);

export function createManager({ getPolicy, vault, audit, now = () => Date.now(), compareLimit = { max: 20, windowMs: 10 * 60_000 } }) {
    const compares = new Map(); // `${client}/${id}` -> [timestamps]

    function scope(chat) {
        const policy = getPolicy();
        const sc = policy.scopeOf(chat);
        if (!sc) {
            if (chat === NO_CHAT) throw new FillError('this agent process has no chat id, and the filler policy has no default_client, so it may not use the vault', 403, 'unbound_chat');
            throw new FillError('this chat is not bound to a client in the filler policy; ask the user to bind it', 403, 'unbound_chat');
        }
        return { policy, client: sc.client, path: sc.path, cfg: policy.client(sc.client), manage: policy.manage(sc.client) };
    }
    function need(ctx, perm) {
        const ok = perm === 'pipe' ? !!ctx.manage?.pipe.length : !!ctx.manage?.[perm];
        if (!ok) throw new FillError(`the filler policy does not let this chat's client ${perm === 'remove' ? 'remove' : perm} vault logins (manage.${perm}); ask the user`, 403, 'refused_manage');
    }
    const vaultErr = (err) => {
        if (err instanceof FillError) return err;
        if (err instanceof HashError || err instanceof GenerateError) return bad(err.message);
        const st = err?.status;
        return new FillError(`vault: ${err.message}`, [400, 403, 404, 409, 422].includes(st) ? st : 502, 'vault');
    };

    // The client's view of the vault: [{...meta, secret?, listed?}] for every login it reaches.
    async function view(ctx, { trash = false } = {}) {
        const items = await vault.listItems({ force: false, trash }).catch((e) => { throw vaultErr(e); });
        const all = ctx.policy.allItems(ctx.client);
        const bySecretId = new Map();
        for (const [name, s] of ctx.cfg.secrets) bySecretId.set(s.item_id, [...(bySecretId.get(s.item_id) || []), name]);
        const out = [];
        for (const it of items) {
            const listedBy = ctx.policy.listedBy(it.id);
            if (listedBy === ctx.client) {
                const names = bySecretId.get(it.id) || [];
                const allow = (key, list) => list.filter((f) => names.some((n) => ctx.cfg.secrets.get(n)[key].includes(f)));
                out.push({ ...it, secret: names[0], listed: true, fields: allow('fields', it.fields), custom_fields: allow('custom_fields', it.custom_fields || []) });
            } else if (!listedBy && all && !it.organization) {
                const slug = itemSlug(it.name);
                out.push({ ...it, ...(slug && !ctx.cfg.secrets.has(slug) && !it.trashed ? { secret: slug } : {}) });
            }
        }
        return out;
    }
    const meta = (it) => ({
        id: it.id, name: it.name, ...(it.secret ? { secret: it.secret } : {}), username: it.username,
        uris: it.uris, hosts: it.hosts, fields: it.fields, custom_fields: [...new Set(it.custom_fields || [])], revision_date: it.revision_date, trashed: it.trashed,
    });
    // Whether this chat may use the field or custom field w of a login it reaches (it, from
    // view): throws 404 (naming the custom fields it may use) or 409 (a duplicate name).
    function usable(it, w) {
        if (w.field !== undefined) {
            if (!it.fields.includes(w.field)) throw new FillError(`that login has no ${w.field} this chat may use`, 404, 'not_found');
        } else {
            const names = it.custom_fields || [];
            if (!names.includes(w.custom)) {
                const shown = [...new Set(names)];
                throw new FillError(`that login has no custom field "${w.custom}" this chat may use (its custom fields: ${shown.length ? shown.map((n) => JSON.stringify(n)).join(', ') : 'none'}; names are case-sensitive)`, 404, 'not_found');
            }
            if (names.filter((n) => n === w.custom).length > 1) throw ambiguous(w.custom);
        }
    }
    const ambiguous = (n) => new FillError(`that login has more than one custom field named "${n}"; ambiguous, rename one in the vault`, 409, 'refused_ambiguous');
    // The value of w, after usable(): reads the item and returns {rec, value}. The caller wipes rec.
    async function valueOf(id, w) {
        const rec = await vault.readItem(id).catch((e) => { throw vaultErr(e); });
        if (w.field !== undefined) return { rec, value: rec[w.field] };
        const hits = (rec.custom || []).filter((c) => c.name === w.custom);
        if (hits.length > 1) { wipe(rec); throw ambiguous(w.custom); }
        return { rec, value: hits[0]?.value ?? null };
    }
    // Drop every value a readItem returned (keep: the username, which pipe's argv may use).
    function wipe(rec, { keepUsername = false } = {}) {
        for (const f of FIELDS) if (!(keepUsername && f === 'username')) rec[f] = null;
        for (const c of rec.custom || []) c.value = null;
        rec.custom = null;
    }
    async function item(ctx, id, { trash = false } = {}) {
        const it = (await view(ctx, { trash })).find((x) => x.id === id);
        if (!it) throw new FillError('no login with that id is reachable from this chat (see vault_list)', 404, 'not_found');
        return it;
    }
    async function slugFree(ctx, name, exceptId = null) {
        const slug = itemSlug(name);
        if (!slug) throw bad('name must contain letters or digits (it becomes the login\'s fill name)');
        if (ctx.cfg.secrets.has(slug)) throw new FillError(`the name "${slug}" is already a secret in the policy; pick another name`, 409, 'refused_name');
        const clash = (await view(ctx)).find((x) => x.id !== exceptId && itemSlug(x.name) === slug);
        if (clash) throw new FillError(`a login named "${clash.name}" already has the fill name "${slug}"; pick another name`, 409, 'refused_name');
        return slug;
    }

    async function run(action, body, fn) {
        const chat = body.chat;
        let ctx = null; const ev = { action };
        try {
            onlyKeys(action, body);
            ctx = scope(chat);
            Object.assign(ev, { chat, client: ctx.client, path: ctx.path });
            const out = await fn(ctx, ev);
            audit.record({ ...ev, outcome: 'ok' });
            return out;
        } catch (err0) {
            const err = vaultErr(err0);
            audit.record({ ...ev, chat, outcome: err.outcome || 'error' });
            throw err;
        }
    }

    return {
        list: (body) => run('list', body, async (ctx) => {
            const trash = checkBool(body.include_trash, 'include_trash');
            return { client: ctx.client, items: (await view(ctx, { trash })).map(meta) };
        }),

        search: (body) => run('search', body, async (ctx) => {
            const q = text(body.query, 'query', { max: 200 }).toLowerCase();
            const trash = checkBool(body.include_trash, 'include_trash');
            const hit = (it) => [it.name, it.username, ...it.hosts].some((v) => typeof v === 'string' && v.toLowerCase().includes(q));
            return { client: ctx.client, items: (await view(ctx, { trash })).filter(hit).map(meta) };
        }),

        create: (body) => run('create', body, async (ctx, ev) => {
            need(ctx, 'create');
            const name = text(body.name, 'name', { max: 100 });
            const uris = checkUris(body.uris);
            const username = text(body.username, 'username', { max: 256 });
            const spec = checkSpec(body.password ?? {});
            await slugFree(ctx, name);
            const password = generatePassword(spec);
            const id = await vault.createLogin({ name, uris, username, password }).catch((e) => { throw vaultErr(e); });
            Object.assign(ev, { item_id: id, changed: 'name,uris,username,password' });
            return meta(await item(ctx, id));
        }),

        update: (body) => run('update', body, async (ctx, ev) => {
            need(ctx, 'update');
            const id = checkId(body.id);
            ev.item_id = id;
            const it = await item(ctx, id);
            const changes = {};
            if (body.name !== undefined) { changes.name = text(body.name, 'name', { max: 100 }); if (!it.listed) await slugFree(ctx, changes.name, id); }
            if (body.uris !== undefined) changes.uris = checkUris(body.uris);
            if (body.username !== undefined) changes.username = text(body.username, 'username', { max: 256 });
            if (body.rotate_password !== undefined) changes.password = generatePassword(checkSpec(body.rotate_password));
            if (!Object.keys(changes).length) throw bad('update needs at least one of name, uris, username, rotate_password');
            const changed = await vault.updateLogin(id, changes).catch((e) => { throw vaultErr(e); });
            ev.changed = changed.join(',');
            return { ...meta(await item(ctx, id)), changed };
        }),

        remove: (body) => run('remove', body, async (ctx, ev) => {
            need(ctx, 'remove');
            const id = checkId(body.id);
            ev.item_id = id;
            await item(ctx, id);
            await vault.trashLogin(id).catch((e) => { throw vaultErr(e); });
            return { id, trashed: true, note: 'moved to the vault trash; vault_restore brings it back' };
        }),

        restore: (body) => run('restore', body, async (ctx, ev) => {
            need(ctx, 'remove');
            const id = checkId(body.id);
            ev.item_id = id;
            const it = await item(ctx, id, { trash: true });
            if (!it.trashed) throw new FillError('that login is not in the trash', 409, 'refused');
            await vault.restoreLogin(id).catch((e) => { throw vaultErr(e); });
            return meta(await item(ctx, id));
        }),

        compare: (body) => run('compare', body, async (ctx, ev) => {
            need(ctx, 'compare');
            const id = checkId(body.id);
            const which = checkWhich(body);
            if (!ALGOS.includes(body.algo)) throw bad(`algo must be one of ${ALGOS.join(', ')}`);
            Object.assign(ev, { item_id: id, field_kind: kindOf(which), algo: body.algo });
            const it = await item(ctx, id);
            usable(it, which);
            const key = `${ctx.client}/${id}`;
            const t = now();
            const recent = (compares.get(key) || []).filter((x) => t - x < compareLimit.windowMs);
            if (recent.length >= compareLimit.max) throw new FillError(`too many compares for this login; wait ${Math.ceil(compareLimit.windowMs / 60_000)} minutes`, 429, 'rate_limited');
            recent.push(t); compares.set(key, recent);
            const { rec, value } = await valueOf(id, which);
            try {
                return { match: compareValue(value ?? '', { algo: body.algo, digest: body.digest, salt: body.salt }) };
            } finally { wipe(rec); }
        }),

        pipe: (body) => run('pipe', body, async (ctx, ev) => {
            need(ctx, 'pipe');
            const id = checkId(body.id);
            const which = checkWhich(body);
            const what = which.custom !== undefined ? `custom field "${which.custom}"` : which.field;
            const name = typeof body.target === 'string' ? body.target : '';
            Object.assign(ev, { item_id: id, field_kind: kindOf(which), target: name.slice(0, 64) });
            const target = ctx.policy.pipeTarget(name);
            if (!target || !ctx.manage.pipe.includes(name)) throw new FillError(`pipe target "${name.slice(0, 64)}" is not one this chat's client may use (allowed: ${ctx.manage.pipe.join(', ')})`, 403, 'refused_target');
            const args = body.args ?? {};
            if (!args || typeof args !== 'object' || Array.isArray(args)) throw bad('args must be an object');
            const want = [...target.args.keys()].sort(); const got = Object.keys(args).sort();
            if (want.join(',') !== got.join(',')) throw bad(`target ${name} takes args {${want.join(', ')}}`);
            for (const [slot, re] of target.args) {
                if (typeof args[slot] !== 'string' || !re.test(args[slot])) throw bad(`args.${slot} does not match what target ${name} allows`);
            }
            usable(await item(ctx, id), which);
            const { rec, value } = await valueOf(id, which);
            try {
                if (!value) throw new FillError(`that login has no ${what} value`, 404, 'not_found');
                const argv = target.argv.map((a) => {
                    if (a === '{username}') {
                        if (!rec.username) throw new FillError(`target ${name} needs the login's username, and it has none`, 422, 'refused');
                        return rec.username;
                    }
                    const m = /^\{arg:([a-z0-9_]+)\}$/.exec(a);
                    return m ? args[m[1]] : a;
                });
                return { target: name, argv, value };
            } finally { wipe(rec, { keepUsername: true }); }
        }),
    };
}
