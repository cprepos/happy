import { z } from "zod";
import {
    VOICE_UNLIMITED,
    VoiceConversationRequestSchema,
    VoiceConversationResponseSchema,
    VoiceUsageResponseSchema,
} from "@slopus/happy-wire";
import { type Fastify } from "../types";
import { db } from "@/storage/db";
import { log } from "@/utils/log";
import { voiceConversationCreate } from "@/app/voice/voiceConversationCreate";
import { voiceLiveKitConfig, voiceTokenCreate } from "@/app/voice/voiceTokenCreate";

const USAGE_WINDOW_MS = 30 * 24 * 60 * 60 * 1000;

export function voiceRoutes(app: Fastify) {
    /**
     * Starts a voice conversation: records it and returns a LiveKit token for
     * its own room. The token dispatches the `happy-voice` agent worker.
     * Voice is self-hosted, so there is no paywall and no quota.
     */
    app.post('/v1/voice/conversations', {
        preHandler: app.authenticate,
        schema: {
            // Unknown fields (the agentId older clients send) are stripped.
            body: VoiceConversationRequestSchema.nullish(),
            response: {
                200: VoiceConversationResponseSchema,
                500: z.object({ error: z.string() }),
            },
        },
    }, async (request, reply) => {
        const userId = request.userId;
        const { sessionId, language } = request.body ?? {};

        const liveKit = voiceLiveKitConfig();
        if (!liveKit) {
            log({ module: 'voice' }, 'LIVEKIT_API_KEY / LIVEKIT_API_SECRET not configured');
            return reply.code(500).send({ error: 'LiveKit is not configured' });
        }

        try {
            const { conversationId, roomName } = await voiceConversationCreate(userId, { sessionId, language });
            const token = await voiceTokenCreate(liveKit, userId, roomName);
            log({ module: 'voice' }, `Voice room ${roomName} issued for user ${userId}`);
            return reply.send({
                allowed: true as const,
                conversationId,
                roomName,
                token,
                url: liveKit.publicUrl,
            });
        } catch (error) {
            log({ module: 'voice' }, `Failed to start voice conversation for user ${userId}: ${error}`);
            return reply.code(500).send({ error: 'Failed to start voice conversation' });
        }
    });

    /**
     * Voice usage over the last 30 days. Voice is unlimited, so both limits are
     * VOICE_UNLIMITED; the shape is kept for the settings screen.
     */
    app.get('/v1/voice/usage', {
        preHandler: app.authenticate,
        schema: {
            response: {
                200: VoiceUsageResponseSchema,
                500: z.object({ error: z.string() }),
            },
        },
    }, async (request, reply) => {
        const userId = request.userId;
        try {
            const usage = await db.voiceConversation.aggregate({
                where: {
                    accountId: userId,
                    createdAt: { gte: new Date(Date.now() - USAGE_WINDOW_MS) },
                },
                _count: { _all: true },
                _sum: { durationSecs: true },
            });
            return reply.send({
                usedSeconds: usage._sum.durationSecs ?? 0,
                limitSeconds: VOICE_UNLIMITED,
                conversationCount: usage._count._all,
                conversationLimit: VOICE_UNLIMITED,
                // Legacy field name; carries the LiveKit identity.
                elevenUserId: `user-${userId}`,
            });
        } catch (error) {
            log({ module: 'voice' }, `Failed to get voice usage for user ${userId}: ${error}`);
            return reply.code(500).send({ error: 'Failed to get voice usage' });
        }
    });
}
