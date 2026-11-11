// Policy upgrades, run by filler-admin policy-upgrade (it reads the policy
// and writes the upgraded one, keeping a backup):
//
//   node scripts/policy-upgrade.mjs <policy.json>
//
// Each step runs once, on a policy that lacks what it adds:
//
//   pipe_targets  (the vault tools) a policy without "pipe_targets" gets
//                 "pipe_targets": {} and, on its all_items client (if it has
//                 one and that client has no "manage" yet), "manage":
//                 {"create": true, "update": true, "remove": true, "compare":
//                 true, "pipe": []}. Once pipe_targets is there, a manage the
//                 operator removed is never added back.
//   backends      (more than one vault) a policy without "backends" gets
//                 "backends": {"shared": {"type": "vaultwarden"}} and
//                 "backend": "shared" on every client: what such a policy
//                 already meant (the Vaultwarden at VAULT_URL, its keys in
//                 secrets/), now written out.
//
// The upgraded policy is validated and printed on stdout (exit 0). Exit 3:
// nothing to upgrade, nothing printed. Exit 1: unreadable or invalid,
// nothing printed.
import { readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parsePolicy } from '../lib/policy.mjs';

export const MANAGE_ALL = Object.freeze({ create: true, update: true, remove: true, compare: true, pipe: [] });

export const SHARED_BACKEND = Object.freeze({ type: 'vaultwarden' });

/** The upgrade steps a policy still needs, by name (see above). */
export function pendingUpgrades(raw) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('policy is not an object');
    return ['pipe_targets', 'backends'].filter((k) => !Object.hasOwn(raw, k));
}

/** The upgraded policy object, or null when it needs no upgrade. */
export function upgradePolicy(raw) {
    const steps = pendingUpgrades(raw);
    if (!steps.length) return null;
    const out = structuredClone(raw);
    if (steps.includes('pipe_targets')) {
        for (const c of Object.values(out.clients || {})) {
            if (c && c.all_items === true && !Object.hasOwn(c, 'manage')) c.manage = { ...MANAGE_ALL, pipe: [] };
        }
        out.pipe_targets = {};
    }
    if (steps.includes('backends')) {
        // A client naming a backend in a policy without backends is invalid; parsePolicy below refuses it.
        for (const c of Object.values(out.clients || {})) if (c && typeof c === 'object' && !Object.hasOwn(c, 'backend')) c.backend = 'shared';
        out.backends = { shared: { ...SHARED_BACKEND } };
    }
    parsePolicy(out); // throws on anything the filler would refuse
    return out;
}

// Through a symlink (current -> releases/<sha>) argv[1] is the link path and
// import.meta.url the real one, so compare real paths.
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
    try {
        const up = upgradePolicy(JSON.parse(readFileSync(process.argv[2], 'utf8')));
        if (!up) process.exit(3);
        process.stdout.write(`${JSON.stringify(up, null, 2)}\n`);
    } catch (err) {
        process.stderr.write(`policy-upgrade: ${err.message}\n`);
        process.exit(1);
    }
}
