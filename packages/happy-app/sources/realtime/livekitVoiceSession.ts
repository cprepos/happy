import {
    ConnectionState,
    ParticipantEvent,
    Room,
    RoomEvent,
    RpcError,
    type Participant,
    type RemoteParticipant,
    type RemoteTrack,
    type RpcInvocationData,
} from 'livekit-client';
import { TokenStorage } from '@/auth/tokenStorage';
import { fetchVoiceCredentials } from '@/sync/apiVoice';
import { storage } from '@/sync/storage';
import { realtimeClientTools } from './realtimeClientTools';
import type { VoiceSession, VoiceSessionConfig } from './types';

/**
 * Room protocol shared with the voice agent worker (see the voice contract):
 * - the agent calls RPC `happy.getConfig` once it joins and gets the session
 *   config as JSON;
 * - the agent calls the client tools by RPC, payload JSON, reply a string;
 * - the app publishes reliable UTF-8 data on `happy.text` (a user turn the
 *   agent answers) and `happy.context` (silent context);
 * - the agent reports its state in the `lk.agent.state` attribute.
 */
export const VOICE_RPC_GET_CONFIG = 'happy.getConfig';
export const VOICE_TOPIC_TEXT = 'happy.text';
export const VOICE_TOPIC_CONTEXT = 'happy.context';
const AGENT_STATE_ATTRIBUTE = 'lk.agent.state';

const MAX_QUEUED_MESSAGES = 100;
const USER_SILENCE_MS = 300;

/** What differs between native and web. */
export interface LiveKitVoicePlatform {
    /** Before connecting: audio session setup. */
    prepare(): Promise<void>;
    /** After connecting and enabling the microphone. */
    afterConnect?(room: Room): Promise<void>;
    /** A remote track was subscribed: make it audible if the platform needs to. */
    attachTrack?(track: RemoteTrack): void;
    detachTrack?(track: RemoteTrack): void;
    /** After the room is gone: undo `prepare` and drop anything attached. */
    cleanup(): Promise<void>;
}

type QueuedMessage = { topic: string; text: string };

const encoder = new TextEncoder();

function parsePayload(payload: string): unknown {
    try {
        return payload ? JSON.parse(payload) : {};
    } catch {
        throw new RpcError(2400, 'payload is not valid JSON');
    }
}

/**
 * A voice conversation over LiveKit. Each `startSession` builds a fresh Room,
 * since a LiveKit Room can't be reused once it has disconnected.
 */
export class LiveKitVoiceSession implements VoiceSession {
    private room: Room | null = null;
    private config: VoiceSessionConfig | null = null;
    private agent: RemoteParticipant | null = null;
    private queue: QueuedMessage[] = [];
    private agentSpeaking = false;
    private userSilenceTimer: ReturnType<typeof setTimeout> | null = null;

    constructor(private readonly platform: LiveKitVoicePlatform) {}

    async startSession(config: VoiceSessionConfig): Promise<string | null> {
        if (this.room) {
            await this.endSession();
        }

        const state = storage.getState();
        state.setRealtimeStatus('connecting');

        const credentials = await TokenStorage.getCredentials();
        if (!credentials) {
            throw new Error('Not authenticated');
        }
        const grant = await fetchVoiceCredentials(credentials, config.sessionId, config.language);
        if (!grant.allowed) {
            throw new Error(`Voice not allowed${grant.reason ? `: ${grant.reason}` : ''}`);
        }

        this.config = config;
        this.queue = [];
        this.agent = null;
        this.agentSpeaking = false;

        const room = new Room({
            adaptiveStream: false,
            dynacast: false,
            audioCaptureDefaults: {
                echoCancellation: true,
                noiseSuppression: true,
                autoGainControl: true,
            },
        });
        this.room = room;
        this.registerRpc(room);
        this.listen(room);

        try {
            await this.platform.prepare();
            await room.connect(grant.url, grant.token);
            await room.localParticipant.setMicrophoneEnabled(true);
            await this.platform.afterConnect?.(room);
            // The agent normally joins after us, but it may already be there.
            for (const participant of room.remoteParticipants.values()) {
                this.onParticipant(room, participant);
            }
            console.log('[Voice] Connected to room', grant.roomName ?? room.name);
            return grant.conversationId;
        } catch (error) {
            console.error('[Voice] Failed to connect:', error);
            await this.teardown(room);
            storage.getState().setRealtimeStatus('error');
            throw error;
        }
    }

    async endSession(): Promise<void> {
        const room = this.room;
        try {
            if (room) {
                await room.disconnect();
                await this.teardown(room);
            }
        } catch (error) {
            console.error('[Voice] Failed to end session:', error);
        } finally {
            storage.getState().setRealtimeStatus('disconnected');
        }
    }

    sendTextMessage(message: string): void {
        this.publish(VOICE_TOPIC_TEXT, message);
    }

    sendContextualUpdate(update: string): void {
        this.publish(VOICE_TOPIC_CONTEXT, update);
    }

    // --- internals ---

