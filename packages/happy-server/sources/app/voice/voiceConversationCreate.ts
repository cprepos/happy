import { randomUUID } from "node:crypto";
import { db } from "@/storage/db";

/**
 * Records a new voice conversation for an account and returns its id and
 * LiveKit room name. Every call creates a new conversation with a fresh room
 * (`happy-voice-<conversationId>`), so a client retry gets its own room and
 * never joins a room minted for someone else. There is no quota.
 */
export async function voiceConversationCreate(
    accountId: string,
    options: { sessionId?: string; language?: string },
): Promise<{ conversationId: string; roomName: string }> {
    const conversationId = randomUUID();
    const roomName = `happy-voice-${conversationId}`;
    await db.voiceConversation.create({
        data: {
            id: conversationId,
            accountId,
            roomName,
            sessionId: options.sessionId ?? null,
            language: options.language ?? null,
        },
    });
    return { conversationId, roomName };
}
