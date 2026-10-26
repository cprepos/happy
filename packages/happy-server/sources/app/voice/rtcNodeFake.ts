import { EventEmitter } from "node:events";

/**
 * Test double for the parts of `@livekit/rtc-node` the voice bridge uses.
 * Specs swap it in with `vi.mock("@livekit/rtc-node", () => import(...))`
 * and drive the room through `rtcFake`. It never loads the native library.
 */

export const RoomEvent = {
    ParticipantConnected: "participantConnected",
    ParticipantDisconnected: "participantDisconnected",
    ParticipantAttributesChanged: "participantAttributesChanged",
    TrackSubscribed: "trackSubscribed",
    TrackUnsubscribed: "trackUnsubscribed",
    DataReceived: "dataReceived",
    Disconnected: "disconnected",
} as const;

export const ParticipantKind = { STANDARD: 0, AGENT: 4 } as const;
export const TrackKind = { KIND_AUDIO: 1, KIND_VIDEO: 2 } as const;
export const TrackSource = { SOURCE_MICROPHONE: 2 } as const;

export class RpcError extends Error {
    constructor(public code: number, message: string) {
        super(message);
    }
}

export class AudioFrame {
    constructor(
        public data: Int16Array,
        public sampleRate: number,
        public channels: number,
        public samplesPerChannel: number,
    ) {}
}

export class TrackPublishOptions {
    constructor(public options: Record<string, unknown>) {}
}

export class AudioSource {
    captured: AudioFrame[] = [];
    closed = false;
    queuedDuration = 0;

    constructor(public sampleRate: number, public numChannels: number, public queueSize: number) {
        rtcFake.sources.push(this);
    }

    async captureFrame(frame: AudioFrame) {
        this.captured.push(frame);
    }

    async close() {
        this.closed = true;
    }
}

export class LocalAudioTrack {
    closed = false;

    constructor(public name: string, public source: AudioSource) {}

    static createAudioTrack(name: string, source: AudioSource) {
        return new LocalAudioTrack(name, source);
    }

    async close(closeSource = true) {
        this.closed = true;
        if (closeSource) await this.source.close();
    }
}

/** Agent audio: the spec pushes frames with `push` and ends it with `end`. */
export class AudioStream extends ReadableStream<AudioFrame> {
    controller!: ReadableStreamDefaultController<AudioFrame>;
    cancelled = false;

    constructor(public track: unknown, public options: Record<string, unknown>) {
        let controller!: ReadableStreamDefaultController<AudioFrame>;
        const state = { cancelled: false };
        super({
            start: (c) => { controller = c; },
            cancel: () => { state.cancelled = true; },
        });
        this.controller = controller;
        Object.defineProperty(this, "cancelled", { get: () => state.cancelled });
        rtcFake.streams.push(this);
    }

    push(samples: number[]) {
        const data = Int16Array.from(samples);
        this.controller.enqueue(new AudioFrame(data, 24000, 1, data.length));
    }
}

export interface FakeParticipant {
    identity: string;
    kind: number;
    attributes: Record<string, string>;
}

export class LocalParticipant {
    rpcHandlers = new Map<string, (data: Record<string, unknown>) => Promise<string>>();
    published: { data: string; topic?: string; reliable?: boolean }[] = [];
    tracks: { track: LocalAudioTrack; options: TrackPublishOptions }[] = [];

    registerRpcMethod(method: string, handler: (data: Record<string, unknown>) => Promise<string>) {
        this.rpcHandlers.set(method, handler);
    }

    async publishData(data: Uint8Array, options: { topic?: string; reliable?: boolean }) {
        this.published.push({ data: new TextDecoder().decode(data), ...options });
    }

    async publishTrack(track: LocalAudioTrack, options: TrackPublishOptions) {
        this.tracks.push({ track, options });
        return {};
    }
}

export class Room extends EventEmitter {
    name = "happy-voice-test";
    remoteParticipants = new Map<string, FakeParticipant>();
    localParticipant?: LocalParticipant;
    connectedWith: { url: string; token: string } | null = null;
    disconnected = false;

    constructor() {
        super();
        rtcFake.rooms.push(this);
    }

    async connect(url: string, token: string) {
        this.connectedWith = { url, token };
        if (rtcFake.connectError) throw rtcFake.connectError;
        await rtcFake.connectGate;
        this.localParticipant = new LocalParticipant();
    }

    async disconnect() {
        this.disconnected = true;
    }

    /** Adds a participant the way LiveKit announces one. */
    join(participant: FakeParticipant) {
        this.remoteParticipants.set(participant.identity, participant);
        this.emit(RoomEvent.ParticipantConnected, participant);
    }

    leave(participant: FakeParticipant) {
        this.remoteParticipants.delete(participant.identity);
        this.emit(RoomEvent.ParticipantDisconnected, participant);
    }

    /** Calls an RPC handler the bridge registered, as `callerIdentity`. */
    callRpc(method: string, callerIdentity: string, payload = "", responseTimeout = 0) {
        const handler = this.localParticipant!.rpcHandlers.get(method);
        if (!handler) throw new Error(`no handler for ${method}`);
        return handler({ requestId: "r", callerIdentity, payload, responseTimeout, method });
    }
}

export async function dispose() {
    rtcFake.disposed = true;
}

export const rtcFake = {
    rooms: [] as Room[],
    sources: [] as AudioSource[],
    streams: [] as AudioStream[],
    connectError: null as Error | null,
    connectGate: Promise.resolve() as Promise<void>,
    disposed: false,
    reset() {
        this.rooms = [];
        this.sources = [];
        this.streams = [];
        this.connectError = null;
        this.connectGate = Promise.resolve();
        this.disposed = false;
    },
};
