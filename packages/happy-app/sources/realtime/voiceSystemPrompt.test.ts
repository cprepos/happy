import { describe, expect, it } from 'vitest';
import { buildVoiceFirstMessage, buildVoiceSystemPrompt, voiceSystemPromptBase } from './voiceSystemPrompt';

const base = { onboardingPromptLoadCount: 0, voiceMessageCount: 0, includePaidVoiceOnboarding: false };

describe('voice system prompt', () => {
    it('answers to the voice name and to Happy, with the voice gender', () => {
        const prompt = buildVoiceSystemPrompt({ ...base, persona: { name: 'Morgan', gender: 'male' } });
        expect(prompt).toContain('You are a friendly man');
        expect(prompt).toContain('like "Morgan, ..." or "Happy, ..."');
        expect(buildVoiceFirstMessage({ ...base, hasPro: true, persona: { name: 'Morgan', gender: 'male' } })).toBe('Hi, Morgan here');
    });

    it('answers to Happy alone without a persona', () => {
        const prompt = buildVoiceSystemPrompt(base);
        expect(prompt).toContain('You are a friendly woman');
        expect(prompt).toContain('like "Happy, ..."');
        expect(buildVoiceFirstMessage({ ...base, hasPro: true })).toBe('Hi, Happy here');
    });

    it('keeps a persona named Happy as Happy', () => {
        expect(voiceSystemPromptBase({ name: 'Happy', gender: 'male' })).toContain('like "Happy, ..."');
        expect(voiceSystemPromptBase({ name: 'Happy', gender: 'male' })).not.toContain('"Happy, ..." or "Happy, ..."');
    });

    it('keeps the onboarding greeting named', () => {
        expect(
            buildVoiceFirstMessage({ hasPro: false, onboardingPromptLoadCount: 0, includePaidVoiceOnboarding: true, persona: { name: 'Morgan', gender: 'male' } }),
        ).toBe('Hi, Morgan here, ask me what I can do');
    });
});
