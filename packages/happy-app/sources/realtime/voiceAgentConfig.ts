import type { VoiceSessionConfig } from './types';

/**
 * The JSON reply to the agent's `happy.getConfig` RPC. `voice` and `speed`
 * are only included when a voice was picked, so the agent keeps its own
 * defaults otherwise.
 */
export function buildAgentConfigJson(config: VoiceSessionConfig | null): string {
    return JSON.stringify({
        systemPrompt: config?.systemPrompt ?? '',
        firstMessage: config?.firstMessage ?? '',
        initialContext: config?.initialContext ?? '',
        language: config?.language ?? null,
        sessionId: config?.sessionId ?? '',
        ...(config?.voice ? { voice: config.voice } : {}),
        ...(config?.voice && typeof config.speed === 'number' ? { speed: config.speed } : {}),
    });
}
