/**
 * On-demand history for Claude Desktop mirrors.
 *
 * `happy attach` no longer uploads a desktop chat's earlier transcript when the
 * mirror starts. The phone asks for it in chunks (`desktop-load-history` RPC),
 * and this module turns a chunk of transcript entries into session-protocol
 * envelopes stamped with their original transcript times, so they sort above
 * the live messages even though the server receives them later.
 *
 * Indexing: `metadata.desktopHistory.before` counts the entries `[0, before)`
 * of the transcript, in `readSessionEntries` order, that have not been loaded.
 *
 * Contract: docs/plans/happyify-desktop-sync.md, "Contract: on-demand history".
 */

import { access, constants } from 'node:fs/promises';
import { join } from 'node:path';
import type { SessionEnvelope } from '@slopus/happy-wire';

import type { RawJSONLines } from '@/claude/types';
import { createDesktopEchoMatcher } from './desktopEcho';
import { closeClaudeTurnWithStatus, mapClaudeLogMessageToSessionEnvelopes, type ClaudeSessionProtocolState } from './sessionProtocolMapper';
import { readSessionEntries, type SessionLogEntry } from './sessionScanner';

export const DEFAULT_HISTORY_LIMIT = 100;
export const MAX_HISTORY_LIMIT = 500;

export type DesktopLoadHistoryParams = { limit?: number };
export type DesktopLoadHistoryResult = { loaded: number; before: number };

/**
 * The entries `[start, end)` the next load takes, given how many are still
 * unloaded. `limit` defaults to 100 and is clamped to `[1, 500]`.
 */
export function planHistoryChunk(before: number, limit?: number): { start: number; end: number } {
    const requested = typeof limit === 'number' && Number.isFinite(limit) ? Math.floor(limit) : DEFAULT_HISTORY_LIMIT;
    const size = Math.min(MAX_HISTORY_LIMIT, Math.max(1, requested));
    const end = Math.max(0, Math.floor(before));
    return { start: Math.max(0, end - size), end };
}

/**
 * Flatten the envelopes of each transcript entry, stamping `time` from the
 * entry's transcript timestamp (epoch ms). Times strictly increase: an
 * envelope that would tie with or precede the previous one gets the previous
 * time + 1 ms. An entry without a timestamp takes the last known one (leading
 * entries take the first known one). Throws when envelopes exist but no entry
 * in the chunk has a timestamp, since nothing could place them in the chat.
 */
export function stampEnvelopeTimes(
    envelopesPerEntry: SessionEnvelope[][],
    timestamps: Array<number | undefined>,
): SessionEnvelope[] {
    if (envelopesPerEntry.length !== timestamps.length) {
        throw new Error(`stampEnvelopeTimes: ${envelopesPerEntry.length} entries but ${timestamps.length} timestamps`);
    }
    const firstKnown = timestamps.find((time): time is number => time !== undefined);
    const stamped: SessionEnvelope[] = [];
    if (firstKnown === undefined) {
        if (envelopesPerEntry.some((group) => group.length > 0)) {
            throw new Error('No transcript timestamps in this history chunk');
        }
        return stamped;
    }
    let base = firstKnown;
    let previous = -Infinity;
    envelopesPerEntry.forEach((group, index) => {
        base = timestamps[index] ?? base;
        for (const envelope of group) {
            const time = Math.max(base, previous + 1);
            previous = time;
            stamped.push({ ...envelope, time });
        }
    });
    return stamped;
}

/** A transcript line's ISO `timestamp` as epoch ms, or undefined when absent or unparseable. */
export function transcriptTimestamp(message: RawJSONLines): number | undefined {
    const raw: unknown = (message as { timestamp?: unknown }).timestamp;
    if (typeof raw !== 'string') return undefined;
    const time = Date.parse(raw);
    return Number.isNaN(time) ? undefined : time;
}

/**
 * Map a chunk of transcript entries to stamped envelopes, as the live mirror
 * would have sent them: summaries and side-channel transcript events are left
 * out, phone deliveries (`[Happy] …` rewake lines) become the plain user text
 * the phone sent, and images are not uploaded. The mapper state is fresh and
 * any turn still open at the end of the chunk is closed.
 */
export function mapHistoryEntries(entries: SessionLogEntry[]): SessionEnvelope[] {
    const state: ClaudeSessionProtocolState = {
        currentTurnId: null,
        uuidToProviderSubagent: new Map(),
        taskPromptToSubagents: new Map(),
        providerSubagentToSessionSubagent: new Map(),
        subagentTitles: new Map(),
        bufferedSubagentMessages: new Map(),
        hiddenParentToolCalls: new Set(),
        startedSubagents: new Set(),
        activeSubagents: new Set(),
    };
    // Nothing is pending in a fresh matcher, so every delivery is 'foreign'
    // and comes back as the plain user text.
    const echoes = createDesktopEchoMatcher();
    const groups: SessionEnvelope[][] = [];
    const timestamps: Array<number | undefined> = [];
    for (const entry of entries) {
        if (entry.kind !== 'message' || entry.message.type === 'summary') continue;
        const decision = echoes.classify(entry.message);
        const message = decision.kind === 'foreign' ? decision.message : entry.message;
        const mapped = mapClaudeLogMessageToSessionEnvelopes(message, state);
        state.currentTurnId = mapped.currentTurnId;
        groups.push(mapped.envelopes);
        timestamps.push(transcriptTimestamp(entry.message));
    }
    const closing = closeClaudeTurnWithStatus(state, 'completed');
    if (closing.envelopes.length > 0) {
        // Placed right after the chunk's last entry.
        groups.push(closing.envelopes);
        timestamps.push(undefined);
    }
    return stampEnvelopeTimes(groups, timestamps);
}

/**
 * Read a desktop transcript for a history load. Unlike the scanner, a
 * transcript that cannot be read is an error, not an empty file.
 */
export async function readDesktopTranscript(projectDir: string, claudeSessionId: string): Promise<SessionLogEntry[]> {
    await access(join(projectDir, `${claudeSessionId}.jsonl`), constants.R_OK);
    return readSessionEntries(projectDir, claudeSessionId);
}

/**
 * `before` for the new transcript after a re-point (resume / fork).
 *
 * The new file repeats the old history, and the scanner marks everything in it
 * as already sent. The entries still unloaded are those whose keys were in the
 * old file's `[0, oldBefore)`; the rule takes the new file's leading run of
 * such entries, i.e. `before` = index of the first new-file entry that was not
 * unloaded history (already on the phone, or new). If the new file shares no
 * leading entries with the unloaded history (a /clear, or a fork that rewrote
 * the uuids) there is nothing loadable in it and `before` is 0.
 */
export function historyBeforeAfterRepoint(
    oldEntries: SessionLogEntry[],
    oldBefore: number,
    newEntries: SessionLogEntry[],
): number {
    const unloaded = new Set(oldEntries.slice(0, oldBefore).map((entry) => entry.key));
    const firstMirrored = newEntries.findIndex((entry) => !unloaded.has(entry.key));
    return firstMirrored < 0 ? newEntries.length : firstMirrored;
}
