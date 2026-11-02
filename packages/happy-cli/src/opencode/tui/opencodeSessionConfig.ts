/**
 * Model and mode pickers for an `opencode serve` session.
 *
 * The app shows model and mode pickers from session metadata, in the shape
 * ACP agents report them. Here they are built from the server's providers
 * and primary agents, and the app's choice on each message is turned back
 * into the `model`/`agent` fields of an OpenCode prompt.
 *
 * The app has a single mode picker, and for OpenCode it already picks the
 * agent (build, plan, ...). Whether tools ask first is folded into the same
 * picker: every agent is listed twice, once per permission policy, as
 * "Build-auto" / "Build-ask". The plain agent id stands for the policy the
 * session was launched with (the app sends the plain id when nothing was
 * picked, so the chip then shows the launch policy); `<agent>:auto` and
 * `<agent>:ask` name a policy explicitly.
 */

import type { SessionModeState, SessionModelState } from '@agentclientprotocol/sdk';
import type { OpencodeAgent, OpencodeProviders } from './opencodeClient';

/**
 * `auto`: permission requests are approved once, automatically, like
 * `opencode --auto` (rules that deny stay denied, they never ask).
 * `ask`: requests are shown in the TUI and the app.
 */
export type OpencodePermissionPolicy = 'auto' | 'ask';

const POLICY_SEPARATOR = ':';

function capitalize(text: string): string {
    return text.charAt(0).toUpperCase() + text.slice(1);
}

function otherPolicy(policy: OpencodePermissionPolicy): OpencodePermissionPolicy {
    return policy === 'auto' ? 'ask' : 'auto';
}

function policyDescription(policy: OpencodePermissionPolicy): string {
    return policy === 'auto'
        ? 'approves tool permissions automatically'
        : 'asks before tools that need permission';
}

export function buildOpencodePickers(input: {
    providers: OpencodeProviders;
    agents: OpencodeAgent[];
    config: { model?: string; default_agent?: string };
    /** The policy the session was launched with; defaults to auto. */
    launchPolicy?: OpencodePermissionPolicy;
}): { models: SessionModelState | null; modes: SessionModeState | null } {
    const launchPolicy = input.launchPolicy ?? 'auto';
    const availableModels = input.providers.providers.flatMap((provider) =>
        Object.entries(provider.models).map(([key, model]) => ({
            modelId: `${provider.id}/${model.id ?? key}`,
            name: `${provider.name ?? provider.id} / ${model.name ?? model.id ?? key}`,
        })),
    );
    const [firstProvider, firstModel] = Object.entries(input.providers.default)[0] ?? [];
    const currentModelId = input.config.model ?? (firstProvider ? `${firstProvider}/${firstModel}` : availableModels[0]?.modelId);

    const primaryAgents = input.agents.filter((agent) => agent.mode !== 'subagent' && !agent.hidden);
    const availableModes = primaryAgents.flatMap((agent) => (
        [launchPolicy, otherPolicy(launchPolicy)].map((policy) => ({
            id: policy === launchPolicy ? agent.name : `${agent.name}${POLICY_SEPARATOR}${policy}`,
            name: `${capitalize(agent.name)}-${policy}`,
            description: agent.description
                ? `${agent.description} (${policyDescription(policy)})`
                : `${capitalize(agent.name)} agent, ${policyDescription(policy)}`,
        }))
    ));
    const agentNames = primaryAgents.map((agent) => agent.name);
    const currentModeId = input.config.default_agent && agentNames.includes(input.config.default_agent)
        ? input.config.default_agent
        : (agentNames.includes('build') ? 'build' : agentNames[0]);

    return {
        models: availableModels.length > 0 && currentModelId ? { availableModels, currentModelId } : null,
        modes: availableModes.length > 0 && currentModeId ? { availableModes, currentModeId } : null,
    };
}

/**
 * What a mode key from the app selects: an agent and/or a permission policy.
 * Besides the keys listed by `buildOpencodePickers`, the generic permission
 * modes other agents use are understood: `bypassPermissions`/`yolo`/`auto`
 * mean auto, `default` means ask. Unknown keys select nothing.
 */
