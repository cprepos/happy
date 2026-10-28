import type { NewSessionAgentType } from '@/sync/persistence';

/**
 * The coding agents Happy can start a session with, and what to call them in
 * the UI. `rig` is the wire/CLI id of Happy's own agent; it is only ever shown
 * as "Happy". `agy` is Antigravity's binary name for the same reason.
 */
export const HARNESS_NAMES: Record<NewSessionAgentType, string> = {
    claude: 'Claude Code',
    codex: 'Codex',
    rig: 'Happy',
    agy: 'Antigravity',
    opencode: 'OpenCode',
    gemini: 'Gemini',
    openclaw: 'OpenClaw',
};

/**
 * Harnesses you can no longer start a session with.
 *
 * Gemini's CLI login is dead for individual accounts — it now refuses with
 * "This client is no longer supported […] migrate to the Antigravity suite",
 * which is the `agy` harness. It stays in HARNESS_NAMES so an existing session
 * still shows a real product name, and it is not removed from the CLI, the
 * wire, or the transcript renderers.
 */
export const RETIRED_HARNESSES: ReadonlySet<NewSessionAgentType> = new Set([
    'gemini',
]);

/** Pick order for every harness list: the ones people reach for come first. */
export const HARNESS_ORDER: readonly NewSessionAgentType[] = [
    'claude',
    'codex',
    'agy',
    'opencode',
    'openclaw',
    'rig',
];

/**
 * Harnesses that are listed only after a daemon reports them installed.
 *
 * They are niche enough that an old or incomplete capability report must not
 * advertise them speculatively, so they are left out of the empty-list
 * fallback and being the current selection does not keep them listed.
 * OpenClaw additionally needs a reachable gateway, which only the machine
 * running it has, so a speculative row would be a dead end everywhere else.
 */
export const EXPLICIT_REPORT_HARNESSES: ReadonlySet<NewSessionAgentType> = new Set([
    'agy',
    'opencode',
    'openclaw',
]);

export function isRetiredHarness(key: NewSessionAgentType | string): boolean {
    return RETIRED_HARNESSES.has(key as NewSessionAgentType);
}

export type HarnessAvailability = Partial<Record<NewSessionAgentType, boolean>>;

export type HarnessOption = {
    key: NewSessionAgentType;
    name: string;
};

export function getHarnessName(key: NewSessionAgentType | string): string {
    return HARNESS_NAMES[key as NewSessionAgentType] ?? key;
}

/** Whether this machine has given the app enough evidence to offer a harness. */
export function isHarnessAvailable({
    availability,
    happyAgentAvailable,
    key,
}: {
    availability?: HarnessAvailability | null;
    happyAgentAvailable: boolean;
    key: NewSessionAgentType;
}): boolean {
    if (key === 'rig') return happyAgentAvailable;
    if (EXPLICIT_REPORT_HARNESSES.has(key)) return availability?.[key] === true;
    return !availability || availability[key] === true;
}

/**
 * The harnesses a machine actually has set up, in pick order.
 *
 * A harness with no CLI on the machine is left out rather than shown disabled:
 * a greyed-out row reads as something you can turn on from here, and you
 * cannot. Two things keep the list from ever being empty — the current
 * selection is usually included, and a machine that reports no capabilities at
 * all (an older daemon, or none selected yet) falls back to the familiar
 * catalog. EXPLICIT_REPORT_HARNESSES are the exception to both fallbacks: they
 * are only listed after an explicit installation report. A retired harness is
 * also exempt from the first rule, because keeping it listed would strand
 * someone on it.
 */
export function listAvailableHarnesses({
    availability,
    happyAgentAvailable,
    selected,
}: {
    availability?: HarnessAvailability | null;
    happyAgentAvailable: boolean;
    selected?: NewSessionAgentType | null;
}): HarnessOption[] {
    const keys = HARNESS_ORDER.filter((key) => (
        (key === selected && !EXPLICIT_REPORT_HARNESSES.has(key))
        || isHarnessAvailable({ availability, happyAgentAvailable, key })
    ));
    const fallback = HARNESS_ORDER.filter((key) => !EXPLICIT_REPORT_HARNESSES.has(key));
    return (keys.length > 0 ? keys : fallback).map((key) => ({
        key,
        name: HARNESS_NAMES[key],
    }));
}
