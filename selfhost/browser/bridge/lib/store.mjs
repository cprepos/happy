// Live links: an unguessable id (128 random bits, 32 lowercase hex chars)
// mapped to an auto-browser session. A link expires after `idleMs` without
// being looked at; an expired id answers 410 for `tombstoneMs`, then 404.
import { randomBytes } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

export const ID_PATTERN = /^[0-9a-f]{32}$/;

export function newLinkId() {
    return randomBytes(16).toString('hex');
}

export class LinkStore {
    constructor({ path = null, idleMs = 12 * 3600_000, tombstoneMs = 7 * 24 * 3600_000, now = Date.now } = {}) {
        this.path = path;
        this.idleMs = idleMs;
        this.tombstoneMs = tombstoneMs;
        this.now = now;
        this.links = new Map(); // id -> record
        this.expired = new Map(); // id -> expiredAt
        this.saveTimer = null;
        this.load();
    }

    load() {
        if (!this.path) return;
        let data;
        try {
            data = JSON.parse(readFileSync(this.path, 'utf8'));
        } catch {
            return;
        }
        for (const rec of data.links || []) if (ID_PATTERN.test(rec.id)) this.links.set(rec.id, rec);
        for (const [id, at] of data.expired || []) if (ID_PATTERN.test(id)) this.expired.set(id, at);
        this.sweep();
    }

    save() {
        if (!this.path || this.saveTimer) return;
        this.saveTimer = setTimeout(() => {
            this.saveTimer = null;
            this.flush();
        }, 200);
        this.saveTimer.unref?.();
    }

    flush() {
        if (!this.path) return;
        mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
        const tmp = `${this.path}.tmp`;
        // Only persistable fields: no share tokens, no frames.
        const links = [...this.links.values()].map(({ id, sessionId, createdAt, lastSeenAt, status, reason, url, title, lastAction }) =>
            ({ id, sessionId, createdAt, lastSeenAt, status, reason, url, title, lastAction: lastAction ?? null }));
        writeFileSync(tmp, JSON.stringify({ links, expired: [...this.expired] }), { mode: 0o600 });
        renameSync(tmp, this.path);
    }

    sweep() {
        const t = this.now();
        let changed = false;
        for (const [id, rec] of this.links) {
            if (t - rec.lastSeenAt > this.idleMs) {
                this.links.delete(id);
                this.expired.set(id, t);
                changed = true;
            }
        }
        for (const [id, at] of this.expired) {
            if (t - at > this.tombstoneMs) {
                this.expired.delete(id);
                changed = true;
            }
        }
        if (changed) this.save();
    }

    /** The live link for a session, reusing an existing one. */
    forSession(sessionId) {
        this.sweep();
        for (const rec of this.links.values()) {
            if (rec.sessionId === sessionId) {
                this.touch(rec);
                return rec;
            }
        }
        const t = this.now();
        const rec = { id: newLinkId(), sessionId, createdAt: t, lastSeenAt: t, status: 'watching', reason: null, url: null, title: null };
        this.links.set(rec.id, rec);
        this.save();
        return rec;
    }

    /** The live link for a session, or null; never creates one. */
    findSession(sessionId) {
        this.sweep();
        for (const rec of this.links.values()) if (rec.sessionId === sessionId) return rec;
        return null;
    }

    all() {
        this.sweep();
        return [...this.links.values()];
    }

    /** {rec} for a live id, {expired: true} for an expired one, null for unknown. */
    lookup(id) {
        if (!ID_PATTERN.test(id)) return null;
        this.sweep();
        const rec = this.links.get(id);
        if (rec) return { rec };
        if (this.expired.has(id)) return { expired: true };
        return null;
    }

    touch(rec) {
        rec.lastSeenAt = this.now();
        // Polled every 1.5 s: persist the idle clock at most once a minute.
        if (!(rec.lastSeenAt - (this.savedSeen?.get(rec.id) ?? 0) < 60_000)) {
            (this.savedSeen ??= new Map()).set(rec.id, rec.lastSeenAt);
            this.save();
        }
    }

    update(rec, fields) {
        Object.assign(rec, fields);
        this.save();
    }
}
