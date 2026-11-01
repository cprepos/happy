import { z } from "zod";
import {
    VOICE_UNLIMITED,
    VoiceConfigResponseSchema,
    VoiceConversationRequestSchema,
    VoiceConversationResponseSchema,
    VoiceUsageResponseSchema,
} from "@slopus/happy-wire";
import { type Fastify } from "../types";
import { db } from "@/storage/db";
import { log, warn } from "@/utils/log";
import { voiceBackendsCurrent } from "@/app/voice/voiceBackendsResolve";
import { voiceConversationCreate } from "@/app/voice/voiceConversationCreate";
import { voiceElevenLabsGrantCreate } from "@/app/voice/voiceElevenLabsGrantCreate";
import {
    VOICE_FREE_LIMIT_SECONDS,
    VOICE_HARD_LIMIT_SECONDS,
    VOICE_USAGE_PAGE_SIZE,
    voiceElevenLabsUsageGet,
    voiceElevenLabsUserId,
} from "@/app/voice/voiceElevenLabsUsageGet";
import { voiceSubscriptionCheck } from "@/app/voice/voiceSubscriptionCheck";
import { voiceLiveKitConfig, voiceTokenCreate } from "@/app/voice/voiceTokenCreate";

const USAGE_WINDOW_MS = 30 * 24 * 60 * 60 * 1000;

export function voiceRoutes(app: Fastify) {
    for (const warning of voiceBackendsCurrent().warnings) {
        warn({ module: 'voice' }, warning);
    }

    /**
     * The voice backends this server offers and the one clients use by default.
     */
    app.get('/v1/voice/config', {
        preHandler: app.authenticate,
        schema: {
            response: {
                200: VoiceConfigResponseSchema,
            },
        },
    }, async (_request, reply) => {
        const { backends, defaultBackend } = voiceBackendsCurrent();
        return reply.send({ backends, defaultBackend });
    });

    /**
     * Starts a voice conversation, the backend chosen by the request.
     *
     * With `agentId`: an ElevenLabs grant, subject to that backend's usage limits.
     * If ElevenLabs isn't offered this is an error, never a LiveKit grant.
     *
     * Without it: records the conversation and returns a LiveKit token for its
     * own room. The token dispatches the `happy-voice` agent worker. Voice is
     * self-hosted, so there is no paywall and no quota.
     */
    app.post('/v1/voice/conversations', {
        preHandler: app.authenticate,
        schema: {
            body: VoiceConversationRequestSchema.nullish(),
            response: {
                200: VoiceConversationResponseSchema,
                500: z.object({ error: z.string() }),
                503: z.object({ error: z.string() }),
            },
        },
    }, async (request, reply) => {
        const userId = request.userId;
        const { sessionId, language, agentId } = request.body ?? {};

        if (agentId !== undefined) {
            log({ module: 'voice' }, `Voice token request from user ${userId}`);
            const elevenLabsApiKey = process.env.ELEVENLABS_API_KEY;
            if (!elevenLabsApiKey) {
                return reply.code(500).send({ error: 'ELEVENLABS_API_KEY not configured' });
            }
            if (!voiceBackendsCurrent().backends.includes('elevenlabs')) {
                return reply.code(503).send({ error: 'ElevenLabs is not offered by this server' });
            }
            const result = await voiceElevenLabsGrantCreate(elevenLabsApiKey, userId, agentId);
            if ('error' in result) {
                return reply.code(500).send(result);
            }
            return reply.send(result);
        }

        const liveKit = voiceLiveKitConfig();
        if (!liveKit) {
            log({ module: 'voice' }, 'LIVEKIT_API_KEY / LIVEKIT_API_SECRET not configured');
            return reply.code(500).send({ error: 'LiveKit is not configured' });
        }
        if (!voiceBackendsCurrent().backends.includes('stream')) {
            return reply.code(503).send({ error: 'Voice stream is not offered by this server' });
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
     * Voice usage over the last 30 days. When ElevenLabs is offered, its numbers
     * and limits, queried from ElevenLabs. Otherwise from the recorded
     * conversations: voice is unlimited, so both limits are VOICE_UNLIMITED; the
     * shape is kept for the settings screen.
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

        const elevenLabsApiKey = process.env.ELEVENLABS_API_KEY;
        if (elevenLabsApiKey && voiceBackendsCurrent().backends.includes('elevenlabs')) {
            const elevenUserId = voiceElevenLabsUserId(userId);
            try {
                const [{ usedSeconds, conversationCount }, subscribed] = await Promise.all([
                    voiceElevenLabsUsageGet(elevenLabsApiKey, elevenUserId),
                    voiceSubscriptionCheck(userId),
                ]);
                return reply.send({
                    usedSeconds,
                    limitSeconds: subscribed ? VOICE_HARD_LIMIT_SECONDS : VOICE_FREE_LIMIT_SECONDS,
                    conversationCount,
                    // Legacy display field required by shipped clients; page size no longer gates voice.
                    conversationLimit: VOICE_USAGE_PAGE_SIZE,
                    elevenUserId,
                });
            } catch (error) {
                log({ module: 'voice' }, `Failed to get voice usage for user ${userId}: ${error}`);
                return reply.code(500).send({ error: 'Failed to get voice usage' });
            }
        }

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
