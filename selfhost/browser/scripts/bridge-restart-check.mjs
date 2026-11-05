#!/usr/bin/env node
// Exit 1 while any live link is held (status user or takeover): restarting the bridge then would
// drop the user's noVNC socket mid-task. Prints each held link by id prefix and a short label
// (its page title) only; never a full id, a reason, a url or a secret.
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
console.error(`refusing to restart the bridge: ${held.length} link(s) held by the user`);
for (const r of held) {
    const label = clean(r.title).slice(0, 40) || '(untitled)';
    console.error(`  ${clean(r.id).slice(0, 8)}…  ${r.status}  ${label}`);
}
process.exit(1);
