import * as z from 'zod';

/**
 * Request body of `POST /v1/voice/conversations`.
 * Unknown fields (such as the `agentId` older clients send) are ignored.
 */
export const VoiceConversationRequestSchema = z.object({
    sessionId: z.string().optional(),
    language: z.string().optional(),
});

export type VoiceConversationRequest = z.infer<typeof VoiceConversationRequestSchema>;

/**
 * Voice is allowed: join LiveKit room `roomName` at `url` with `token`.
 * The token dispatches the `happy-voice` agent worker into the room.
 */
export const VoiceConversationGrantedSchema = z.object({
    allowed: z.literal(true),
    conversationId: z.string(),
    roomName: z.string(),
    token: z.string(),
    url: z.string(),
});

/**
 * Kept for compatibility with older clients and servers. The self-hosted
 * server has no quota or paywall and never sends it.
 */
export const VoiceConversationDeniedSchema = z.object({
    allowed: z.literal(false),
    reason: z.enum(['voice_hard_limit_reached', 'subscription_required', 'voice_conversation_limit_reached']),
    usedSeconds: z.number(),
    limitSeconds: z.number(),
    agentId: z.string(),
});

export const VoiceConversationResponseSchema = z.discriminatedUnion('allowed', [
    VoiceConversationGrantedSchema,
    VoiceConversationDeniedSchema,
]);

export type VoiceConversationGranted = z.infer<typeof VoiceConversationGrantedSchema>;
export type VoiceConversationResponse = z.infer<typeof VoiceConversationResponseSchema>;

/**
 * Response of `GET /v1/voice/usage`. Voice is unlimited, so `limitSeconds` and
 * `conversationLimit` are `VOICE_UNLIMITED`; `elevenUserId` is a legacy field
 * name and carries the LiveKit identity (`user-<accountId>`).
 */
export const VoiceUsageResponseSchema = z.object({
    usedSeconds: z.number(),
    limitSeconds: z.number(),
    conversationCount: z.number(),
    conversationLimit: z.number(),
    elevenUserId: z.string(),
});

export type VoiceUsageResponse = z.infer<typeof VoiceUsageResponseSchema>;

/** Limit value meaning "no limit" in `VoiceUsageResponse`. */
export const VOICE_UNLIMITED = Number.MAX_SAFE_INTEGER;