    private publish(topic: string, text: string) {
        const room = this.room;
        if (!room) {
            console.warn('[Voice] No active voice session, dropping', topic);
            return;
        }
        if (!this.agent || room.state !== ConnectionState.Connected) {
            this.queue.push({ topic, text });
            if (this.queue.length > MAX_QUEUED_MESSAGES) {
                this.queue.shift();
            }
            return;
        }
        room.localParticipant
            .publishData(encoder.encode(text), { reliable: true, topic })
            .catch((error) => console.error('[Voice] Failed to publish', topic, error));
    }

    private flushQueue(room: Room) {
        const pending = this.queue;
        this.queue = [];
        for (const { topic, text } of pending) {
            if (room !== this.room) return;
            this.publish(topic, text);
        }
    }

    private registerRpc(room: Room) {
        // Only the dispatched agent may drive the client tools.
        const fromAgent = (data: RpcInvocationData) => {
            const caller = room.remoteParticipants.get(data.callerIdentity);
            if (!caller?.isAgent) {
                throw new RpcError(2403, 'caller is not the voice agent');
            }
        };

        room.registerRpcMethod(VOICE_RPC_GET_CONFIG, async (data) => {
            fromAgent(data);
            const config = this.config;
            return JSON.stringify({
                systemPrompt: config?.systemPrompt ?? '',
                firstMessage: config?.firstMessage ?? '',
                initialContext: config?.initialContext ?? '',
                language: config?.language ?? null,
                sessionId: config?.sessionId ?? '',
            });
        });

        room.registerRpcMethod('sendMessageToSession', async (data) => {
            fromAgent(data);
            return realtimeClientTools.sendMessageToSession(parsePayload(data.payload));
        });

        room.registerRpcMethod('processPermissionRequest', async (data) => {
            fromAgent(data);
            return realtimeClientTools.processPermissionRequest(parsePayload(data.payload));
        });
    }

    private listen(room: Room) {
        const isCurrent = () => room === this.room;

        room.on(RoomEvent.ConnectionStateChanged, (connectionState) => {
            if (!isCurrent()) return;
            const state = storage.getState();
            switch (connectionState) {
                case ConnectionState.Connected:
                    state.setRealtimeStatus('connected');
                    if (!this.agentSpeaking) state.setRealtimeMode('idle');
                    break;
                case ConnectionState.Connecting:
                case ConnectionState.Reconnecting:
                case ConnectionState.SignalReconnecting:
                    state.setRealtimeStatus('connecting');
                    break;
                case ConnectionState.Disconnected:
                    this.onDisconnected(room);
                    break;
            }
        });

        room.on(RoomEvent.ParticipantConnected, (participant) => {
            if (isCurrent()) this.onParticipant(room, participant);
        });

        room.on(RoomEvent.ParticipantDisconnected, (participant) => {
            if (!isCurrent() || participant !== this.agent) return;
            console.log('[Voice] Agent left the room');
            this.agent = null;
            this.setAgentSpeaking(false);
        });

        room.on(RoomEvent.ParticipantAttributesChanged, (_changed, participant) => {
            if (!isCurrent() || !participant.isAgent || participant.isLocal) return;
            if (!this.agent) this.onParticipant(room, participant as RemoteParticipant);
            this.applyAgentState(participant);
        });

        room.on(RoomEvent.TrackSubscribed, (track) => {
            if (isCurrent()) this.platform.attachTrack?.(track);
        });

        room.on(RoomEvent.TrackUnsubscribed, (track) => {
            this.platform.detachTrack?.(track);
        });

        room.on(RoomEvent.AudioPlaybackStatusChanged, () => {
            if (isCurrent() && !room.canPlaybackAudio) {
                console.warn('[Voice] Audio playback is blocked until the next user gesture');
            }
        });

        room.localParticipant.on(ParticipantEvent.IsSpeakingChanged, (speaking: boolean) => {
            if (isCurrent()) this.onUserSpeaking(speaking);
        });
    }

    private onParticipant(room: Room, participant: RemoteParticipant) {
        if (!participant.isAgent || this.agent) return;
        console.log('[Voice] Agent joined:', participant.identity);
        this.agent = participant;
        this.applyAgentState(participant);
        this.flushQueue(room);
    }

    private applyAgentState(participant: Participant) {
        if (participant !== this.agent) return;
        const agentState = participant.attributes[AGENT_STATE_ATTRIBUTE];
        this.setAgentSpeaking(agentState === 'speaking');
    }

    private setAgentSpeaking(speaking: boolean) {
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

    private onDisconnected(room: Room) {
        console.log('[Voice] Room disconnected');
        const state = storage.getState();
        const prev = state.realtimeStatus;
        state.setRealtimeStatus('disconnected');
        state.setRealtimeMode('idle', true);
        state.clearRealtimeModeDebounce();
        void this.teardown(room);
        // A new provider generation gives the next conversation a fresh
        // component; only bump when a live session ended, not on cold start.
        if (prev === 'connected' || prev === 'connecting') {
            state.incrementVoiceSessionGeneration();
        }
    }

    private async teardown(room: Room) {
        if (room !== this.room) return;
        this.room = null;
        this.agent = null;
        this.queue = [];
        this.agentSpeaking = false;
        this.clearUserSilenceTimer();
        room.removeAllListeners();
        room.localParticipant.removeAllListeners(ParticipantEvent.IsSpeakingChanged);
        try {
            await this.platform.cleanup();
        } catch (error) {
            console.warn('[Voice] Platform cleanup failed:', error);
        }
    }
}
