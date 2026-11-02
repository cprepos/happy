/**
 * Recognises phone messages coming back through a Claude desktop transcript.
 *
 * `happy attach` hands each phone message to the daemon, and the happy plugin's
 * SessionStart / Stop hook delivers it to the desktop's Claude by printing
 * `[Happy] <text>` and exiting 2 (asyncRewake). Claude Code then records the
 * woken turn as a user entry wrapping that output:
 *
 *   <task-notification>…Stop hook feedback…</task-notification>
 *   <system-reminder>
 *   Stop hook blocking error from command "Stop": [Happy] <text>
 *   </system-reminder>
 *
 * (SessionStart rewakes carry their own event name, e.g. "SessionStart:resume".)
 * Older Claude Code versions write `Stop hook feedback:\n[<command>]: [Happy] <text>`
 * instead, as an isMeta entry.
 *
 * The phone already shows the message it sent, so attach must not forward the
 * echo as a new user message. This module extracts the delivered text and maps
 * it back to the pending message it came from. Everything that is not a Happy
 * delivery is left alone.
 */

import type { RawJSONLines } from '@/claude/types';

/** The `[Happy] <text>` payload of a rewake delivery, with the hook event that delivered it. */
export type DesktopDelivery = {
    /** Hook event name (`Stop`, `SessionStart:resume`, …), or the hook command for the older format. */
    hook: string;
    text: string;
};

/**
 * What the attach loop should do with one transcript entry.
 * - `forward`: an ordinary entry; mirror it as-is.
 * - `echo`: a delivery of a message attach enqueued; the phone already shows it.
 * - `foreign`: a Happy delivery attach did not enqueue (an earlier attach process,
 *   or history backfill). Mirror it, but as the plain text the phone sent.
 */
export type DesktopEchoDecision =
    | { kind: 'forward' }
    | { kind: 'echo'; localId: string; text: string }
    | { kind: 'foreign'; text: string; message: RawJSONLines };

const HAPPY_PREFIX = '[Happy] ';
const BLOCKING_ERROR = /Stop hook blocking error from command "([^"]*)": \[Happy\] /;
const LEGACY_FEEDBACK = /^Stop hook feedback:\n\[([^\]]*)\]: \[Happy\] /;
const REMINDER_CLOSE = /\s*<\/system-reminder>\s*$/;
const LEGACY_PLUGIN_FOOTER = /\n\nThis hook comes from the [^\n]* plugin\.\s*$/;

/**
 * Extract the Happy delivery from a transcript user entry's text, or null when
 * the text is not one.
 */
export function parseDesktopDelivery(content: string): DesktopDelivery | null {
    const blocking = BLOCKING_ERROR.exec(content);
    if (blocking) {
        const rest = content.slice(blocking.index + blocking[0].length);
        return { hook: blocking[1], text: rest.replace(REMINDER_CLOSE, '').trim() };
    }
    const legacy = LEGACY_FEEDBACK.exec(content);
    if (legacy) {
        const rest = content.slice(legacy[0].length);
        return { hook: legacy[1], text: rest.replace(LEGACY_PLUGIN_FOOTER, '').trim() };
    }
    return null;
}

/** The text of a user entry: string content, or its text blocks joined. Null for other entries. */
function userEntryText(message: RawJSONLines): string | null {
    if (message.type !== 'user') return null;
    const content: unknown = message.message.content;
    if (typeof content === 'string') return content;
    if (!Array.isArray(content)) return null;
    const texts = content
        .filter((block): block is { type: 'text'; text: string } =>
            typeof block === 'object' && block !== null && block.type === 'text' && typeof block.text === 'string')
        .map((block) => block.text);
    return texts.length > 0 ? texts.join('\n') : null;
}

/**
 * Tracks the phone messages attach has enqueued and classifies transcript
 * entries against them. Matching is by text (trimmed), oldest first, so two
 * identical messages are consumed in the order they were sent.
 */
export function createDesktopEchoMatcher() {
    const pending: Array<{ localId: string; text: string }> = [];

    return {
        /** Record a message handed to the daemon, before its echo can appear. */
        expect(localId: string, text: string): void {
            pending.push({ localId, text: text.trim() });
        },

        /** Forget a message that was never handed over (enqueue failed). */
        forget(localId: string): void {
            const index = pending.findIndex((entry) => entry.localId === localId);
            if (index >= 0) pending.splice(index, 1);
        },

        pendingCount(): number {
            return pending.length;
        },

        classify(message: RawJSONLines): DesktopEchoDecision {
            const content = userEntryText(message);
            if (content === null || !content.includes(HAPPY_PREFIX)) return { kind: 'forward' };
            const delivery = parseDesktopDelivery(content);
            if (!delivery) return { kind: 'forward' };

            const index = pending.findIndex((entry) => entry.text === delivery.text);
            if (index >= 0) {
                const [match] = pending.splice(index, 1);
                return { kind: 'echo', localId: match.localId, text: delivery.text };
            }
            return {
                kind: 'foreign',
                text: delivery.text,
                message: {
                    ...message,
                    isMeta: false,
                    message: { ...(message as Extract<RawJSONLines, { type: 'user' }>).message, content: delivery.text },
                } as RawJSONLines,
            };
        },
    };
}

export type DesktopEchoMatcher = ReturnType<typeof createDesktopEchoMatcher>;
