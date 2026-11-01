import { VoiceBackendSchema, type VoiceBackend, type VoiceConfigResponse } from "@slopus/happy-wire";
import { voiceLiveKitConfig } from "@/app/voice/voiceTokenCreate";

export interface VoiceBackendsInput {
    /** The `VOICE_BACKENDS` comma list. Empty counts as unset. */
    voiceBackends: string | undefined;
    isLiveKitConfigured: boolean;
    isElevenLabsConfigured: boolean;
}

export interface VoiceBackendsResolved extends VoiceConfigResponse {
    /** One message for each listed name that was dropped. */
    warnings: string[];
}

/**
 * Works out which voice backends the server offers. A non-empty `VOICE_BACKENDS`
 * decides the list and its order, the first entry being the default; a listed
 * backend that is unknown or not configured is dropped with a warning, and is
 * never replaced by another. Otherwise the list is whatever is configured:
 * LiveKit gives `stream`, an ElevenLabs key gives `elevenlabs`, `stream` first.
 */
export function voiceBackendsResolve(input: VoiceBackendsInput): VoiceBackendsResolved {
    const isConfigured: Record<VoiceBackend, boolean> = {
        stream: input.isLiveKitConfigured,
        elevenlabs: input.isElevenLabsConfigured,
    };
    const listed = (input.voiceBackends ?? "").split(",").map((name) => name.trim()).filter(Boolean);
    const backends: VoiceBackend[] = [];
    const warnings: string[] = [];

    if (listed.length === 0) {
        backends.push(...VoiceBackendSchema.options.filter((backend) => isConfigured[backend]));
    }
    for (const name of new Set(listed)) {
        const backend = VoiceBackendSchema.safeParse(name);
        if (!backend.success) {
            warnings.push(`VOICE_BACKENDS lists unknown backend "${name}"; dropped`);
        } else if (!isConfigured[backend.data]) {
            warnings.push(`VOICE_BACKENDS lists "${name}" but it is not configured; dropped`);
        } else {
            backends.push(backend.data);
        }
    }

    return { backends, defaultBackend: backends[0] ?? null, warnings };
}

/** The voice backends this server offers, from its environment. */
export function voiceBackendsCurrent(): VoiceBackendsResolved {
    return voiceBackendsResolve({
        voiceBackends: process.env.VOICE_BACKENDS,
        isLiveKitConfigured: voiceLiveKitConfig() !== null,
        isElevenLabsConfigured: Boolean(process.env.ELEVENLABS_API_KEY),
    });
}
