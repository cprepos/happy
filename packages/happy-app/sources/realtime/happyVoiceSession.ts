import {
    VOICE_STREAM_PATH,
    VoiceStreamServerMessageSchema,
    type VoiceStreamClientMessage,
    type VoiceStreamServerMessage,
    type VoiceStreamTopic,
} from '@slopus/happy-wire';
import { TokenStorage } from '@/auth/tokenStorage';
import { getVoiceServerUrl } from '@/sync/serverConfig';
import { storage } from '@/sync/storage';
import { realtimeClientTools } from './realtimeClientTools';
import type { VoiceSession, VoiceSessionConfig } from './types';
import { buildAgentConfigJson } from './voiceAgentConfig';

const MAX_QUEUED_MESSAGES = 100;
const USER_SILENCE_MS = 300;
/** How long `hello` may wait for `ready` before the start fails. */
const READY_TIMEOUT_MS = 15000;
/**
 * Microphone frames still unsent on the socket beyond this are dropped
 * instead of queued (~1 s of 16 kHz PCM16): after a stall, fresh audio
 * matters more than complete audio.
 */
const MAX_UPLINK_BUFFERED_BYTES = 32000;

/** What differs between web and native: microphone capture and agent playback. */
export interface HappyVoiceAudio {
    /**
     * Called synchronously inside the user gesture that starts voice, before
     * any await: Safari only lets audio start from there.
     */
    prime?(): void;
    /** Opens the microphone and the output. */
    start(handlers: HappyVoiceAudioHandlers): Promise<void>;
    /** One downlink frame (PCM16, 24 kHz); ownership passes to the audio. */
    play(frame: ArrayBuffer): void;
    /** Drops agent audio not yet played. */
    flush(): void;
    /** Releases the microphone and the output. Safe to call at any time. */
    stop(): Promise<void>;
}

export interface HappyVoiceAudioHandlers {
    /** One uplink frame (PCM16, 16 kHz, 20 ms). */
    onFrame(frame: ArrayBuffer): void;
    /** The microphone level crossed the speech threshold (with hangover). */
    onSpeaking(speaking: boolean): void;
    /** The microphone went away (device unplugged, permission revoked). */
    onEnded(): void;
}

/** The part of the browser WebSocket the session uses. */
export interface VoiceSocket {
    binaryType: string;
    readonly readyState: number;
    readonly bufferedAmount: number;
    onopen: ((event: unknown) => void) | null;
    onmessage: ((event: { data: unknown }) => void) | null;
    onclose: ((event: { code: number; reason: string }) => void) | null;
    onerror: ((event: unknown) => void) | null;
    send(data: string | ArrayBuffer): void;
    close(code?: number, reason?: string): void;
}

export interface HappyVoiceSessionOptions {
    createSocket?: (url: string) => VoiceSocket;
}

const SOCKET_OPEN = 1;

/** `https://host/base` → `wss://host/base/v1/voice/stream`. */
export function voiceStreamUrl(serverUrl: string): string {
    const url = new URL(serverUrl);
    url.protocol = url.protocol === 'http:' ? 'ws:' : 'wss:';
    url.pathname = url.pathname.replace(/\/+$/, '') + VOICE_STREAM_PATH;
    url.search = '';
    url.hash = '';
    return url.toString();
}

type QueuedMessage = { topic: VoiceStreamTopic; text: string };

/** One socket's worth of state; a new one per `startSession`. */
interface Connection {
    socket: VoiceSocket;
    ready: boolean;
    agentPresent: boolean;
    failed: boolean;
    /** Rejects a start still waiting for `ready`. */
    abort?: (error: Error) => void;
}

/**
 * A voice conversation streamed through happy-server: one WebSocket carries
 * control messages as JSON and audio as binary frames (see `voiceStream.ts`
 * in happy-wire). The server sits in the LiveKit room on our behalf, so the
 * observable behavior (status, mode, client tools) matches
 * `LiveKitVoiceSession`.
 */
export class HappyVoiceSession implements VoiceSession {
    private connection: Connection | null = null;
    private config: VoiceSessionConfig | null = null;
    private queue: QueuedMessage[] = [];
    private agentSpeaking = false;
    private userSilenceTimer: ReturnType<typeof setTimeout> | null = null;
    private readonly createSocket: (url: string) => VoiceSocket;

    constructor(
        private readonly audio: HappyVoiceAudio,
        options: HappyVoiceSessionOptions = {},
    ) {
        this.createSocket = options.createSocket ?? ((url) => new WebSocket(url) as unknown as VoiceSocket);
    }

    prepare(): void {
        try {
            this.audio.prime?.();
        } catch (error) {
            console.warn('[Voice] Audio prime failed:', error);
        }
    }

