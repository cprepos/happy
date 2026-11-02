import { describe, expect, it } from 'vitest';
import type { OpencodeProviders } from './opencodeClient';
import {
    buildOpencodePickers,
    opencodeModeCode,
    opencodePromptOptions,
    parseOpencodeMode,
    parseOpencodeSlashCommand,
} from './opencodeSessionConfig';

const providers: OpencodeProviders = {
    providers: [
        { id: 'opencode', name: 'OpenCode Zen', models: { 'big-pickle': { id: 'big-pickle', name: 'Big Pickle' } } },
        { id: 'coder', models: { coder: { id: 'coder', name: 'Coder' } } },
    ],
    default: { opencode: 'big-pickle', coder: 'coder' },
};

const agents = [
    { name: 'build', mode: 'primary' },
    { name: 'plan', mode: 'primary', description: 'Read-only planning' },
    { name: 'title', mode: 'primary', hidden: true },
    { name: 'explore', mode: 'subagent' },
];

describe('buildOpencodePickers', () => {
    it('lists every provider model and the selectable primary agents', () => {
        const pickers = buildOpencodePickers({ providers, agents, config: { model: 'coder/coder' } });
        expect(pickers.models).toEqual({
            availableModels: [
                { modelId: 'opencode/big-pickle', name: 'OpenCode Zen / Big Pickle' },
                { modelId: 'coder/coder', name: 'coder / Coder' },
            ],
            currentModelId: 'coder/coder',
        });
        expect(pickers.modes).toEqual({
            availableModes: [
                { id: 'build', name: 'Build-auto', description: 'Build agent, approves tool permissions automatically' },
                { id: 'build:ask', name: 'Build-ask', description: 'Build agent, asks before tools that need permission' },
                { id: 'plan', name: 'Plan-auto', description: 'Read-only planning (approves tool permissions automatically)' },
                { id: 'plan:ask', name: 'Plan-ask', description: 'Read-only planning (asks before tools that need permission)' },
            ],
            currentModeId: 'build',
        });
    });

    it('lists the launch policy under the plain agent id', () => {
        const pickers = buildOpencodePickers({ providers, agents, config: {}, launchPolicy: 'ask' });
        expect(pickers.modes?.availableModes.map((mode) => [mode.id, mode.name])).toEqual([
            ['build', 'Build-ask'],
            ['build:auto', 'Build-auto'],
            ['plan', 'Plan-ask'],
            ['plan:auto', 'Plan-auto'],
        ]);
        expect(pickers.modes?.currentModeId).toBe('build');
    });

    it('falls back to the first provider default without a configured model', () => {
        const pickers = buildOpencodePickers({ providers, agents, config: { default_agent: 'plan' } });
        expect(pickers.models?.currentModelId).toBe('opencode/big-pickle');
        expect(pickers.modes?.currentModeId).toBe('plan');
        expect(buildOpencodePickers({ providers: { providers: [], default: {} }, agents: [], config: {} })).toEqual({ models: null, modes: null });
    });
});

describe('opencodePromptOptions', () => {
    it('turns app picks into prompt fields and ignores unknown ones', () => {
        const agentNames = ['build', 'plan'];
        expect(opencodePromptOptions({ model: 'coder/coder', permissionMode: 'plan', agentNames })).toEqual({
            model: { providerID: 'coder', modelID: 'coder' },
            agent: 'plan',
        });
        expect(opencodePromptOptions({ model: 'openrouter/anthropic/x', agentNames })).toEqual({
            model: { providerID: 'openrouter', modelID: 'anthropic/x' },
        });
        expect(opencodePromptOptions({ model: 'nomodel', permissionMode: 'default', agentNames })).toEqual({});
        expect(opencodePromptOptions({ model: null, permissionMode: null, agentNames })).toEqual({});
        expect(opencodePromptOptions({ permissionMode: 'plan:ask', agentNames })).toEqual({ agent: 'plan' });
    });

    it('reads a known model plus one segment as a variant, as opencode acp lists them', () => {
        const knownModels = ['openrouter/anthropic/x', 'coder/coder'];
        const agentNames = ['build'];
        expect(opencodePromptOptions({ model: 'openrouter/anthropic/x', agentNames, knownModels })).toEqual({
            model: { providerID: 'openrouter', modelID: 'anthropic/x' },
        });
        expect(opencodePromptOptions({ model: 'coder/coder/high', agentNames, knownModels })).toEqual({
            model: { providerID: 'coder', modelID: 'coder' },
            variant: 'high',
        });
    });

    it('drops a model the known list does not have', () => {
        expect(opencodePromptOptions({ model: 'gone/model', agentNames: [], knownModels: ['coder/coder'] })).toEqual({});
    });
});

describe('parseOpencodeMode', () => {
    const agentNames = ['build', 'plan'];

    it('reads the agent and policy from the picker ids', () => {
        expect(parseOpencodeMode('build', agentNames, 'auto')).toEqual({ agent: 'build', policy: 'auto' });
        expect(parseOpencodeMode('build', agentNames, 'ask')).toEqual({ agent: 'build', policy: 'ask' });
        expect(parseOpencodeMode('plan:ask', agentNames, 'auto')).toEqual({ agent: 'plan', policy: 'ask' });
        expect(parseOpencodeMode('plan:auto', agentNames, 'ask')).toEqual({ agent: 'plan', policy: 'auto' });
    });

    it('maps the generic permission modes to a policy', () => {
        expect(parseOpencodeMode('bypassPermissions', agentNames, 'ask')).toEqual({ policy: 'auto' });
        expect(parseOpencodeMode('yolo', agentNames, 'ask')).toEqual({ policy: 'auto' });
        expect(parseOpencodeMode('default', agentNames, 'auto')).toEqual({ policy: 'ask' });
    });

    it('selects nothing for unknown or empty keys', () => {
        expect(parseOpencodeMode('review:ask', agentNames, 'auto')).toEqual({});
        expect(parseOpencodeMode('build:sometimes', agentNames, 'auto')).toEqual({});
        expect(parseOpencodeMode(undefined, agentNames, 'auto')).toEqual({});
    });
});

describe('opencodeModeCode', () => {
    it('uses the plain id for the launch policy and the explicit key for the other', () => {
        expect(opencodeModeCode('build', 'auto', 'auto')).toBe('build');
        expect(opencodeModeCode('build', 'ask', 'auto')).toBe('build:ask');
        expect(opencodeModeCode('plan', 'auto', 'ask')).toBe('plan:auto');
    });
});

describe('parseOpencodeSlashCommand', () => {
    const known = ['init', 'compact'];

    it('splits a known command from its arguments', () => {
        expect(parseOpencodeSlashCommand('/compact', known)).toEqual({ name: 'compact', args: '' });
        expect(parseOpencodeSlashCommand('  /init fix the\nreadme ', known)).toEqual({ name: 'init', args: 'fix the\nreadme' });
    });

    it('treats anything else as an ordinary prompt', () => {
        expect(parseOpencodeSlashCommand('/etc/hosts looks wrong', known)).toBeNull();
        expect(parseOpencodeSlashCommand('/unknown', known)).toBeNull();
        expect(parseOpencodeSlashCommand('please /init', known)).toBeNull();
    });
});
