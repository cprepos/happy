import { AccessToken, RoomAgentDispatch, RoomConfiguration } from "livekit-server-sdk";

/** Agent name the voice worker registers with; the token dispatches it into the room. */
export const VOICE_AGENT_NAME = "happy-voice";

/** Lifetime of a voice room token. It only needs to outlive the join. */
export const VOICE_TOKEN_TTL_SECONDS = 15 * 60;

export const DEFAULT_LIVEKIT_PUBLIC_URL = "wss://livekit.girthbass.duckdns.org";

export interface LiveKitConfig {
    apiKey: string;
    apiSecret: string;
    publicUrl: string;
}

/**
 * Reads the LiveKit settings from the environment. Returns null when the key
 * or secret is missing, so the caller can answer with a clear error.
 */
export function voiceLiveKitConfig(): LiveKitConfig | null {
    const apiKey = process.env.LIVEKIT_API_KEY;
    const apiSecret = process.env.LIVEKIT_API_SECRET;
    if (!apiKey || !apiSecret) {
        return null;
    }
    return {
        apiKey,
        apiSecret,
        publicUrl: process.env.LIVEKIT_PUBLIC_URL || DEFAULT_LIVEKIT_PUBLIC_URL,
    };
}

/**
 * Mints a LiveKit access token for an account to join one voice room.
 * Identity is `user-<accountId>`; the user may join, publish, subscribe and
 * send data in that room only. The room configuration dispatches the
 * `happy-voice` agent worker when the room is created.
 */
export async function voiceTokenCreate(
    config: LiveKitConfig,
    accountId: string,
    roomName: string,
): Promise<string> {
    const token = new AccessToken(config.apiKey, config.apiSecret, {
        identity: `user-${accountId}`,
        ttl: VOICE_TOKEN_TTL_SECONDS,
    });
    token.addGrant({
        room: roomName,
        roomJoin: true,
        canPublish: true,
        canSubscribe: true,
        canPublishData: true,
    });
    token.roomConfig = new RoomConfiguration({
        agents: [new RoomAgentDispatch({ agentName: VOICE_AGENT_NAME })],
    });
    return await token.toJwt();
}
