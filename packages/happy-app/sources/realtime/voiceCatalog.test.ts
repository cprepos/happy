import { describe, expect, it } from 'vitest';
import {
    VOICE_PRESETS,
    findVoicePreset,
    getSessionVoicePreset,
    resolveVoicePreset,
    setSessionVoice,
    voiceConfigFor,
} from './voiceCatalog';
import { buildAgentConfigJson } from './voiceAgentConfig';

// Voices served by the self-hosted Kokoro-FastAPI (GET /v1/audio/voices).
const KOKORO_VOICES = new Set([
    'af_heart', 'af_bella', 'af_nicole', 'am_michael', 'am_onyx', 'am_fenrir', 'am_puck',
    'bf_emma', 'bm_george', 'bm_fable', 'bm_lewis',
]);
// Same grammar the agent accepts: a name, or name(n)+name(n) with up to 4 parts.
const BLEND_PART = /^([a-z]{2}_[a-z]+)\((\d+)\)$/;

describe('voice catalog', () => {
    it('has unique ids and labels', () => {
        expect(new Set(VOICE_PRESETS.map((p) => p.id)).size).toBe(VOICE_PRESETS.length);
        expect(new Set(VOICE_PRESETS.map((p) => p.label)).size).toBe(VOICE_PRESETS.length);
    });

    it('only uses Kokoro voices the agent will accept', () => {
        for (const preset of VOICE_PRESETS) {
            const parts = preset.voice.split('+');
            expect(parts.length).toBeLessThanOrEqual(4);
            for (const part of parts) {
                const name = parts.length === 1 ? part : part.match(BLEND_PART)?.[1];
                if (parts.length > 1) {
                    expect(Number(part.match(BLEND_PART)?.[2])).toBeGreaterThan(0);
                }
                expect(KOKORO_VOICES.has(name ?? ''), `${preset.id}: ${part}`).toBe(true);
            }
            expect(preset.speed).toBeGreaterThanOrEqual(0.5);
            expect(preset.speed).toBeLessThanOrEqual(1.5);
        }
    });

    it('keeps the current server voice as the Heart preset', () => {
        expect(findVoicePreset('heart')).toMatchObject({ voice: 'af_heart', speed: 1 });
        expect(findVoicePreset('deep')).toMatchObject({ voice: 'am_michael(2)+am_onyx(1)', speed: 0.85 });
    });

    it('finds presets by id', () => {
        expect(findVoicePreset(null)).toBeNull();
        expect(findVoicePreset(undefined)).toBeNull();
        expect(findVoicePreset('')).toBeNull();
        expect(findVoicePreset('nope')).toBeNull();
        expect(findVoicePreset('george')?.label).toBe('George');
    });
});

describe('resolveVoicePreset', () => {
    it('prefers the chat override, then the default, then none', () => {
        expect(resolveVoicePreset('s1', { s1: 'lewis' }, 'bella')?.id).toBe('lewis');
        expect(resolveVoicePreset('s2', { s1: 'lewis' }, 'bella')?.id).toBe('bella');
        expect(resolveVoicePreset('s2', {}, null)).toBeNull();
        expect(resolveVoicePreset('s2', undefined, undefined)).toBeNull();
    });

    it('skips unknown ids', () => {
        expect(resolveVoicePreset('s1', { s1: 'retired' }, 'bella')?.id).toBe('bella');
        expect(resolveVoicePreset('s1', { s1: 'retired' }, 'gone')).toBeNull();
        expect(getSessionVoicePreset('s1', { s1: 'retired' })).toBeNull();
    });
});

describe('setSessionVoice', () => {
    it('sets and removes a chat override without mutating', () => {
        const base = { a: 'heart' };
        const set = setSessionVoice(base, 'b', 'onyx');
        expect(set).toEqual({ a: 'heart', b: 'onyx' });
        expect(base).toEqual({ a: 'heart' });
        expect(setSessionVoice(set, 'b', null)).toEqual({ a: 'heart' });
        expect(setSessionVoice(set, 'b', 'unknown')).toEqual({ a: 'heart' });
        expect(setSessionVoice(undefined, 'c', 'emma')).toEqual({ c: 'emma' });
    });
});

describe('agent config', () => {
    const base = { sessionId: 's1', systemPrompt: 'p', firstMessage: 'hi', initialContext: 'ctx', language: 'en' };

    it('includes voice and speed when a preset is picked', () => {
        const json = JSON.parse(buildAgentConfigJson({ ...base, ...voiceConfigFor(findVoicePreset('deep')) }));
        expect(json).toEqual({ ...base, voice: 'am_michael(2)+am_onyx(1)', speed: 0.85 });
    });

    it('omits voice and speed when none is picked', () => {
        expect(voiceConfigFor(null)).toEqual({});
        const json = JSON.parse(buildAgentConfigJson({ ...base, ...voiceConfigFor(null) }));
        expect(json).toEqual(base);
        expect('voice' in json).toBe(false);
        expect('speed' in json).toBe(false);
    });

    it('answers with empty defaults before a session starts', () => {
        expect(JSON.parse(buildAgentConfigJson(null))).toEqual({
            systemPrompt: '', firstMessage: '', initialContext: '', language: null, sessionId: '',
        });
    });
});
