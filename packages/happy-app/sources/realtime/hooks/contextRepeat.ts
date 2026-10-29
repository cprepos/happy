/**
 * Drops a voice context update identical to one sent moments ago.
 *
 * The sync layer can emit one server event as several identical updates: a tool call renders
 * to the same string when it arrives and again when its result lands, because the rendering
 * carries no state (formatMessage under LIMITED_TOOL_CALLS prints only the name and
 * description). Three such pairs arrived 1 ms apart in a three-minute session, and every
 * update is appended to the prompt the voice agent has to prefill on each later turn.
 *
 * Past the window an identical update is taken at face value — the same file really can be
 * read twice, and that is worth telling the agent about.
 *
 * The voice agent drops short repeats of its own too (happy_voice/context.py), since it has to
 * cope with app versions that predate this.
 */

export const CONTEXT_REPEAT_WINDOW_MS = 2000;

export interface RepeatFilter {
    /** True when this exact text was already passed within the window. */
    isRepeat: (text: string, now?: number) => boolean;
    reset: () => void;
}

export function createRepeatFilter(
    windowMs: number = CONTEXT_REPEAT_WINDOW_MS,
    keep: number = 8
): RepeatFilter {
    let seen: { text: string; at: number }[] = [];
    return {
        isRepeat(text: string, now: number = Date.now()): boolean {
            seen = seen.filter(entry => now - entry.at <= windowMs);
            if (seen.some(entry => entry.text === text)) return true;
            seen.push({ text, at: now });
            if (seen.length > keep) seen = seen.slice(-keep);
            return false;
        },
        reset() {
            seen = [];
        }
    };
}
