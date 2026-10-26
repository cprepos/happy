/**
 * Model and agent pickers for an `opencode serve` session.
 *
 * The app shows model and mode pickers from session metadata, in the shape
 * ACP agents report them. Here they are built from the server's providers
 * and primary agents, and the app's choice on each message is turned back
 * into the `model`/`agent` fields of an OpenCode prompt.
 */

import type { SessionModeState, SessionModelState } from '@agentclientprotocol/sdk';
import type { OpencodeAgent, OpencodeProviders } from './opencodeClient';

export function buildOpencodePickers(input: {
    providers: OpencodeProviders;
    agents: OpencodeAgent[];
    config: { model?: string; default_agent?: string };
}): { models: SessionModelState | null; modes: SessionModeState | null } {
    const availableModels = input.providers.providers.flatMap((provider) =>
        Object.entries(provider.models).map(([key, model]) => ({
            modelId: `${provider.id}/${model.id ?? key}`,
            name: `${provider.name ?? provider.id} / ${model.name ?? model.id ?? key}`,
        })),
    );
    const [firstProvider, firstModel] = Object.entries(input.providers.default)[0] ?? [];
    const currentModelId = input.config.model ?? (firstProvider ? `${firstProvider}/${firstModel}` : availableModels[0]?.modelId);

    const availableModes = input.agents
        .filter((agent) => agent.mode !== 'subagent' && !agent.hidden)
        .map((agent) => ({
            id: agent.name,
            name: agent.name,
            ...(agent.description ? { description: agent.description } : {}),
        }));
    const currentModeId = input.config.default_agent ?? (availableModes.some((mode) => mode.id === 'build') ? 'build' : availableModes[0]?.id);

    return {
        models: availableModels.length > 0 && currentModelId ? { availableModels, currentModelId } : null,
        modes: availableModes.length > 0 && currentModeId ? { availableModes, currentModeId } : null,
    };
}

/**
 * The prompt options for the app's picks. Unknown or empty picks are left
 * out, so OpenCode falls back to the session's own model and agent.
 */
export function opencodePromptOptions(input: {
    model?: string | null;
    permissionMode?: string | null;
    agentNames: string[];
}): { model?: { providerID: string; modelID: string }; agent?: string } {
    const slash = input.model ? input.model.indexOf('/') : -1;
    const model = input.model && slash > 0 && slash < input.model.length - 1
        ? { providerID: input.model.slice(0, slash), modelID: input.model.slice(slash + 1) }
        : undefined;
    const agent = input.permissionMode && input.agentNames.includes(input.permissionMode) ? input.permissionMode : undefined;
    return { ...(model ? { model } : {}), ...(agent ? { agent } : {}) };
}
