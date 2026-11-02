import { describe, expect, it } from 'vitest';
import { resolveAvatarHarness } from './avatarHarness';

describe('resolveAvatarHarness', () => {
    it('keeps the existing Claude, Codex, and Antigravity mappings', () => {
        expect(resolveAvatarHarness('claude')).toBe('claude');
        expect(resolveAvatarHarness('codex')).toBe('codex');
        expect(resolveAvatarHarness('agy')).toBe('agy');
        expect(resolveAvatarHarness('openclaw')).toBe('openclaw');
    });

    it('uses Happy for the Rig client regardless of provider flavor', () => {
        expect(resolveAvatarHarness('codex', 'rig')).toBe('rig');
        expect(resolveAvatarHarness(null, 'rig')).toBe('rig');
    });

    it('badges a Claude Desktop session as claude-desktop, not plain Claude', () => {
        expect(resolveAvatarHarness('claude', null, 'claude-desktop')).toBe('claude-desktop');
        expect(resolveAvatarHarness('claude', undefined, undefined)).toBe('claude');
        expect(resolveAvatarHarness('claude', null, 'future-host')).toBe('claude');
    });

    it('does not badge retired or unknown flavors', () => {
        expect(resolveAvatarHarness('gemini')).toBeNull();
        expect(resolveAvatarHarness('future-harness')).toBeNull();
        expect(resolveAvatarHarness(null)).toBeNull();
        expect(resolveAvatarHarness(undefined, 'other-client')).toBeNull();
    });
});