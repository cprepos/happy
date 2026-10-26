import { describe, expect, it } from 'vitest';
import type { Metadata } from '@/api/types';
import { opencodeModeAgent, withOpencodePermissionModes } from './acpPermissionModes';

const base = {
    path: '/tmp',
    host: 'host',
    homeDir: '/tmp',
    happyHomeDir: '/tmp/.happy',
    happyLibDir: '/tmp/lib',
    happyToolsDir: '/tmp/tools',
} as unknown as Metadata;

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
