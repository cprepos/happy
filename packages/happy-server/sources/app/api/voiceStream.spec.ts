import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { Server as SocketIoServer } from "socket.io";
import { WebSocket } from "ws";
import { TokenVerifier } from "livekit-server-sdk";
import { VOICE_STREAM_PATH, VoiceStreamServerMessageSchema, type VoiceStreamServerMessage } from "@slopus/happy-wire";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { socketServerOptions } from "./socketConfig";

const { dbMock, authMock, logMock } = vi.hoisted(() => ({
    dbMock: {
        voiceConversation: {
            create: vi.fn(),
            update: vi.fn(),
        },
        session: {
            findFirst: vi.fn(),
        },
    },
    authMock: {
        verifyToken: vi.fn(),
    },
    logMock: vi.fn(),
}));

vi.mock("@/storage/db", () => ({ db: dbMock }));
vi.mock("@/app/auth/auth", () => ({ auth: authMock }));
vi.mock("@/utils/log", () => ({ log: logMock }));
vi.mock("@livekit/rtc-node", () => import("@/app/voice/rtcNodeFake"));

import { ParticipantKind, rtcFake } from "@/app/voice/rtcNodeFake";
import { voiceStreamAttach, type VoiceStreamServer } from "./voiceStream";

const userId = "voice-user";
const goodToken = "happy-token-of-voice-user";
const apiKey = "test-livekit-key";
const apiSecret = "test-livekit-secret-that-is-long-enough-for-hs256";

interface Client {
    ws: WebSocket;
    messages: VoiceStreamServerMessage[];
    audio: Buffer[];
    closed: Promise<{ code: number }>;
    next(type: VoiceStreamServerMessage["type"]): Promise<VoiceStreamServerMessage>;
    send(message: unknown): void;
}

