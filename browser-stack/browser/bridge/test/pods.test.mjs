// PodManager against a fake launcher and fake per-pod controllers (no Docker, no network).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPodManager, newVncPassword, PodError } from '../lib/pods.mjs';
import { LinkStore } from '../lib/store.mjs';

const A = 'a'.repeat(31) + '1', B = 'b'.repeat(31) + '2', C = 'c'.repeat(31) + '3';
const delay = (ms) => new Promise((r) => setTimeout(r, ms));

function harness({ maxPods = 2, warm = 0, ensureMs = 0, readyAfter = 0, createFail = null, ...opts } = {}) {
    const calls = [];          // every launcher and controller call, in order
    const up = new Map();      // slot -> {pod_id, state}
    const authDirs = new Map(); // chatKey -> saved?
    const slotAuth = new Map(); // slot -> has profiles?
    const clients = new Map(); // slot -> fake client
    let sessions = 0;
    let t = 1_000_000;
    const state = { copyFail: 0 }; // copy_auth calls still to fail
    const launcher = {
        async call(op, args = {}) {
            calls.push(`launcher.${op}${args.slot !== undefined ? ':' + args.slot : ''}`);
            if (op === 'ensure') {
                await delay(ensureMs);
                up.set(args.slot, { pod_id: args.pod_id, state: 'running', at: Date.now() });
                slotAuth.set(args.slot, false);
                return { slot: args.slot, pod_id: args.pod_id, ports: { novnc: 6100 + args.slot, api: 8100 + args.slot, playwright: 9300 + args.slot }, existing: false };
            }
            if (op === 'stop') { up.delete(args.slot); slotAuth.delete(args.slot); return { slot: args.slot }; }
            if (op === 'list') {
                return { pods: [...up].map(([slot, p]) => ({ slot, pod_id: p.pod_id, ports: { novnc: 6100 + slot, api: 8100 + slot, playwright: 9300 + slot }, containers: { node: { state: p.state }, controller: { state: p.state } } })) };
            }
            if (op === 'adopt_auth') { const had = !!authDirs.get(args.chat_hash); if (had) slotAuth.set(args.slot, true); return { adopted: had }; }
            if (op === 'stash_auth') { if (!slotAuth.get(args.slot)) return { stashed: false }; authDirs.set(args.chat_hash, true); return { stashed: true }; }
            if (op === 'copy_auth') {
                calls[calls.length - 1] = `launcher.copy_auth:${args.from_chat_hash.slice(0, 4)}>${args.chat_hash.slice(0, 4)}`;
                if (state.copyFail > 0) { state.copyFail--; throw new Error('launcher down'); }
                if (authDirs.get(args.chat_hash)) return { copied: false, reason: 'exists' };
                if (!authDirs.get(args.from_chat_hash)) return { copied: false, reason: 'no_source' };
                authDirs.set(args.chat_hash, true);
                return { copied: true };
            }
            if (op === 'screen') {
                calls[calls.length - 1] = `launcher.screen:${args.slot}:${args.pod_id === up.get(args.slot)?.pod_id ? 'pod' : 'other'}${args.rect ? `:rect=${args.rect.x},${args.rect.y},${args.rect.width},${args.rect.height}` : ''}`;
                const rect = args.rect || { x: 0, y: 0, width: 1920, height: 1200 };
                return {
                    mime: 'image/png', width: rect.width, height: rect.height, data: 'iVBORw0K', raw_sha256: 'a'.repeat(64),
                    captured_at: '2026-11-11T15:00:00.250Z', local: '2026-11-11T10:00:00.250-05:00', tz: 'America/Toronto',
                    screen: { width: 1920, height: 1200 }, capture_rect: rect, panel_px: 28,
                };
            }
            throw new Error('unknown op');
        },
    };
    const clientFor = ({ apiPort, slot }) => {
        const c = {
            healthy: true,
            started: Date.now(),
            async readyz() { calls.push(`ctl.readyz:${slot}`); return c.healthy && up.has(slot) && Date.now() - (up.get(slot)?.at ?? 0) >= readyAfter; },
            async createSession(o = {}) {
                calls.push(`ctl.createSession:${slot}${o.authProfile ? ':' + o.authProfile : ''}${o.startUrl ? ' ' + o.startUrl : ''}`);
                if (createFail) createFail(o);
                return { id: `s${++sessions}`, status: 'active' };
            },
            async saveAuthProfile(sid, name) { calls.push(`ctl.saveAuthProfile:${slot}:${name}`); slotAuth.set(slot, true); return true; },
            async closeSession(sid) { calls.push(`ctl.closeSession:${slot}`); return true; },
            dead: new Set(),
            approvals: 0,
            async pendingApprovals() { if (c.approvalsFail) throw new Error('down'); return c.approvals; },
            screenQueue: [], // errors (or null) the next screenFront / screenScrub calls throw, in order
            noRect: false, // a controller from before the tab view: no capture_rect back
            async screenFront(sid, { activate, redact, view }) {
                calls.push(`ctl.screenFront:${slot}:${sid}:${activate}${redact === false ? ':raw' : ''}${view ? `:${view}` : ''}`);
                const e = c.screenQueue.shift();
                if (e) throw e;
                const tab = view === 'tab' && !c.noRect;
                return { token: `tok-${slot}-${calls.length}`, url: 'https://example.com/', title: 'Example', view: view || 'desktop', capture_rect: tab ? { x: 0, y: 28, width: 1920, height: 1172 } : null };
            },
            scrubSent: [], // {rawSha256, capture} each screenScrub was sent
            echo: null, // extra fields the controller's reply carries
            async screenScrub(sid, { token, png, label, redact, rawSha256, capture }) {
                calls.push(`ctl.screenScrub:${slot}:${sid}:${token.startsWith(`tok-${slot}-`) ? 'tok' : 'bad'}:${png}:${label}${redact === false ? ':raw' : ''}`);
                c.scrubSent.push({ rawSha256, capture });
                const e = c.screenQueue.shift();
                if (e) throw e;
                const raw = redact === false && !c.ignoresRedact;
                return { ...(c.echo || {}), url: 'https://example.com/', title: 'Example', screenshot_path: `/data/artifacts/${sid}/x-screen-${label}.png`, screenshot_url: `/artifacts/${sid}/x-screen-${label}.png`, width: 1920, height: 1200, png: raw ? 'UkFX' : 'U0NSVUJCRUQ=', pii_scrubbed: !raw, redaction: raw ? 'off_by_request' : 'on', chrome_strip: { x: 0, y: 0, width: 1920, height: 120, source: 'window' }, address_bar_scheme: true };
            },
            async pageShot(sid, { label, redact }) {
                calls.push(`ctl.pageShot:${slot}:${sid}:${label}:${redact}`);
                const e = c.screenQueue.shift();
                if (e) throw e;
                const raw = redact === false && !c.ignoresRedact;
                return { ...(c.echo || {}), url: 'https://example.com/', title: 'Example', screenshot_path: `/data/artifacts/${sid}/x-${label}.png`, screenshot_url: `/artifacts/${sid}/x-${label}.png`, width: 1280, height: 800, png: raw ? 'UkFX' : 'U0NSVUJCRUQ=', pii_scrubbed: !raw, redaction: raw ? 'off_by_request' : 'on' };
            },
            async getSession(sid) {
                calls.push(`ctl.getSession:${slot}`);
                if (c.dead.has(sid)) { const e = new Error('not found'); e.status = 404; throw e; }
                return { id: sid, status: 'active' };
            },
        };
        clients.set(slot, c);
        return c;
    };
    const store = opts.store ?? new LinkStore();
    const mgr = createPodManager({
        launcher, clientFor, store, maxPods, warm,
        idleMs: 10 * 60_000, readyPollMs: 5, readyTimeoutMs: 2000, evictMinIdleMs: 60_000,
        nodeReady: async () => true, portBusy: async () => false,
        now: () => t,
        ...opts,
    });
    return { mgr, calls, up, authDirs, clients, store, state, advance: (ms) => { t += ms; }, now: () => t };
}

