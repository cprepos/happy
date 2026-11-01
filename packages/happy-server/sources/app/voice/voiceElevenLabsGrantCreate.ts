import * as privacyKit from "privacy-kit";
import type { VoiceConversationDenied, VoiceConversationElevenLabsGrant } from "@slopus/happy-wire";
import { log } from "@/utils/log";
import { voiceSubscriptionCheck } from "@/app/voice/voiceSubscriptionCheck";
import {
    ELEVEN_LABS_API,
    VOICE_FREE_LIMIT_SECONDS,
    VOICE_HARD_LIMIT_SECONDS,
    voiceElevenLabsUsageGet,
    voiceElevenLabsUserId,
} from "@/app/voice/voiceElevenLabsUsageGet";

/**
 * Decides whether a user may start ElevenLabs agent `agentId` and, if so, gets
 * the conversation token. Past the hard limit voice is denied; past the free
 * limit it needs an active subscription. The conversation id is read from the
 * token, whose LiveKit room name contains it.
 *
 * A provider failure returns `{ error }`, and no token is ever issued on unknown
 * usage.
 */
export async function voiceElevenLabsGrantCreate(
    elevenLabsApiKey: string,
    userId: string,
    agentId: string,
): Promise<VoiceConversationElevenLabsGrant | VoiceConversationDenied | { error: string }> {
    const elevenUserId = voiceElevenLabsUserId(userId);

    let usage: Awaited<ReturnType<typeof voiceElevenLabsUsageGet>>;
    try {
        usage = await voiceElevenLabsUsageGet(elevenLabsApiKey, elevenUserId);
    } catch (error) {
        log({ module: 'voice' }, `Failed to get voice usage for user ${userId}: ${error}`);
        return { error: 'Failed to get voice usage' };
    }
    const { usedSeconds, conversationCount } = usage;
    log({ module: 'voice' }, `User ${userId}: ${usedSeconds}s used, ${conversationCount} convos (free=${VOICE_FREE_LIMIT_SECONDS}s, hard=${VOICE_HARD_LIMIT_SECONDS}s)`);

    if (usedSeconds >= VOICE_HARD_LIMIT_SECONDS) {
        return {
            allowed: false,
            reason: 'voice_hard_limit_reached',
            usedSeconds,
            limitSeconds: VOICE_HARD_LIMIT_SECONDS,
            agentId,
        };
    }

    if (usedSeconds >= VOICE_FREE_LIMIT_SECONDS) {
        const subscribed = await voiceSubscriptionCheck(userId);
        log({ module: 'voice' }, `User ${userId}: subscription check = ${subscribed}`);
        if (!subscribed) {
            return {
                allowed: false,
                reason: 'subscription_required',
                usedSeconds,
                limitSeconds: VOICE_FREE_LIMIT_SECONDS,
                agentId,
            };
        }
    }

    try {
        // `agentId` comes from the client: encoded, it cannot add query
        // parameters, such as a second participant_name to dodge the usage count.
        const tokenRes = await fetch(
            `${ELEVEN_LABS_API}/conversation/token?agent_id=${encodeURIComponent(agentId)}&participant_name=${elevenUserId}`,
            { headers: { 'xi-api-key': elevenLabsApiKey } }
        );

        if (!tokenRes.ok) {
            log({ module: 'voice' }, `Failed to get conversation token for user ${userId}: ${tokenRes.status}`);
            return { error: 'Failed to get voice credentials' };
        }

        const { token: conversationToken } = (await tokenRes.json()) as { token: string };

        const jwtPayload = JSON.parse(privacyKit.decodeUTF8(privacyKit.decodeBase64(conversationToken.split('.')[1], 'base64url')));
        const conversationId = (jwtPayload.video?.room || '').match(/(conv_[a-zA-Z0-9]+)/)?.[0];

        if (!conversationId) {
            log({ module: 'voice' }, `No conversation_id in JWT for user ${userId}`);
            return { error: 'Failed to get conversation ID' };
        }

        log({ module: 'voice' }, `Voice token issued for user ${userId}, conv=${conversationId}`);
        return {
            allowed: true,
            conversationToken,
            conversationId,
            agentId,
            elevenUserId,
            usedSeconds,
            limitSeconds: usedSeconds >= VOICE_FREE_LIMIT_SECONDS ? VOICE_HARD_LIMIT_SECONDS : VOICE_FREE_LIMIT_SECONDS,
        };
    } catch (error) {
        log({ module: 'voice' }, `ElevenLabs request error for user ${userId}: ${error}`);
        return { error: 'Failed to get voice credentials' };
    }
}
