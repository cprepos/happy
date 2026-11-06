import { describe, expect, it } from 'vitest';
import {
    buildSessionChildEnvironment,
    consumeSessionScopedEnv,
    DAEMON_SCOPED_ENV_KEYS,
    sanitizeSessionEnvironment,
    SESSION_SCOPED_ENV_KEYS,
    sessionEnvironmentKeysToUnset,
    wrapTmuxCommandWithSessionEnvironmentSanitizer,
} from './sessionEnvironment';

function contaminatedEnvironment(): NodeJS.ProcessEnv {
    return {
        KEEP_ME: 'safe',
        ...Object.fromEntries(SESSION_SCOPED_ENV_KEYS.map((key) => [key, `stale-${key}`])),
    };
}

describe('sessionEnvironment', () => {
    it('removes all inherited session-scoped values without mutating the source', () => {
        const source = contaminatedEnvironment();

        const sanitized = sanitizeSessionEnvironment(source);

        expect(sanitized).toMatchObject({ KEEP_ME: 'safe' });
        for (const key of SESSION_SCOPED_ENV_KEYS) {
            expect(sanitized).not.toHaveProperty(key);
            expect(source[key]).toBe(`stale-${key}`);
        }
    });

    it('keeps explicit fork values after removing stale ambient values', () => {
        const childEnv = buildSessionChildEnvironment(contaminatedEnvironment(), {
            HAPPY_FORKED_FROM_SESSION_ID: 'new-parent-session',
            HAPPY_FORKED_FROM_MESSAGE_ID: 'new-parent-message',
            HAPPY_FORK_CODEX_THREAD_ID: 'new-codex-thread',
            HAPPY_SIDE_CHAT: '1',
        });

        expect(childEnv).toMatchObject({
            KEEP_ME: 'safe',
            HAPPY_FORKED_FROM_SESSION_ID: 'new-parent-session',
            HAPPY_FORKED_FROM_MESSAGE_ID: 'new-parent-message',
            HAPPY_FORK_CODEX_THREAD_ID: 'new-codex-thread',
            HAPPY_SIDE_CHAT: '1',
        });
        expect(childEnv).not.toHaveProperty('CODEX_THREAD_ID');
        expect(childEnv).not.toHaveProperty('HAPPY_RECONNECT_SESSION_ID');
    });

    it('replaces stale reconnect state with the values for the resumed session', () => {
        const childEnv = buildSessionChildEnvironment(contaminatedEnvironment(), {
            HAPPY_RECONNECT_SESSION_ID: 'new-session',
            HAPPY_RECONNECT_ENCRYPTION_KEY: 'new-key',
            HAPPY_RECONNECT_ENCRYPTION_VARIANT: 'dataKey',
            HAPPY_RECONNECT_SEQ: '12',
            HAPPY_RECONNECT_METADATA_VERSION: '13',
            HAPPY_RECONNECT_AGENT_STATE_VERSION: '14',
        });

        expect(childEnv).toMatchObject({
            HAPPY_RECONNECT_SESSION_ID: 'new-session',
            HAPPY_RECONNECT_ENCRYPTION_KEY: 'new-key',
            HAPPY_RECONNECT_ENCRYPTION_VARIANT: 'dataKey',
            HAPPY_RECONNECT_SEQ: '12',
            HAPPY_RECONNECT_METADATA_VERSION: '13',
            HAPPY_RECONNECT_AGENT_STATE_VERSION: '14',
        });
        expect(childEnv).not.toHaveProperty('HAPPY_FORK_CODEX_THREAD_ID');
        expect(childEnv).not.toHaveProperty('CODEX_THREAD_ID');
    });

    it('unsets inherited tmux values without removing an explicit fork value', () => {
        const explicitEnv = { HAPPY_FORK_CODEX_THREAD_ID: 'new-codex-thread' };
        const keysToUnset = sessionEnvironmentKeysToUnset(explicitEnv);
        const command = wrapTmuxCommandWithSessionEnvironmentSanitizer('node happy.mjs codex', explicitEnv);

        expect(keysToUnset).not.toContain('HAPPY_FORK_CODEX_THREAD_ID');
        expect(keysToUnset).toContain('CODEX_THREAD_ID');
        expect(command).toMatch(/^unset /);
        expect(command).toContain('CODEX_THREAD_ID');
        expect(command).not.toContain('unset HAPPY_FORK_CODEX_THREAD_ID');
        expect(command).toMatch(/node happy\.mjs codex$/);
    });

    it('consumes the reconnect and fork values and clears them from the environment', () => {
        const env: NodeJS.ProcessEnv = {
            KEEP_ME: 'safe',
            HAPPY_RECONNECT_SESSION_ID: 'session-1',
            HAPPY_RECONNECT_ENCRYPTION_KEY: 'a2V5',
            HAPPY_RECONNECT_ENCRYPTION_VARIANT: 'dataKey',
            HAPPY_RECONNECT_SEQ: '7',
            HAPPY_RECONNECT_METADATA_VERSION: '3',
            HAPPY_RECONNECT_AGENT_STATE_VERSION: '4',
            HAPPY_FORKED_FROM_SESSION_ID: 'parent',
            HAPPY_FORKED_FROM_MESSAGE_ID: 'message',
            HAPPY_FORK_CLAUDE_SESSION_ID: 'agent-session',
            HAPPY_FORK_CODEX_THREAD_ID: 'thread',
            HAPPY_SIDE_CHAT: '1',
            CODEX_THREAD_ID: 'inherited-thread',
        };

        const snapshot = consumeSessionScopedEnv(env);

        expect(snapshot).toEqual({
            reconnect: {
                sessionId: 'session-1',
                keyBase64: 'a2V5',
                variant: 'dataKey',
                seq: 7,
                metadataVersion: 3,
                agentStateVersion: 4,
            },
            forkedFromSessionId: 'parent',
            forkedFromMessageId: 'message',
            forkClaudeSessionId: 'agent-session',
            forkCodexThreadId: 'thread',
            sideChat: true,
        });
        expect(env).toEqual({ KEEP_ME: 'safe' });
        for (const key of SESSION_SCOPED_ENV_KEYS) {
            expect(env).not.toHaveProperty(key);
        }
    });

    it('returns no reconnect target when the reconnect values are incomplete', () => {
        const env: NodeJS.ProcessEnv = {
            HAPPY_RECONNECT_SESSION_ID: 'session-1',
            HAPPY_RECONNECT_ENCRYPTION_VARIANT: 'bogus',
            HAPPY_RECONNECT_ENCRYPTION_KEY: 'a2V5',
        };

        const snapshot = consumeSessionScopedEnv(env);

        expect(snapshot.reconnect).toBeNull();
        expect(snapshot.sideChat).toBe(false);
        expect(env).toEqual({});
    });

    it('strips daemon-scoped values from session children', () => {
        const childEnv = buildSessionChildEnvironment({
            KEEP_ME: 'safe',
            HAPPY_DAEMON_SUPERVISOR: 'launchd:com.happy.cli-daemon',
        });

        expect(DAEMON_SCOPED_ENV_KEYS).toContain('HAPPY_DAEMON_SUPERVISOR');
        expect(childEnv).toEqual({ KEEP_ME: 'safe' });
    });

    it("drops launchd's daemon job name but keeps any other", () => {
        expect(buildSessionChildEnvironment({ XPC_SERVICE_NAME: 'com.happy.cli-daemon', KEEP_ME: 'safe' })).toEqual({ KEEP_ME: 'safe' });
        expect(buildSessionChildEnvironment({ XPC_SERVICE_NAME: 'application.com.apple.Terminal' })).toEqual({ XPC_SERVICE_NAME: 'application.com.apple.Terminal' });
    });
});
