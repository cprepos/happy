#!/usr/bin/env node
// make browser-pods-reap: remove this project's pod containers that no chat is using.
//
// A pod is kept when the bridge (GET /api/pods) says its slot is in use: assigned to a chat
// (an active session), its link held by the user (user/takeover), starting or stopping, or
// used in the last REAP_RECENT_MIN minutes. Everything else (warm spares, slots the bridge
// does not know, containers left from a bridge that is gone) is listed, and removed after a
// yes on a terminal. Without a terminal, or with DRY_RUN=1, the list is only printed.
// When the bridge does not answer nothing is removed, since what is in use cannot be told.
// FORCE=1: the old behaviour, every pod container of the project removed, no questions.
// Saved logins (data/chats) are never touched; the launcher wipes a slot's directory when
// the slot is next used.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { pathToFileURL } from 'node:url';

const BUSY_STATES = new Set(['starting', 'assigned', 'stopping']);

/**
 * containers: [{id, slot, role, state, name}] from docker. status: the bridge's /api/pods
 * answer, or null when it did not answer. -> {remove: [container], keep: [{slot, why, containers}], refused?}
 */
export function planReap(containers, status, { force = false, recentS = 600 } = {}) {
    if (force) return { remove: containers, keep: [] };
    if (!status) return { remove: [], keep: [], refused: 'the bridge did not answer, so which pods are in use cannot be told (FORCE=1 removes them all)' };
    const known = new Map(Array.isArray(status.pods) ? status.pods.map((p) => [String(p.slot), p]) : []);
    const bySlot = new Map();
    for (const c of containers) {
        const k = String(c.slot);
        if (!bySlot.has(k)) bySlot.set(k, []);
        bySlot.get(k).push(c);
    }
    const remove = [];
    const keep = [];
    for (const [slot, cs] of bySlot) {
        const p = known.get(slot);
        const why = [];
        if (p) {
            if (p.chat) why.push(`chat ${p.chat}'s session`);
            if (p.held) why.push('its link is held by the user');
            if (typeof p.idle_s === 'number' && p.idle_s < recentS) why.push(`used ${p.idle_s} s ago`);
            if (BUSY_STATES.has(p.state) && !p.chat) why.push(p.state);
        }
        if (why.length) keep.push({ slot, why, containers: cs });
        else remove.push(...cs);
    }
    return { remove, keep };
}

function dockerPods(project) {
    const r = spawnSync('docker', ['ps', '-a', '--filter', 'label=happy-browser.pod=1', '--filter', `label=happy-browser.project=${project}`,
        '--format', '{{.ID}}\t{{.Label "happy-browser.slot"}}\t{{.Label "happy-browser.role"}}\t{{.State}}\t{{.Names}}'], { encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`docker ps failed: ${(r.stderr || '').trim()}`);
    return r.stdout.split('\n').filter(Boolean).map((l) => {
        const [id, slot, role, state, name] = l.split('\t');
        return { id, slot, role, state, name };
    });
}

async function bridgeStatus(bridge, home) {
    try {
        const token = readFileSync(join(home, 'secrets', 'bridge-token'), 'utf8').trim();
        const r = await fetch(`${bridge}/api/pods`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(5000) });
        if (!r.ok) return null;
        const j = await r.json();
        // Pods off: the bridge runs none, so every pod container is a leftover.
        return j.pods === false ? { pods: [] } : j;
    } catch { return null; }
}

const line = (c) => `  slot ${c.slot} ${c.role.padEnd(10)} ${c.state.padEnd(8)} ${c.name}`;

async function main() {
    const env = process.env;
    const force = env.FORCE === '1';
    const dry = env.DRY_RUN === '1';
    const containers = dockerPods(env.BROWSER_PROJECT || 'happy-browser');
    if (!containers.length) { console.log('no pods'); return 0; }
    const status = force ? null : await bridgeStatus(env.BROWSER_BRIDGE || 'http://127.0.0.1:6090', env.HAPPY_BROWSER_HOME || join(env.HOME, '.local/share/happy-browser'));
    const plan = planReap(containers, status, { force, recentS: 60 * Number(env.REAP_RECENT_MIN || 10) });
    if (plan.refused) { console.error(`browser-pods-reap: nothing removed: ${plan.refused}`); return 1; }
    for (const k of plan.keep) console.log(`keep slot ${k.slot}: ${k.why.join(', ')}`);
    if (!plan.remove.length) { console.log('nothing to remove'); return 0; }
    console.log(`${force ? 'removing' : 'would remove'} ${plan.remove.length} container(s):`);
    for (const c of plan.remove) console.log(line(c));
    if (!force) {
        if (dry || !process.stdin.isTTY || !process.stdout.isTTY) { console.log(dry ? '(DRY_RUN=1: nothing removed)' : '(no terminal: nothing removed; run it in a terminal to confirm, or FORCE=1)'); return 0; }
        const rl = createInterface({ input: process.stdin, output: process.stdout });
        const a = (await rl.question('Remove them? [y/N] ')).trim().toLowerCase();
        rl.close();
        if (a !== 'y' && a !== 'yes') { console.log('nothing removed'); return 0; }
    }
    const r = spawnSync('docker', ['rm', '-f', ...plan.remove.map((c) => c.id)], { stdio: 'inherit' });
    return r.status ?? 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exit(await main());
