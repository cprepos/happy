// Which browser sessions have had a secret typed into them, and for which
// (chat, client). A session is bound to the first (chat, client) that fills
// into it; a fill for any other is refused. The record (no values) is kept in
// state/taint.json so a restart keeps sessions tainted; the values themselves,
// for scrubbing, are in memory only (scrub.mjs).
//
// A session that is closed or gone (404) is dropped, values and all, after a
// grace period (10 minutes), so late tool results are still scrubbed.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { isLive } from './controller.mjs';

export function createTaint({ statePath = null, scrubber, controllers = null, now = () => Date.now(), graceMs = 10 * 60_000, log = () => {} }) {
    /** "<port>/<session id>" -> {chat, client, port, session, drop_images, since, closed_at} */
    const sessions = new Map();
    if (statePath) {
        try {
            const raw = JSON.parse(readFileSync(statePath, 'utf8'));
            for (const [id, s] of Object.entries(raw.sessions || {})) sessions.set(id, { ...s, restored: true });
        } catch {}
    }
    function save() {
        if (!statePath) return;
        try {
            mkdirSync(dirname(statePath), { recursive: true });
            const tmp = `${statePath}.tmp`;
            const out = {};
            for (const [id, s] of sessions) out[id] = { chat: s.chat, client: s.client, port: s.port ?? null, session: s.session ?? null, drop_images: !!s.drop_images, since: s.since, closed_at: s.closed_at ?? null };
            writeFileSync(tmp, JSON.stringify({ version: 1, sessions: out }), { mode: 0o600 });
            renameSync(tmp, statePath);
        } catch (err) { log(`taint state not saved: ${err.code || err.message}`); }
    }

    return {
        /** Refuse a session already bound to another chat or client. */
        checkBinding(session, chat, client) {
            const s = sessions.get(session);
            if (s && (s.chat !== chat || s.client !== client)) return 'this browser session already holds secrets for another chat or client';
            return null;
        },
        /** Taint before typing, so the value is scrubbed even if the type call half-succeeds. */
        mark(session, { chat, client, name, value, kind, port = null, session: sid = null }) {
            const s = sessions.get(session) || { chat, client, port, session: sid, drop_images: false, since: now(), closed_at: null };
            if (kind !== 'password') s.drop_images = true;
            sessions.set(session, s);
            scrubber.add(session, name, value);
            save();
        },
        get: (session) => sessions.get(session) || null,
        anyTainted: () => sessions.size > 0,
        anyDropImages: () => [...sessions.values()].some((s) => s.drop_images),
        list: () => [...sessions.keys()],
        /** Check every tainted session; forget closed ones after the grace period. */
        async sweep() {
            if (!controllers) return;
            let changed = false;
            for (const [id, s] of sessions) {
                let live = true;
                const c = controllers(s.port ?? null)?.controller;
                if (!c) continue;
                try { live = isLive(await c.getSession(s.session ?? id)); } catch (err) { if (err.status === 404) live = false; else continue; }
                if (live) { if (s.closed_at) { s.closed_at = null; changed = true; } continue; }
                if (!s.closed_at) { s.closed_at = now(); changed = true; continue; }
                if (now() - s.closed_at >= graceMs) {
                    sessions.delete(id);
                    scrubber.drop(id);
                    changed = true;
                }
            }
            if (changed) save();
        },
    };
}