test('a cold start makes one pod, one session and the chat link', async () => {
    const h = harness();
    const d = await h.mgr.ensure(A, { source: 'claude' });
    assert.equal(d.state, 'running');
    assert.equal(d.session_id, 's1');
    assert.equal(d.mcp_url, 'http://127.0.0.1:8100/mcp');
    assert.equal(d.slot, 0);
    const link = h.store.findChat(A);
    assert.equal(link.id, d.link_id);
    assert.equal(link.sessionId, 's1');
    assert.deepEqual(h.calls.filter((c) => !c.startsWith('ctl.readyz')), ['launcher.ensure:0', 'ctl.createSession:0']);
    // A second call reuses it.
    const again = await h.mgr.ensure(A);
    assert.equal(again.session_id, 's1');
    assert.equal(h.calls.filter((c) => c === 'launcher.ensure:0').length, 1);
});

test('concurrent calls for one chat start one pod', async () => {
    const h = harness({ ensureMs: 30 });
    const ds = await Promise.all([h.mgr.ensure(A), h.mgr.ensure(A), h.mgr.ensure(A)]);
    assert.deepEqual(new Set(ds.map((d) => d.session_id)), new Set(['s1']));
    assert.equal(h.calls.filter((c) => c.startsWith('launcher.ensure')).length, 1);
    assert.equal(h.mgr.podState(A), 'running');
});

test('a warm spare is assigned without a cold start, and the pool refills', async () => {
    const h = harness({ maxPods: 3, warm: 1 });
    await h.mgr.refill();
    assert.equal(h.mgr.status().pods.filter((p) => p.state === 'ready').length, 1);
    const before = h.calls.filter((c) => c.startsWith('launcher.ensure')).length;
    const d = await h.mgr.ensure(A);
    assert.equal(d.slot, 0);
    // Assigning the spare made no launcher.ensure of its own before the session.
    const sinceAssign = h.calls.slice(h.calls.lastIndexOf('launcher.ensure:0') + 1).filter((c) => !c.startsWith('ctl.readyz'));
    assert.equal(sinceAssign[0], 'ctl.createSession:0');
    assert.equal(h.mgr.timings.at(-1).warm, true);
    await delay(20);
    await h.mgr.refill();
    const st = h.mgr.status();
    assert.equal(st.pods.filter((p) => p.state === 'ready').length, 1, 'refilled');
    assert.equal(h.calls.filter((c) => c.startsWith('launcher.ensure')).length, before + 1);
});

test('a chat waits on a spare that is still starting instead of starting another', async () => {
    const h = harness({ maxPods: 3, warm: 1, ensureMs: 40 });
    const filling = h.mgr.refill();
    await delay(5);
    const d = await h.mgr.ensure(A);
    assert.equal(d.slot, 0);
    await filling;
    assert.equal(h.mgr.timings.at(-1).spare, true);
    assert.equal(h.mgr.timings.at(-1).warm, false, 'it was not ready yet');
    assert.equal(h.calls.filter((c) => c.startsWith('launcher.ensure')).length, 2, 'the spare, then its refill');
});

test('idle stop runs save, stash, close, stop in that order, then the chat is asleep', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    h.calls.length = 0;
    h.advance(11 * 60_000);
    await h.mgr.idleSweep();
    assert.deepEqual(h.calls, ['ctl.saveAuthProfile:0:happy-chat', 'launcher.stash_auth:0', 'ctl.closeSession:0', 'launcher.stop:0']);
    assert.equal(h.mgr.podState(A), 'asleep');
    assert.equal(h.up.size, 0);
    assert.equal(h.mgr.podOf(A), null);
});

test('viewer activity or a held link keeps a pod up', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    h.advance(9 * 60_000);
    h.mgr.touchViewer(A);
    h.advance(5 * 60_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'running', 'a viewer polled 5 min ago');
    h.store.update(h.store.findChat(A), { status: 'user' });
    h.advance(60 * 60_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'running', 'the user holds it');
    h.store.update(h.store.findChat(A), { status: 'watching' });
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'asleep');
});

test('the idle stop defaults to 60 minutes', async () => {
    const h = harness({ idleMs: undefined });
    assert.equal(h.mgr.status().idle_min, 60);
    await h.mgr.ensure(A);
    h.advance(45 * 60_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'running', 'a slow task 45 min in keeps its browser');
    h.advance(16 * 60_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'asleep');
});

