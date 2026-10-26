import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => {
    const state = {
        realtimeStatus: 'disconnected' as string,
        modes: [] as string[],
        generation: 0,
        setRealtimeStatus(status: string) { state.realtimeStatus = status; },
        setRealtimeMode(mode: string) { state.modes.push(mode); },
        clearRealtimeModeDebounce() {},
        incrementVoiceSessionGeneration() { state.generation++; },
    };
    return {
        state,
        credentials: { token: 'secret-token', secret: 'x' } as { token: string; secret: string } | null,
        sendMessageToSession: vi.fn(async (_: unknown) => 'sent'),
        processPermissionRequest: vi.fn(async (_: unknown) => 'approved'),
    };
});

vi.mock('@/auth/tokenStorage', () => ({ TokenStorage: { getCredentials: async () => mocks.credentials } }));
vi.mock('@/sync/serverConfig', () => ({ getVoiceServerUrl: () => 'https://happy.example/' }));
vi.mock('@/sync/storage', () => ({ storage: { getState: () => mocks.state } }));
vi.mock('./realtimeClientTools', () => ({
    realtimeClientTools: {
        sendMessageToSession: mocks.sendMessageToSession,
        processPermissionRequest: mocks.processPermissionRequest,
    },
}));

import { HappyVoiceSession, voiceStreamUrl, type HappyVoiceAudio, type HappyVoiceAudioHandlers, type VoiceSocket } from './happyVoiceSession';

class FakeSocket implements VoiceSocket {
    binaryType = 'blob';
    readyState = 0;
    bufferedAmount = 0;
    sent: (string | ArrayBuffer)[] = [];
    closed = false;
    onopen: VoiceSocket['onopen'] = null;
    onmessage: VoiceSocket['onmessage'] = null;
    onclose: VoiceSocket['onclose'] = null;
    onerror: VoiceSocket['onerror'] = null;

    constructor(readonly url: string) {}

    send(data: string | ArrayBuffer) { this.sent.push(data); }
    close() { this.closed = true; this.readyState = 3; }

    open() { this.readyState = 1; this.onopen?.({}); }
    receive(message: object) { this.onmessage?.({ data: JSON.stringify(message) }); }
    receiveAudio(frame: ArrayBuffer) { this.onmessage?.({ data: frame }); }
    serverClose(code = 1000, reason = '') { this.readyState = 3; this.onclose?.({ code, reason }); }
    json() { return this.sent.filter((m): m is string => typeof m === 'string').map((m) => JSON.parse(m)); }
}

function fakeAudio() {
    let handlers: HappyVoiceAudioHandlers | null = null;
    const audio = {
        prime: vi.fn(),
        start: vi.fn(async (h: HappyVoiceAudioHandlers) => { handlers = h; }),
        play: vi.fn(),
        flush: vi.fn(),
        stop: vi.fn(async () => {}),
    } satisfies HappyVoiceAudio;
    return { audio, handlers: () => handlers! };
}

const config = {
    sessionId: 'session-1',
    initialContext: 'ctx',
    systemPrompt: 'prompt',
    firstMessage: 'hi',
    language: 'en',
};

async function connect() {
    const sockets: FakeSocket[] = [];
    const { audio, handlers } = fakeAudio();
    const session = new HappyVoiceSession(audio, {
        createSocket: (url) => {
            const socket = new FakeSocket(url);
            sockets.push(socket);
            return socket;
        },
    });
    const started = session.startSession(config);
    await vi.waitFor(() => expect(sockets).toHaveLength(1));
    const socket = sockets[0];
    return { session, socket, audio, handlers, started };
}

async function connectReady() {
    const setup = await connect();
    setup.socket.open();
    setup.socket.receive({ type: 'ready', conversationId: 'conv-1' });
    await expect(setup.started).resolves.toBe('conv-1');
    return setup;
}

beforeEach(() => {
    mocks.state.realtimeStatus = 'disconnected';
    mocks.state.modes = [];
    mocks.state.generation = 0;
    mocks.credentials = { token: 'secret-token', secret: 'x' };
    mocks.sendMessageToSession.mockClear();
    mocks.processPermissionRequest.mockClear();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
});

