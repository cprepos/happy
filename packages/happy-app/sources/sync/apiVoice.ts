import { z } from 'zod';
import {
    VoiceUsageResponseSchema,
    type VoiceUsageResponse,
} from '@slopus/happy-wire';
import { AuthCredentials } from '@/auth/tokenStorage';
import { getVoiceServerUrl } from './serverConfig';
import { getHappyClientId } from './apiSocket';

export type { VoiceUsageResponse };

/**
 * Response of `POST /v1/voice/conversations`: a LiveKit access token for a
 * fresh room with the voice agent dispatched to it. The `allowed: false`
 * variant is kept so an older server's refusal surfaces as an error instead
 * of a parse failure.
 */
const VoiceConversationGrantSchema = z.object({
    allowed: z.literal(true),
    conversationId: z.string().min(1),
    roomName: z.string().optional(),
    token: z.string().min(1),
    url: z.string().min(1),
});

const VoiceConversationRefusalSchema = z.object({
    allowed: z.literal(false),
    reason: z.string().optional(),
});

const VoiceConversationResponseSchema = z.discriminatedUnion('allowed', [
    VoiceConversationGrantSchema,
    VoiceConversationRefusalSchema,
]);

export type VoiceConversationGrant = z.infer<typeof VoiceConversationGrantSchema>;
export type VoiceConversationResponse = z.infer<typeof VoiceConversationResponseSchema>;

/**
 * Asks the server for a LiveKit room token. Voice always goes to the same
 * server as everything else, with the same credentials.
 */
export async function fetchVoiceCredentials(
    credentials: AuthCredentials,
    sessionId: string,
    language?: string,
): Promise<VoiceConversationResponse> {
    const serverUrl = getVoiceServerUrl();

    const response = await fetch(`${serverUrl}/v1/voice/conversations`, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${credentials.token}`,
            'Content-Type': 'application/json',
            'X-Happy-Client': getHappyClientId(),
        },
        body: JSON.stringify({
            sessionId,
            ...(language ? { language } : {}),
        }),
    });

    if (!response.ok) {
        throw new Error(`Voice token request failed: ${response.status}`);
    }

    return VoiceConversationResponseSchema.parse(await response.json());
}

export async function fetchVoiceUsage(
    credentials: AuthCredentials
): Promise<VoiceUsageResponse> {
    const serverUrl = getVoiceServerUrl();

    const response = await fetch(`${serverUrl}/v1/voice/usage`, {
        method: 'GET',
        headers: {
            'Authorization': `Bearer ${credentials.token}`,
            'X-Happy-Client': getHappyClientId(),
        },
    });

    if (!response.ok) {
        throw new Error(`Voice usage request failed: ${response.status}`);
    }

    return VoiceUsageResponseSchema.parse(await response.json());
}
