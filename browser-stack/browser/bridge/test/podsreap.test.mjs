// make browser-pods-reap's plan (scripts/pods-reap.mjs), on fake docker and bridge answers only.
import test from 'node:test';
import assert from 'node:assert/strict';
import { planReap } from '../../scripts/pods-reap.mjs';

const pod = (slot) => [
    { id: `n${slot}`, slot: String(slot), role: 'node', state: 'running', name: `pod-${slot}-node` },
    { id: `c${slot}`, slot: String(slot), role: 'controller', state: 'running', name: `pod-${slot}-controller` },
];
const containers = [0, 1, 2, 3, 4, 5].flatMap(pod);
const status = {
    pods: [
        { slot: 0, state: 'ready', chat: null, held: false, idle_s: null },              // warm spare
        { slot: 1, state: 'assigned', chat: '1e8536d7', held: false, idle_s: 4000 },     // active session
        { slot: 2, state: 'assigned', chat: 'aa11bb22', held: true, idle_s: 9000 },      // user holds the link
        { slot: 3, state: 'starting', chat: null, held: false, idle_s: null },
        { slot: 4, state: 'ready', chat: null, held: false, idle_s: 30 },               // used just now
        // slot 5: the bridge does not know it (a leftover)
    ],
};

test('reap: in-use pods are kept, spares and leftovers are listed for removal', () => {
    const p = planReap(containers, status);
    assert.deepEqual(p.remove.map((c) => c.id).sort(), ['c0', 'c5', 'n0', 'n5']);
    const why = Object.fromEntries(p.keep.map((k) => [k.slot, k.why.join('; ')]));
    assert.match(why[1], /chat 1e8536d7's session/);
    assert.match(why[2], /held by the user/);
    assert.match(why[3], /starting/);
    assert.match(why[4], /used 30 s ago/);
});

test('reap: no bridge answer removes nothing; FORCE removes everything; pods off means all are leftovers', () => {
    const none = planReap(containers, null);
    assert.equal(none.remove.length, 0);
    assert.match(none.refused, /FORCE=1/);
    assert.equal(planReap(containers, null, { force: true }).remove.length, containers.length);
    assert.equal(planReap(containers, { pods: [] }).remove.length, containers.length);
});
