/**
 * OpenCode's mode picker: an agent (build, plan, ...) plus a permission policy.
 *
 * OpenCode has a single mode picker, and its modes are its agents. Whether a
 * tool asks first is folded into the same picker: each agent is offered as
 * `<Agent>-auto` (permission requests are approved automatically, like
 * `opencode --auto`) and `<Agent>-ask` (they are shown for approval). The
 * keys are `<agent>:auto` and `<agent>:ask`; happy-cli also accepts a plain
 * agent id, which means "this agent, with the policy the session runs with".
 *
 * What a session reports depends on the CLI that runs it:
 * - the ACP runner lists the explicit keys;
 * - the TUI mirror lists the plain id for its launch policy and
 *   `<agent>:<other policy>` for the other one;
 * - older CLIs list plain agent ids only.
 * The app always shows the explicit keys, built from whichever of these the
 * session has, so the picker looks the same everywhere.
 */

export type OpencodePermissionPolicy = 'auto' | 'ask';

export const OPENCODE_POLICIES: readonly OpencodePermissionPolicy[] = ['auto', 'ask'];

/** The default: OpenCode's own default agent, approving tool permissions automatically. */
export const OPENCODE_DEFAULT_PERMISSION_MODE = 'build:auto';

/** OpenCode's primary agents, before a session has reported its own. */
export const OPENCODE_DEFAULT_AGENTS = ['build', 'plan'] as const;

/**
 * Permission keys other harnesses use. They are not OpenCode agent names, so
 * they are never turned into `<key>:<policy>`.
 */
const GENERIC_PERMISSION_KEYS = new Set([
    'default',
    'auto',
    'yolo',
    'bypassPermissions',
    'acceptEdits',
    'safe-yolo',
    'read-only',
]);

type MetadataOption = { code: string; value: string; description?: string | null };

/** `build:ask` -> { agent: 'build', policy: 'ask' }; `build` -> { agent: 'build', policy: null }. */
export function splitOpencodeModeKey(key: string): { agent: string; policy: OpencodePermissionPolicy | null } {
    const separator = key.lastIndexOf(':');
    if (separator > 0) {
        const policy = key.slice(separator + 1);
        if (policy === 'auto' || policy === 'ask') {
            return { agent: key.slice(0, separator), policy };
        }
    }
    return { agent: key, policy: null };
}

/**
 * The policy a plain agent id stands for in this mode list. The TUI mirror
 * lists the plain id next to `<agent>:<other policy>`; anything else (an
 * older CLI) is treated as auto, the default.
 */
export function opencodeLaunchPolicy(
    modes: readonly MetadataOption[] | null | undefined,
    agent: string,
): OpencodePermissionPolicy {
    const codes = new Set((modes ?? []).map((mode) => mode.code));
    return codes.has(agent) && codes.has(`${agent}:auto`) && !codes.has(`${agent}:ask`) ? 'ask' : 'auto';
}

/**
 * Maps a saved or reported OpenCode mode key onto an explicit
 * `<agent>:<policy>` key. Generic permission keys and empty values are
 * returned unchanged.
 */
export function normalizeOpencodePermissionModeKey<T extends string | null | undefined>(
    key: T,
    modes?: readonly MetadataOption[] | null,
): T | string {
    if (!key || GENERIC_PERMISSION_KEYS.has(key)) {
        return key;
    }
    const { agent, policy } = splitOpencodeModeKey(key);
    if (policy) {
        return key;
    }
    return `${agent}:${opencodeLaunchPolicy(modes, agent)}`;
}

/** The agents in a reported mode list, in order, with their own display name if any. */
export function opencodeAgentsFromModes(
    modes: readonly MetadataOption[] | null | undefined,
): Array<{ agent: string; option: MetadataOption | null }> {
    const agents: Array<{ agent: string; option: MetadataOption | null }> = [];
    for (const mode of modes ?? []) {
        const { agent } = splitOpencodeModeKey(mode.code);
        if (GENERIC_PERMISSION_KEYS.has(agent)) {
            continue;
        }
        const existing = agents.find((entry) => entry.agent === agent);
        if (!existing) {
            agents.push({ agent, option: mode.code === agent ? mode : null });
        } else if (!existing.option && mode.code === agent) {
            existing.option = mode;
        }
    }
    return agents;
}

/**
 * The display name of an agent: "Build" for build. OpenCode sometimes
 * reports names as "build, build" or "plan/plan", and the TUI mirror names
 * its plain entries "Build-auto"; all of that is stripped.
 */
export function opencodeAgentDisplayName(agent: string, option: MetadataOption | null): string {
    const raw = option?.value?.trim() || agent;
    const first = (raw.split(/[,/]/)[0] ?? '').trim().replace(/-(auto|ask)$/i, '') || agent;
    return first.charAt(0).toUpperCase() + first.slice(1);
}