test('a watched live view keeps a pod up for as long as it is watched', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    // The phone polls frames/state (or holds a noVNC socket) for two hours, no agent call.
    for (let i = 0; i < 24; i++) {
        h.advance(5 * 60_000);
        h.mgr.touchViewer(A);
        await h.mgr.idleSweep();
    }
    assert.equal(h.mgr.podState(A), 'running');
    h.advance(11 * 60_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'asleep', 'stopped once nobody watches');
});

test('a pending approval keeps an idle pod up until it is decided, or until protectMaxMs', async () => {
    const h = harness({ protectMaxMs: 3 * 3600_000 });
    await h.mgr.ensure(A);
    h.clients.get(0).approvals = 1;
    h.advance(30 * 60_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'running', 'approval pending');
    assert.equal(h.mgr.status().pods[0].kept_for, 'approval_pending');
    h.clients.get(0).approvals = 0;
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'asleep', 'decided: idle as before');

    await h.mgr.ensure(B);
    const c = h.clients.get(0);
    c.approvals = 2;
    h.advance(2 * 3600_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(B), 'running');
    h.advance(3600_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(B), 'asleep', 'a forgotten approval does not pin a pod for ever');
});

test('a controller that cannot list approvals does not keep a pod up', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    h.clients.get(0).approvalsFail = true;
    h.advance(11 * 60_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'asleep');
});

test('hold() keeps a pod from the idle stop; the idle clock restarts at release', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    const release = h.mgr.hold(A, 'approval_ui');
    h.advance(90 * 60_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'running');
    assert.deepEqual(h.mgr.status().pods[0].holds, ['approval_ui']);
    release();
    release();
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'running', 'just released: a fresh idle window');
    h.advance(11 * 60_000);
    await h.mgr.idleSweep();
    assert.equal(h.mgr.podState(A), 'asleep');
    assert.throws(() => h.mgr.hold('nope'), /bad chat_key/);
});

test('eviction skips protected pods and takes the longest idle of the rest', async () => {
    const h = harness({ maxPods: 2 });
    await h.mgr.ensure(A);
    h.advance(5 * 60_000);
    await h.mgr.ensure(B);
    h.advance(5 * 60_000);
    // A is the longest idle, but it has an approval pending: B goes instead.
    h.clients.get(h.mgr._chats.get(A).slot).approvals = 1;
    await h.mgr.ensure(C);
    assert.equal(h.mgr.podState(A), 'running');
    assert.equal(h.mgr.podState(B), 'asleep');
    assert.equal(h.mgr.podState(C), 'running');
    // C held by the bridge, A still pending: the cap holds and nothing is evicted.
    const release = h.mgr.hold(C, 'test');
    h.advance(5 * 60_000);
    await assert.rejects(h.mgr.ensure(B), (e) => e instanceof PodError && e.code === 'busy');
    assert.equal(h.up.size, 2, 'never more pods than the cap');
    release();
    h.advance(2 * 60_000);
    await h.mgr.ensure(B);
    assert.equal(h.mgr.podState(C), 'asleep');
    assert.equal(h.mgr.podState(A), 'running');
});

test('restore passes the saved login only when the chat has one', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    assert.ok(h.calls.includes('ctl.createSession:0'));
    assert.ok(!h.calls.some((c) => c.startsWith('launcher.adopt_auth')), 'nothing to adopt yet');
    h.advance(11 * 60_000);
    await h.mgr.idleSweep();
    assert.equal(h.authDirs.get(A), true);
    h.calls.length = 0;
    const d = await h.mgr.ensure(A);
    assert.equal(d.session_id, 's2');
    const seq = h.calls.filter((c) => !c.startsWith('ctl.readyz'));
    assert.deepEqual(seq, ['launcher.ensure:0', 'launcher.adopt_auth:0', 'ctl.createSession:0:happy-chat']);
    // Same link, new session.
    assert.equal(h.store.findChat(A).sessionId, 's2');
});

test('a session that fails with the saved login is retried without it', async () => {
    let first = true;
    const h = harness({ createFail: (o) => { if (o.authProfile && first) { first = false; throw new Error('bad profile'); } } });
    await h.mgr.ensure(A);
    h.advance(11 * 60_000);
    await h.mgr.idleSweep();
    const d = await h.mgr.ensure(A);
    assert.equal(d.state, 'running');
    assert.ok(h.calls.includes('ctl.createSession:0:happy-chat'));
});

test('two health failures stop a crashed pod; the next call gets a new session under the same link', async () => {
    const h = harness();
    const d1 = await h.mgr.ensure(A);
    h.clients.get(0).healthy = false;
    await h.mgr.healthCheck();
    assert.equal(h.mgr.podState(A), 'running', 'one failure is not enough');
    h.calls.length = 0;
    await h.mgr.healthCheck();
    assert.equal(h.mgr.podState(A), 'crashed');
    assert.ok(!h.calls.includes('ctl.saveAuthProfile:0:happy-chat'), 'a crashed controller is not asked to save');
    assert.ok(h.calls.includes('launcher.stash_auth:0'), 'the last checkpoint is kept');
    const d2 = await h.mgr.ensure(A);
    assert.notEqual(d2.session_id, d1.session_id);
    assert.equal(d2.link_id, d1.link_id);
});

test('a container that is gone counts as a health failure', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    h.up.get(0).state = 'exited';
    await h.mgr.healthCheck();
    await h.mgr.healthCheck();
    assert.equal(h.mgr.podState(A), 'crashed');
});

test('verify replaces a pod that stopped answering', async () => {
    const h = harness();
    const d1 = await h.mgr.ensure(A);
    h.clients.get(0).healthy = false;
    const d2 = await h.mgr.ensure(A, { verify: true });
    assert.notEqual(d2.session_id, d1.session_id);
    assert.equal(d2.state, 'running');
});

