import { describe, expect, it } from 'vitest';

import { happySessionEnv } from './happySessionEnv';

describe('happySessionEnv', () => {
    it('names the Happy session for the MCP servers a harness starts', () => {
        expect(happySessionEnv('session-123')).toEqual({ HAPPY_SESSION_ID: 'session-123' });
    });

    it('adds nothing while there is no session', () => {
        expect(happySessionEnv(undefined)).toEqual({});
        expect(happySessionEnv(null)).toEqual({});
        expect(happySessionEnv('')).toEqual({});
    });
});
