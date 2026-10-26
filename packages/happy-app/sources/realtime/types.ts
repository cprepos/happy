/**
 * What the voice agent receives when it asks for its configuration
 * (RPC `happy.getConfig`): every field here is sent as JSON.
 */
export interface VoiceSessionConfig {
    sessionId: string;
    initialContext?: string;
    systemPrompt?: string;
    firstMessage?: string;
    /** ISO language code such as `en`; absent means auto-detect. */
    language?: string;
    /** Kokoro voice or blend (see voiceCatalog.ts); absent means the server default. */
    voice?: string;
    /** Kokoro speed multiplier; absent means the server default. */
    speed?: number;
}

export interface VoiceSession {
    /**
     * Called synchronously from the user gesture that starts voice, before
     * anything is awaited (Safari only lets audio start inside the gesture).
     */
    prepare?(): void;
    startSession(config: VoiceSessionConfig): Promise<string | null>;
    endSession(): Promise<void>;
    sendTextMessage(message: string): void;
    sendContextualUpdate(update: string): void;
}

export type ConversationStatus = 'disconnected' | 'connecting' | 'connected';
export type ConversationMode = 'idle' | 'agent-speaking' | 'user-speaking';
