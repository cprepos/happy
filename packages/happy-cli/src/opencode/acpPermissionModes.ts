/**
 * Auto/ask permission policy for OpenCode sessions on the ACP runner
 * (`opencode acp`, which daemon- and app-started sessions use).
 *
 * `opencode acp` reports its primary agents (build, plan, ...) as the mode
 * list. The app has a single mode picker, so the permission policy is folded
 * into it the same way the TUI mirror does: every agent is listed once per
 * policy, with explicit keys `<agent>:auto` / `<agent>:ask`. The plain agent
 * id is still understood and stands for the policy the session runs with.
 *
 * In `auto` a permission request is approved once, straight away, like
 * `opencode --auto`. In `ask` it goes through the normal approval flow.
 */

import type { Metadata } from '@/api/types';
import type { OpencodePermissionPolicy } from './tui/opencodeSessionConfig';

export type { OpencodePermissionPolicy } from './tui/opencodeSessionConfig';

type MetadataOption = { code: string; value: string; description?: string | null };

const POLICIES: OpencodePermissionPolicy[] = ['auto', 'ask'];

function capitalize(text: string): string {
    return text.charAt(0).toUpperCase() + text.slice(1);
}

/** `build:ask` -> `build`; a plain id is returned as is. */
export function opencodeModeAgent(code: string): string {
    const separator = code.lastIndexOf(':');
    if (separator > 0) {
        const suffix = code.slice(separator + 1);
        if (suffix === 'auto' || suffix === 'ask') {
            return code.slice(0, separator);
        }
    }
    return code;
}

/** The agent's display name: OpenCode sometimes reports "build, build" or "plan/plan". */
function agentDisplayName(option: MetadataOption | undefined, agent: string): string {
    const raw = option?.value?.trim() || agent;
    const first = raw.split(/[,/]/)[0]?.trim() || agent;
    return capitalize(first);
}

function policyDescription(policy: OpencodePermissionPolicy): string {
    return policy === 'auto'
        ? 'approves tool permissions automatically'
        : 'asks before tools that need permission';
}

/**
 * Rewrites the mode list reported by `opencode acp` so each agent appears as
 * `<Agent>-auto` and `<Agent>-ask`, and marks the current agent with the
 * current policy. Idempotent: an already expanded list is rebuilt the same.
 */
export function withOpencodePermissionModes(metadata: Metadata, policy: OpencodePermissionPolicy): Metadata {
    const reported = metadata.operatingModes;
    if (!reported || reported.length === 0) {
        return metadata;
    }
    const agents: string[] = [];
    const plainOptions = new Map<string, MetadataOption>();
    for (const option of reported) {
        const agent = opencodeModeAgent(option.code);
        if (!agents.includes(agent)) {
            agents.push(agent);
        }
        if (agent === option.code) {
            plainOptions.set(agent, option);
        }
    }
    const operatingModes: MetadataOption[] = agents.flatMap((agent) => {
        const plain = plainOptions.get(agent);
        const name = agentDisplayName(plain, agent);
        return POLICIES.map((entryPolicy) => ({
            code: `${agent}:${entryPolicy}`,
            value: `${name}-${entryPolicy}`,
            description: plain?.description
                ? `${plain.description} (${policyDescription(entryPolicy)})`
                : `${name} agent, ${policyDescription(entryPolicy)}`,
        }));
    });
    const currentAgent = metadata.currentOperatingModeCode
        ? opencodeModeAgent(metadata.currentOperatingModeCode)
        : (agents.includes('build') ? 'build' : agents[0]);
    return {
        ...metadata,
        operatingModes,
        ...(currentAgent ? { currentOperatingModeCode: `${currentAgent}:${policy}` } : {}),
    };
}
