import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
    mockReadPersistedSessions: vi.fn(),
    mockReadCredentials: vi.fn(),
    mockAxiosGet: vi.fn(),
}));

vi.mock('axios', async (importOriginal) => {
    const actual = await importOriginal<typeof import('axios')>();
    return {
        ...actual,
        default: { ...actual.default, get: mocks.mockAxiosGet },
    };
});

vi.mock('@/persistence', () => ({
    readPersistedSessions: mocks.mockReadPersistedSessions,
    readCredentials: mocks.mockReadCredentials,
}));

vi.mock('@/configuration', () => ({
    configuration: {
        sessionsFile: '/tmp/.happy/sessions.json',
        serverUrl: 'https://api.example.test',
        currentCliVersion: '1.1.10',
    },
}));

import { encodeBase64, encrypt } from '@/api/encryption';
import { LocalResumeSessionError, resolveLocalReconnectableSession } from './localResumeStore';

const AGY_KEY = new Uint8Array(32).fill(7);

function persistedAgySession(metadata: Record<string, unknown>) {
    return {
        'agy-session': {
            encryptionKey: encodeBase64(AGY_KEY),
            encryptionVariant: 'dataKey',
            seq: 5,
            metadataVersion: 2,
            agentStateVersion: 1,
            metadata: {
                path: '/tmp/repo',
                flavor: 'agy',
                host: 'localhost',
                homeDir: '/tmp',
                happyHomeDir: '/tmp/.happy',
                happyLibDir: '/tmp/happy',
                happyToolsDir: '/tmp/happy/tools',
                ...metadata,
            },
            savedAt: Date.now(),
        },
    };
}

describe('resolveLocalReconnectableSession', () => {
    beforeEach(() => {
        vi.clearAllMocks();
        mocks.mockReadCredentials.mockResolvedValue(null);
    });

    it('resolves a locally persisted dataKey session without agent.key credentials', async () => {
        mocks.mockReadPersistedSessions.mockReturnValue({
            'session-1': {
                encryptionKey: 'AQIDBA==',
                encryptionVariant: 'dataKey',
                seq: 12,
                metadataVersion: 3,
                agentStateVersion: 4,
                metadata: {
                    path: '/tmp/repo',
                    flavor: 'codex',
                    codexThreadId: 'thread-1',
                    host: 'localhost',
                    homeDir: '/tmp',
                    happyHomeDir: '/tmp/.happy',
                    happyLibDir: '/tmp/happy',
                    happyToolsDir: '/tmp/happy/tools',
                },
                savedAt: Date.now(),
            },
        });

        await expect(resolveLocalReconnectableSession('session-1')).resolves.toMatchObject({
            id: 'session-1',
            seq: 12,
            metadataVersion: 3,
            agentStateVersion: 4,
            encryptionVariant: 'dataKey',
            metadata: {
                codexThreadId: 'thread-1',
            },
        });
    });

    it('reports missing local encryption data without suggesting happy-agent auth login', async () => {
        mocks.mockReadPersistedSessions.mockReturnValue({});

        let thrown: unknown;
        try {
            await resolveLocalReconnectableSession('missing');
        } catch (error) {
            thrown = error;
        }

        expect(thrown).toBeInstanceOf(LocalResumeSessionError);
        expect((thrown as Error).message).toContain('/tmp/.happy/sessions.json');
        expect((thrown as Error).message).not.toContain('happy-agent auth login');
    });

    it('resumes an Antigravity session from its persisted conversation ID without asking the server', async () => {
        mocks.mockReadPersistedSessions.mockReturnValue(persistedAgySession({ agyConversationId: 'conv-1' }));

        await expect(resolveLocalReconnectableSession('agy-session')).resolves.toMatchObject({
            id: 'agy-session',
            metadata: { flavor: 'agy', agyConversationId: 'conv-1' },
        });
        expect(mocks.mockReadCredentials).not.toHaveBeenCalled();
        expect(mocks.mockAxiosGet).not.toHaveBeenCalled();
    });

    it('fetches the conversation ID from the server when the persisted Antigravity metadata predates the first turn', async () => {
        // The session file is written at startup; the conversation is pinned after the first turn.
        mocks.mockReadPersistedSessions.mockReturnValue(persistedAgySession({}));
        mocks.mockReadCredentials.mockResolvedValue({ token: 'token' });
        const serverMetadata = {
            ...persistedAgySession({})['agy-session'].metadata,
            agyConversationId: 'conv-from-server',
        };
        mocks.mockAxiosGet.mockResolvedValue({
            data: {
                sessions: [{
                    id: 'agy-session',
                    metadata: encodeBase64(encrypt(AGY_KEY, 'dataKey', serverMetadata)),
                }],
            },
        });

        await expect(resolveLocalReconnectableSession('agy-session')).resolves.toMatchObject({
            metadata: { flavor: 'agy', agyConversationId: 'conv-from-server' },
        });
        expect(mocks.mockAxiosGet).toHaveBeenCalledTimes(1);
    });

    it('does not take a Claude session ID as fresh enough for an Antigravity session', async () => {
        mocks.mockReadPersistedSessions.mockReturnValue(persistedAgySession({ claudeSessionId: 'stray-claude-id' }));
        mocks.mockReadCredentials.mockResolvedValue(null);

        await expect(resolveLocalReconnectableSession('agy-session')).resolves.toMatchObject({
            metadata: { flavor: 'agy' },
        });
        // Without credentials the fetch is skipped, but it was attempted.
        expect(mocks.mockReadCredentials).toHaveBeenCalledTimes(1);
    });
});