test('at the cap the least recently active pod is evicted; held and busy pods never are', async () => {
    const h = harness({ maxPods: 2 });
    await h.mgr.ensure(A);
    h.advance(5 * 60_000);
    await h.mgr.ensure(B);
    h.advance(2 * 60_000);
    // A is older: it goes.
    await h.mgr.ensure(C);
    assert.equal(h.mgr.podState(A), 'asleep');
    assert.equal(h.mgr.podState(B), 'running');
    assert.equal(h.mgr.podState(C), 'running');
    // B held, C just used: nothing can go.
    h.store.update(h.store.findChat(B), { status: 'takeover' });
    await assert.rejects(h.mgr.ensure(A), (e) => e instanceof PodError && e.code === 'busy' && /all 2 browsers are busy/.test(e.message));
    assert.equal(h.mgr.podState(B), 'running');
    // Once C is idle long enough it can be evicted, B still cannot.
    h.advance(2 * 60_000);
    await h.mgr.ensure(A);
    assert.equal(h.mgr.podState(C), 'asleep');
    assert.equal(h.mgr.podState(B), 'running');
});

test('a chat that arrives while a stop refills the pool takes that spare', async () => {
    const h = harness({ maxPods: 2, warm: 1, ensureMs: 20 });
    await h.mgr.ensure(A);
    h.advance(11 * 60_000);
    await h.mgr.refill();
    await h.mgr.stopChat(A, 'idle');
    const d = await h.mgr.ensure(A);
    assert.equal(h.mgr.timings.at(-1).spare, true);
    assert.equal(d.state, 'running');
    await h.mgr.refill();
    assert.ok(h.mgr.status().pods.length <= 2);
});

test('a slot whose port is already taken is skipped', async () => {
    const h = harness({ maxPods: 2, portBases: { novnc: 6100, api: 8100, playwright: 9300 }, portBusy: async (p) => p === 8100 });
    const d = await h.mgr.ensure(A);
    assert.equal(d.slot, 1);
    assert.deepEqual(h.mgr.status().blocked_slots, [0]);
});

test('checkpoints save the login at most once a minute unless forced', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    assert.equal(await h.mgr.checkpointAuth(A), true);
    assert.equal(await h.mgr.checkpointAuth(A), false);
    assert.equal(await h.mgr.checkpointAuth(A, { force: true }), true);
    h.advance(61_000);
    assert.equal(await h.mgr.checkpointAuth(A), true);
    assert.equal(h.calls.filter((c) => c === 'launcher.stash_auth:0').length, 3);
    assert.equal(h.mgr.podState(A), 'running', 'a checkpoint keeps the pod');
});

test('viewer polls do not wake a sleeping chat; wake does', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    h.advance(11 * 60_000);
    await h.mgr.idleSweep();
    h.calls.length = 0;
    h.mgr.touchViewer(A);
    assert.equal(h.mgr.podState(A), 'asleep');
    assert.equal(h.calls.length, 0);
    assert.equal(h.mgr.wake(A), 'starting');
    assert.equal(h.mgr.podState(A), 'starting');
    await delay(30);
    assert.equal(h.mgr.podState(A), 'running');
});

test('lookups by link and session, and stopChat for an ended browser', async () => {
    const h = harness();
    const d = await h.mgr.ensure(A);
    assert.equal(h.mgr.chatForLink(d.link_id).chatKey, A);
    assert.equal(h.mgr.chatForSession('s1').chatKey, A);
    const p = h.mgr.podOf(A);
    assert.equal(p.novncPort, 6100);
    assert.match(p.vncPassword, /^[A-Za-z0-9]{8}$/);
    assert.equal(await h.mgr.stopChat(A, 'user_ended'), true);
    assert.equal(h.mgr.podState(A), 'asleep');
    assert.equal(await h.mgr.stopChat(A, 'user_ended'), false, 'nothing left to stop');
});

test('screen asks the launcher for the chat\'s own slot and pod id, and never wakes a sleeping chat', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    await h.mgr.ensure(B);
    h.calls.length = 0;
    const shot = await h.mgr.screen(B);
    assert.deepEqual([shot.mime, shot.width, shot.height, shot.data], ['image/png', 1920, 1200, 'iVBORw0K']);
    assert.deepEqual(h.calls, ['launcher.screen:1:pod']);
    await h.mgr.stopChat(A, 'idle');
    h.calls.length = 0;
    await assert.rejects(h.mgr.screen(A), (e) => e.status === 503 && /asleep/.test(e.message));
    await assert.rejects(h.mgr.screen('c'.repeat(32)), (e) => e.status === 503);
    await assert.rejects(h.mgr.screen('nothex'), (e) => e.status === 400);
    assert.deepEqual(h.calls, [], 'no launcher call and no wake');
});

test('reconcile adopts recorded pods that are up and ready and removes everything else', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'pods-'));
    const podsPath = join(dir, 'pods.json'), chatsPath = join(dir, 'chats.json');
    const h1 = harness({ maxPods: 3, warm: 1, podsPath, chatsPath });
    await h1.mgr.ensure(A);
    await h1.mgr.ensure(B);
    await h1.mgr.refill();
    h1.mgr.close();
    assert.equal(statSync(podsPath).mode & 0o777, 0o600);
    assert.ok(!readFileSync(chatsPath, 'utf8').includes('vncPassword'));
    // A second bridge, same launcher state: B's pod went away underneath, the spare is not adopted.
    const h2 = harness({ maxPods: 3, podsPath, chatsPath });
    for (const [slot, p] of h1.up) h2.up.set(slot, p);
    const bSlot = h1.mgr._chats.get(B).slot;
    h2.up.get(bSlot).state = 'exited';
    const r = await h2.mgr.reconcile();
    assert.equal(r.adopted, 1);
    assert.equal(r.removed, 2);
    assert.equal(h2.mgr.podState(A), 'running');
    assert.equal(h2.mgr.podState(B), 'asleep');
    assert.equal(h2.mgr.podOf(A).vncPassword, h1.mgr._pods.get(h1.mgr._chats.get(A).slot).vncPassword);
    const again = await h2.mgr.ensure(A);
    assert.equal(again.session_id, 's1', 'the adopted session is kept');
});

test('vnc passwords are 8 alphanumerics and differ', () => {
    const seen = new Set();
    for (let i = 0; i < 200; i++) { const p = newVncPassword(); assert.match(p, /^[A-Za-z0-9]{8}$/); seen.add(p); }
    assert.ok(seen.size > 195);
});

