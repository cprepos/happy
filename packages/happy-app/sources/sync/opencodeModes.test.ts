import { describe, expect, it } from 'vitest';
import { normalizeOpencodePermissionModeKey, opencodeLaunchPolicy, splitOpencodeModeKey } from './opencodeModes';
import { getAgentDefaultOverride, resolveAgentDefaultConfig } from './agentDefaults';

describe('opencodeModes', () => {
    it('splits a mode key into agent and policy', () => {
        expect(splitOpencodeModeKey('build:ask')).toEqual({ agent: 'build', policy: 'ask' });
        expect(splitOpencodeModeKey('plan')).toEqual({ agent: 'plan', policy: null });
        expect(splitOpencodeModeKey('ns:agent')).toEqual({ agent: 'ns:agent', policy: null });
    });

    it('reads the launch policy from a TUI mode list and defaults to auto', () => {
        const tuiAsk = [{ code: 'build', value: 'Build-ask' }, { code: 'build:auto', value: 'Build-auto' }];
        const tuiAuto = [{ code: 'build', value: 'Build-auto' }, { code: 'build:ask', value: 'Build-ask' }];
        expect(opencodeLaunchPolicy(tuiAsk, 'build')).toBe('ask');
        expect(opencodeLaunchPolicy(tuiAuto, 'build')).toBe('auto');
        expect(opencodeLaunchPolicy([{ code: 'build', value: 'build' }], 'build')).toBe('auto');
        expect(opencodeLaunchPolicy(null, 'build')).toBe('auto');
        expect(normalizeOpencodePermissionModeKey('build', tuiAsk)).toBe('build:ask');
        expect(normalizeOpencodePermissionModeKey('plan')).toBe('plan:auto');
        expect(normalizeOpencodePermissionModeKey('plan:ask')).toBe('plan:ask');
        expect(normalizeOpencodePermissionModeKey('default')).toBe('default');
        expect(normalizeOpencodePermissionModeKey(undefined)).toBeUndefined();
    });

    it('defaults OpenCode to build with auto permissions and upgrades bare saved defaults', () => {
        expect(resolveAgentDefaultConfig({}, 'opencode').permissionMode).toBe('build:auto');
        expect(getAgentDefaultOverride({ opencode: { permissionMode: 'plan' } }, 'opencode').permissionMode).toBe('plan:auto');
        expect(resolveAgentDefaultConfig({ opencode: { permissionMode: 'build:ask' } }, 'opencode').permissionMode).toBe('build:ask');
    });
});
