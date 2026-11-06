import { describe, expect, it } from 'vitest';
import { isVersionRequest } from './versionRequest';

describe('isVersionRequest', () => {
    it('matches the default command asking for its version', () => {
        expect(isVersionRequest(['--version'])).toBe(true);
        expect(isVersionRequest(['-v'])).toBe(true);
        expect(isVersionRequest(['claude', '--version'])).toBe(true);
        expect(isVersionRequest(['--yolo', '-v'])).toBe(true);
    });

    it('does not match other invocations', () => {
        expect(isVersionRequest([])).toBe(false);
        expect(isVersionRequest(['--yolo'])).toBe(false);
        expect(isVersionRequest(['daemon', '--version'])).toBe(false);
        expect(isVersionRequest(['codex', '--version'])).toBe(false);
        expect(isVersionRequest(['--', '--version'])).toBe(false);
    });
});
