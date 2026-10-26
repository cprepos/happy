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