    async startSession(config: VoiceSessionConfig): Promise<string | null> {
        if (this.connection) {
            await this.endSession();
        }

        storage.getState().setRealtimeStatus('connecting');

        const credentials = await TokenStorage.getCredentials();
        if (!credentials) {
            throw new Error('Not authenticated');
        }

        this.config = config;
        this.queue = [];
        this.agentSpeaking = false;

        const socket = this.createSocket(voiceStreamUrl(getVoiceServerUrl()));
        socket.binaryType = 'arraybuffer';
        const connection: Connection = { socket, ready: false, agentPresent: false, failed: false };
        this.connection = connection;

        try {
            // Microphone and socket come up in parallel; neither waits on the other.
            const [conversationId] = await Promise.all([
                this.handshake(connection, {
                    type: 'hello',
                    token: credentials.token,
                    sessionId: config.sessionId,
                    ...(config.language ? { language: config.language } : {}),
                }),
                this.audio.start({
                    onFrame: (frame) => this.sendAudio(connection, frame),
                    onSpeaking: (speaking) => {
                        if (connection === this.connection) this.onUserSpeaking(speaking);
                    },
                    onEnded: () => {
                        if (connection !== this.connection) return;
                        console.warn('[Voice] Microphone ended');
                        void this.endSession();
                    },
                }),
            ]);
            if (connection !== this.connection) {
                throw new Error('Voice session ended while starting');
            }
            console.log('[Voice] Connected, conversation', conversationId);
            return conversationId;
        } catch (error) {
            console.error('[Voice] Failed to connect:', error);
            if (connection === this.connection) {
                await this.teardown(connection);
                storage.getState().setRealtimeStatus('error');
            }
            throw error;
        }
    }

    async endSession(): Promise<void> {
        const connection = this.connection;
        try {
            if (connection) {
                this.send(connection, { type: 'end' });
                this.onDisconnected(connection);
            } else {
                await this.audio.stop();
            }
        } catch (error) {
            console.error('[Voice] Failed to end session:', error);
        } finally {
            storage.getState().setRealtimeStatus('disconnected');
        }
    }

    sendTextMessage(message: string): void {
        this.publish('happy.text', message);
    }

    sendContextualUpdate(update: string): void {
        this.publish('happy.context', update);
    }

    // --- internals ---

    /** Opens the socket, says hello and resolves with the conversation id on `ready`. */
    private handshake(connection: Connection, hello: VoiceStreamClientMessage): Promise<string> {
        const { socket } = connection;
        return new Promise<string>((resolve, reject) => {
            let settled = false;
            const timer = setTimeout(() => fail(new Error('Voice server did not answer')), READY_TIMEOUT_MS);
            const fail = (error: Error) => {
                if (settled) return;
                settled = true;
                clearTimeout(timer);
                reject(error);
            };
            connection.abort = fail;

            socket.onopen = () => this.send(connection, hello);
            socket.onerror = () => fail(new Error('Voice connection failed'));
            socket.onclose = (event) => {
                fail(new Error(`Voice connection closed (${event.code}${event.reason ? `: ${event.reason}` : ''})`));
                if (connection === this.connection && connection.ready) this.onDisconnected(connection);
            };
            socket.onmessage = (event) => {
                if (connection !== this.connection) return;
                if (typeof event.data !== 'string') {
                    if (event.data instanceof ArrayBuffer && connection.ready) this.audio.play(event.data);
                    return;
                }
                const message = parseServerMessage(event.data);
                if (!message) return;
                if (message.type === 'ready' && !settled) {
                    settled = true;
                    clearTimeout(timer);
                    this.onReady(connection);
                    resolve(message.conversationId);
                    return;
                }
                if (message.type === 'error' && !settled) {
                    connection.failed = true;
                    fail(new Error(`Voice server error (${message.code}): ${message.message}`));
                    return;
                }
                this.onMessage(connection, message);
            };
        });
    }

    private onReady(connection: Connection) {
        connection.ready = true;
        const state = storage.getState();
        state.setRealtimeStatus('connected');
        if (!this.agentSpeaking) state.setRealtimeMode('idle');
    }

    private onMessage(connection: Connection, message: VoiceStreamServerMessage) {
        switch (message.type) {
            case 'agent':
                this.onAgent(connection, message.present, message.state);
                break;
            case 'rpc':
                void this.onRpc(connection, message.id, message.method, message.payload);
                break;
            case 'flush':
                this.audio.flush();
                break;
            case 'error':
                console.error(`[Voice] Server error (${message.code}):`, message.message);
                connection.failed = true;
                storage.getState().setRealtimeStatus('error');
                break;
            case 'ready':
                break;
        }
    }

    private onAgent(connection: Connection, present: boolean, agentState: string | undefined) {
        if (present && !connection.agentPresent) {
            console.log('[Voice] Agent joined');
            connection.agentPresent = true;
            this.flushQueue(connection);
        } else if (!present && connection.agentPresent) {
            console.log('[Voice] Agent left the room');
            connection.agentPresent = false;
        }
        this.setAgentSpeaking(present && agentState === 'speaking');
    }

