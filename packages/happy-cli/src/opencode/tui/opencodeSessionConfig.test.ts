import { describe, expect, it } from 'vitest';
import type { OpencodeProviders } from './opencodeClient';
import { buildOpencodePickers, opencodePromptOptions, parseOpencodeMode } from './opencodeSessionConfig';

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
