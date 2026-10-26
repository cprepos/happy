import {
    VOICE_STREAM_DOWNLINK_RATE,
    VOICE_STREAM_UPLINK_FRAME_SAMPLES,
    VOICE_STREAM_UPLINK_RATE,
} from '@slopus/happy-wire';
import type { HappyVoiceAudio, HappyVoiceAudioHandlers } from './happyVoiceSession';
import {
    VOICE_CAPTURE_PROCESSOR,
    VOICE_JITTER_DEFAULTS,
    VOICE_PLAYBACK_PROCESSOR,
    VOICE_WORKLET_SOURCE,
} from './voiceAudioWorklets';

/** Mic RMS counted as speech (≈ -36 dBFS, after the browser's AGC and noise suppression). */
const SPEECH_THRESHOLD = 0.015;
/** Frames (20 ms) above the threshold before speaking, and below it before not. */
const SPEECH_ATTACK_FRAMES = 2;
const SPEECH_RELEASE_FRAMES = 10;

type AudioContextConstructor = typeof AudioContext;

function audioContextClass(): AudioContextConstructor {
    const constructor = window.AudioContext
        ?? (window as unknown as { webkitAudioContext?: AudioContextConstructor }).webkitAudioContext;
    if (!constructor) {
        throw new Error('This browser has no Web Audio support');
    }
    return constructor;
}

/** Worklet modules are per AudioWorklet, so each new context loads them again. */
async function loadVoiceWorklets(context: AudioContext) {
    if (!context.audioWorklet) {
        throw new Error('This browser has no AudioWorklet support');
    }
    const url = URL.createObjectURL(new Blob([VOICE_WORKLET_SOURCE], { type: 'application/javascript' }));
    try {
        await context.audioWorklet.addModule(url);
    } finally {
        URL.revokeObjectURL(url);
    }
}

/**
 * Browser audio for `HappyVoiceSession`: one AudioContext for both
 * directions, the microphone through a capture worklet (16 kHz PCM16 frames
 * plus a speaking flag) and agent audio through a jitter-buffered playback
 * worklet. Everything is released on `stop`.
 */
export function createWebVoiceAudio(): HappyVoiceAudio {
    let context: AudioContext | null = null;
    let stream: MediaStream | null = null;
    let source: MediaStreamAudioSourceNode | null = null;
    let capture: AudioWorkletNode | null = null;
    let playback: AudioWorkletNode | null = null;
    // Bumped by stop, so a start still awaiting knows it was cancelled.
    let generation = 0;

    const ensureContext = (): AudioContext => {
        if (!context || context.state === 'closed') {
            const AudioContextClass = audioContextClass();
            context = new AudioContextClass({ latencyHint: 'interactive' });
            context.onstatechange = () => {
                // iOS suspends ("interrupted") on calls and Siri; pick up again when allowed.
                if (context && context.state !== 'running' && context.state !== 'closed' && capture) {
                    console.warn('[Voice] AudioContext', context.state);
                    context.resume().catch(() => {});
                }
            };
        }
        if (context.state !== 'running') {
            context.resume().catch((error) => console.warn('[Voice] AudioContext resume failed:', error));
        }
        return context;
    };

    const release = async () => {
        capture?.port.postMessage({ type: 'stop' });
        playback?.port.postMessage({ type: 'stop' });
        if (capture) capture.port.onmessage = null;
        source?.disconnect();
        capture?.disconnect();
        playback?.disconnect();
        stream?.getTracks().forEach((track) => track.stop());
        source = null;
        capture = null;
        playback = null;
        stream = null;
        const closing = context;
        context = null;
        if (closing && closing.state !== 'closed') {
            closing.onstatechange = null;
            await closing.close();
        }
    };

    return {
        prime() {
            ensureContext();
        },

        async start(handlers: HappyVoiceAudioHandlers) {
            if (!navigator.mediaDevices?.getUserMedia) {
                throw new Error('This browser has no microphone access (getUserMedia)');
            }
            const started = ++generation;
            const ctx = ensureContext();
            const [media] = await Promise.all([
                navigator.mediaDevices.getUserMedia({
                    audio: {
                        channelCount: 1,
                        echoCancellation: true,
                        noiseSuppression: true,
                        autoGainControl: true,
                    },
                }),
                loadVoiceWorklets(ctx),
            ]);
            if (started !== generation || ctx !== context) {
                media.getTracks().forEach((track) => track.stop());
                throw new Error('Voice audio stopped while starting');
            }
            stream = media;
            if (ctx.state !== 'running') {
                await ctx.resume().catch((error) => console.warn('[Voice] AudioContext resume failed:', error));
            }

            capture = new AudioWorkletNode(ctx, VOICE_CAPTURE_PROCESSOR, {
                numberOfInputs: 1,
                numberOfOutputs: 1,
                outputChannelCount: [1],
                channelCount: 1,
                channelCountMode: 'explicit',
                channelInterpretation: 'speakers',
                processorOptions: {
                    outRate: VOICE_STREAM_UPLINK_RATE,
                    frameSamples: VOICE_STREAM_UPLINK_FRAME_SAMPLES,
                    speechThreshold: SPEECH_THRESHOLD,
                    attackFrames: SPEECH_ATTACK_FRAMES,
                    releaseFrames: SPEECH_RELEASE_FRAMES,
                },
            });
            capture.port.onmessage = (event: MessageEvent) => {
                const data = event.data;
                if (data instanceof ArrayBuffer) handlers.onFrame(data);
                else if (data?.type === 'speaking') handlers.onSpeaking(Boolean(data.speaking));
            };

            playback = new AudioWorkletNode(ctx, VOICE_PLAYBACK_PROCESSOR, {
                numberOfInputs: 0,
                numberOfOutputs: 1,
                outputChannelCount: [1],
                processorOptions: { inRate: VOICE_STREAM_DOWNLINK_RATE, ...VOICE_JITTER_DEFAULTS },
            });

            source = ctx.createMediaStreamSource(media);
            source.connect(capture);
            // The capture node only outputs silence; connecting it keeps every
            // browser pulling it (not all process unconnected nodes).
            capture.connect(ctx.destination);
            playback.connect(ctx.destination);

            media.getAudioTracks()[0]?.addEventListener('ended', () => {
                if (started === generation) handlers.onEnded();
            });
            console.log(`[Voice] Audio running at ${ctx.sampleRate} Hz, base latency ${Math.round((ctx.baseLatency ?? 0) * 1000)} ms`);
        },

        play(frame: ArrayBuffer) {
            playback?.port.postMessage(frame, [frame]);
        },

        flush() {
            playback?.port.postMessage({ type: 'flush' });
        },

        async stop() {
            generation++;
            await release();
        },
    };
}
