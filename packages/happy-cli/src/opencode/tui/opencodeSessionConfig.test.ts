import { describe, expect, it } from 'vitest';
import type { OpencodeProviders } from './opencodeClient';
import { buildOpencodePickers, opencodePromptOptions } from './opencodeSessionConfig';

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
            availableModes: [{ id: 'build', name: 'build' }, { id: 'plan', name: 'plan', description: 'Read-only planning' }],
            currentModeId: 'build',
        });
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
    });
});
