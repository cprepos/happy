import * as crypto from "crypto";

/** 20 minutes free per 30 days. */
export const VOICE_FREE_LIMIT_SECONDS = 1200;
/** 5 hours absolute cap per 30 days, even with a subscription. */
export const VOICE_HARD_LIMIT_SECONDS = 18000;
/** ElevenLabs' maximum page size, not a conversation quota. */
export const VOICE_USAGE_PAGE_SIZE = 100;
export const ELEVEN_LABS_API = "https://api.elevenlabs.io/v1/convai";

/**
 * The account's identity at ElevenLabs: a hash keyed with the master secret, so
 * ElevenLabs never sees the account id.
 */
export function voiceElevenLabsUserId(accountId: string): string {
    const digest = crypto.createHmac("sha256", process.env.HANDY_MASTER_SECRET!).update(accountId).digest("base64url");
    return `u_${digest}`;
}

/**
 * Gets a user's voice usage over the last 30 days, across all agents, from
 * ElevenLabs by the user id set when the token is minted. ElevenLabs is the
 * source of truth; nothing is stored locally.
 *
 * Pages through the history, stopping once the hard duration limit is reached,
 * so above it the numbers are lower bounds. Throws on a failed request or on
 * malformed history, so a caller never acts on partial usage.
 */
export async function voiceElevenLabsUsageGet(
    elevenLabsApiKey: string,
    elevenUserId: string,
): Promise<{ usedSeconds: number; conversationCount: number }> {
    const thirtyDaysAgo = Math.floor(Date.now() / 1000) - 30 * 86400;

    let usedSeconds = 0;
    let conversationCount = 0;
    let cursor: string | undefined;
    const seenCursors = new Set<string>();
    const signal = AbortSignal.timeout(15_000);

    do {
        const query = new URLSearchParams({
            user_id: elevenUserId,
            call_start_after_unix: String(thirtyDaysAgo),
            page_size: String(VOICE_USAGE_PAGE_SIZE),
        });
        if (cursor) query.set("cursor", cursor);
        const res = await fetch(`${ELEVEN_LABS_API}/conversations?${query}`, {
            headers: { "xi-api-key": elevenLabsApiKey },
            // Bridge the conflicting Node/undici AbortSignal declarations,
            // as in pushSend; at runtime these refer to the same native signal.
            signal: signal as unknown as RequestInit["signal"],
        });
        if (!res.ok) {
            throw new Error(`ElevenLabs conversations query failed: ${res.status}`);
        }

        const data = (await res.json()) as {
            conversations?: Array<{ call_duration_secs?: number | null }>;
            has_more?: boolean;
            next_cursor?: string | null;
        };
        if (!Array.isArray(data.conversations) || typeof data.has_more !== "boolean") {
            throw new Error("Invalid ElevenLabs conversation history");
        }
        for (const conversation of data.conversations) {
            const duration = conversation.call_duration_secs ?? 0;
            if (!Number.isFinite(duration) || duration < 0) {
                throw new Error("Invalid ElevenLabs conversation duration");
            }
            usedSeconds += duration;
        }
        conversationCount += data.conversations.length;

        // Once the actual duration quota is reached, further history cannot allow voice.
        if (usedSeconds >= VOICE_HARD_LIMIT_SECONDS || !data.has_more) break;
        if (!data.next_cursor || typeof data.next_cursor !== "string" || seenCursors.has(data.next_cursor)) {
            throw new Error("Invalid ElevenLabs conversation history cursor");
        }
        seenCursors.add(data.next_cursor);
        cursor = data.next_cursor;
    } while (cursor);

    return { usedSeconds, conversationCount };
}
