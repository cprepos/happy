import fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import { serializerCompiler, validatorCompiler, ZodTypeProvider } from "fastify-type-provider-zod";
import { TokenVerifier } from "livekit-server-sdk";
import {
    VOICE_UNLIMITED,
    VoiceConversationGrantedSchema,
    VoiceConversationResponseSchema,
    VoiceUsageResponseSchema,
} from "@slopus/happy-wire";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type Fastify } from "../types";

const { dbMock } = vi.hoisted(() => ({
    dbMock: {
        voiceConversation: {
            create: vi.fn(),
            aggregate: vi.fn(),
        },
    },
}));

vi.mock("@/storage/db", () => ({ db: dbMock }));

import { voiceRoutes } from "./voiceRoutes";

const userId = "voice-user";
const apiKey = "test-livekit-key";
const apiSecret = "test-livekit-secret-that-is-long-enough-for-hs256";

describe("voiceRoutes", () => {
    let app: Fastify;
    const fetchMock = vi.fn<typeof fetch>();

    beforeEach(async () => {
        vi.stubEnv("LIVEKIT_API_KEY", apiKey);
        vi.stubEnv("LIVEKIT_API_SECRET", apiSecret);
        vi.stubEnv("LIVEKIT_PUBLIC_URL", undefined);
        dbMock.voiceConversation.create.mockReset().mockResolvedValue({});
        dbMock.voiceConversation.aggregate.mockReset();
        // No provider is called any more; any network request is a bug.
        fetchMock.mockReset().mockRejectedValue(new Error("Unexpected network request"));
        vi.stubGlobal("fetch", fetchMock);

        app = fastify().withTypeProvider<ZodTypeProvider>();
        app.setValidatorCompiler(validatorCompiler);
        app.setSerializerCompiler(serializerCompiler);
        app.decorate("authenticate", async (request: FastifyRequest, reply: FastifyReply) => {
            const authenticatedUserId = request.headers["x-user-id"];
            if (typeof authenticatedUserId !== "string") {
                return reply.code(401).send({ error: "Unauthorized" });
            }
            request.userId = authenticatedUserId;
        });
        voiceRoutes(app);
        await app.ready();
    });

    afterEach(async () => {
        await app.close();
        vi.unstubAllGlobals();
        vi.unstubAllEnvs();
    });

    function requestConversation(payload: unknown = {}, authenticated = true) {
        return app.inject({
            method: "POST",
            url: "/v1/voice/conversations",
            headers: authenticated ? { "x-user-id": userId } : {},
            payload: payload as object,
        });
    }

    it("mints a LiveKit token for the conversation's own room with the happy-voice agent dispatch", async () => {
        const startedAt = Math.floor(Date.now() / 1000);
        const response = await requestConversation({ sessionId: "session-1", language: "en" });

        expect(response.statusCode).toBe(200);
        const body = VoiceConversationGrantedSchema.parse(response.json());
        expect(VoiceConversationResponseSchema.parse(response.json())).toEqual(body);
        expect(Object.keys(response.json()).sort()).toEqual(["allowed", "conversationId", "roomName", "token", "url"]);
        expect(body.roomName).toBe(`happy-voice-${body.conversationId}`);
        expect(body.url).toBe("wss://livekit.girthbass.duckdns.org");

        // Signature must verify with the server's secret.
        const claims = await new TokenVerifier(apiKey, apiSecret).verify(body.token);
        expect(claims.iss).toBe(apiKey);
        expect(claims.sub).toBe(`user-${userId}`);
        expect(claims.video).toEqual({
            room: body.roomName,
            roomJoin: true,
            canPublish: true,
            canSubscribe: true,
            canPublishData: true,
        });
        expect(claims.roomConfig?.agents.map((agent) => agent.agentName)).toEqual(["happy-voice"]);
        const exp = (claims as { exp?: number }).exp!;
        expect(exp - startedAt).toBeGreaterThanOrEqual(15 * 60 - 5);
        expect(exp - startedAt).toBeLessThanOrEqual(15 * 60 + 5);

        expect(dbMock.voiceConversation.create).toHaveBeenCalledWith({
            data: {
                id: body.conversationId,
                accountId: userId,
                roomName: body.roomName,
                sessionId: "session-1",
                language: "en",
            },
        });
        expect(fetchMock).not.toHaveBeenCalled();
    });

    it("gives every request its own conversation and room", async () => {
        const first = VoiceConversationGrantedSchema.parse((await requestConversation()).json());
        const second = VoiceConversationGrantedSchema.parse((await requestConversation()).json());
        expect(first.conversationId).not.toBe(second.conversationId);
        expect(first.roomName).not.toBe(second.roomName);
    });

    it("accepts the old client body and an empty body", async () => {
        const old = await requestConversation({ agentId: "legacy-agent" });
        expect(old.statusCode).toBe(200);
        expect(VoiceConversationGrantedSchema.parse(old.json()).allowed).toBe(true);
        expect(dbMock.voiceConversation.create).toHaveBeenLastCalledWith({
            data: expect.objectContaining({ sessionId: null, language: null }),
        });

        const empty = await app.inject({
            method: "POST",
            url: "/v1/voice/conversations",
            headers: { "x-user-id": userId },
        });
        expect(empty.statusCode).toBe(200);
    });

    it("uses LIVEKIT_PUBLIC_URL when set", async () => {
        vi.stubEnv("LIVEKIT_PUBLIC_URL", "wss://livekit.example.test");
        const body = VoiceConversationGrantedSchema.parse((await requestConversation()).json());
        expect(body.url).toBe("wss://livekit.example.test");
    });

    it("fails clearly when LiveKit keys are missing", async () => {
        vi.stubEnv("LIVEKIT_API_SECRET", undefined);
        const response = await requestConversation();
        expect(response.statusCode).toBe(500);
        expect(response.json()).toEqual({ error: "LiveKit is not configured" });
        expect(dbMock.voiceConversation.create).not.toHaveBeenCalled();
    });

    it("fails when the conversation cannot be recorded", async () => {
        dbMock.voiceConversation.create.mockRejectedValueOnce(new Error("db down"));
        const response = await requestConversation();
        expect(response.statusCode).toBe(500);
        expect(response.json()).toEqual({ error: "Failed to start voice conversation" });
    });

    it("requires authentication", async () => {
        const response = await requestConversation({}, false);
        expect(response.statusCode).toBe(401);
        expect(dbMock.voiceConversation.create).not.toHaveBeenCalled();
    });

    it("reports unlimited usage in the existing shape", async () => {
        dbMock.voiceConversation.aggregate.mockResolvedValueOnce({
            _count: { _all: 3 },
            _sum: { durationSecs: 42 },
        });
        const response = await app.inject({
            method: "GET",
            url: "/v1/voice/usage",
            headers: { "x-user-id": userId },
        });
        expect(response.statusCode).toBe(200);
        expect(VoiceUsageResponseSchema.parse(response.json())).toEqual({
            usedSeconds: 42,
            limitSeconds: VOICE_UNLIMITED,
            conversationCount: 3,
            conversationLimit: VOICE_UNLIMITED,
            elevenUserId: `user-${userId}`,
        });
        const where = dbMock.voiceConversation.aggregate.mock.calls[0][0].where;
        expect(where.accountId).toBe(userId);
    });

    it("reports zero usage when no durations are known", async () => {
        dbMock.voiceConversation.aggregate.mockResolvedValueOnce({
            _count: { _all: 0 },
            _sum: { durationSecs: null },
        });
        const response = await app.inject({
            method: "GET",
            url: "/v1/voice/usage",
            headers: { "x-user-id": userId },
        });
        expect(response.json()).toMatchObject({ usedSeconds: 0, conversationCount: 0 });
    });
});