describe("voice stream", () => {
    let server: Server;
    let voiceStream: VoiceStreamServer;
    let port: number;
    const clients: WebSocket[] = [];

    beforeEach(async () => {
        rtcFake.reset();
        vi.stubEnv("LIVEKIT_API_KEY", apiKey);
        vi.stubEnv("LIVEKIT_API_SECRET", apiSecret);
        vi.stubEnv("LIVEKIT_URL", undefined);
        dbMock.voiceConversation.create.mockReset().mockResolvedValue({});
        dbMock.voiceConversation.update.mockReset().mockResolvedValue({});
        dbMock.session.findFirst.mockReset().mockImplementation(async ({ where }) =>
            where.id === "own-session" && where.accountId === userId ? { id: where.id } : null,
        );
        authMock.verifyToken.mockReset().mockImplementation(async (token: string) =>
            token === goodToken ? { userId } : null,
        );
        logMock.mockReset();

        server = createServer();
        voiceStream = voiceStreamAttach(server, { helloTimeoutMs: 200 });
        await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
        port = (server.address() as AddressInfo).port;
    });

    afterEach(async () => {
        for (const ws of clients.splice(0)) ws.terminate();
        await voiceStream.close();
        await new Promise((resolve) => server.close(resolve));
        vi.unstubAllEnvs();
    });

    async function connect(path = VOICE_STREAM_PATH): Promise<Client> {
        const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`);
        clients.push(ws);
        const messages: VoiceStreamServerMessage[] = [];
        const audio: Buffer[] = [];
        const waiters: { type: string; resolve: (message: VoiceStreamServerMessage) => void }[] = [];
        ws.on("message", (data, isBinary) => {
            if (isBinary) {
                audio.push(data as Buffer);
                return;
            }
            const message = VoiceStreamServerMessageSchema.parse(JSON.parse(data.toString()));
            messages.push(message);
            const index = waiters.findIndex((waiter) => waiter.type === message.type);
            if (index >= 0) waiters.splice(index, 1)[0].resolve(message);
        });
        const closed = new Promise<{ code: number }>((resolve) => ws.on("close", (code) => resolve({ code })));
        await new Promise((resolve, reject) => {
            ws.once("open", resolve);
            ws.once("error", reject);
        });
        return {
            ws,
            messages,
            audio,
            closed,
            next: (type) => {
                const seen = messages.find((message) => message.type === type);
                if (seen) return Promise.resolve(seen);
                return new Promise((resolve) => waiters.push({ type, resolve }));
            },
            send: (message) => ws.send(JSON.stringify(message)),
        };
    }

    async function connectReady(hello: Record<string, unknown> = {}) {
        const client = await connect();
        client.send({ type: "hello", token: goodToken, ...hello });
        const ready = await client.next("ready");
        return { client, ready, room: rtcFake.rooms[0] };
    }

    it("joins the conversation's room as the user and answers ready", async () => {
        const { ready, room } = await connectReady({ sessionId: "own-session", language: "en" });
        if (ready.type !== "ready") throw new Error("expected ready");

        expect(authMock.verifyToken).toHaveBeenCalledWith(goodToken);
        expect(dbMock.voiceConversation.create).toHaveBeenCalledWith({
            data: expect.objectContaining({
                id: ready.conversationId,
                accountId: userId,
                roomName: `happy-voice-${ready.conversationId}`,
                sessionId: "own-session",
                language: "en",
            }),
        });
        expect(room.connectedWith!.url).toBe("ws://livekit:7880");
        const claims = await new TokenVerifier(apiKey, apiSecret).verify(room.connectedWith!.token);
        expect(claims.sub).toBe(`user-${userId}`);
        expect(claims.video?.room).toBe(`happy-voice-${ready.conversationId}`);
        expect(claims.roomConfig?.agents.map((agent) => agent.agentName)).toEqual(["happy-voice"]);
    });

    it("joins LiveKit at LIVEKIT_URL when set", async () => {
        vi.stubEnv("LIVEKIT_URL", "ws://10.0.0.5:7880");
        const { room } = await connectReady();
        expect(room.connectedWith!.url).toBe("ws://10.0.0.5:7880");
    });

    it("never logs the token", async () => {
        const client = await connect();
        client.send({ type: "hello", token: "secret-but-wrong" });
        await client.closed;
        await connectReady();
        const logged = JSON.stringify(logMock.mock.calls);
        expect(logged).not.toContain(goodToken);
        expect(logged).not.toContain("secret-but-wrong");
    });

    it("closes with unauthorized when no hello arrives in time", async () => {
        const client = await connect();
        expect(await client.next("error")).toMatchObject({ code: "unauthorized" });
        expect((await client.closed).code).toBe(1008);
        expect(rtcFake.rooms).toHaveLength(0);
    });

    it.each([
        ["a bad token", { type: "hello", token: "not-a-token" }],
        ["a missing token", { type: "hello" }],
        ["an empty token", { type: "hello", token: "" }],
    ])("rejects %s as unauthorized", async (_name, hello) => {
        const client = await connect();
        client.send(hello);
        expect(await client.next("error")).toMatchObject({ code: "unauthorized" });
        expect((await client.closed).code).toBe(1008);
        expect(dbMock.voiceConversation.create).not.toHaveBeenCalled();
        expect(rtcFake.rooms).toHaveLength(0);
    });

    it.each([
        ["text that is not JSON", "hello?"],
        ["another message first", JSON.stringify({ type: "end" })],
    ])("rejects %s before hello as a bad request", async (_name, raw) => {
        const client = await connect();
        client.ws.send(raw);
        expect(await client.next("error")).toMatchObject({ code: "bad_request" });
        expect((await client.closed).code).toBe(1008);
    });

    it("refuses a session that belongs to another account", async () => {
        const client = await connect();
        client.send({ type: "hello", token: goodToken, sessionId: "someone-elses-session" });
        expect(await client.next("error")).toMatchObject({ code: "unauthorized" });
        expect(dbMock.session.findFirst).toHaveBeenCalledWith({
            where: { id: "someone-elses-session", accountId: userId },
            select: { id: true },
        });
        await client.closed;
        expect(dbMock.voiceConversation.create).not.toHaveBeenCalled();
        expect(rtcFake.rooms).toHaveLength(0);
    });

    it("answers unavailable when LiveKit is not configured or unreachable", async () => {
        vi.stubEnv("LIVEKIT_API_SECRET", undefined);
        const unconfigured = await connect();
        unconfigured.send({ type: "hello", token: goodToken });
        expect(await unconfigured.next("error")).toMatchObject({ code: "unavailable" });

        vi.stubEnv("LIVEKIT_API_SECRET", apiSecret);
        rtcFake.connectError = new Error("connection refused");
        const unreachable = await connect();
        unreachable.send({ type: "hello", token: goodToken });
        expect(await unreachable.next("error")).toMatchObject({ code: "unavailable" });
        expect((await unreachable.closed).code).toBe(1011);
    });

    it("drops audio sent before ready and captures it after", async () => {
        let open!: () => void;
        rtcFake.connectGate = new Promise((resolve) => { open = resolve; });
        const client = await connect();
        client.ws.send(Buffer.alloc(640));
        client.send({ type: "hello", token: goodToken });
        client.ws.send(Buffer.alloc(640));
        await new Promise((resolve) => setTimeout(resolve, 50));
        open();
        await client.next("ready");
        const frame = Buffer.alloc(640);
        frame.writeInt16LE(42, 0);
        client.ws.send(frame);
        await vi.waitFor(() => expect(rtcFake.sources[0].captured).toHaveLength(1));
        expect(rtcFake.sources[0].captured[0].data[0]).toBe(42);
    });

    it("rejects audio frames of the wrong size", async () => {
        const { client } = await connectReady();
        client.ws.send(Buffer.alloc(641));
        expect(await client.next("error")).toMatchObject({ code: "bad_request" });
        expect((await client.closed).code).toBe(1008);
        expect(rtcFake.sources[0].captured).toHaveLength(0);
    });

    it("relays agent RPCs and text over the socket", async () => {
        const { client, room } = await connectReady();
        client.send({ type: "text", topic: "happy.text", text: "queued" });
        const agent = { identity: "agent-1", kind: ParticipantKind.AGENT, attributes: {} };
        room.join(agent);
        await vi.waitFor(() => expect(room.localParticipant!.published).toEqual([
            { data: "queued", topic: "happy.text", reliable: true },
        ]));

        const call = room.callRpc("happy.getConfig", agent.identity);
        const rpc = await client.next("rpc");
        if (rpc.type !== "rpc") throw new Error("expected rpc");
        expect(rpc.method).toBe("happy.getConfig");
        client.send({ type: "rpcResult", id: rpc.id, result: '{"sessionId":"s"}' });
        await expect(call).resolves.toBe('{"sessionId":"s"}');
    });

    it("sends the agent's speech as binary frames", async () => {
        const { client, room } = await connectReady();
        const agent = { identity: "agent-1", kind: ParticipantKind.AGENT, attributes: {} };
        room.join(agent);
        room.emit("trackSubscribed", { kind: 1 }, {}, agent);
        rtcFake.streams[0].push(new Array(960).fill(7));
        await vi.waitFor(() => expect(client.audio).toHaveLength(2));
        expect(client.audio.every((frame) => frame.length === 960)).toBe(true);
    });

    it("leaves the room on end and records the duration", async () => {
        const { client, ready, room } = await connectReady();
        if (ready.type !== "ready") throw new Error("expected ready");
        client.send({ type: "end" });
        expect((await client.closed).code).toBe(1000);
        await vi.waitFor(() => expect(room.disconnected).toBe(true));
        await vi.waitFor(() => expect(dbMock.voiceConversation.update).toHaveBeenCalledWith({
            where: { id: ready.conversationId },
            data: { durationSecs: expect.any(Number) },
        }));
        expect(voiceStream.connectionCount).toBe(0);
    });

    it("leaves the room when the socket drops, and closes the socket when the room goes away", async () => {
        const first = await connectReady();
        first.client.ws.terminate();
        await vi.waitFor(() => expect(first.room.disconnected).toBe(true));

        rtcFake.reset();
        const second = await connectReady();
        second.room.emit("disconnected", 1);
        expect((await second.client.closed).code).toBe(1000);
        await vi.waitFor(() => expect(voiceStream.connectionCount).toBe(0));
    });

    it("leaves the room when the socket closes while still joining", async () => {
        let open!: () => void;
        rtcFake.connectGate = new Promise((resolve) => { open = resolve; });
        const client = await connect();
        client.send({ type: "hello", token: goodToken });
        await vi.waitFor(() => expect(rtcFake.rooms).toHaveLength(1));
        client.ws.close();
        await client.closed;
        open();
        await vi.waitFor(() => expect(rtcFake.rooms[0].disconnected).toBe(true));
        expect(rtcFake.sources).toHaveLength(0);
    });

    it("shares the HTTP server with socket.io without either taking the other's upgrades", async () => {
        const io = new SocketIoServer(server, socketServerOptions);
        try {
            const { client } = await connectReady();
            // socket.io ends upgrades it does not own after a second unless
            // something was written; the voice stream must survive that.
            await new Promise((resolve) => setTimeout(resolve, 1300));
            expect(client.ws.readyState).toBe(WebSocket.OPEN);

            const engine = new WebSocket(`ws://127.0.0.1:${port}/v1/updates/?EIO=4&transport=websocket`);
            clients.push(engine);
            const open = await new Promise<string>((resolve, reject) => {
                engine.once("message", (data) => resolve(data.toString()));
                engine.once("error", reject);
            });
            expect(open.startsWith("0{")).toBe(true);
        } finally {
            // io.close() also closes the HTTP server, which waits for open sockets.
            for (const ws of clients.splice(0)) ws.terminate();
            await io.close();
        }
    });
});
