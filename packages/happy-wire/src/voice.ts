import * as z from 'zod';

/**
 * How a client reaches voice on a server.
 * - `stream`: audio over the `/v1/voice/stream` WebSocket; the server handles LiveKit.
 * - `elevenlabs`: the client joins ElevenLabs with a grant from `POST /v1/voice/conversations`.
 */
export const VoiceBackendSchema = z.enum(['stream', 'elevenlabs']);

export type VoiceBackend = z.infer<typeof VoiceBackendSchema>;

/**
 * Response of `GET /v1/voice/config`: the backends this server offers, and the
 * one clients use unless the user chose another. A server offering none answers
 * `{ backends: [], defaultBackend: null }`.
 */
export const VoiceConfigResponseSchema = z.object({
    backends: z.array(VoiceBackendSchema),
    defaultBackend: VoiceBackendSchema.nullable(),
});

export type VoiceConfigResponse = z.infer<typeof VoiceConfigResponseSchema>;

/**
 * Request body of `POST /v1/voice/conversations`. With `agentId` the request is
 * for an ElevenLabs grant; without it, for a LiveKit grant.
 */
export const VoiceConversationRequestSchema = z.object({
    sessionId: z.string().optional(),
    language: z.string().optional(),
    agentId: z.string().optional(),
});

export type VoiceConversationRequest = z.infer<typeof VoiceConversationRequestSchema>;

/**
 * Voice is allowed: join LiveKit room `roomName` at `url` with `token`.
 * The token dispatches the `happy-voice` agent worker into the room.
 */
export const VoiceConversationLiveKitGrantSchema = z.object({
    allowed: z.literal(true),
    conversationId: z.string(),
    roomName: z.string(),
    token: z.string(),
    url: z.string(),
});

/**
 * Voice is allowed: start ElevenLabs agent `agentId` with `conversationToken`.
 * `elevenUserId` is the identity the conversation is recorded under, and the
 * seconds are this user's usage and current limit.
 */
export const VoiceConversationElevenLabsGrantSchema = z.object({
    allowed: z.literal(true),
    conversationToken: z.string(),
    conversationId: z.string(),
    agentId: z.string(),
    elevenUserId: z.string(),
    usedSeconds: z.number(),
    limitSeconds: z.number(),
});

// Both grants have `allowed: true`, so these are plain unions: a discriminated
// union needs a different `allowed` value for each option.
export const VoiceConversationGrantedSchema = z.union([
    VoiceConversationLiveKitGrantSchema,
    VoiceConversationElevenLabsGrantSchema,
]);

/** ElevenLabs voice is refused: the user reached a limit of that backend. */
export const VoiceConversationDeniedSchema = z.object({
    allowed: z.literal(false),
    reason: z.enum(['voice_hard_limit_reached', 'subscription_required', 'voice_conversation_limit_reached']),
    usedSeconds: z.number(),
    limitSeconds: z.number(),
    agentId: z.string(),
});

export const VoiceConversationResponseSchema = z.union([
    VoiceConversationLiveKitGrantSchema,
    VoiceConversationElevenLabsGrantSchema,
    VoiceConversationDeniedSchema,
]);

export type VoiceConversationLiveKitGrant = z.infer<typeof VoiceConversationLiveKitGrantSchema>;
export type VoiceConversationElevenLabsGrant = z.infer<typeof VoiceConversationElevenLabsGrantSchema>;
export type VoiceConversationDenied = z.infer<typeof VoiceConversationDeniedSchema>;
export type VoiceConversationGranted = z.infer<typeof VoiceConversationGrantedSchema>;
export type VoiceConversationResponse = z.infer<typeof VoiceConversationResponseSchema>;

/**
 * Response of `GET /v1/voice/usage`. When the server offers ElevenLabs these are
 * that backend's usage and limits, and `elevenUserId` is the ElevenLabs identity.
 * Otherwise voice is unlimited: `limitSeconds` and `conversationLimit` are
 * `VOICE_UNLIMITED`, and `elevenUserId` is a legacy field name carrying the
 * LiveKit identity (`user-<accountId>`).
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