test('a bad chat key is refused', async () => {
    const h = harness();
    await assert.rejects(h.mgr.ensure('nope'), (e) => e.status === 400);
});

test('the pool refills after chats take the spare and the one started behind it', async () => {
    const B2 = 'c'.repeat(32);
    const h = harness({ maxPods: 8, warm: 1, ensureMs: 20 });
    await h.mgr.refill();
    await Promise.all([h.mgr.ensure(A), h.mgr.ensure(B2)]);
    await delay(150);
    assert.equal(h.mgr.status().pods.filter((p) => !p.chat && (p.state === 'ready' || p.state === 'starting')).length, 1, 'a spare is up again');
    await h.mgr.stopChat(A, 'idle');
    await h.mgr.stopChat(B2, 'idle');
    await delay(150);
    const spares = h.mgr.status().pods.filter((p) => !p.chat);
    assert.equal(spares.length, 1);
    assert.equal(spares[0].state, 'ready');
});

test('a refill with nothing to do does not block the next one', async () => {
    const h = harness({ maxPods: 4, warm: 1 });
    await h.mgr.refill();
    await h.mgr.refill(); // pool already full: nothing to do
    await h.mgr.ensure(A);
    await delay(50);
    const spares = h.mgr.status().pods.filter((p) => !p.chat);
    assert.equal(spares.length, 1, 'the spare taken by the chat was replaced');
});

// ── Forked chats inherit the parent's login ─────────────────────────────────
const noReady = (calls) => calls.filter((c) => !c.startsWith('ctl.readyz'));
const copies = (calls) => calls.filter((c) => c.startsWith('launcher.copy_auth')).length;

test('fork: a forked chat copies its parent login once, then adopts it', async () => {
    const logs = [];
    const h = harness({ maxPods: 3, log: (m) => logs.push(m) });
    h.authDirs.set(A, true); // the parent has a saved login and no running pod
    const d = await h.mgr.ensure(B, { source: 'happy', forkedFrom: A });
    assert.equal(d.state, 'running');
    assert.deepEqual(noReady(h.calls), ['launcher.copy_auth:aaaa>bbbb', 'launcher.ensure:0', 'launcher.adopt_auth:0', 'ctl.createSession:0:happy-chat']);
    assert.equal(h.mgr.status().chats.find((c) => c.chat === B.slice(0, 8)).has_auth, true);
    assert.ok(logs.includes(`fork login: chat ${B.slice(0, 8)} from ${A.slice(0, 8)}: copied`), logs.join('\n'));
    assert.ok(logs.every((m) => !m.includes(A) && !m.includes(B)), 'only short keys are logged');

    // Asleep and back: its own login is used, never a second copy.
    await h.mgr.stopChat(B, 'idle');
    h.calls.length = 0;
    await h.mgr.ensure(B, { source: 'happy', forkedFrom: A });
    assert.equal(copies(h.calls), 0, 'copied only once');
    assert.ok(h.calls.some((c) => c.startsWith('ctl.createSession:') && c.endsWith(':happy-chat')));
});

test('fork: a non-forked chat starts fresh, with no copy', async () => {
    const h = harness();
    h.authDirs.set(A, true);
    await h.mgr.ensure(B, { source: 'happy' });
    assert.deepEqual(noReady(h.calls), ['launcher.ensure:0', 'ctl.createSession:0']);
});

test('fork: a running parent is saved first, so the fork gets its current login', async () => {
    const h = harness({ maxPods: 3 });
    await h.mgr.ensure(A, { source: 'happy' }); // parent running, nothing saved yet
    assert.equal(h.authDirs.get(A), undefined);
    h.calls.length = 0;
    await h.mgr.ensure(B, { source: 'happy', forkedFrom: A });
    const seq = noReady(h.calls);
    assert.deepEqual(seq.slice(0, 3), ['ctl.saveAuthProfile:0:happy-chat', 'launcher.stash_auth:0', 'launcher.copy_auth:aaaa>bbbb']);
    assert.ok(seq.includes('ctl.createSession:1:happy-chat'), 'the fork starts with the copied login');
    assert.equal(h.mgr.podState(A), 'running', 'the parent keeps running');
});

test('fork: an existing child login is never overwritten', async () => {
    const logs = [];
    const h = harness({ log: (m) => logs.push(m) });
    h.authDirs.set(A, true);
    h.authDirs.set(B, true); // on disk, but this manager has no record of it
    await h.mgr.ensure(B, { source: 'happy', forkedFrom: A });
    assert.equal(copies(h.calls), 1);
    assert.ok(logs.some((m) => m.endsWith('not copied (exists)')), logs.join('\n'));

    // A chat that knows it has its own login never even asks.
    const h2 = harness({ maxPods: 3 });
    h2.authDirs.set(A, true);
    await h2.mgr.ensure(C, { source: 'happy' });
    await h2.mgr.stopChat(C, 'idle'); // saves C's own login
    h2.calls.length = 0;
    await h2.mgr.ensure(C, { source: 'happy', forkedFrom: A });
    assert.equal(copies(h2.calls), 0);
});

test('fork: a parent with no saved login is tried once', async () => {
    const logs = [];
    const h = harness({ maxPods: 3, log: (m) => logs.push(m) });
    await h.mgr.ensure(B, { source: 'happy', forkedFrom: A });
    assert.ok(logs.some((m) => m.endsWith('not copied (no_source)')));
    assert.deepEqual(noReady(h.calls), ['launcher.copy_auth:aaaa>bbbb', 'launcher.ensure:0', 'ctl.createSession:0']);
    await h.mgr.stopChat(B, 'crashed');
    h.calls.length = 0;
    h.authDirs.set(A, true);
    await h.mgr.ensure(B, { source: 'happy', forkedFrom: A });
    assert.equal(copies(h.calls), 0, 'the fork already had its one try');
});

