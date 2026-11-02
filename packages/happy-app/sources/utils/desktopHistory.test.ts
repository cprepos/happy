import { describe, expect, it } from 'vitest';
import { desktopHistoryButtonState, desktopHistoryRemaining } from './desktopHistory';

const desktop = (before?: number) => ({
    harness: 'claude-desktop',
    ...(before !== undefined ? { desktopHistory: { before } } : {}),
});

describe('desktopHistoryRemaining', () => {
    it('reads before', () => {
        expect(desktopHistoryRemaining(desktop(42))).toBe(42);
    });

    it('is 0 when absent, zero, negative or not a number', () => {
        expect(desktopHistoryRemaining(desktop())).toBe(0);
        expect(desktopHistoryRemaining(desktop(0))).toBe(0);
        expect(desktopHistoryRemaining(desktop(-3))).toBe(0);
        expect(desktopHistoryRemaining(desktop(Number.NaN))).toBe(0);
        expect(desktopHistoryRemaining({ desktopHistory: null })).toBe(0);
        expect(desktopHistoryRemaining(null)).toBe(0);
        expect(desktopHistoryRemaining(undefined)).toBe(0);
    });
});

describe('desktopHistoryButtonState', () => {
    it('is ready for a desktop session with history left at the oldest page', () => {
        expect(desktopHistoryButtonState({ metadata: desktop(10), reachedOldest: true, request: 'idle' })).toBe('ready');
    });

    it('shows the request state while history is left', () => {
        expect(desktopHistoryButtonState({ metadata: desktop(10), reachedOldest: true, request: 'loading' })).toBe('loading');
        expect(desktopHistoryButtonState({ metadata: desktop(10), reachedOldest: true, request: 'failed' })).toBe('failed');
    });

    it('is hidden for a session that is not Claude Desktop', () => {
        const metadata = { harness: 'codex', desktopHistory: { before: 10 } };
        expect(desktopHistoryButtonState({ metadata, reachedOldest: true, request: 'idle' })).toBe('hidden');
        expect(desktopHistoryButtonState({ metadata: { desktopHistory: { before: 10 } }, reachedOldest: true, request: 'idle' })).toBe('hidden');
        expect(desktopHistoryButtonState({ metadata: null, reachedOldest: true, request: 'idle' })).toBe('hidden');
    });

    it('is hidden when nothing is left to load, even mid-request', () => {
        expect(desktopHistoryButtonState({ metadata: desktop(), reachedOldest: true, request: 'idle' })).toBe('hidden');
        expect(desktopHistoryButtonState({ metadata: desktop(0), reachedOldest: true, request: 'loading' })).toBe('hidden');
        expect(desktopHistoryButtonState({ metadata: desktop(0), reachedOldest: true, request: 'failed' })).toBe('hidden');
    });

    it('is hidden until the reader reaches the oldest server page', () => {
        expect(desktopHistoryButtonState({ metadata: desktop(10), reachedOldest: false, request: 'idle' })).toBe('hidden');
        expect(desktopHistoryButtonState({ metadata: desktop(10), reachedOldest: false, request: 'loading' })).toBe('hidden');
    });
});

describe('MetadataSchema desktopHistory', async () => {
    const { MetadataSchema } = await import('@/sync/storageTypes');
    const base = { path: '/tmp', host: 'mac', harness: 'claude-desktop' };

    it('keeps a valid before', () => {
        expect(MetadataSchema.parse({ ...base, desktopHistory: { before: 12 } }).desktopHistory).toEqual({ before: 12 });
    });

    it('drops a malformed value without failing the parse', () => {
        for (const desktopHistory of [{ before: 'x' }, { before: -1 }, 'nope', null]) {
            const parsed = MetadataSchema.safeParse({ ...base, desktopHistory });
            expect(parsed.success).toBe(true);
            expect(parsed.success && parsed.data.desktopHistory).toBeUndefined();
        }
    });
});
