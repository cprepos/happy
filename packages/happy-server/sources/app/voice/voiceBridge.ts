import type {
    AudioSource,
    LocalAudioTrack,
    Participant,
    RemoteParticipant,
    RemoteTrack,
    Room,
    RpcInvocationData,
} from "@livekit/rtc-node";
import {
    VOICE_STREAM_DOWNLINK_FRAME_SAMPLES,
    VOICE_STREAM_DOWNLINK_RATE,
    VOICE_STREAM_FRAME_MS,
    VOICE_STREAM_UPLINK_FRAME_SAMPLES,
    VOICE_STREAM_UPLINK_RATE,
    VOICE_TOPIC_INTERRUPTED,
    VoiceAgentStateSchema,
    VoiceStreamRpcMethodSchema,
    type VoiceAgentState,
    type VoiceStreamRpcMethod,
    type VoiceStreamServerMessage,
    type VoiceStreamTopic,
} from "@slopus/happy-wire";
import { log } from "@/utils/log";

type Rtc = typeof import("@livekit/rtc-node");

/** Bytes in one uplink frame: 20 ms of PCM16 mono at 16 kHz. */
export const VOICE_UPLINK_FRAME_BYTES = VOICE_STREAM_UPLINK_FRAME_SAMPLES * 2;

/** The agent's `happy.getConfig` call: the agent itself gives up after 10 s. */
export const VOICE_GET_CONFIG_TIMEOUT_MS = 10_000;
/** Tool calls use the agent's own deadline, within these bounds. */
const TOOL_TIMEOUT_DEFAULT_MS = 30_000;
const TOOL_TIMEOUT_MAX_MS = 60_000;
/** How long an RPC from a not-yet-known participant waits for it to appear. */
const AGENT_LOOKUP_TIMEOUT_MS = 3000;
/** Text sent before the agent joins waits here; the oldest is dropped past this. */
export const VOICE_MAX_QUEUED_MESSAGES = 100;
/**
 * The microphone source can buffer this much. Frames are dropped while more
 * than `UPLINK_MAX_QUEUED_MS` is queued or a capture is still waiting for
 * room, so a burst after a network stall never leaves the agent hearing the
 * user late for the rest of the conversation.
 */
const UPLINK_QUEUE_MS = 100;
const UPLINK_MAX_QUEUED_MS = 60;
const UPLINK_MAX_PENDING_FRAMES = 2;
const AGENT_STATE_ATTRIBUTE = "lk.agent.state";

const encoder = new TextEncoder();

let rtcModule: Promise<Rtc> | null = null;

/**
 * rtc-node loads a native library, so it is only loaded once someone starts
 * a voice stream. A server without voice never pays for it.
 */
function loadRtc(): Promise<Rtc> {
    rtcModule ??= import("@livekit/rtc-node");
    return rtcModule;
}

/** Releases rtc-node's native side, if it was ever loaded. */
export async function voiceBridgeDispose(): Promise<void> {
    if (!rtcModule) {
        return;
    }
    const rtc = await rtcModule;
    await rtc.dispose();
}

/** What the bridge needs from the app's connection. */
export interface VoiceBridgeClient {
    send(message: VoiceStreamServerMessage): void;
    /** One downlink frame: exactly `VOICE_STREAM_DOWNLINK_FRAME_SAMPLES` samples. */
    sendAudio(frame: Buffer): void;
    /** The room went away on its own (agent ended it, LiveKit, network). */
    onRoomClosed(): void;
}

/**
 * Cuts a stream of PCM16 samples into frames of exactly `frameSamples`,
 * whatever sizes it arrives in. Each emitted buffer is its own copy.
 */
export class PcmChunker {
    private frame: Int16Array;
    private filled = 0;

    constructor(private readonly frameSamples: number) {
        this.frame = new Int16Array(frameSamples);
    }

    push(samples: Int16Array, emit: (frame: Buffer) => void) {
        let offset = 0;
        while (offset < samples.length) {
            const take = Math.min(this.frameSamples - this.filled, samples.length - offset);
            this.frame.set(samples.subarray(offset, offset + take), this.filled);
            this.filled += take;
            offset += take;
            if (this.filled === this.frameSamples) {
                emit(Buffer.from(this.frame.buffer, this.frame.byteOffset, this.frame.byteLength));
                this.frame = new Int16Array(this.frameSamples);
                this.filled = 0;
            }
        }
    }