test('fork: a launcher error is not a try; the next start asks again', async () => {
    const logs = [];
    const h = harness({ maxPods: 3, log: (m) => logs.push(m) });
    h.authDirs.set(A, true);
    h.state.copyFail = 1;
    const d = await h.mgr.ensure(B, { source: 'happy', forkedFrom: A });
    assert.equal(d.state, 'running', 'the chat still starts, without a login');
    assert.ok(logs.some((m) => m.endsWith('copy failed: launcher down')), logs.join('\n'));
    await h.mgr.stopChat(B, 'crashed');
    await h.mgr.ensure(B, { source: 'happy', forkedFrom: A });
    assert.equal(copies(h.calls), 2);
    assert.equal(h.authDirs.get(B), true);
    assert.ok(h.calls.some((c) => c.startsWith('ctl.createSession:') && c.endsWith(':happy-chat')));
});

test('fork: a bad or self forkedFrom is refused before anything starts', async () => {
    const h = harness();
    for (const bad of ['nothex', A.toUpperCase(), B, 7]) {
        await assert.rejects(h.mgr.ensure(B, { forkedFrom: bad }), (e) => e instanceof PodError && e.status === 400);
    }
    assert.deepEqual(h.calls, []);
});

test('fork: the one try survives a bridge restart', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'pods-fork-'));
    const paths = { chatsPath: join(dir, 'chats.json'), podsPath: join(dir, 'pods.json') };
    const h = harness(paths);
    await h.mgr.ensure(B, { source: 'happy', forkedFrom: A });
    const saved = JSON.parse(readFileSync(paths.chatsPath, 'utf8')).chats.find((c) => c.chatKey === B);
    assert.equal(saved.forkChecked, true);
    const h2 = harness(paths);
    h2.authDirs.set(A, true);
    await h2.mgr.ensure(B, { source: 'happy', forkedFrom: A });
    assert.equal(copies(h2.calls), 0);
});

test('preflight: check asks a live session once per window; a dead one is replaced at the last page, at most twice per 5 minutes', async () => {
    const h = harness();
    const KEY = 'a'.repeat(32);
    const d0 = await h.mgr.ensure(KEY, {});
    const alive = await h.mgr.ensure(KEY, { check: true });
    assert.equal(alive.session_id, d0.session_id);
    assert.equal(alive.recovered, undefined);
    assert.ok(!h.calls.includes(`ctl.getSession:${d0.slot}`), 'just started: no need to ask');
    h.advance(3000);
    await h.mgr.ensure(KEY, { check: true });
    assert.ok(h.calls.includes(`ctl.getSession:${d0.slot}`));

    const link = h.store.findChat(KEY);
    assert.ok(link, 'the chat has a link');
    link.url = 'https://news.ycombinator.com/item?id=1';
    let cur = d0;
    for (let i = 1; i <= 2; i++) {
        h.advance(3000);
        h.clients.get(cur.slot).dead.add(cur.session_id);
        const r = await h.mgr.ensure(KEY, { check: true });
        assert.deepEqual(r.recovered, { reason: 'session_ended', previous_session_id: cur.session_id });
        assert.notEqual(r.session_id, cur.session_id);
        assert.ok(h.calls.some((c) => c.endsWith(' https://news.ycombinator.com/item?id=1')), 'reopened at the last page');
        cur = r;
    }
    h.advance(3000);
    h.clients.get(cur.slot).dead.add(cur.session_id);
    await assert.rejects(h.mgr.ensure(KEY, { check: true }), (e) => e.code === 'recovery_limit' && e.status === 503);
    h.advance(5 * 60_000);
    const again = await h.mgr.ensure(KEY, { check: true });
    assert.equal(again.recovered.reason, 'session_ended');
});

test('phantoms: a start stuck past its deadline is torn down and the chat left asleep, not hanging', async () => {
    const h = harness({ ensureMs: 300, startTimeoutMs: 60 });
    const KEY = 'b'.repeat(32);
    await assert.rejects(h.mgr.ensure(KEY, {}), (e) => e.code === 'start_timeout');
    assert.deepEqual(h.mgr.liveness(KEY), { live: false, pod: 'asleep', reason: 'asleep' });
    assert.ok(h.calls.includes('launcher.stop:0'), 'its slot is stopped');
    await delay(400); // the launcher answers late: nothing comes back to life
    assert.equal(h.mgr.podState(KEY), 'asleep');
    assert.equal(h.mgr._chats.get(KEY).slot, null);
    assert.ok(!h.calls.some((c) => c.startsWith('ctl.createSession')), 'no session on the abandoned pod');
});

test('phantoms: live needs a session that answered lately; the sweep refreshes it, sleeps a dead one and clears a stale slot', async () => {
    const h = harness();
    const KEY = 'c'.repeat(32);
    const d = await h.mgr.ensure(KEY, {});
    assert.equal(h.mgr.liveness(KEY).live, true);
    h.advance(151_000);
    assert.deepEqual(h.mgr.liveness(KEY), { live: false, pod: 'dead', reason: 'session_not_answering' });
    assert.equal(await h.mgr.phantomSweep(), 0);
    assert.equal(h.mgr.liveness(KEY).live, true);

    const link = h.store.findChat(KEY);
    h.store.update(link, { url: 'https://news.ycombinator.com/news', title: 'HN' });
    h.store.update(link, { url: 'about:blank', title: '' });
    h.store.update(link, { url: 'chrome://newtab/' });
    assert.equal(link.url, 'https://news.ycombinator.com/news', 'the last real page is kept');
    assert.equal(link.title, 'HN');

    h.clients.get(d.slot).dead.add(d.session_id);
    assert.equal(await h.mgr.phantomSweep(), 1);
    assert.deepEqual(h.mgr.liveness(KEY), { live: false, pod: 'asleep', reason: 'asleep' });
    assert.ok(h.calls.some((c) => c.startsWith(`ctl.saveAuthProfile:${d.slot}`)), 'the sleep path saved the login');
    assert.ok(h.calls.includes(`launcher.stash_auth:${d.slot}`));

    // An asleep chat still naming a slot (from an older chats.json) is cleared.
    Object.assign(h.mgr._chats.get(KEY), { slot: 2, podId: 'gone' });
    assert.equal(await h.mgr.phantomSweep(), 1);
    assert.equal(h.mgr._chats.get(KEY).slot, null);
    // Woken again: it reopens the last real page.
    await h.mgr.ensure(KEY, {});
    assert.ok(h.calls.some((c) => c.endsWith(' https://news.ycombinator.com/news')));
});

