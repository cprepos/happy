// One-time policy upgrade for the vault tools, run by filler-admin install
// as happy-filler (it reads the policy and prints the upgraded one):
//
//   node scripts/policy-upgrade.mjs <policy.json>
//
// A policy without a top-level "pipe_targets" key predates the vault tools.
// It gets "pipe_targets": {} and, on its all_items client (if it has one and
// that client has no "manage" yet), "manage": {"create": true, "update":
// true, "remove": true, "compare": true, "pipe": []}. The upgraded policy is
// validated and printed on stdout (exit 0); the installing shell backs up the
// old file and writes the new one. Exit 3: already upgraded (it has
// pipe_targets, so a manage the operator removed is never added back), nothing
// printed. Exit 1: unreadable or invalid, nothing printed.
import { readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parsePolicy } from '../lib/policy.mjs';

export const MANAGE_ALL = Object.freeze({ create: true, update: true, remove: true, compare: true, pipe: [] });

/** The upgraded policy object, or null when it already has pipe_targets. */
export function upgradePolicy(raw) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('policy is not an object');
    if (Object.hasOwn(raw, 'pipe_targets')) return null;
    const out = structuredClone(raw);
    for (const c of Object.values(out.clients || {})) {
        if (c && c.all_items === true && !Object.hasOwn(c, 'manage')) c.manage = { ...MANAGE_ALL, pipe: [] };
    }
    out.pipe_targets = {};
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
