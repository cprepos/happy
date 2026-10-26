import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { VoiceStreamServerMessage } from "@slopus/happy-wire";

vi.mock("@livekit/rtc-node", () => import("./rtcNodeFake"));

import { ParticipantKind, RoomEvent, TrackKind, rtcFake, type FakeParticipant, type Room } from "./rtcNodeFake";
import { PcmChunker, VOICE_UPLINK_FRAME_BYTES, VoiceBridge, pcm16FromBytes } from "./voiceBridge";

const agent: FakeParticipant = { identity: "agent-1", kind: ParticipantKind.AGENT, attributes: {} };
const stranger: FakeParticipant = { identity: "someone", kind: ParticipantKind.STANDARD, attributes: {} };

function createClient() {
    const messages: VoiceStreamServerMessage[] = [];
    const audio: Buffer[] = [];
    const client = {
        send: (message: VoiceStreamServerMessage) => { messages.push(message); },
        sendAudio: (frame: Buffer) => { audio.push(frame); },
        onRoomClosed: vi.fn(),
    };
    return { client, messages, audio };
}

async function connectBridge() {
    const { client, messages, audio } = createClient();
    const bridge = new VoiceBridge(client);
    await bridge.connect("ws://livekit:7880", "room-token");
    const room = rtcFake.rooms[0] as Room;
    return { bridge, room, client, messages, audio };
}

const flush = () => new Promise((resolve) => setImmediate(resolve));

describe("PcmChunker", () => {
    it("cuts any input sizes into exact frames and keeps the remainder", () => {
        const chunker = new PcmChunker(4);
        const frames: number[][] = [];
        const emit = (frame: Buffer) => frames.push([...pcm16FromBytes(frame)]);
        chunker.push(Int16Array.from([1, 2, 3]), emit);
        expect(frames).toEqual([]);
        chunker.push(Int16Array.from([4, 5, 6, 7, 8, 9, 10]), emit);
        expect(frames).toEqual([[1, 2, 3, 4], [5, 6, 7, 8]]);
        chunker.reset();
        chunker.push(Int16Array.from([11, 12, 13, 14]), emit);
        expect(frames[2]).toEqual([11, 12, 13, 14]);
    });

    it("reads little-endian samples from unaligned buffers", () => {
        const bytes = Buffer.alloc(5);
        bytes.writeInt16LE(-2, 1);
        bytes.writeInt16LE(300, 3);
        expect([...pcm16FromBytes(bytes.subarray(1))]).toEqual([-2, 300]);
    });
});

