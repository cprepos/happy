// Plugins: heartbeats of a resumed session (src/plugins/heartbeat.rs) against
// the TS server's sessionCache.ts and sessionUpdateHandler.ts.
//   - After a stop, beats from a socket connected before it stay ignored for
//     the stop window; beats from a socket connected after it count at once.
//   - A session's first beat after it was seen inactive is written at the next
//     flush even within the update threshold.
import { connected, login, step } from './phase2.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => Date.now();
// The activity cache flushes every 5 s.
const FLUSH = 6000;

export async function scenario(t, { sql }) {
    const token = await login(t, 1);
    const H = { authorization: 'Bearer ' + token };
    const s1 = await t.req('create s1', 'POST', '/v1/sessions', { headers: H, body: { tag: 'hb1', metadata: 'm1' } });
    const s2 = await t.req('create s2', 'POST', '/v1/sessions', { headers: H, body: { tag: 'hb2', metadata: 'm2' } });
    const sid = s1.session.id;
    const sid2 = s2.session.id;
    const state = async (name, id) => t.note(name, (await sql(`SELECT "active", "lastActiveAt" > now() AT TIME ZONE 'UTC' - interval '20 seconds' FROM "Session" WHERE "id" = '${id}'`)).trim());

    const ui = await connected(t, 'ui', { token, clientType: 'user-scoped' });
    const a = await connected(t, 'owner a', { token, clientType: 'session-scoped', sessionId: sid });
    const all = [ui, a];

    await step(t, 'a alive', all, () => a.emit('session-alive', { sid, time: now(), thinking: false }));
    await step(t, 'a end', all, () => a.emit('session-end', { sid, time: now() }));
    await sleep(FLUSH);
    await state('after end', sid);
    await step(t, 'a alive after end', all, () => a.emit('session-alive', { sid, time: now() }));
    await sleep(FLUSH);
    await state('a ignored', sid);

    // The resumed owner connects after the stop.
    await sleep(50);
    const b = await connected(t, 'owner b', { token, clientType: 'session-scoped', sessionId: sid });
    all.push(b);
    await step(t, 'b alive', all, () => b.emit('session-alive', { sid, time: now(), thinking: true }));
    await sleep(FLUSH);
    await state('b counted', sid);
    await step(t, 'a alive again', all, () => a.emit('session-alive', { sid, time: now() }));
    await step(t, 'b alive again', all, () => b.emit('session-alive', { sid, time: now() }));

    // An inactive session whose last activity is recent: its first beat is written.
    await sql(`UPDATE "Session" SET "active" = false, "lastActiveAt" = now() AT TIME ZONE 'UTC' - interval '2 seconds' WHERE "id" = '${sid2}'`);
    const c = await connected(t, 'owner c', { token, clientType: 'session-scoped', sessionId: sid2 });
    all.push(c);
    await step(t, 'c alive inactive', all, () => c.emit('session-alive', { sid: sid2, time: now() }));
    await sleep(FLUSH);
    await state('c written', sid2);
    await step(t, 'c alive within threshold', all, () => c.emit('session-alive', { sid: sid2, time: now() }));

    for (const x of all) x.close();
}

export function normalize(s) {
    return s;
}