export function parseOpencodeMode(
    key: string | null | undefined,
    agentNames: string[],
    launchPolicy: OpencodePermissionPolicy,
): { agent?: string; policy?: OpencodePermissionPolicy } {
    if (!key) {
        return {};
    }
    if (agentNames.includes(key)) {
        return { agent: key, policy: launchPolicy };
    }
    const separator = key.lastIndexOf(POLICY_SEPARATOR);
    if (separator > 0) {
        const agent = key.slice(0, separator);
        const policy = key.slice(separator + 1);
        if (agentNames.includes(agent) && (policy === 'auto' || policy === 'ask')) {
            return { agent, policy };
        }
    }
    if (key === 'bypassPermissions' || key === 'yolo' || key === 'auto') {
        return { policy: 'auto' };
    }
    if (key === 'default') {
        return { policy: 'ask' };
    }
    return {};
}

/**
 * The key `buildOpencodePickers` lists for this agent and policy: the plain id
 * for the launch policy, `<agent>:<policy>` for the other.
 */
export function opencodeModeCode(
    agent: string,
    policy: OpencodePermissionPolicy,
    launchPolicy: OpencodePermissionPolicy,
): string {
    return policy === launchPolicy ? agent : `${agent}${POLICY_SEPARATOR}${policy}`;
}

function splitModelKey(key: string): { providerID: string; modelID: string } | undefined {
    const slash = key.indexOf('/');
    return slash > 0 && slash < key.length - 1
        ? { providerID: key.slice(0, slash), modelID: key.slice(slash + 1) }
        : undefined;
}

/**
 * A model pick from the app -> OpenCode's model and variant. `opencode acp`
 * lists variants as `<provider>/<model>/<variant>`, and a session started there
 * can keep sending one, so a pick that is a known model plus one more segment
 * means that variant. Against a known list anything else is dropped, as the ACP
 * runner drops it; model ids can contain slashes, so only the list can tell.
 */
function resolveModelPick(
    pick: string | null | undefined,
    knownModels: readonly string[] | undefined,
): { model?: { providerID: string; modelID: string }; variant?: string } {
    if (!pick) {
        return {};
    }
    if (!knownModels || knownModels.length === 0 || knownModels.includes(pick)) {
        const model = splitModelKey(pick);
        return model ? { model } : {};
    }
    const slash = pick.lastIndexOf('/');
    const base = slash > 0 ? pick.slice(0, slash) : '';
    const model = knownModels.includes(base) ? splitModelKey(base) : undefined;
    return model ? { model, variant: pick.slice(slash + 1) } : {};
}

/**
 * The prompt options for the app's picks. Unknown or empty picks are left
 * out, so OpenCode falls back to the session's own model and agent.
 */
export function opencodePromptOptions(input: {
    model?: string | null;
    permissionMode?: string | null;
    agentNames: string[];
    launchPolicy?: OpencodePermissionPolicy;
    /** The models the pickers offer, when they could be read. */
    knownModels?: readonly string[];
}): { model?: { providerID: string; modelID: string }; variant?: string; agent?: string } {
    const { model, variant } = resolveModelPick(input.model, input.knownModels);
    const { agent } = parseOpencodeMode(input.permissionMode, input.agentNames, input.launchPolicy ?? 'auto');
    return { ...(model ? { model } : {}), ...(variant ? { variant } : {}), ...(agent ? { agent } : {}) };
}

/**
 * `/name some args` -> the command, when `name` is one of `known`. Anything
 * else is an ordinary prompt: a message that merely starts with a path must
 * still reach the model.
 */
export function parseOpencodeSlashCommand(
    text: string,
    known: readonly string[],
): { name: string; args: string } | null {
    const match = text.trim().match(/^\/(\S+)(?:\s+([\s\S]*))?$/);
    return match && known.includes(match[1]) ? { name: match[1], args: match[2] ?? '' } : null;
}
