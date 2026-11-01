import { createHmac } from "crypto";
import fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import { serializerCompiler, validatorCompiler, ZodTypeProvider } from "fastify-type-provider-zod";
import { TokenVerifier } from "livekit-server-sdk";
import {
    VOICE_UNLIMITED,
    VoiceConfigResponseSchema,
    VoiceConversationElevenLabsGrantSchema,
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

    it("accepts an empty body", async () => {
        const empty = await app.inject({
            method: "POST",
            url: "/v1/voice/conversations",
            headers: { "x-user-id": userId },
        });
        expect(empty.statusCode).toBe(200);
        expect(dbMock.voiceConversation.create).toHaveBeenLastCalledWith({
            data: expect.objectContaining({ sessionId: null, language: null }),
        });
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

    describe("ElevenLabs", () => {
        const agentId = "test-agent";
        const masterSecret = "test-master-secret";
        const elevenUserId = `u_${createHmac("sha256", masterSecret).update(userId).digest("base64url")}`;
        // Only the provider's JWT payload is read by this route; signing belongs to ElevenLabs.
        const conversationToken = [
            Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url"),
            Buffer.from(JSON.stringify({ video: { room: "agent_conv_test123" } })).toString("base64url"),
            "provider-signature",
        ].join(".");

        beforeEach(() => {
            vi.stubEnv("LIVEKIT_API_KEY", undefined);
            vi.stubEnv("LIVEKIT_API_SECRET", undefined);
            vi.stubEnv("ELEVENLABS_API_KEY", "test-elevenlabs-key");
            vi.stubEnv("HANDY_MASTER_SECRET", masterSecret);
            vi.stubEnv("REVENUECAT_API_KEY", undefined);
            fetchMock.mockRejectedValue(new Error("Unexpected provider request"));
        });

        function mockUsage(durations: number[], nextCursor?: string) {
            fetchMock.mockResolvedValueOnce(Response.json({
                conversations: durations.map(call_duration_secs => ({ call_duration_secs })),
                has_more: nextCursor !== undefined,
                next_cursor: nextCursor ?? null,
            }));
        }

        function mockToken() {
            fetchMock.mockResolvedValueOnce(Response.json({ token: conversationToken }));
        }

        function requestConversation(authenticated = true) {
            return app.inject({
                method: "POST",
                url: "/v1/voice/conversations",
                headers: authenticated ? { "x-user-id": userId } : {},
                payload: { agentId },
            });
        }

        function requestUsage() {
            return app.inject({
                method: "GET",
                url: "/v1/voice/usage",
                headers: { "x-user-id": userId },
            });
        }

        it.each([0, 1199])("grants free voice at %i seconds without RevenueCat configuration", async (usedSeconds) => {
            mockUsage(usedSeconds ? [usedSeconds] : []);
            mockToken();

            const requestStartedAt = Date.now();
            const response = await requestConversation();

            expect(response.statusCode).toBe(200);
            expect(VoiceConversationResponseSchema.parse(response.json())).toEqual({
                allowed: true,
                conversationToken,
                conversationId: "conv_test123",
                agentId,
                elevenUserId,
                usedSeconds,
                limitSeconds: 1200,
            });
            expect(fetchMock).toHaveBeenCalledTimes(2);
            const usageUrl = new URL(String(fetchMock.mock.calls[0][0]));
            expect(usageUrl.origin).toBe("https://api.elevenlabs.io");
            expect(usageUrl.pathname).toBe("/v1/convai/conversations");
            expect(usageUrl.searchParams.get("user_id")).toBe(elevenUserId);
            expect(usageUrl.searchParams.get("page_size")).toBe("100");
            expect(usageUrl.searchParams.has("created_after")).toBe(false);
            const windowStart = Number(usageUrl.searchParams.get("call_start_after_unix"));
            expect(Number.isInteger(windowStart)).toBe(true);
            expect(windowStart).toBeGreaterThanOrEqual(Math.floor(requestStartedAt / 1000) - 30 * 86400);
            expect(windowStart).toBeLessThanOrEqual(Math.floor(Date.now() / 1000) - 30 * 86400);
            expect(fetchMock).toHaveBeenNthCalledWith(2,
                `https://api.elevenlabs.io/v1/convai/conversation/token?agent_id=${agentId}&participant_name=${elevenUserId}`,
                { headers: { "xi-api-key": "test-elevenlabs-key" } },
            );
        });

        it.each([1200, 17999])("requires a subscription at %i seconds without RevenueCat configuration", async (usedSeconds) => {
            mockUsage([usedSeconds]);

            const response = await requestConversation();

            expect(response.statusCode).toBe(200);
            expect(VoiceConversationResponseSchema.parse(response.json())).toEqual({
                allowed: false,
                reason: "subscription_required",
                usedSeconds,
                limitSeconds: 1200,
                agentId,
            });
            expect(fetchMock).toHaveBeenCalledTimes(1);
        });

        it("requires authentication before querying usage or minting a token", async () => {
            const response = await requestConversation(false);

            expect(response.statusCode).toBe(401);
            expect(fetchMock).not.toHaveBeenCalled();
        });

        it("still requires ElevenLabs credentials", async () => {
            vi.stubEnv("ELEVENLABS_API_KEY", undefined);

            const response = await requestConversation();

            expect(response.statusCode).toBe(500);
            expect(response.json()).toEqual({ error: "ELEVENLABS_API_KEY not configured" });
            expect(fetchMock).not.toHaveBeenCalled();
        });

        it.each([undefined, "test-revenuecat-key"])("enforces the hard cap with RevenueCat key %s", async (key) => {
            vi.stubEnv("REVENUECAT_API_KEY", key);
            mockUsage([18000]);

            const response = await requestConversation();

            expect(response.statusCode).toBe(200);
            expect(VoiceConversationResponseSchema.parse(response.json())).toEqual({
                allowed: false,
                reason: "voice_hard_limit_reached",
                usedSeconds: 18000,
                limitSeconds: 18000,
                agentId,
            });
            expect(fetchMock).toHaveBeenCalledTimes(1);
        });

        it.each([undefined, "test-revenuecat-key"])("allows a full history page below the free limit with RevenueCat key %s", async (key) => {
            vi.stubEnv("REVENUECAT_API_KEY", key);
            mockUsage(Array.from({ length: 100 }, () => 1));
            mockToken();

            const response = await requestConversation();

            expect(response.statusCode).toBe(200);
            expect(VoiceConversationResponseSchema.parse(response.json())).toEqual({
                allowed: true,
                conversationToken,
                conversationId: "conv_test123",
                elevenUserId,
                usedSeconds: 100,
                limitSeconds: 1200,
                agentId,
            });
            expect(fetchMock).toHaveBeenCalledTimes(2);
        });

        it("allows an active subscription above the free limit when RevenueCat is configured", async () => {
            vi.stubEnv("REVENUECAT_API_KEY", "test-revenuecat-key");
            mockUsage([1200]);
            fetchMock.mockResolvedValueOnce(Response.json({ items: [{ entitlement_id: "voice" }] }));
            mockToken();

            const response = await requestConversation();

            expect(response.statusCode).toBe(200);
            expect(VoiceConversationResponseSchema.parse(response.json())).toEqual({
                allowed: true,
                conversationToken,
                conversationId: "conv_test123",
                agentId,
                elevenUserId,
                usedSeconds: 1200,
                limitSeconds: 18000,
            });
            expect(fetchMock).toHaveBeenCalledTimes(3);
            expect(fetchMock).toHaveBeenNthCalledWith(2,
                `https://api.revenuecat.com/v2/projects/proj493735ad/customers/${userId}/active_entitlements`,
                { method: "GET", headers: { Authorization: "Bearer test-revenuecat-key" } },
            );
        });

        it.each([
            { name: "no active entitlement", status: 200, body: { items: [] } },
            { name: "a failed subscription check", status: 503, body: {} },
        ])("requires a subscription with $name when RevenueCat is configured", async ({ status, body }) => {
            vi.stubEnv("REVENUECAT_API_KEY", "test-revenuecat-key");
            mockUsage([1200]);
            fetchMock.mockResolvedValueOnce(Response.json(body, { status }));

            const response = await requestConversation();

            expect(response.statusCode).toBe(200);
            expect(VoiceConversationResponseSchema.parse(response.json())).toEqual({
                allowed: false,
                reason: "subscription_required",
                usedSeconds: 1200,
                limitSeconds: 1200,
                agentId,
            });
            expect(fetchMock).toHaveBeenCalledTimes(2);
        });

        it("reports the free allowance in usage without RevenueCat configuration", async () => {
            mockUsage([400, 800]);

            const response = await app.inject({
                method: "GET",
                url: "/v1/voice/usage",
                headers: { "x-user-id": userId },
            });

            expect(response.statusCode).toBe(200);
            expect(VoiceUsageResponseSchema.parse(response.json())).toEqual({
                usedSeconds: 1200,
                limitSeconds: 1200,
                conversationCount: 2,
                conversationLimit: 100,
                elevenUserId,
            });
            expect(fetchMock).toHaveBeenCalledTimes(1);
        });

        it("excludes expired conversations from both usage and eligibility", async () => {
            const now = Date.now();
            vi.spyOn(Date, "now").mockReturnValue(now);
            const windowStart = Math.floor(now / 1000) - 30 * 86400;
            // Emulate the provider's documented date filter. Unknown query parameters
            // (including the old created_after) leave the expired history included.
            const history = Array.from({ length: 100 }, () => ({
                start_time_unix_secs: windowStart - 1,
                call_duration_secs: 300,
            }));
            history.push({ start_time_unix_secs: windowStart + 1, call_duration_secs: 60 });
            fetchMock.mockImplementation(async (input) => {
                const url = new URL(String(input));
                if (url.pathname === "/v1/convai/conversation/token") {
                    return Response.json({ token: conversationToken });
                }
                const after = Number(url.searchParams.get("call_start_after_unix") ?? 0);
                return Response.json({
                    conversations: history.filter(c => c.start_time_unix_secs > after).slice(0, 100),
                    has_more: false,
                });
            });

            try {
                const usage = await app.inject({
                    method: "GET",
                    url: "/v1/voice/usage",
                    headers: { "x-user-id": userId },
                });
                expect(usage.statusCode).toBe(200);
                expect(VoiceUsageResponseSchema.parse(usage.json())).toMatchObject({
                    usedSeconds: 60,
                    conversationCount: 1,
                });

                const response = await requestConversation();
                expect(response.statusCode).toBe(200);
                expect(VoiceConversationResponseSchema.parse(response.json())).toMatchObject({
                    allowed: true,
                    usedSeconds: 60,
                    conversationToken,
                });
            } finally {
                vi.restoreAllMocks();
            }
        });

        it.each([true, false])("accounts for 101 recent conversations before checking subscription (active=%s)", async (subscribed) => {
            vi.stubEnv("REVENUECAT_API_KEY", "test-revenuecat-key");
            mockUsage(Array.from({ length: 100 }, () => 88), "page+/2=");
            mockUsage([2]);
            fetchMock.mockResolvedValueOnce(Response.json({ items: subscribed ? [{ entitlement_id: "voice" }] : [] }));
            if (subscribed) mockToken();

            const response = await requestConversation();

            expect(response.statusCode).toBe(200);
            expect(VoiceConversationResponseSchema.parse(response.json())).toMatchObject({
                allowed: subscribed,
                usedSeconds: 8802,
                limitSeconds: subscribed ? 18000 : 1200,
                ...(subscribed ? { conversationToken } : { reason: "subscription_required" }),
            });
            expect(fetchMock).toHaveBeenCalledTimes(subscribed ? 4 : 3);
            const firstPage = new URL(String(fetchMock.mock.calls[0][0]));
            const secondPage = new URL(String(fetchMock.mock.calls[1][0]));
            expect(firstPage.searchParams.has("cursor")).toBe(false);
            expect(secondPage.searchParams.get("cursor")).toBe("page+/2=");
            for (const key of ["user_id", "call_start_after_unix", "page_size"]) {
                expect(secondPage.searchParams.get(key)).toBe(firstPage.searchParams.get(key));
            }
            expect(fetchMock.mock.calls[1][1]?.signal).toBe(fetchMock.mock.calls[0][1]?.signal);
            expect(fetchMock.mock.calls[0][1]?.signal).toBeInstanceOf(AbortSignal);
        });

        it("reports total duration and conversation count across history pages", async () => {
            mockUsage(Array.from({ length: 100 }, () => 1), "page-2");
            mockUsage([10, 20], "page-3");
            mockUsage([30]);

            const response = await app.inject({
                method: "GET",
                url: "/v1/voice/usage",
                headers: { "x-user-id": userId },
            });

            expect(response.statusCode).toBe(200);
            expect(VoiceUsageResponseSchema.parse(response.json())).toMatchObject({
                usedSeconds: 160,
                conversationCount: 103,
                conversationLimit: 100, // Legacy display compatibility; never gates voice.
            });
            expect(new URL(String(fetchMock.mock.calls[2][0])).searchParams.get("cursor")).toBe("page-3");
        });

        it("stops fetching history once a later page reaches the actual hard duration limit", async () => {
            vi.stubEnv("REVENUECAT_API_KEY", "test-revenuecat-key");
            mockUsage([17900], "page-2");
            mockUsage([100], "page-3");

            const response = await requestConversation();

            expect(response.statusCode).toBe(200);
            expect(VoiceConversationResponseSchema.parse(response.json())).toMatchObject({
                allowed: false,
                reason: "voice_hard_limit_reached",
                usedSeconds: 18000,
                limitSeconds: 18000,
            });
            expect(fetchMock).toHaveBeenCalledTimes(2); // No further page, subscription request, or token.
        });

        it.each([false, true])("fails safely when a provider history request fails (later page=%s)", async (laterPage) => {
            if (laterPage) mockUsage([60], "page-2");
            fetchMock.mockResolvedValueOnce(Response.json({}, { status: 503 }));

            const response = await requestConversation();

            expect(response.statusCode).toBe(500);
            expect(response.json()).toEqual({ error: "Failed to get voice usage" });
            expect(fetchMock).toHaveBeenCalledTimes(laterPage ? 2 : 1);
        });

        it.each([
            { conversations: [], has_more: true },
            { conversations: [], has_more: true, next_cursor: "" },
            { conversations: [], has_more: true, next_cursor: 42 },
            { conversations: [] },
            { has_more: false },
            { conversations: [{ call_duration_secs: -1 }], has_more: false },
        ])("fails safely on malformed provider history: %j", async (body) => {
            fetchMock.mockResolvedValueOnce(Response.json(body));

            const response = await requestConversation();

            expect(response.statusCode).toBe(500);
            expect(response.json()).toEqual({ error: "Failed to get voice usage" });
            expect(fetchMock).toHaveBeenCalledTimes(1);
        });

        it("rejects a repeating cursor without issuing a token or looping", async () => {
            mockUsage([60], "repeat");
            mockUsage([60], "repeat");

            const response = await requestConversation();

            expect(response.statusCode).toBe(500);
            expect(response.json()).toEqual({ error: "Failed to get voice usage" });
            expect(fetchMock).toHaveBeenCalledTimes(2);
        });

        it("does not report partial usage after a later provider timeout", async () => {
            mockUsage([60], "page-2");
            fetchMock.mockRejectedValueOnce(new DOMException("History request timed out", "TimeoutError"));

            const response = await app.inject({
                method: "GET",
                url: "/v1/voice/usage",
                headers: { "x-user-id": userId },
            });

            expect(response.statusCode).toBe(500);
            expect(response.json()).toEqual({ error: "Failed to get voice usage" });
            expect(fetchMock).toHaveBeenCalledTimes(2);
        });

        it("encodes the agent id, so it cannot add parameters to the token request", async () => {
            mockUsage([]);
            mockToken();

            const response = await app.inject({
                method: "POST",
                url: "/v1/voice/conversations",
                headers: { "x-user-id": userId },
                payload: { agentId: "a&participant_name=someone-else" },
            });

            expect(response.statusCode).toBe(200);
            const tokenUrl = new URL(String(fetchMock.mock.calls[1][0]));
            expect(tokenUrl.searchParams.get("agent_id")).toBe("a&participant_name=someone-else");
            expect(tokenUrl.searchParams.getAll("participant_name")).toEqual([elevenUserId]);
        });

        it.each([
            { name: "a failed token request", token: () => Response.json({}, { status: 503 }), error: "Failed to get voice credentials" },
            { name: "a token that is not a JWT", token: () => Response.json({ token: "not-a-jwt" }), error: "Failed to get voice credentials" },
            {
                name: "a token without a conversation id",
                token: () => Response.json({ token: `h.${Buffer.from(JSON.stringify({ video: { room: "other" } })).toString("base64url")}.s` }),
                error: "Failed to get conversation ID",
            },
        ])("answers an error for $name", async ({ token, error }) => {
            mockUsage([]);
            fetchMock.mockResolvedValueOnce(token());

            const response = await requestConversation();

            expect(response.statusCode).toBe(500);
            expect(response.json()).toEqual({ error });
        });

        it("uses a subscription's hard limit in usage", async () => {
            vi.stubEnv("REVENUECAT_API_KEY", "test-revenuecat-key");
            fetchMock.mockImplementation(async (input) => String(input).includes("revenuecat")
                ? Response.json({ items: [{ entitlement_id: "voice" }] })
                : Response.json({ conversations: [{ call_duration_secs: 30 }], has_more: false }));

            const response = await requestUsage();

            expect(response.statusCode).toBe(200);
            expect(VoiceUsageResponseSchema.parse(response.json())).toEqual({
                usedSeconds: 30,
                limitSeconds: 18000,
                conversationCount: 1,
                conversationLimit: 100,
                elevenUserId,
            });
        });

        describe("choosing the backend", () => {
            function mockAggregate() {
                dbMock.voiceConversation.aggregate.mockResolvedValueOnce({
                    _count: { _all: 3 },
                    _sum: { durationSecs: 42 },
                });
            }

            beforeEach(() => {
                vi.stubEnv("LIVEKIT_API_KEY", apiKey);
                vi.stubEnv("LIVEKIT_API_SECRET", apiSecret);
            });

            it("gives each request its own backend's grant when both are offered", async () => {
                mockUsage([]);
                mockToken();
                const elevenLabs = await requestConversation();
                expect(VoiceConversationElevenLabsGrantSchema.parse(elevenLabs.json()).conversationToken).toBe(conversationToken);
                expect(dbMock.voiceConversation.create).not.toHaveBeenCalled();

                const liveKit = await app.inject({
                    method: "POST",
                    url: "/v1/voice/conversations",
                    headers: { "x-user-id": userId },
                    payload: { sessionId: "session-1" },
                });
                expect(VoiceConversationLiveKitGrantSchema.parse(liveKit.json()).roomName).toMatch(/^happy-voice-/);
                expect(fetchMock).toHaveBeenCalledTimes(2);
            });

            it("answers an error, never a LiveKit grant, for an agentId without an ElevenLabs key", async () => {
                vi.stubEnv("ELEVENLABS_API_KEY", undefined);
                const response = await requestConversation();
                expect(response.statusCode).toBe(500);
                expect(response.json()).toEqual({ error: "ELEVENLABS_API_KEY not configured" });
                expect(dbMock.voiceConversation.create).not.toHaveBeenCalled();
                expect(fetchMock).not.toHaveBeenCalled();
            });

            it("answers an error, never a LiveKit grant, for an agentId when VOICE_BACKENDS leaves ElevenLabs out", async () => {
                vi.stubEnv("VOICE_BACKENDS", "stream");
                const response = await requestConversation();
                expect(response.statusCode).toBe(503);
                expect(response.json()).toEqual({ error: "ElevenLabs is not offered by this server" });
                expect(dbMock.voiceConversation.create).not.toHaveBeenCalled();
                expect(fetchMock).not.toHaveBeenCalled();
            });

            it("treats an empty agentId as a request for ElevenLabs", async () => {
                vi.stubEnv("VOICE_BACKENDS", "stream");
                const response = await app.inject({
                    method: "POST",
                    url: "/v1/voice/conversations",
                    headers: { "x-user-id": userId },
                    payload: { agentId: "" },
                });
                expect(response.statusCode).toBe(503);
                expect(dbMock.voiceConversation.create).not.toHaveBeenCalled();
            });

            it("reports ElevenLabs usage when it is offered, even alongside the stream", async () => {
                mockUsage([400]);
                const response = await requestUsage();
                expect(VoiceUsageResponseSchema.parse(response.json())).toMatchObject({ usedSeconds: 400, limitSeconds: 1200, elevenUserId });
                expect(dbMock.voiceConversation.aggregate).not.toHaveBeenCalled();
            });

            it("reports the recorded usage when VOICE_BACKENDS leaves ElevenLabs out", async () => {
                vi.stubEnv("VOICE_BACKENDS", "stream");
                mockAggregate();
                const response = await requestUsage();
                expect(VoiceUsageResponseSchema.parse(response.json())).toMatchObject({
                    usedSeconds: 42,
                    limitSeconds: VOICE_UNLIMITED,
                    elevenUserId: `user-${userId}`,
                });
                expect(fetchMock).not.toHaveBeenCalled();
            });

            it("reports the recorded usage without an ElevenLabs key", async () => {
                vi.stubEnv("ELEVENLABS_API_KEY", undefined);
                mockAggregate();
                const response = await requestUsage();
                expect(VoiceUsageResponseSchema.parse(response.json())).toMatchObject({ usedSeconds: 42, limitSeconds: VOICE_UNLIMITED });
                expect(fetchMock).not.toHaveBeenCalled();
            });
        });
    });
});
