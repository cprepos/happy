import fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import { serializerCompiler, validatorCompiler, ZodTypeProvider } from "fastify-type-provider-zod";
import { TokenVerifier } from "livekit-server-sdk";
import {
    VOICE_UNLIMITED,
    VoiceConfigResponseSchema,
    VoiceConversationLiveKitGrantSchema,
    VoiceConversationResponseSchema,
    VoiceUsageResponseSchema,
} from "@slopus/happy-wire";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type Fastify } from "../types";

const { dbMock, warnMock } = vi.hoisted(() => ({
    warnMock: vi.fn(),
    dbMock: {
        voiceConversation: {
            create: vi.fn(),
            aggregate: vi.fn(),
        },
    },
}));

vi.mock("@/storage/db", () => ({ db: dbMock }));
vi.mock("@/utils/log", () => ({ log: vi.fn(), warn: warnMock }));

import { voiceRoutes } from "./voiceRoutes";

const userId = "voice-user";
const apiKey = "test-livekit-key";
const apiSecret = "test-livekit-secret-that-is-long-enough-for-hs256";

describe("voiceRoutes", () => {
    let app: Fastify;
    const fetchMock = vi.fn<typeof fetch>();

    async function startApp() {
        const started = fastify().withTypeProvider<ZodTypeProvider>();
        started.setValidatorCompiler(validatorCompiler);
        started.setSerializerCompiler(serializerCompiler);
        started.decorate("authenticate", async (request: FastifyRequest, reply: FastifyReply) => {
            const authenticatedUserId = request.headers["x-user-id"];
            if (typeof authenticatedUserId !== "string") {
                return reply.code(401).send({ error: "Unauthorized" });
            }
            request.userId = authenticatedUserId;
        });
        voiceRoutes(started);
        await started.ready();
        return started;
    }

    beforeEach(async () => {
        vi.stubEnv("LIVEKIT_API_KEY", apiKey);
        vi.stubEnv("LIVEKIT_API_SECRET", apiSecret);
        vi.stubEnv("LIVEKIT_PUBLIC_URL", undefined);
        vi.stubEnv("VOICE_BACKENDS", undefined);
        vi.stubEnv("ELEVENLABS_API_KEY", undefined);
        warnMock.mockReset();
        dbMock.voiceConversation.create.mockReset().mockResolvedValue({});
        dbMock.voiceConversation.aggregate.mockReset();
        // No provider is called any more; any network request is a bug.
        fetchMock.mockReset().mockRejectedValue(new Error("Unexpected network request"));
        vi.stubGlobal("fetch", fetchMock);

        app = await startApp();
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
        const body = VoiceConversationLiveKitGrantSchema.parse(response.json());
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
        const first = VoiceConversationLiveKitGrantSchema.parse((await requestConversation()).json());
        const second = VoiceConversationLiveKitGrantSchema.parse((await requestConversation()).json());
        expect(first.conversationId).not.toBe(second.conversationId);
        expect(first.roomName).not.toBe(second.roomName);
    });

    it("accepts the old client body and an empty body", async () => {
        const old = await requestConversation({ agentId: "legacy-agent" });
        expect(old.statusCode).toBe(200);
        expect(VoiceConversationLiveKitGrantSchema.parse(old.json()).allowed).toBe(true);
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
        const body = VoiceConversationLiveKitGrantSchema.parse((await requestConversation()).json());
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

    it("refuses a LiveKit grant when VOICE_BACKENDS leaves the stream out", async () => {
        vi.stubEnv("ELEVENLABS_API_KEY", "test-elevenlabs-key");
        vi.stubEnv("VOICE_BACKENDS", "elevenlabs");
        const response = await requestConversation();
        expect(response.statusCode).toBe(503);
        expect(response.json()).toEqual({ error: "Voice stream is not offered by this server" });
        expect(dbMock.voiceConversation.create).not.toHaveBeenCalled();
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

    describe("GET /v1/voice/config", () => {
        function requestConfig(authenticated = true) {
            return app.inject({
                method: "GET",
                url: "/v1/voice/config",
                headers: authenticated ? { "x-user-id": userId } : {},
            });
        }

        it("requires authentication", async () => {
            expect((await requestConfig(false)).statusCode).toBe(401);
        });

        it("offers what is configured, stream first", async () => {
            expect((await requestConfig()).json()).toEqual({ backends: ["stream"], defaultBackend: "stream" });

            vi.stubEnv("ELEVENLABS_API_KEY", "test-elevenlabs-key");
            const response = await requestConfig();
            expect(response.statusCode).toBe(200);
            expect(VoiceConfigResponseSchema.parse(response.json())).toEqual({
                backends: ["stream", "elevenlabs"],
                defaultBackend: "stream",
            });
        });

        it("follows VOICE_BACKENDS", async () => {
            vi.stubEnv("ELEVENLABS_API_KEY", "test-elevenlabs-key");
            vi.stubEnv("VOICE_BACKENDS", "elevenlabs,stream");
            expect((await requestConfig()).json()).toEqual({
                backends: ["elevenlabs", "stream"],
                defaultBackend: "elevenlabs",
            });
        });

        it("answers an empty list with a null default when nothing is offered", async () => {
            vi.stubEnv("LIVEKIT_API_KEY", undefined);
            const response = await requestConfig();
            expect(response.statusCode).toBe(200);
            expect(response.json()).toEqual({ backends: [], defaultBackend: null });
        });

        it("warns about a dropped backend at startup and not on each request", async () => {
            expect(warnMock).not.toHaveBeenCalled();

            vi.stubEnv("VOICE_BACKENDS", "stream,elevenlabs,livekit");
            const started = await startApp();
            try {
                expect(warnMock.mock.calls.map(([, message]) => message)).toEqual([
                    'VOICE_BACKENDS lists "elevenlabs" but it is not configured; dropped',
                    'VOICE_BACKENDS lists unknown backend "livekit"; dropped',
                ]);
                await started.inject({ method: "GET", url: "/v1/voice/config", headers: { "x-user-id": userId } });
                expect(warnMock).toHaveBeenCalledTimes(2);
            } finally {
                await started.close();
            }
        });
    });
});
