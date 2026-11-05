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
            throw new Error('unknown op');
        },
    };
    const clientFor = ({ apiPort, slot }) => {
        const c = {
            healthy: true,
            started: Date.now(),
            async readyz() { calls.push(`ctl.readyz:${slot}`); return c.healthy && up.has(slot) && Date.now() - (up.get(slot)?.at ?? 0) >= readyAfter; },
            async createSession(o = {}) {
                calls.push(`ctl.createSession:${slot}${o.authProfile ? ':' + o.authProfile : ''}`);
                if (createFail) createFail(o);
                return { id: `s${++sessions}`, status: 'active' };
            },
            async saveAuthProfile(sid, name) { calls.push(`ctl.saveAuthProfile:${slot}:${name}`); slotAuth.set(slot, true); return true; },
            async closeSession(sid) { calls.push(`ctl.closeSession:${slot}`); return true; },
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
    return { mgr, calls, up, authDirs, clients, store, advance: (ms) => { t += ms; }, now: () => t };
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
