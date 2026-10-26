/**
 * Which Happy session (chat in the app) belongs to an OpenCode session.
 *
 * `happy opencode --resume <id>` continues the OpenCode session, and should
 * continue the same Happy chat too instead of opening a new one. The server
 * only hands an existing session back by its creation tag, and that does not
 * work here: on accounts with per-session data keys the CLI generates a new
 * key per call and could not read the existing session with it. Instead the
 * session is reattached by id with the key the daemon saved for it in
 * `~/.happy/sessions.json`, the same way `happy resume` and the daemon's
 * resume reconnect in place.
 *
 * The Happy session id is found, in order, from:
 * 1. the link file written by every owner (`happy-sessions.json`),
 * 2. the session's state file (still present while an owner runs),
 * 3. the saved sessions themselves: an OpenCode session id in the saved
 *    metadata, or else in the server's copy of the metadata (sessions started
 *    before the link file existed only have it there).
 */

import axios from 'axios';
import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { decodeBase64, decrypt } from '@/api/encryption';
import type { Session } from '@/api/types';
import { configuration } from '@/configuration';
import type { PersistedSession } from '@/persistence';
import { logger } from '@/ui/logger';
import { readTuiState } from './opencodeProcesses';

type LinkFile = Record<string, { happySessionId: string; updatedAt: number }>;

function linkFile(dir: string): string {
    return join(dir, 'happy-sessions.json');
}

function readLinks(dir: string): LinkFile {
    try {
        const parsed = JSON.parse(readFileSync(linkFile(dir), 'utf8'));
        return parsed && typeof parsed === 'object' ? parsed as LinkFile : {};
    } catch {
        return {};
    }
}

/** Record that `opencodeSessionId` is mirrored to `happySessionId`. */
export function rememberHappySession(dir: string, opencodeSessionId: string, happySessionId: string): void {
    try {
        const links = readLinks(dir);
        if (links[opencodeSessionId]?.happySessionId === happySessionId) {
            return;
        }
        links[opencodeSessionId] = { happySessionId, updatedAt: Date.now() };
        mkdirSync(dir, { recursive: true, mode: 0o700 });
        const file = linkFile(dir);
        const tmp = `${file}.${process.pid}.tmp`;
        writeFileSync(tmp, JSON.stringify(links, null, 2), { mode: 0o600 });
        chmodSync(tmp, 0o600);
        renameSync(tmp, file);
    } catch (error) {
        logger.debug('[OpenCode] Could not record the Happy session link:', error);
    }
}

/** The Happy session last linked to an OpenCode session, if any is known locally. */
export function linkedHappySessionId(dir: string, opencodeSessionId: string): string | null {
    const linked = readLinks(dir)[opencodeSessionId]?.happySessionId;
    if (typeof linked === 'string' && linked) {
        return linked;
    }
    const state = readTuiState(dir, opencodeSessionId);
    return state && typeof state.happySessionId === 'string' && state.happySessionId ? state.happySessionId : null;
}

/** A session row from `GET /v1/sessions` (encrypted fields still base64). */
export type ServerSessionRow = {
    id: string;
    seq: number;
    metadata: string;
    metadataVersion: number;
    agentState: string | null;
    agentStateVersion: number;
};

function decryptField(key: Uint8Array, variant: 'legacy' | 'dataKey', value: string | null): any | null {
    if (!value) {
        return null;
    }
    try {
        return decrypt(key, variant, decodeBase64(value));
    } catch {
        return null;
    }
}

/**
 * Pick the Happy session to reattach for `opencodeSessionId`, with what is
 * needed to reconnect to it. Server rows (fresher versions and metadata) win
 * over the saved copy. Returns null if no session can be matched exactly.
 */
export function findReconnectableHappySession(opts: {
    opencodeSessionId: string;
    linkedId: string | null;
    persisted: Record<string, PersistedSession>;
    /** null when the server could not be asked. */
    serverSessions: ServerSessionRow[] | null;
}): Session | null {
    const { opencodeSessionId, linkedId, persisted, serverSessions } = opts;
    const entries = Object.entries(persisted)
        .filter(([id, record]) => id === linkedId || record.metadata?.flavor === 'opencode')
        .sort(([idA, a], [idB, b]) => {
            if (idA === linkedId) return -1;
            if (idB === linkedId) return 1;
            return (b.lastAliveAt ?? b.savedAt) - (a.lastAliveAt ?? a.savedAt);
        });

    for (const [id, record] of entries) {
        let key: Uint8Array;
        try {
            key = decodeBase64(record.encryptionKey);
        } catch {
            continue;
        }
        const variant = record.encryptionVariant;
        const row = serverSessions?.find((candidate) => candidate.id === id);
        const serverMetadata = row ? decryptField(key, variant, row.metadata) : null;
        const knownOpencodeId = serverMetadata?.opencodeSessionId ?? record.metadata?.opencodeSessionId;
        const matches = id === linkedId || knownOpencodeId === opencodeSessionId;
        if (!matches) {
            continue;
        }
        if (row && serverMetadata) {
            return {
                id,
                seq: row.seq,
                encryptionKey: key,
                encryptionVariant: variant,
                metadata: serverMetadata,
                metadataVersion: row.metadataVersion,
                agentState: decryptField(key, variant, row.agentState),
                agentStateVersion: row.agentStateVersion,
            };
        }
        return {
            id,
            seq: record.seq,
            encryptionKey: key,
            encryptionVariant: variant,
            metadata: record.metadata,
            metadataVersion: record.metadataVersion,
            agentState: null,
            agentStateVersion: record.agentStateVersion,
        };
    }
    return null;
}

/** The account's recent sessions, or null if the server cannot be reached. */
export async function fetchServerSessions(token: string): Promise<ServerSessionRow[] | null> {
    try {
        const response = await axios.get(`${configuration.serverUrl}/v1/sessions`, {
            headers: {
                Authorization: `Bearer ${token}`,
                'X-Happy-Client': `cli-coding-session/${configuration.currentCliVersion}`,
            },
            timeout: 15_000,
        });
        const sessions = (response.data as { sessions?: ServerSessionRow[] }).sessions;
        return Array.isArray(sessions) ? sessions : null;
    } catch (error) {
        logger.debug('[OpenCode] Could not list sessions on the server:', error);
        return null;
    }
}