describe("VoiceBridge", () => {
    beforeEach(() => {
        rtcFake.reset();
    });

    afterEach(() => {
        vi.useRealTimers();
    });

    it("joins the room and publishes a 16 kHz microphone track", async () => {
        const { room } = await connectBridge();
        expect(room.connectedWith).toEqual({ url: "ws://livekit:7880", token: "room-token" });
        const [{ track, options }] = room.localParticipant!.tracks;
        expect(track.source.sampleRate).toBe(16000);
        expect(track.source.numChannels).toBe(1);
        expect(options.options).toEqual({ source: 2 });
        expect([...room.localParticipant!.rpcHandlers.keys()].sort()).toEqual(
            ["happy.getConfig", "processPermissionRequest", "sendMessageToSession"],
        );
    });

    it("captures uplink frames as 320-sample 16 kHz audio", async () => {
        const { bridge } = await connectBridge();
        const bytes = Buffer.alloc(VOICE_UPLINK_FRAME_BYTES);
        bytes.writeInt16LE(1234, 0);
        bytes.writeInt16LE(-5, VOICE_UPLINK_FRAME_BYTES - 2);
        bridge.pushAudio(bytes);
        await flush();
        const [frame] = rtcFake.sources[0].captured;
        expect(frame.sampleRate).toBe(16000);
        expect(frame.samplesPerChannel).toBe(320);
        expect(frame.data[0]).toBe(1234);
        expect(frame.data[319]).toBe(-5);
    });

    it("drops uplink frames while the source is backed up", async () => {
        const { bridge } = await connectBridge();
        rtcFake.sources[0].queuedDuration = 80;
        bridge.pushAudio(Buffer.alloc(VOICE_UPLINK_FRAME_BYTES));
        await flush();
        expect(rtcFake.sources[0].captured).toHaveLength(0);
    });

    it("streams the agent's audio as exact 480-sample frames at 24 kHz", async () => {
        const { room, audio } = await connectBridge();
        room.join(agent);
        room.emit(RoomEvent.TrackSubscribed, { kind: TrackKind.KIND_AUDIO }, {}, agent);
        const [stream] = rtcFake.streams;
        expect(stream.options).toEqual({ sampleRate: 24000, numChannels: 1, frameSizeMs: 20 });

        stream.push(new Array(300).fill(1));
        stream.push(new Array(700).fill(2));
        await flush();
        expect(audio.map((frame) => frame.length)).toEqual([960, 960]);
        expect([...pcm16FromBytes(audio[0])].slice(298, 302)).toEqual([1, 1, 2, 2]);
    });

    it("ignores audio tracks of other participants", async () => {
        const { room } = await connectBridge();
        room.emit(RoomEvent.TrackSubscribed, { kind: TrackKind.KIND_AUDIO }, {}, stranger);
        expect(rtcFake.streams).toHaveLength(0);
    });

    it("reports the agent's presence and state", async () => {
        const { room, messages } = await connectBridge();
        const speaking: FakeParticipant = { ...agent, attributes: { "lk.agent.state": "listening" } };
        room.join(speaking);
        speaking.attributes = { "lk.agent.state": "speaking" };
        room.emit(RoomEvent.ParticipantAttributesChanged, {}, speaking);
        speaking.attributes = { "lk.agent.state": "speaking", other: "x" };
        room.emit(RoomEvent.ParticipantAttributesChanged, {}, speaking);
        room.leave(speaking);
        expect(messages).toEqual([
            { type: "agent", present: true, state: "listening" },
            { type: "agent", present: true, state: "speaking" },
            { type: "agent", present: false },
        ]);
    });

    it("tells the app to flush when the agent is interrupted", async () => {
        const { room, messages } = await connectBridge();
        room.emit(RoomEvent.DataReceived, new Uint8Array(), stranger, 0, "happy.interrupted");
        expect(messages).toEqual([]);
        room.emit(RoomEvent.DataReceived, new Uint8Array(), agent, 0, "happy.interrupted");
        expect(messages).toEqual([{ type: "flush" }]);
    });

    it("queues text until the agent joins, keeping the newest 100", async () => {
        const { bridge, room } = await connectBridge();
        bridge.sendText("happy.context", "first");
        for (let i = 0; i < 104; i++) bridge.sendText("happy.text", `t${i}`);
        expect(room.localParticipant!.published).toEqual([]);

        room.join(agent);
        await flush();
        const published = room.localParticipant!.published;
        expect(published).toHaveLength(100);
        expect(published[0]).toEqual({ data: "t4", topic: "happy.text", reliable: true });
        expect(published[99].data).toBe("t103");

        bridge.sendText("happy.context", "live");
        await flush();
        expect(published[100]).toEqual({ data: "live", topic: "happy.context", reliable: true });
    });

    it("relays the agent's RPCs to the app and returns its answer", async () => {
        const { bridge, room, messages } = await connectBridge();
        room.join(agent);
        messages.length = 0;

        const call = room.callRpc("sendMessageToSession", agent.identity, '{"message":"hi"}', 30_000);
        await flush();
        expect(messages).toEqual([{ type: "rpc", id: "1", method: "sendMessageToSession", payload: '{"message":"hi"}' }]);
        bridge.rpcResult("1", "sent", undefined);
        await expect(call).resolves.toBe("sent");

        const failing = room.callRpc("processPermissionRequest", agent.identity, "{}");
        await flush();
        bridge.rpcResult("2", undefined, "no such request");
        await expect(failing).rejects.toMatchObject({ code: 1500, message: "no such request" });
    });

    it("refuses RPCs from anyone but the agent", async () => {
        vi.useFakeTimers();
        const { room, messages } = await connectBridge();
        room.join(stranger);
        await expect(room.callRpc("happy.getConfig", stranger.identity)).rejects.toMatchObject({ code: 2403 });

        // An unknown caller gets a moment to show up, then is refused too.
        const unknown = room.callRpc("happy.getConfig", "ghost");
        const assertion = expect(unknown).rejects.toMatchObject({ code: 2403 });
        await vi.advanceTimersByTimeAsync(3100);
        await assertion;
        expect(messages.filter((message) => message.type === "rpc")).toEqual([]);
    });

    it("accepts an RPC from the agent that arrives before it is announced", async () => {
        const { bridge, room } = await connectBridge();
        const call = room.callRpc("happy.getConfig", agent.identity);
        setTimeout(() => room.join(agent), 20);
        await new Promise((resolve) => setTimeout(resolve, 120));
        bridge.rpcResult("1", "{}", undefined);
        await expect(call).resolves.toBe("{}");
    });

    it("times out happy.getConfig after 10 s", async () => {
        vi.useFakeTimers();
        const { room } = await connectBridge();
        room.join(agent);
        const call = room.callRpc("happy.getConfig", agent.identity);
        const assertion = expect(call).rejects.toMatchObject({ code: 1502 });
        await vi.advanceTimersByTimeAsync(9_900);
        await vi.advanceTimersByTimeAsync(200);
        await assertion;
    });

    it("fails pending RPCs and leaves the room on close", async () => {
        const { bridge, room } = await connectBridge();
        room.join(agent);
        const call = room.callRpc("sendMessageToSession", agent.identity, "{}");
        await flush();
        await bridge.close();
        await expect(call).rejects.toMatchObject({ code: 1503 });
        expect(room.disconnected).toBe(true);
        expect(room.listenerCount(RoomEvent.TrackSubscribed)).toBe(0);
        expect(rtcFake.sources[0].closed).toBe(true);
        bridge.sendText("happy.text", "late");
        expect(room.localParticipant!.published).toEqual([]);
    });

    it("stops the agent audio stream on close", async () => {
        const { bridge, room } = await connectBridge();
        room.join(agent);
        room.emit(RoomEvent.TrackSubscribed, { kind: TrackKind.KIND_AUDIO }, {}, agent);
        await bridge.close();
        await flush();
        expect(rtcFake.streams[0].cancelled).toBe(true);
    });

    it("releases the room when closed while still connecting", async () => {
        let open!: () => void;
        rtcFake.connectGate = new Promise((resolve) => { open = resolve; });
        const { client } = createClient();
        const bridge = new VoiceBridge(client);
        const connecting = bridge.connect("ws://livekit:7880", "room-token");
        await flush();
        await bridge.close();
        open();
        await expect(connecting).rejects.toThrow("Voice bridge closed");
        expect(rtcFake.rooms[0].disconnected).toBe(true);
        expect(rtcFake.sources).toHaveLength(0);
    });

    it("reports when the room goes away on its own", async () => {
        const { room, client } = await connectBridge();
        room.emit(RoomEvent.Disconnected, 1);
        expect(client.onRoomClosed).toHaveBeenCalledTimes(1);
    });
});