    /** Drops a partial frame. */
    reset() {
        this.filled = 0;
    }
}

/** Little-endian PCM16 bytes to samples, whatever the buffer's alignment. */
export function pcm16FromBytes(bytes: Buffer): Int16Array {
    const samples = new Int16Array(bytes.length >> 1);
    for (let i = 0; i < samples.length; i++) {
        samples[i] = bytes.readInt16LE(i * 2);
    }
    return samples;
}

type PendingRpc = {
    resolve: (result: string) => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
};

/**
 * One app's seat in a LiveKit voice room. The server joins the room as the
 * user (`user-<accountId>`), publishes the app's microphone frames as the
 * user's audio track, streams the agent's speech back as 20 ms frames, and
 * relays the room protocol the app used to speak itself: the agent's RPCs,
 * the `happy.text` / `happy.context` data topics, the agent state attribute
 * and interruptions.
 *
 * A bridge is used once: `connect`, then `close`. `close` may come at any
 * time, also while `connect` is still running.
 */
export class VoiceBridge {
    private rtc: Rtc | null = null;
    private room: Room | null = null;
    private source: AudioSource | null = null;
    private track: LocalAudioTrack | null = null;
    private closed = false;

    private agent: RemoteParticipant | null = null;
    private lastAgentMessage = "";
    private agentAudio: ReadableStreamDefaultReader<unknown> | null = null;
    private readonly downlink = new PcmChunker(VOICE_STREAM_DOWNLINK_FRAME_SAMPLES);

    private uplink: Promise<void> = Promise.resolve();
    private uplinkPending = 0;
    private uplinkDropped = 0;

    private queue: { topic: VoiceStreamTopic; text: string }[] = [];
    private pendingRpcs = new Map<string, PendingRpc>();
    private rpcSeq = 0;

    constructor(private readonly client: VoiceBridgeClient) {}

    /** Joins the room and publishes the microphone track. Throws if it cannot. */
    async connect(url: string, token: string): Promise<void> {
        const rtc = await loadRtc();
        this.rtc = rtc;
        this.assertOpen();

        const room = new rtc.Room();
        this.room = room;
        this.listen(rtc, room);
        await room.connect(url, token, { autoSubscribe: true, dynacast: false });
        await this.assertOpenOrRelease();

        this.source = new rtc.AudioSource(VOICE_STREAM_UPLINK_RATE, 1, UPLINK_QUEUE_MS);
        this.track = rtc.LocalAudioTrack.createAudioTrack("microphone", this.source);
        const local = room.localParticipant!;
        this.registerRpc(rtc, local);
        await local.publishTrack(this.track, new rtc.TrackPublishOptions({ source: rtc.TrackSource.SOURCE_MICROPHONE }));
        await this.assertOpenOrRelease();

        // The agent normally joins after us, but it may already be there.
        for (const participant of room.remoteParticipants.values()) {
            this.onParticipant(participant);
        }
    }

    /** One uplink frame from the app; the caller checks its size. */
    pushAudio(bytes: Buffer) {
        const rtc = this.rtc;
        const source = this.source;
        if (!rtc || !source || this.closed) {
            return;
        }
        if (this.uplinkPending >= UPLINK_MAX_PENDING_FRAMES || source.queuedDuration > UPLINK_MAX_QUEUED_MS) {
            this.uplinkDropped++;
            if (this.uplinkDropped === 1 || this.uplinkDropped % 500 === 0) {
                log({ module: 'voice-bridge' }, `Uplink behind, dropped ${this.uplinkDropped} frames`);
            }
            return;
        }
        const frame = new rtc.AudioFrame(pcm16FromBytes(bytes), VOICE_STREAM_UPLINK_RATE, 1, VOICE_STREAM_UPLINK_FRAME_SAMPLES);
        this.uplinkPending++;
        // One capture at a time keeps the frames in order.
        this.uplink = this.uplink
            .then(() => source.captureFrame(frame))
            .catch(() => { /* source closed */ })
            .finally(() => { this.uplinkPending--; });
    }