// Sleep (the user's Sleep button, an idle stop, the agent's close) resumes on the last page;
// only the user's End starts the next browser on a new page, still signed in.
async function stoppedWith(why, paths = {}) {
    const h = harness(paths);
    await h.mgr.ensure(A);
    h.store.update(h.store.findChat(A), { url: 'https://example.com/cart', title: 'Cart' });
    assert.equal(await h.mgr.stopChat(A, why), true);
    return h;
}
const starts = (h) => h.calls.filter((c) => c.startsWith('ctl.createSession'));

test('sleep: a slept chat wakes on its last page with its login', async () => {
    const h = await stoppedWith('slept');
    h.calls.length = 0;
    await h.mgr.ensure(A);
    assert.deepEqual(starts(h), ['ctl.createSession:0:happy-chat https://example.com/cart']);
    assert.equal(h.store.findChat(A).url, 'https://example.com/cart');
});

test('sleep: the agent closing the browser still resumes on the last page', async () => {
    const h = await stoppedWith('closed');
    h.calls.length = 0;
    await h.mgr.ensure(A);
    assert.deepEqual(starts(h), ['ctl.createSession:0:happy-chat https://example.com/cart']);
});

test('end: an ended chat starts signed in on a new page, and the link forgets the old one', async () => {
    const h = await stoppedWith('user_ended');
    h.calls.length = 0;
    const d = await h.mgr.ensure(A, { check: true });
    assert.deepEqual(starts(h), ['ctl.createSession:0:happy-chat']);
    assert.equal(d.recovered.reason, 'ended');
    const link = h.store.findChat(A);
    assert.equal(link.url, null);
    assert.equal(link.title, null);
    // One fresh start only: after that, stops resume on the last page again.
    link.url = 'https://example.com/next';
    await h.mgr.stopChat(A, 'idle');
    h.calls.length = 0;
    const d2 = await h.mgr.ensure(A, { check: true });
    assert.deepEqual(starts(h), ['ctl.createSession:0:happy-chat https://example.com/next']);
    assert.equal(d2.recovered.reason, 'pod_asleep');
});

test('end: a close after End with nothing running keeps the next start fresh', async () => {
    const h = await stoppedWith('user_ended');
    assert.equal(await h.mgr.stopChat(A, 'closed'), false);
    h.calls.length = 0;
    await h.mgr.ensure(A);
    assert.deepEqual(starts(h), ['ctl.createSession:0:happy-chat']);
});

test('end: the fresh start survives a bridge restart and clears after one start', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'pods-fresh-'));
    const paths = { chatsPath: join(dir, 'chats.json'), podsPath: join(dir, 'pods.json') };
    const store = new LinkStore();
    const h = await stoppedWith('user_ended', { ...paths, store });
    const saved = JSON.parse(readFileSync(paths.chatsPath, 'utf8')).chats.find((c) => c.chatKey === A);
    assert.equal(saved.fresh, true);
    const h2 = harness({ ...paths, store });
    h2.authDirs.set(A, true);
    await h2.mgr.ensure(A);
    assert.deepEqual(starts(h2), ['ctl.createSession:0:happy-chat']);
    const after = JSON.parse(readFileSync(paths.chatsPath, 'utf8')).chats.find((c) => c.chatKey === A);
    assert.equal(after.fresh, false);
});

test('screenShot: the chat\'s own tab forward, its own pod\'s screen, scrubbed by its own controller', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    await h.mgr.ensure(B);
    h.calls.length = 0;
    const shot = await h.mgr.screenShot(B, { label: 'evidence' });
    assert.deepEqual(h.calls, ['ctl.screenFront:1:s2:true', 'launcher.screen:1:pod', 'ctl.screenScrub:1:s2:tok:iVBORw0K:evidence']);
    assert.equal(shot.data, 'U0NSVUJCRUQ=', 'the scrubbed image, never the raw capture');
    assert.equal(shot.session_id, 's2');
    assert.equal(shot.url, 'https://example.com/');
    assert.equal(shot.title, 'Example');
    assert.equal(shot.pii_scrubbed, true);
    assert.equal(shot.redaction, 'on');
    assert.deepEqual(shot.chrome_strip, { x: 0, y: 0, width: 1920, height: 120, source: 'window' });
    assert.equal(shot.address_bar_scheme, true);
    assert.equal(shot.screenshot_url, '/artifacts/s2/x-screen-evidence.png');
    assert.match(shot.captured_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
    // Held by the user: their tab is not changed.
    h.calls.length = 0;
    await h.mgr.screenShot(A, { activate: false });
    assert.deepEqual(h.calls[0], 'ctl.screenFront:0:s1:false');
    // Asleep, unknown or malformed: refused, never woken.
    await h.mgr.stopChat(A, 'idle');
    h.calls.length = 0;
    await assert.rejects(h.mgr.screenShot(A), (e) => e.status === 503 && /asleep/.test(e.message));
    await assert.rejects(h.mgr.screenShot('c'.repeat(32)), (e) => e.status === 503);
    await assert.rejects(h.mgr.screenShot('nothex'), (e) => e.status === 400);
    assert.deepEqual(h.calls, []);
});

test('screenShot: a page that moved is captured again once; a refusal is passed on in the controller\'s words', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    const c = h.clients.get(0);
    const err = (status, code, detail) => Object.assign(new PodError(`pod POST /happy -> ${status}`, status, code), { detail });
    c.screenQueue.push(null, err(409, 'moved', 'The page navigated'));
    h.calls.length = 0;
    const shot = await h.mgr.screenShot(A);
    assert.equal(shot.data, 'U0NSVUJCRUQ=');
    assert.equal(h.calls.filter((x) => x.startsWith('launcher.screen')).length, 2);
    c.screenQueue.push(null, err(409, 'moved', 'x'), null, err(409, 'moved', 'The page navigated again'));
    await assert.rejects(h.mgr.screenShot(A), (e) => e.status === 409 && /refused: The page navigated again/.test(e.message));
    c.screenQueue.push(err(409, 'not_in_front', 'This session\'s tab is not the one the browser window shows'));
    h.calls.length = 0;
    await assert.rejects(h.mgr.screenShot(A), (e) => e.status === 409 && e.code === 'not_in_front');
    assert.ok(!h.calls.some((x) => x.startsWith('launcher.screen')), 'nothing captured when the tab is not in front');
    c.screenQueue.push(err(404, undefined, null));
    c.screenQueue[0].message = 'pod POST /happy -> 404 {"detail":"Not Found"}';
    await assert.rejects(h.mgr.screenShot(A), (e) => e.status === 501 && e.code === 'screen_unsupported');
});

