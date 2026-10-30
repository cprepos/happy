import { describe, expect, it } from 'vitest';
import type { Metadata } from '@/api/types';
import { opencodeModeAgent, opencodeModePolicy, withOpencodePermissionModes } from './acpPermissionModes';

const base = {
    path: '/tmp',
    host: 'host',
    homeDir: '/tmp',
    happyHomeDir: '/tmp/.happy',
    happyLibDir: '/tmp/lib',
    happyToolsDir: '/tmp/tools',
} as unknown as Metadata;

describe('opencodeModePolicy', () => {
    it('takes the policy suffix and leaves a plain agent id unpoliced', () => {
        expect(opencodeModePolicy('build:ask')).toBe('ask');
        expect(opencodeModePolicy('plan:auto')).toBe('auto');
        // No suffix means "whatever policy the session runs with".
        expect(opencodeModePolicy('build')).toBeNull();
        // `agent` is not a policy, so this is a whole agent id, as
        // opencodeModeAgent also reads it.
        expect(opencodeModePolicy('ns:agent')).toBeNull();
    });

    // `build:auto` is the harness default and what resume-happy-session puts
    // on the command line, so this is the shape that has to parse.
    it('reads the default mode the daemon sends on resume', () => {
        expect(opencodeModePolicy('build:auto')).toBe('auto');
        expect(opencodeModeAgent('build:auto')).toBe('build');
    });
});

describe('opencodeModeAgent', () => {
    it('strips a policy suffix and leaves other ids alone', () => {
        expect(opencodeModeAgent('build:ask')).toBe('build');
        expect(opencodeModeAgent('plan:auto')).toBe('plan');
        expect(opencodeModeAgent('build')).toBe('build');
        expect(opencodeModeAgent('ns:agent')).toBe('ns:agent');
    });
});

describe('withOpencodePermissionModes', () => {
    it('lists every agent once per policy and marks the current one', () => {
        const metadata = withOpencodePermissionModes({
            ...base,
            operatingModes: [
                { code: 'build', value: 'build, build', description: 'Builds things' },
                { code: 'plan', value: 'plan' },
            ],
            currentOperatingModeCode: 'build',
        }, 'auto');
        expect(metadata.operatingModes).toEqual([
            { code: 'build:auto', value: 'Build-auto', description: 'Builds things (approves tool permissions automatically)' },
            { code: 'build:ask', value: 'Build-ask', description: 'Builds things (asks before tools that need permission)' },
            { code: 'plan:auto', value: 'Plan-auto', description: 'Plan agent, approves tool permissions automatically' },
            { code: 'plan:ask', value: 'Plan-ask', description: 'Plan agent, asks before tools that need permission' },
        ]);
        expect(metadata.currentOperatingModeCode).toBe('build:auto');
    });

    it('is idempotent and follows the policy', () => {
        const once = withOpencodePermissionModes({
            ...base,
            operatingModes: [{ code: 'build', value: 'build' }, { code: 'plan', value: 'plan' }],
            currentOperatingModeCode: 'plan',
        }, 'auto');
        const twice = withOpencodePermissionModes(once, 'ask');
        expect(twice.operatingModes?.map((mode) => mode.code)).toEqual(['build:auto', 'build:ask', 'plan:auto', 'plan:ask']);
        expect(twice.currentOperatingModeCode).toBe('plan:ask');
    });

    it('leaves metadata without modes alone', () => {
        expect(withOpencodePermissionModes(base, 'auto')).toBe(base);
    });
});