    /** Text for the agent, published once it is in the room. */
    sendText(topic: VoiceStreamTopic, text: string) {
        if (this.closed) {
            return;
        }
        const local = this.room?.localParticipant;
        if (!this.agent || !local) {
            this.queue.push({ topic, text });
            if (this.queue.length > VOICE_MAX_QUEUED_MESSAGES) {
                this.queue.shift();
            }
            return;
        }
        local.publishData(encoder.encode(text), { reliable: true, topic }).catch((error) => {
            log({ module: 'voice-bridge' }, `Failed to publish ${topic}: ${error}`);
        });
    }

    /** The app's answer to an `rpc` message. Unknown or late ids are ignored. */
    rpcResult(id: string, result: string | undefined, error: string | undefined) {
        const pending = this.pendingRpcs.get(id);
        if (!pending) {
            return;
        }
        this.pendingRpcs.delete(id);
        clearTimeout(pending.timer);
        if (error !== undefined) {
            pending.reject(this.rpcError(1500, error));
        } else {
            pending.resolve(result ?? "");
        }
    }

    /** Leaves the room and releases everything. Safe to call more than once. */
    async close(): Promise<void> {
        if (this.closed) {
            return;
        }
        this.closed = true;
        await this.release();
    }

    // --- internals ---

    private assertOpen() {
        if (this.closed) {
            throw new Error("Voice bridge closed");
        }
    }

    private async assertOpenOrRelease() {
        if (this.closed) {
            await this.release();
            throw new Error("Voice bridge closed");
        }
    }

    private async release() {
        this.queue = [];
        for (const [id, pending] of this.pendingRpcs) {
            clearTimeout(pending.timer);
            pending.reject(this.rpcError(1503, "the app disconnected"));
            this.pendingRpcs.delete(id);
        }
        this.stopAgentAudio();
        this.agent = null;

        const room = this.room;
        this.room = null;
        if (room) {
            room.removeAllListeners();
            try {
                await room.disconnect();
            } catch (error) {
                log({ module: 'voice-bridge' }, `Room disconnect failed: ${error}`);
            }
        }
        const track = this.track;
        const source = this.source;
        this.track = null;
        this.source = null;
        try {
            if (track) {
                await track.close(true);
            } else if (source) {
                await source.close();
            }
        } catch (error) {
            log({ module: 'voice-bridge' }, `Audio track close failed: ${error}`);
        }
    }

    private rpcError(code: number, message: string): Error {
        return this.rtc ? new this.rtc.RpcError(code, message) : new Error(message);
    }

    private listen(rtc: Rtc, room: Room) {
        const isAgent = (participant?: Participant) =>
            participant?.kind === rtc.ParticipantKind.AGENT;

        room.on(rtc.RoomEvent.ParticipantConnected, (participant) => this.onParticipant(participant));

        room.on(rtc.RoomEvent.ParticipantDisconnected, (participant) => {
            if (participant !== this.agent) return;
            log({ module: 'voice-bridge' }, `Agent left room ${room.name}`);
            this.agent = null;
            this.stopAgentAudio();
            this.sendAgent();
        });

        room.on(rtc.RoomEvent.ParticipantAttributesChanged, (_changed, participant) => {
            if (!isAgent(participant)) return;
            if (!this.agent) {
                this.onParticipant(participant as RemoteParticipant);
            } else if (participant === this.agent) {
                this.sendAgent();
            }
        });

        room.on(rtc.RoomEvent.TrackSubscribed, (track, _publication, participant) => {
            if (isAgent(participant) && track.kind === rtc.TrackKind.KIND_AUDIO) {
                void this.pumpAgentAudio(rtc, track);
            }
        });

        room.on(rtc.RoomEvent.TrackUnsubscribed, (_track, _publication, participant) => {
            if (isAgent(participant)) this.stopAgentAudio();
        });

        room.on(rtc.RoomEvent.DataReceived, (_payload, participant, _kind, topic) => {
            if (topic === VOICE_TOPIC_INTERRUPTED && isAgent(participant)) {
                this.downlink.reset();
                this.client.send({ type: 'flush' });
            }
        });

        room.on(rtc.RoomEvent.Disconnected, (reason) => {
            if (this.closed) return;
            log({ module: 'voice-bridge' }, `Room ${room.name} disconnected (${reason})`);
            this.client.onRoomClosed();
        });
    }

