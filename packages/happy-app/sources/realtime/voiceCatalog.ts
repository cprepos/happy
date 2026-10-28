/**
 * Curated voices for the self-hosted voice assistant.
 *
 * Each preset maps to a Kokoro voice (or a weighted blend of Kokoro voices)
 * plus a speaking rate. The app only stores the preset id; the agent receives
 * the resolved `voice` and `speed` through `happy.getConfig` and validates them
 * against the voices its Kokoro server actually has.
 *
 * Labels are names, not descriptions, so they are not translated. Accent and
 * tone are shown through translated strings.
 */

export type VoiceAccent = 'us' | 'uk';
export type VoiceTone = 'warm' | 'bright' | 'soft' | 'calm' | 'deep' | 'lively';

export interface VoicePreset {
    /** Stable id stored in settings. Never reuse an id for a different voice. */
    id: string;
    label: string;
    /** Kokoro voice name, or a blend such as `am_michael(2)+am_onyx(1)`. */
    voice: string;
    /** Kokoro speed multiplier; 1.0 is Kokoro's default pace. */
    speed: number;
    accent: VoiceAccent;
    tone: VoiceTone;
}

export const VOICE_PRESETS: readonly VoicePreset[] = [
    { id: 'morgan', label: 'Morgan', voice: 'am_morgan', speed: 1.0, accent: 'us', tone: 'deep' },
    { id: 'heart', label: 'Heart', voice: 'af_heart', speed: 1.0, accent: 'us', tone: 'warm' },
    { id: 'bella', label: 'Bella', voice: 'af_bella', speed: 1.0, accent: 'us', tone: 'bright' },
    { id: 'nicole', label: 'Nicole', voice: 'af_nicole', speed: 1.0, accent: 'us', tone: 'soft' },
    { id: 'michael', label: 'Michael', voice: 'am_michael', speed: 1.0, accent: 'us', tone: 'calm' },
    { id: 'onyx', label: 'Onyx', voice: 'am_onyx', speed: 1.0, accent: 'us', tone: 'deep' },
    { id: 'deep', label: 'Deep Blend', voice: 'am_michael(2)+am_onyx(1)', speed: 0.85, accent: 'us', tone: 'deep' },
    { id: 'fenrir', label: 'Fenrir', voice: 'am_fenrir', speed: 1.0, accent: 'us', tone: 'lively' },
    { id: 'puck', label: 'Puck', voice: 'am_puck', speed: 1.0, accent: 'us', tone: 'bright' },
    { id: 'emma', label: 'Emma', voice: 'bf_emma', speed: 1.0, accent: 'uk', tone: 'warm' },
    { id: 'george', label: 'George', voice: 'bm_george', speed: 1.0, accent: 'uk', tone: 'calm' },
    { id: 'fable', label: 'Fable', voice: 'bm_fable', speed: 1.0, accent: 'uk', tone: 'lively' },
    { id: 'lewis', label: 'Lewis', voice: 'bm_lewis', speed: 1.0, accent: 'uk', tone: 'deep' },
];

export function findVoicePreset(id: string | null | undefined): VoicePreset | null {
    if (!id) {
        return null;
    }
    return VOICE_PRESETS.find((preset) => preset.id === id) ?? null;
}

/** The chat's own preset, or null when it has none (or an unknown id). */
export function getSessionVoicePreset(
    sessionId: string,
    voiceBySession: Record<string, string> | null | undefined,
): VoicePreset | null {
    return findVoicePreset(voiceBySession?.[sessionId]);
}

/**
 * The preset a chat speaks with: the chat's override, else the global default,
 * else null (the server's default voice). Unknown ids are skipped, so a preset
 * removed in a later app version falls through to the next level.
 */
export function resolveVoicePreset(
    sessionId: string,
    voiceBySession: Record<string, string> | null | undefined,
    defaultVoiceId: string | null | undefined,
): VoicePreset | null {
    return getSessionVoicePreset(sessionId, voiceBySession) ?? findVoicePreset(defaultVoiceId);
}

/** Fields to merge into the voice session config; empty when the server default applies. */
export function voiceConfigFor(preset: VoicePreset | null): { voice?: string; speed?: number } {
    if (!preset) {
        return {};
    }
    return { voice: preset.voice, speed: preset.speed };
}

/**
 * Returns a new per-chat map with the chat's override set, or removed when
 * `presetId` is null. Unknown preset ids are treated as removal.
 */
export function setSessionVoice(
    voiceBySession: Record<string, string> | null | undefined,
    sessionId: string,
    presetId: string | null,
): Record<string, string> {
    const next = { ...(voiceBySession ?? {}) };
    if (presetId && findVoicePreset(presetId)) {
        next[sessionId] = presetId;
    } else {
        delete next[sessionId];
    }
    return next;
}
