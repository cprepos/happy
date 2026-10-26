import { randomBytes } from 'node:crypto';
import { mkdtempSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { encodeBase64, encrypt } from '@/api/encryption';
import type { Metadata } from '@/api/types';
import type { PersistedSession } from '@/persistence';
import { findReconnectableHappySession, linkedHappySessionId, rememberHappySession, type ServerSessionRow } from './opencodeHappySession';
import { writeTuiState } from './opencodeProcesses';

const key = new Uint8Array(randomBytes(32));

function record(metadata: Partial<Metadata>, aliveAt: number): PersistedSession {
    return {
        encryptionKey: encodeBase64(key),
        encryptionVariant: 'dataKey',
        seq: 1,
        metadataVersion: 1,
        agentStateVersion: 1,
        metadata: { path: '/work', host: 'h', flavor: 'opencode', ...metadata } as Metadata,
        savedAt: aliveAt,
        lastAliveAt: aliveAt,
    };
}

function row(id: string, metadata: Partial<Metadata>): ServerSessionRow {
    return {
        id,
        seq: 42,
        metadata: encodeBase64(encrypt(key, 'dataKey', { path: '/work', flavor: 'opencode', ...metadata })),
        metadataVersion: 7,
        agentState: encodeBase64(encrypt(key, 'dataKey', { controlledByUser: false })),
        agentStateVersion: 5,
    };
}

describe('happy session links', () => {
    it('remembers the latest Happy session per OpenCode session in a private file', () => {
        const dir = mkdtempSync(join(tmpdir(), 'oc-links-'));
        expect(linkedHappySessionId(dir, 'ses_a')).toBeNull();
        rememberHappySession(dir, 'ses_a', 'happy-1');
        rememberHappySession(dir, 'ses_b', 'happy-2');
        rememberHappySession(dir, 'ses_a', 'happy-3');
        expect(linkedHappySessionId(dir, 'ses_a')).toBe('happy-3');
        expect(linkedHappySessionId(dir, 'ses_b')).toBe('happy-2');
        expect(statSync(join(dir, 'happy-sessions.json')).mode & 0o777).toBe(0o600);
    });

    it('falls back to the state file of a session started before links existed', () => {
        const dir = mkdtempSync(join(tmpdir(), 'oc-links-'));
        writeTuiState(dir, {
            ownerPid: 1, serverPid: 2, url: 'http://127.0.0.1:1', password: 'x', cwd: '/work',
            opencodeSessionId: 'ses_old', happySessionId: 'happy-old', startedAt: 0, ownerTuiAttached: false,
        });
        expect(linkedHappySessionId(dir, 'ses_old')).toBe('happy-old');
    });
});

describe('findReconnectableHappySession', () => {
    it('reattaches the linked session with the server copy of its state', () => {
        const found = findReconnectableHappySession({
            opencodeSessionId: 'ses_a',
            linkedId: 'happy-1',
            persisted: { 'happy-1': record({}, 1), 'happy-2': record({ opencodeSessionId: 'ses_a' }, 2) },
            serverSessions: [row('happy-1', { opencodeSessionId: 'ses_a' })],
        });
        expect(found?.id).toBe('happy-1');
        expect(found?.seq).toBe(42);
        expect(found?.metadataVersion).toBe(7);
        expect(found?.agentStateVersion).toBe(5);
        expect(found?.metadata.opencodeSessionId).toBe('ses_a');
        expect(found?.agentState).toEqual({ controlledByUser: false });
    });

    it('finds an unlinked session by the OpenCode id in the server metadata', () => {
        const found = findReconnectableHappySession({
            opencodeSessionId: 'ses_a',
            linkedId: null,
            persisted: {
                'happy-other': record({}, 5),
                'happy-1': record({}, 1),
                'happy-claude': record({ flavor: 'claude' }, 9),
            },
            serverSessions: [row('happy-other', { opencodeSessionId: 'ses_b' }), row('happy-1', { opencodeSessionId: 'ses_a' })],
        });
        expect(found?.id).toBe('happy-1');
    });

    it('uses the saved copy when the server cannot be asked', () => {
        const found = findReconnectableHappySession({
            opencodeSessionId: 'ses_a',
            linkedId: null,
            persisted: { 'happy-1': record({ opencodeSessionId: 'ses_a' }, 1) },
            serverSessions: null,
        });
        expect(found?.id).toBe('happy-1');
        expect(found?.seq).toBe(1);
    });

    it('never guesses: no exact match means a new session', () => {
        expect(findReconnectableHappySession({
            opencodeSessionId: 'ses_a',
            linkedId: null,
            persisted: { 'happy-1': record({}, 1) },
            serverSessions: null,
        })).toBeNull();
        expect(findReconnectableHappySession({
            opencodeSessionId: 'ses_a',
            linkedId: 'happy-missing',
            persisted: { 'happy-1': record({ opencodeSessionId: 'ses_b' }, 1) },
            serverSessions: [row('happy-1', { opencodeSessionId: 'ses_b' })],
        })).toBeNull();
    });
});