    private onParticipant(participant: RemoteParticipant) {
        if (!this.rtc || participant.kind !== this.rtc.ParticipantKind.AGENT || this.agent) {
            return;
        }
        log({ module: 'voice-bridge' }, `Agent ${participant.identity} joined`);
        this.agent = participant;
        this.sendAgent();
        const pending = this.queue;
        this.queue = [];
        for (const { topic, text } of pending) {
            this.sendText(topic, text);
        }
    }

    /** Tells the app about the agent, when what it would hear changed. */
    private sendAgent() {
        const agent = this.agent;
        let state: VoiceAgentState | undefined;
        if (agent) {
            const parsed = VoiceAgentStateSchema.safeParse(agent.attributes[AGENT_STATE_ATTRIBUTE]);
            state = parsed.success ? parsed.data : undefined;
        }
        const message: VoiceStreamServerMessage = state
            ? { type: 'agent', present: !!agent, state }
            : { type: 'agent', present: !!agent };
        const key = JSON.stringify(message);
        if (key === this.lastAgentMessage) {
            return;
        }
        this.lastAgentMessage = key;
        this.client.send(message);
    }

    private async pumpAgentAudio(rtc: Rtc, track: RemoteTrack) {
        this.stopAgentAudio();
        const stream = new rtc.AudioStream(track, {
            sampleRate: VOICE_STREAM_DOWNLINK_RATE,
            numChannels: 1,
            frameSizeMs: VOICE_STREAM_FRAME_MS,
        });
        const reader = stream.getReader();
        this.agentAudio = reader;
        this.downlink.reset();
        try {
            while (this.agentAudio === reader) {
                const { done, value } = await reader.read();
                if (done || this.agentAudio !== reader) break;
                this.downlink.push(value.data, (frame) => this.client.sendAudio(frame));
            }
        } catch {
            // The stream ends with an error when the room goes away.
        } finally {
            if (this.agentAudio === reader) this.agentAudio = null;
        }
    }

    private stopAgentAudio() {
        const reader = this.agentAudio;
        this.agentAudio = null;
        this.downlink.reset();
        reader?.cancel().catch(() => { /* already closed */ });
    }

    private registerRpc(rtc: Rtc, local: NonNullable<Room["localParticipant"]>) {
        for (const method of VoiceStreamRpcMethodSchema.options) {
            local.registerRpcMethod(method, async (data) => {
                await this.requireAgent(rtc, data);
                const timeoutMs = method === 'happy.getConfig'
                    ? VOICE_GET_CONFIG_TIMEOUT_MS
                    : Math.min(data.responseTimeout > 0 ? data.responseTimeout : TOOL_TIMEOUT_DEFAULT_MS, TOOL_TIMEOUT_MAX_MS);
                return await this.forwardRpc(method, data.payload, timeoutMs);
            });
        }
    }

    /**
     * Only the dispatched agent may drive the app. Its first RPC can arrive
     * before the update that adds it to the room, so an unknown caller gets a
     * moment to show up.
     */
    private async requireAgent(rtc: Rtc, data: RpcInvocationData) {
        const deadline = Date.now() + AGENT_LOOKUP_TIMEOUT_MS;
        let caller = this.room?.remoteParticipants.get(data.callerIdentity);
        while (!caller && Date.now() < deadline && !this.closed) {
            await new Promise((resolve) => setTimeout(resolve, 50));
            caller = this.room?.remoteParticipants.get(data.callerIdentity);
        }
        if (caller?.kind !== rtc.ParticipantKind.AGENT) {
            throw new rtc.RpcError(2403, "caller is not the voice agent");
        }
    }

    private forwardRpc(method: VoiceStreamRpcMethod, payload: string, timeoutMs: number): Promise<string> {
        if (this.closed) {
            return Promise.reject(this.rpcError(1503, "the app disconnected"));
        }
        const id = String(++this.rpcSeq);
        return new Promise<string>((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pendingRpcs.delete(id);
                reject(this.rpcError(1502, "the app did not answer in time"));
            }, timeoutMs);
            this.pendingRpcs.set(id, { resolve, reject, timer });
            this.client.send({ type: 'rpc', id, method, payload });
        });
    }
}
