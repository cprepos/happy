import { describe, expect, it } from 'vitest';
import {
    VoiceConfigResponseSchema,
    VoiceConversationElevenLabsGrantSchema,
    VoiceConversationGrantedSchema,
    VoiceConversationLiveKitGrantSchema,
    VoiceConversationRequestSchema,
    VoiceConversationResponseSchema,
} from './voice';

const liveKitGrant = {
    allowed: true,
    conversationId: 'conversation-1',
    roomName: 'happy-voice-conversation-1',
    token: 'livekit-token',
    url: 'wss://livekit.example.test',
};

const elevenLabsGrant = {
    allowed: true,
    conversationToken: 'elevenlabs-token',
    conversationId: 'conv_1',
    agentId: 'agent-1',
    elevenUserId: 'u_abc',
    usedSeconds: 10,
    limitSeconds: 1200,
};

const denied = {
    allowed: false,
    reason: 'subscription_required',
    usedSeconds: 1200,
    limitSeconds: 1200,
    agentId: 'agent-1',
};

describe('VoiceConfigResponseSchema', () => {
    it('accepts offered backends and a default', () => {
        const config = { backends: ['stream', 'elevenlabs'], defaultBackend: 'stream' };
        expect(VoiceConfigResponseSchema.parse(config)).toEqual(config);
    });

    it('accepts a server offering nothing', () => {
        const config = { backends: [], defaultBackend: null };
        expect(VoiceConfigResponseSchema.parse(config)).toEqual(config);
    });

    it('rejects an unknown backend and a missing default', () => {
        expect(VoiceConfigResponseSchema.safeParse({ backends: ['carrier-pigeon'], defaultBackend: null }).success).toBe(false);
        expect(VoiceConfigResponseSchema.safeParse({ backends: ['stream'], defaultBackend: 'carrier-pigeon' }).success).toBe(false);
        expect(VoiceConfigResponseSchema.safeParse({ backends: [] }).success).toBe(false);
    });
});

describe('VoiceConversationRequestSchema', () => {
    it('accepts every field, and none', () => {
        const request = { sessionId: 'session-1', language: 'en', agentId: 'agent-1' };
        expect(VoiceConversationRequestSchema.parse(request)).toEqual(request);
        expect(VoiceConversationRequestSchema.parse({})).toEqual({});
    });
});

describe('VoiceConversationResponseSchema', () => {
    it.each([
        ['LiveKit grant', liveKitGrant],
        ['ElevenLabs grant', elevenLabsGrant],
        ['denial', denied],
    ])('keeps every field of a %s', (_name, response) => {
        expect(VoiceConversationResponseSchema.parse(response)).toEqual(response);
    });

    it('rejects a grant of neither shape', () => {
        expect(VoiceConversationResponseSchema.safeParse({ allowed: true, conversationId: 'conversation-1' }).success).toBe(false);
    });

    it('tells the two grants apart', () => {
        expect(VoiceConversationLiveKitGrantSchema.safeParse(elevenLabsGrant).success).toBe(false);
        expect(VoiceConversationElevenLabsGrantSchema.safeParse(liveKitGrant).success).toBe(false);
        expect(VoiceConversationGrantedSchema.parse(liveKitGrant)).toEqual(liveKitGrant);
        expect(VoiceConversationGrantedSchema.parse(elevenLabsGrant)).toEqual(elevenLabsGrant);
        expect(VoiceConversationGrantedSchema.safeParse(denied).success).toBe(false);
    });
});