    private async onRpc(connection: Connection, id: string, method: string, payload: string) {
        // The server only forwards RPCs whose caller is the dispatched agent.
        let reply: VoiceStreamClientMessage;
        try {
            reply = { type: 'rpcResult', id, result: await this.callTool(method, payload) };
        } catch (error) {
            reply = { type: 'rpcResult', id, error: error instanceof Error ? error.message : String(error) };
        }
        if (connection === this.connection) this.send(connection, reply);
    }

    private async callTool(method: string, payload: string): Promise<string> {
        switch (method) {
            case 'happy.getConfig': {
                return buildAgentConfigJson(this.config);
            }
            case 'sendMessageToSession':
                return realtimeClientTools.sendMessageToSession(parsePayload(payload));
            case 'processPermissionRequest':
                return realtimeClientTools.processPermissionRequest(parsePayload(payload));
            default:
                throw new Error(`unknown method ${method}`);
        }
    }

    private publish(topic: VoiceStreamTopic, text: string) {
        const connection = this.connection;
        if (!connection) {
            console.warn('[Voice] No active voice session, dropping', topic);
            return;
        }
        if (!connection.ready || !connection.agentPresent) {
            this.queue.push({ topic, text });
            if (this.queue.length > MAX_QUEUED_MESSAGES) {
                this.queue.shift();
            }
            return;
        }
        this.send(connection, { type: 'text', topic, text });
    }

    private flushQueue(connection: Connection) {
        const pending = this.queue;
        this.queue = [];
        for (const { topic, text } of pending) {
            if (connection !== this.connection) return;
            this.publish(topic, text);
        }
    }

    private send(connection: Connection, message: VoiceStreamClientMessage) {
        if (connection.socket.readyState !== SOCKET_OPEN) return;
        try {
            connection.socket.send(JSON.stringify(message));
        } catch (error) {
            console.error('[Voice] Failed to send', message.type, error);
        }
    }

    private sendAudio(connection: Connection, frame: ArrayBuffer) {
        // The server drops audio before `ready`, so don't spend bandwidth on it.
        if (connection !== this.connection || !connection.ready) return;
        const { socket } = connection;
        if (socket.readyState !== SOCKET_OPEN || socket.bufferedAmount > MAX_UPLINK_BUFFERED_BYTES) return;
        socket.send(frame);
    }

    private setAgentSpeaking(speaking: boolean) {
        if (speaking === this.agentSpeaking) return;
        this.agentSpeaking = speaking;
        if (speaking) {
            this.clearUserSilenceTimer();
            storage.getState().setRealtimeMode('agent-speaking');
        } else {
            storage.getState().setRealtimeMode('idle');
        }
    }

    private onUserSpeaking(speaking: boolean) {
        if (this.agentSpeaking) return; // the agent speaking takes priority
        if (speaking) {
            this.clearUserSilenceTimer();
            storage.getState().setRealtimeMode('user-speaking', true);
        } else if (!this.userSilenceTimer) {
            this.userSilenceTimer = setTimeout(() => {
                this.userSilenceTimer = null;
                if (!this.agentSpeaking) storage.getState().setRealtimeMode('idle');
            }, USER_SILENCE_MS);
        }
    }

    private clearUserSilenceTimer() {
        if (this.userSilenceTimer) {
            clearTimeout(this.userSilenceTimer);
            this.userSilenceTimer = null;
        }
    }

    private onDisconnected(connection: Connection) {
        if (connection !== this.connection) return;
        console.log('[Voice] Disconnected');
        const state = storage.getState();
        const prev = state.realtimeStatus;
        const wasLive = connection.ready || prev === 'connected' || prev === 'connecting';
        state.setRealtimeStatus(connection.failed ? 'error' : 'disconnected');
        state.setRealtimeMode('idle', true);
        state.clearRealtimeModeDebounce();
        void this.teardown(connection);
        // A new provider generation gives the next conversation a fresh
        // component; only bump when a live session ended, not on cold start.
        if (wasLive) {
            state.incrementVoiceSessionGeneration();
        }
    }

    private async teardown(connection: Connection) {
        if (connection !== this.connection) return;
        this.connection = null;
        this.queue = [];
        this.agentSpeaking = false;
        this.clearUserSilenceTimer();
        connection.abort?.(new Error('Voice session ended'));
        const { socket } = connection;
        socket.onopen = null;
        socket.onmessage = null;
        socket.onclose = null;
        socket.onerror = null;
        try {
            socket.close(1000, 'end');
        } catch {
            // already closed
        }
        try {
            await this.audio.stop();
        } catch (error) {
            console.warn('[Voice] Audio cleanup failed:', error);
        }
    }
}

function parseServerMessage(data: string): VoiceStreamServerMessage | null {
    try {
        const parsed = VoiceStreamServerMessageSchema.safeParse(JSON.parse(data));
        if (parsed.success) return parsed.data;
        console.warn('[Voice] Ignoring unknown message:', data.slice(0, 200));
    } catch {
        console.warn('[Voice] Ignoring malformed message');
    }
    return null;
}

function parsePayload(payload: string): unknown {
    try {
        return payload ? JSON.parse(payload) : {};
    } catch {
        throw new Error('payload is not valid JSON');
    }
}
