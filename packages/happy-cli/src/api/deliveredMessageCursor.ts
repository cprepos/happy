/**
 * How far into a Happy session's message log the agent has been fed.
 *
 * Every process that owns a Happy session records here the seq of the last
 * user message it handed to its agent. A later process that reconnects to the
 * same session (daemon resume, `--restart`, `happy opencode --resume`) reads
 * it back to tell messages the agent already has in its history (at or below
 * the cursor: skip, or they would be prompted twice) from messages sent while
 * nothing was listening (above it: deliver, or they are silently lost).
 *
 * One small file per session, `<happyHome>/session-cursors/<sessionId>.json`,
 * written atomically. Per-session files keep concurrent owners of different
 * sessions from racing on one shared file; the daemon's `sessions.json` is
 * left alone for the same reason.
 */

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { configuration } from '@/configuration';
import { logger } from '@/ui/logger';

const SESSION_ID_PATTERN = /^[A-Za-z0-9_-]+$/;

type CursorFile = { deliveredSeq: number; updatedAt: number };

function cursorPath(sessionId: string): string | null {
    if (!configuration.happyHomeDir || !SESSION_ID_PATTERN.test(sessionId)) {
        return null;
    }
    return join(configuration.happyHomeDir, 'session-cursors', `${sessionId}.json`);
}

/** The seq of the last user message an owner handed to its agent, or null when none was ever recorded. */
export function readDeliveredSeq(sessionId: string): number | null {
    const path = cursorPath(sessionId);
    if (!path) {
        return null;
    }
    try {
        const data = JSON.parse(readFileSync(path, 'utf-8')) as Partial<CursorFile>;
        return Number.isSafeInteger(data.deliveredSeq) && data.deliveredSeq! >= 0 ? data.deliveredSeq! : null;
    } catch {
        return null;
    }
}

export function writeDeliveredSeq(sessionId: string, deliveredSeq: number): void {
    const path = cursorPath(sessionId);
    if (!path) {
        return;
    }
    try {
        mkdirSync(join(configuration.happyHomeDir, 'session-cursors'), { recursive: true, mode: 0o700 });
        const tmp = `${path}.${process.pid}.tmp`;
        const body: CursorFile = { deliveredSeq, updatedAt: Date.now() };
        writeFileSync(tmp, JSON.stringify(body), { encoding: 'utf-8', mode: 0o600 });
        renameSync(tmp, path);
    } catch (error) {
        logger.debug(`[API] Failed to record delivered message seq for ${sessionId}:`, error);
    }
}