describe('voiceStreamUrl', () => {
    it('turns the server URL into the stream URL', () => {
        expect(voiceStreamUrl('https://happy.example')).toBe('wss://happy.example/v1/voice/stream');
        expect(voiceStreamUrl('https://happy.example/')).toBe('wss://happy.example/v1/voice/stream');
        expect(voiceStreamUrl('http://192.168.1.2:3005')).toBe('ws://192.168.1.2:3005/v1/voice/stream');
        expect(voiceStreamUrl('https://example.com/happy/?x=1')).toBe('wss://example.com/happy/v1/voice/stream');
    });
});

describe('HappyVoiceSession', () => {
    it('sends hello first with the token, never in the URL', async () => {
        const { socket, started } = await connect();
        expect(socket.url).toBe('wss://happy.example/v1/voice/stream');
        expect(socket.url).not.toContain('secret-token');
        expect(socket.binaryType).toBe('arraybuffer');
        expect(mocks.state.realtimeStatus).toBe('connecting');
        socket.open();
        expect(socket.json()).toEqual([{ type: 'hello', token: 'secret-token', sessionId: 'session-1', language: 'en' }]);
        socket.receive({ type: 'ready', conversationId: 'conv-1' });
        await expect(started).resolves.toBe('conv-1');
    });

    it('fails without credentials', async () => {
        mocks.credentials = null;
        const { audio } = fakeAudio();
        const session = new HappyVoiceSession(audio, { createSocket: () => { throw new Error('no socket expected'); } });
        await expect(session.startSession(config)).rejects.toThrow('Not authenticated');
    });

    it('is connected and idle on ready', async () => {
        await connectReady();
        expect(mocks.state.realtimeStatus).toBe('connected');
        expect(mocks.state.modes).toEqual(['idle']);
    });

    it('only streams microphone audio once ready', async () => {
        const { socket, handlers, started } = await connect();
        socket.open();
        handlers().onFrame(new ArrayBuffer(640));
        expect(socket.sent.filter((m) => m instanceof ArrayBuffer)).toHaveLength(0);
        socket.receive({ type: 'ready', conversationId: 'conv-1' });
        await started;
        const frame = new ArrayBuffer(640);
        handlers().onFrame(frame);
        expect(socket.sent[socket.sent.length - 1]).toBe(frame);
        // A backed-up socket drops audio rather than adding latency.
        socket.bufferedAmount = 64000;
        handlers().onFrame(new ArrayBuffer(640));
        expect(socket.sent.filter((m) => m instanceof ArrayBuffer)).toHaveLength(1);
    });

    it('plays agent audio and flushes it on interrupt', async () => {
        const { socket, audio } = await connectReady();
        const frame = new ArrayBuffer(960);
        socket.receiveAudio(frame);
        expect(audio.play).toHaveBeenCalledWith(frame);
        socket.receive({ type: 'flush' });
        expect(audio.flush).toHaveBeenCalledTimes(1);
    });

    it('queues text until the agent is present, then sends it in order', async () => {
        const { session, socket, started } = await connect();
        session.sendContextualUpdate('context before open');
        socket.open();
        socket.receive({ type: 'ready', conversationId: 'conv-1' });
        await started;
        session.sendTextMessage('hello agent');
        expect(socket.json().filter((m) => m.type === 'text')).toHaveLength(0);

        socket.receive({ type: 'agent', present: true, state: 'listening' });
        expect(socket.json().filter((m) => m.type === 'text')).toEqual([
            { type: 'text', topic: 'happy.context', text: 'context before open' },
            { type: 'text', topic: 'happy.text', text: 'hello agent' },
        ]);
        session.sendTextMessage('direct');
        expect(socket.json().at(-1)).toEqual({ type: 'text', topic: 'happy.text', text: 'direct' });
    });

    it('follows the agent state for the speaking mode', async () => {
        const { socket } = await connectReady();
        socket.receive({ type: 'agent', present: true, state: 'speaking' });
        expect(mocks.state.modes.at(-1)).toBe('agent-speaking');
        socket.receive({ type: 'agent', present: true, state: 'listening' });
        expect(mocks.state.modes.at(-1)).toBe('idle');
        socket.receive({ type: 'agent', present: true, state: 'speaking' });
        socket.receive({ type: 'agent', present: false });
        expect(mocks.state.modes.at(-1)).toBe('idle');
    });

    it('shows the user speaking with the same debounce as LiveKit', async () => {
        vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
        const { handlers } = await connectReady();
        handlers().onSpeaking(true);
        expect(mocks.state.modes.at(-1)).toBe('user-speaking');
        handlers().onSpeaking(false);
        expect(mocks.state.modes.at(-1)).toBe('user-speaking');
        vi.advanceTimersByTime(300);
        expect(mocks.state.modes.at(-1)).toBe('idle');
    });

    it('answers happy.getConfig with the session config', async () => {
        const { socket } = await connectReady();
        socket.receive({ type: 'rpc', id: 'r1', method: 'happy.getConfig', payload: '' });
        await vi.waitFor(() => expect(socket.json().some((m) => m.type === 'rpcResult')).toBe(true));
        const reply = socket.json().find((m) => m.type === 'rpcResult');
        expect(reply.id).toBe('r1');
        expect(JSON.parse(reply.result)).toEqual({
            systemPrompt: 'prompt',
            firstMessage: 'hi',
            initialContext: 'ctx',
            language: 'en',
            sessionId: 'session-1',
        });
    });

    it('relays client tool RPCs and their errors', async () => {
        const { socket } = await connectReady();
        socket.receive({ type: 'rpc', id: 'r2', method: 'sendMessageToSession', payload: '{"message":"do it"}' });
        socket.receive({ type: 'rpc', id: 'r3', method: 'processPermissionRequest', payload: '{"decision":"allow"}' });
        socket.receive({ type: 'rpc', id: 'r4', method: 'sendMessageToSession', payload: 'not json' });
        await vi.waitFor(() => expect(socket.json().filter((m) => m.type === 'rpcResult')).toHaveLength(3));
        expect(mocks.sendMessageToSession).toHaveBeenCalledWith({ message: 'do it' });
        expect(mocks.processPermissionRequest).toHaveBeenCalledWith({ decision: 'allow' });
        const results = Object.fromEntries(socket.json().filter((m) => m.type === 'rpcResult').map((m) => [m.id, m]));
        expect(results.r2).toEqual({ type: 'rpcResult', id: 'r2', result: 'sent' });
        expect(results.r3).toEqual({ type: 'rpcResult', id: 'r3', result: 'approved' });
        expect(results.r4).toEqual({ type: 'rpcResult', id: 'r4', error: 'payload is not valid JSON' });
    });

    it('rejects the start on a server error before ready', async () => {
        const { socket, started, audio } = await connect();
        socket.open();
        socket.receive({ type: 'error', code: 'unauthorized', message: 'bad token' });
        await expect(started).rejects.toThrow('unauthorized');
        expect(mocks.state.realtimeStatus).toBe('error');
        expect(audio.stop).toHaveBeenCalled();
        expect(socket.closed).toBe(true);
    });

    it('sets error status on a server error after ready', async () => {
        const { socket } = await connectReady();
        socket.receive({ type: 'error', code: 'unavailable', message: 'agent gone' });
        expect(mocks.state.realtimeStatus).toBe('error');
    });

    it('rejects the start when the socket closes before ready', async () => {
        const { socket, started } = await connect();
        socket.serverClose(1006);
        await expect(started).rejects.toThrow('closed (1006)');
        expect(mocks.state.realtimeStatus).toBe('error');
    });

    it('is disconnected and starts a new generation when the server closes', async () => {
        const { socket, audio } = await connectReady();
        socket.serverClose(1000);
        expect(mocks.state.realtimeStatus).toBe('disconnected');
        expect(mocks.state.generation).toBe(1);
        expect(audio.stop).toHaveBeenCalled();
    });

    it('ends with an end message, closes and releases audio', async () => {
        const { session, socket, audio } = await connectReady();
        await session.endSession();
        expect(socket.json().at(-1)).toEqual({ type: 'end' });
        expect(socket.closed).toBe(true);
        expect(audio.stop).toHaveBeenCalled();
        expect(mocks.state.realtimeStatus).toBe('disconnected');
        expect(mocks.state.generation).toBe(1);
        // Late messages from the old socket are ignored.
        session.sendTextMessage('after end');
        expect(socket.json().at(-1)).toEqual({ type: 'end' });
    });

    it('ending while connecting rejects the pending start', async () => {
        const { session, started } = await connect();
        await session.endSession();
        await expect(started).rejects.toThrow('ended');
    });

    it('prepare primes audio synchronously', () => {
        const { audio } = fakeAudio();
        new HappyVoiceSession(audio).prepare();
        expect(audio.prime).toHaveBeenCalledTimes(1);
    });
});
