import type { IncomingMessage, Server } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocket, WebSocketServer, type RawData } from "ws";
import {
    VOICE_STREAM_PATH,
    VoiceStreamClientMessageSchema,
    VoiceStreamHelloSchema,
    type VoiceStreamServerMessage,
} from "@slopus/happy-wire";
import { auth } from "@/app/auth/auth";
import { db } from "@/storage/db";
import { log } from "@/utils/log";
import { onShutdown } from "@/utils/shutdown";
import { voiceConversationCreate } from "@/app/voice/voiceConversationCreate";
import { voiceLiveKitConfig, voiceTokenCreate } from "@/app/voice/voiceTokenCreate";
import { VOICE_UPLINK_FRAME_BYTES, VoiceBridge, voiceBridgeDispose } from "@/app/voice/voiceBridge";
import { type Fastify } from "./types";

/** The app must say `hello` within this long after connecting. */
export const VOICE_HELLO_TIMEOUT_MS = 5000;
/** Largest message the app may send (an RPC result carries the session config). */
const MAX_MESSAGE_BYTES = 1024 * 1024;
/**
 * Agent audio is dropped while this much is still unsent to the app (about
 * 1.3 s of speech), so a stalled connection never builds up a backlog the
 * user would hear late.
 */
const MAX_DOWNLINK_BUFFERED_BYTES = 64 * 1024;

type ErrorCode = Extract<VoiceStreamServerMessage, { type: 'error' }>['code'];

export interface VoiceStreamServer {
    /** Ends every voice stream and stops accepting new ones. */
    close(): Promise<void>;
    readonly connectionCount: number;
}

function isVoiceStreamRequest(request: IncomingMessage): boolean {
    try {
        return new URL(request.url ?? '', 'http://localhost').pathname === VOICE_STREAM_PATH;
    } catch {
        return false;
    }
}

/**
 * Serves the voice stream WebSocket on `VOICE_STREAM_PATH` of an existing
 * HTTP server, next to socket.io.
 *
 * Both listen to the server's `upgrade` event. This handler takes only its
 * own path and leaves every other request alone; socket.io takes
 * `/v1/updates` and, after a second, ends any upgrade nobody answered
 * (`destroyUpgrade`). It only ends sockets nothing was written to, and the
 * voice stream answers with 101 synchronously, so the two never collide.
 */
export function voiceStreamAttach(server: Server, options: { helloTimeoutMs?: number } = {}): VoiceStreamServer {
    const helloTimeoutMs = options.helloTimeoutMs ?? VOICE_HELLO_TIMEOUT_MS;
    const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES, perMessageDeflate: false });
    const connections = new Set<VoiceStreamConnection>();

    const onUpgrade = (request: IncomingMessage, socket: Duplex, head: Buffer) => {
        if (!isVoiceStreamRequest(request)) {
            return;
        }
        // Audio frames are small and must leave at once, not wait for Nagle.
        (socket as Partial<import("node:net").Socket>).setNoDelay?.(true);
        wss.handleUpgrade(request, socket, head, (ws) => {
            const connection = new VoiceStreamConnection(ws, helloTimeoutMs, () => connections.delete(connection));
            connections.add(connection);
        });
    };
    server.on('upgrade', onUpgrade);

    return {
        async close() {
            server.off('upgrade', onUpgrade);
            await Promise.all([...connections].map((connection) => connection.close()));
            wss.close();
        },
        get connectionCount() {
            return connections.size;
        },
    };
}

/** Starts the voice stream on the API server and ends it on shutdown. */
export function startVoiceStream(app: Fastify) {
    const voiceStream = voiceStreamAttach(app.server);
    onShutdown('api', async () => {
        await voiceStream.close();
        await voiceBridgeDispose();
    });
}

/**
 * One app's voice stream. The first text message must be `hello` with the
 * account's token; it is verified like a REST Bearer token, and a `sessionId`
 * must be one of the account's own sessions. The server then records the
 * conversation, joins its LiveKit room as the user and answers `ready`.
 * From then on binary messages are microphone frames and the agent's speech
 * comes back the same way. Closing the socket or sending `end` leaves the room;
 * the room going away closes the socket.
 */
class VoiceStreamConnection {
    private state: 'hello' | 'starting' | 'ready' | 'closed' = 'hello';
    private bridge: VoiceBridge | null = null;
    private helloTimer: ReturnType<typeof setTimeout> | null;
    private userId: string | null = null;
    private conversationId: string | null = null;
    private readyAt = 0;

    constructor(private readonly ws: WebSocket, helloTimeoutMs: number, private readonly onClosed: () => void) {
        this.helloTimer = setTimeout(() => this.fail('unauthorized', 'No hello received'), helloTimeoutMs);
        ws.on('message', (data, isBinary) => this.onMessage(data, isBinary));
        ws.on('close', () => void this.close());
        ws.on('error', (error) => {
            log({ module: 'voice-stream' }, `Socket error: ${error.message}`);
        });
    }

    /** Leaves the room and closes the socket. Safe to call more than once. */
    async close(code = 1000, reason = '') {
        if (this.state === 'closed') {
            return;
        }
        const wasReady = this.state === 'ready';
        this.state = 'closed';
        this.clearHelloTimer();
        if (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING) {
            this.ws.close(code, reason);
        }
        this.onClosed();
        await this.bridge?.close();
        this.bridge = null;
        if (wasReady && this.conversationId) {
            log({ module: 'voice-stream' }, `Voice stream ended for user ${this.userId}`);
            await this.recordDuration(this.conversationId);
        }
    }

