import * as z from 'zod';

/**
 * Voice stream: the app's only voice connection, a WebSocket to happy-server
 * at `VOICE_STREAM_PATH`. The server joins the LiveKit room on the app's
 * behalf, so the app never talks to LiveKit.
 *
 * Binary frames carry audio, PCM 16-bit signed little-endian mono, one
 * `VOICE_STREAM_FRAME_MS` frame per message:
 * - app → server: microphone at `VOICE_STREAM_UPLINK_RATE`;
 * - server → app: agent speech at `VOICE_STREAM_DOWNLINK_RATE`.
 *
 * Text frames carry one JSON control message each. The app's first message
 * must be `hello`; the server answers `ready` or `error` and closes on error.
 * Audio sent before `ready` is dropped.
 */
export const VOICE_STREAM_PATH = '/v1/voice/stream';
export const VOICE_STREAM_UPLINK_RATE = 16000;
export const VOICE_STREAM_DOWNLINK_RATE = 24000;
export const VOICE_STREAM_FRAME_MS = 20;
/** Samples per uplink frame (320) and per downlink frame (480). */
export const VOICE_STREAM_UPLINK_FRAME_SAMPLES = (VOICE_STREAM_UPLINK_RATE * VOICE_STREAM_FRAME_MS) / 1000;
export const VOICE_STREAM_DOWNLINK_FRAME_SAMPLES = (VOICE_STREAM_DOWNLINK_RATE * VOICE_STREAM_FRAME_MS) / 1000;

/** Data topics relayed between the app and the agent. */
export const VoiceStreamTopicSchema = z.enum(['happy.text', 'happy.context']);
export type VoiceStreamTopic = z.infer<typeof VoiceStreamTopicSchema>;

/** RPC methods the agent may call on the app (through the server). */
export const VoiceStreamRpcMethodSchema = z.enum([
    'happy.getConfig',
    'sendMessageToSession',
    'processPermissionRequest',
]);
export type VoiceStreamRpcMethod = z.infer<typeof VoiceStreamRpcMethodSchema>;

/** Values of the agent's `lk.agent.state` attribute. */
export const VoiceAgentStateSchema = z.enum(['initializing', 'idle', 'listening', 'thinking', 'speaking']);
export type VoiceAgentState = z.infer<typeof VoiceAgentStateSchema>;

// --- app → server ---

export const VoiceStreamHelloSchema = z.object({
    type: z.literal('hello'),
    /** The account's Happy auth token (same as the REST Bearer token). */
    token: z.string().min(1),
    sessionId: z.string().optional(),
    language: z.string().optional(),
});

export const VoiceStreamClientTextSchema = z.object({
    type: z.literal('text'),
    topic: VoiceStreamTopicSchema,
    text: z.string(),
});

export const VoiceStreamRpcResultSchema = z.object({
    type: z.literal('rpcResult'),
    id: z.string(),
    /** Present on success. */
    result: z.string().optional(),
    /** Present on failure. */
    error: z.string().optional(),
});

export const VoiceStreamEndSchema = z.object({
    type: z.literal('end'),
});

export const VoiceStreamClientMessageSchema = z.discriminatedUnion('type', [
    VoiceStreamHelloSchema,
    VoiceStreamClientTextSchema,
    VoiceStreamRpcResultSchema,
    VoiceStreamEndSchema,
]);
export type VoiceStreamClientMessage = z.infer<typeof VoiceStreamClientMessageSchema>;

// --- server → app ---

export const VoiceStreamReadySchema = z.object({
    type: z.literal('ready'),
    conversationId: z.string(),
});

export const VoiceStreamAgentSchema = z.object({
    type: z.literal('agent'),
    /** Whether the agent is in the room. */
    present: z.boolean(),
    state: VoiceAgentStateSchema.optional(),
});

export const VoiceStreamRpcSchema = z.object({
    type: z.literal('rpc'),
    id: z.string(),
    method: VoiceStreamRpcMethodSchema,
    /** JSON string, as the agent sent it. */
    payload: z.string(),
});

/** The agent was interrupted: drop any agent audio not yet played. */
export const VoiceStreamFlushSchema = z.object({
    type: z.literal('flush'),
});

export const VoiceStreamErrorSchema = z.object({
    type: z.literal('error'),
    code: z.enum(['unauthorized', 'bad_request', 'unavailable', 'internal']),
    message: z.string(),
});

export const VoiceStreamServerMessageSchema = z.discriminatedUnion('type', [
    VoiceStreamReadySchema,
    VoiceStreamAgentSchema,
    VoiceStreamRpcSchema,
    VoiceStreamFlushSchema,
    VoiceStreamErrorSchema,
]);
export type VoiceStreamServerMessage = z.infer<typeof VoiceStreamServerMessageSchema>;

/**
 * Data topic on which the agent announces it was interrupted, so the server
 * can tell the app to `flush`. Payload is empty.
 */
export const VOICE_TOPIC_INTERRUPTED = 'happy.interrupted';
