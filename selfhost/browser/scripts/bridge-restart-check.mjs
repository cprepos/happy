#!/usr/bin/env node
// Information only, before a bridge restart: lists the live links the user holds (status user or
// takeover), which the stopping bridge will release (reason bridge_restarting). Each by id prefix
// and a short label (its page title) only; never a full id, a reason, a url or a secret. Exits 0
// either way, 2 only when the links file cannot be read.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const home = process.env.HAPPY_BROWSER_HOME || join(process.env.HOME, '.local/share/happy-browser');
const path = process.env.BRIDGE_STORE || join(home, 'bridge/links.json');
let data;
try {
    data = JSON.parse(readFileSync(path, 'utf8'));
} catch (err) {
    if (err.code === 'ENOENT') { console.log('no links file: nothing is held'); process.exit(0); }
    console.error(`cannot read the links file: ${err.code || err.message}`);
    process.exit(2);
}
const clean = (s) => String(s ?? '').replace(/[\u0000-\u001f\u007f]+/g, ' ').trim();
const held = (data.links || []).filter((r) => r.status === 'user' || r.status === 'takeover');
if (!held.length) { console.log('no link is held'); process.exit(0); }
console.log(`the restart will release ${held.length} held link(s); the agent can take control again after it:`);
for (const r of held) {
    const label = clean(r.title).slice(0, 40) || '(untitled)';
    console.log(`  ${clean(r.id).slice(0, 8)}…  ${r.status}  ${label}`);
}