    private send(message: VoiceStreamServerMessage) {
        if (this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify(message));
        }
    }

    private sendAudio(frame: Buffer) {
        if (this.state !== 'ready' || this.ws.readyState !== WebSocket.OPEN) {
            return;
        }
        if (this.ws.bufferedAmount > MAX_DOWNLINK_BUFFERED_BYTES) {
            return;
        }
        this.ws.send(frame, { binary: true });
    }

    private fail(code: ErrorCode, message: string) {
        if (this.state === 'closed') {
            return;
        }
        this.send({ type: 'error', code, message });
        void this.close(code === 'unauthorized' || code === 'bad_request' ? 1008 : 1011, code);
    }

    private clearHelloTimer() {
        if (this.helloTimer) {
            clearTimeout(this.helloTimer);
            this.helloTimer = null;
        }
    }

    private onMessage(data: RawData, isBinary: boolean) {
        if (this.state === 'closed') {
            return;
        }
        if (isBinary) {
            // Audio before `ready` is dropped.
            if (this.state !== 'ready') {
                return;
            }
            const frame = data as Buffer;
            if (frame.length !== VOICE_UPLINK_FRAME_BYTES) {
                this.fail('bad_request', `Audio frames must be ${VOICE_UPLINK_FRAME_BYTES} bytes`);
                return;
            }
            this.bridge?.pushAudio(frame);
            return;
        }

        let json: unknown;
        try {
            json = JSON.parse(data.toString());
        } catch {
            json = undefined;
        }

        if (this.state === 'hello') {
            this.onHello(json);
            return;
        }

        const parsed = VoiceStreamClientMessageSchema.safeParse(json);
        if (!parsed.success) {
            // Newer apps may send messages this server does not know yet.
            return;
        }
        const message = parsed.data;
        switch (message.type) {
            case 'hello':
                this.fail('bad_request', 'Already said hello');
                break;
            case 'text':
                this.bridge?.sendText(message.topic, message.text);
                break;
            case 'rpcResult':
                this.bridge?.rpcResult(message.id, message.result, message.error);
                break;
            case 'end':
                void this.close();
                break;
        }
    }

    private onHello(json: unknown) {
        this.clearHelloTimer();
        const type = (json as { type?: unknown } | null)?.type;
        if (type !== 'hello') {
            this.fail('bad_request', 'First message must be hello');
            return;
        }
        const token = (json as { token?: unknown }).token;
        if (typeof token !== 'string' || !token) {
            this.fail('unauthorized', 'Missing token');
            return;
        }
        const hello = VoiceStreamHelloSchema.safeParse(json);
        if (!hello.success) {
            this.fail('bad_request', 'Invalid hello');
            return;
        }
        this.state = 'starting';
        this.bridge = new VoiceBridge({
            send: (message) => this.send(message),
            sendAudio: (frame) => this.sendAudio(frame),
            onRoomClosed: () => void this.close(1000, 'room closed'),
        });
        this.start(hello.data.token, hello.data.sessionId, hello.data.language).catch((error) => {
            log({ module: 'voice-stream' }, `Voice stream start failed: ${error}`);
            this.fail('internal', 'Failed to start voice');
        });
    }

    private async start(token: string, sessionId: string | undefined, language: string | undefined) {
        const verified = await auth.verifyToken(token).catch(() => null);
        if (this.state !== 'starting') return;
        if (!verified) {
            this.fail('unauthorized', 'Invalid token');
            return;
        }
        const userId = verified.userId;
        this.userId = userId;

        if (sessionId) {
            const session = await db.session.findFirst({
                where: { id: sessionId, accountId: userId },
                select: { id: true },
            });
            if (this.state !== 'starting') return;
            if (!session) {
                log({ module: 'voice-stream' }, `User ${userId} asked for voice on a session that is not theirs`);
                this.fail('unauthorized', 'Session not found');
                return;
            }
        }

        const liveKit = voiceLiveKitConfig();
        if (!liveKit) {
            log({ module: 'voice-stream' }, 'LIVEKIT_API_KEY / LIVEKIT_API_SECRET not configured');
            this.fail('unavailable', 'LiveKit is not configured');
            return;
        }

        const { conversationId, roomName } = await voiceConversationCreate(userId, { sessionId, language });
        this.conversationId = conversationId;
        if (this.state !== 'starting') return;
        const roomToken = await voiceTokenCreate(liveKit, userId, roomName);

        try {
            await this.bridge!.connect(liveKit.url, roomToken);
        } catch (error) {
            if (this.state !== 'starting') return;
            log({ module: 'voice-stream' }, `Failed to join voice room ${roomName} for user ${userId}: ${error}`);
            this.fail('unavailable', 'Voice service unavailable');
            return;
        }
        if (this.state !== 'starting') return;

        this.state = 'ready';
        this.readyAt = Date.now();
        log({ module: 'voice-stream' }, `Voice stream ready in room ${roomName} for user ${userId}`);
        this.send({ type: 'ready', conversationId });
    }

    private async recordDuration(conversationId: string) {
        try {
            await db.voiceConversation.update({
                where: { id: conversationId },
                data: { durationSecs: Math.round((Date.now() - this.readyAt) / 1000) },
            });
        } catch (error) {
            log({ module: 'voice-stream' }, `Failed to record voice duration: ${error}`);
        }
    }
}