test('screenShot / pageShot: redact false is passed to the chat\'s own controller and must come back unredacted', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    h.calls.length = 0;
    const raw = await h.mgr.screenShot(A, { label: 'ev', redact: false });
    assert.deepEqual(h.calls, ['ctl.screenFront:0:s1:true:raw', 'launcher.screen:0:pod', 'ctl.screenScrub:0:s1:tok:iVBORw0K:ev:raw']);
    assert.deepEqual([raw.data, raw.pii_scrubbed, raw.redaction], ['UkFX', false, 'off_by_request']);
    h.calls.length = 0;
    const page = await h.mgr.pageShot(A, { label: 'p', redact: false });
    assert.deepEqual(h.calls, ['ctl.pageShot:0:s1:p:false']);
    assert.deepEqual([page.session_id, page.width, page.redaction, page.pii_scrubbed], ['s1', 1280, 'off_by_request', false]);
    assert.match(page.captured_at, /Z$/);
    // A controller that did not honour it: refused, not passed off as unredacted.
    h.clients.get(0).ignoresRedact = true;
    await assert.rejects(h.mgr.screenShot(A, { redact: false }), (e) => e.status === 502);
    await assert.rejects(h.mgr.pageShot(A, { redact: false }), (e) => e.status === 502);
    // The deployment's strict mode, in the controller's words.
    const c = h.clients.get(0);
    c.screenQueue.push(Object.assign(new PodError('pod POST -> 403', 403, 'redaction_required'), { detail: 'This deployment requires screenshots to be PII-scrubbed' }));
    await assert.rejects(h.mgr.pageShot(A, { redact: false }), (e) => e.status === 403 && e.code === 'redaction_required' && /requires/.test(e.message));
    await h.mgr.stopChat(A, 'idle');
    await assert.rejects(h.mgr.pageShot(A, { redact: false }), (e) => e.status === 503);
    await assert.rejects(h.mgr.pageShot('nothex'), (e) => e.status === 400);
});

test('screenShot: the capture\'s hash and meta go to the controller, and its evidence fields come back', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    const c = h.clients.get(0);
    // A controller that says no captured_at: the bridge's own time stands.
    const old = await h.mgr.screenShot(A, { label: 'ev' });
    assert.match(old.captured_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
    assert.ok(!('evidence_bar_px' in old));
    assert.deepEqual(c.scrubSent[0], {
        rawSha256: 'a'.repeat(64),
        capture: {
            captured_at: '2026-11-11T15:00:00.250Z', local: '2026-11-11T10:00:00.250-05:00', tz: 'America/Toronto',
            screen: { width: 1920, height: 1200 }, capture_rect: { x: 0, y: 0, width: 1920, height: 1200 }, panel_px: 28,
        },
    });
    const fields = {
        captured_at: '2026-11-11T15:00:00.250Z', tz: 'America/Toronto', view: 'desktop', evidence_bar_px: 28, panel_px: 28,
        capture_rect: { x: 0, y: 0, width: 1920, height: 1200 }, raw_sha256: 'a'.repeat(64), filed_sha256: 'b'.repeat(64),
    };
    c.echo = fields;
    const shot = await h.mgr.screenShot(A, { label: 'ev' });
    for (const [k, v] of Object.entries(fields)) assert.deepEqual(shot[k], v, k);
    assert.ok(!('stamp_text' in shot));
    const page = await h.mgr.pageShot(A, { label: 'p' });
    assert.equal(page.captured_at, '2026-11-11T15:00:00.250Z');
    // Nonsense in the fields is not passed on.
    c.echo = { captured_at: 5, evidence_bar_px: '28', view: 'window', raw_sha256: 1, tz: {} };
    const odd = await h.mgr.pageShot(A, { label: 'p' });
    assert.match(odd.captured_at, /Z$/);
    for (const k of ['evidence_bar_px', 'view', 'raw_sha256', 'tz']) assert.ok(!(k in odd), k);
});

test('screenShot view "tab": the controller\'s window rectangle is what the launcher reads', async () => {
    const h = harness();
    await h.mgr.ensure(A);
    const c = h.clients.get(0);
    h.calls.length = 0;
    await h.mgr.screenShot(A, { label: 'ev', view: 'tab' });
    assert.deepEqual(h.calls, ['ctl.screenFront:0:s1:true:tab', 'launcher.screen:0:pod:rect=0,28,1920,1172', 'ctl.screenScrub:0:s1:tok:iVBORw0K:ev']);
    assert.deepEqual(c.scrubSent.at(-1).capture.capture_rect, { x: 0, y: 28, width: 1920, height: 1172 });
    // desktop: no rectangle, the whole screen.
    h.calls.length = 0;
    await h.mgr.screenShot(A, { view: 'desktop' });
    assert.equal(h.calls[1], 'launcher.screen:0:pod');
    // A controller without the tab view: refused, never a whole-screen shot passed off as the tab.
    c.noRect = true;
    h.calls.length = 0;
    await assert.rejects(h.mgr.screenShot(A, { view: 'tab' }), (e) => e.status === 502);
    assert.ok(!h.calls.some((x) => x.startsWith('launcher.screen')));
    // The controller's 400s (a hash that does not match, a capture of the wrong rectangle) in its words.
    c.noRect = false;
    c.screenQueue.push(null, Object.assign(new PodError('pod POST -> 400', 400, 'raw_hash_mismatch'), { detail: 'The image is not the one the capture produced' }));
    await assert.rejects(h.mgr.screenShot(A), (e) => e.status === 400 && e.code === 'raw_hash_mismatch' && /not the one/.test(e.message));
});
