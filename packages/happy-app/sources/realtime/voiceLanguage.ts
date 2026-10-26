import { findLanguageByCode } from '@/constants/Languages';

/**
 * Temporary stand-in for `getVoiceLanguageCode` from `constants/Languages.ts`,
 * which replaces `getElevenLabsCodeFromPreference` in a parallel change. It
 * reads the language's `voiceCode` (new name) or `elevenLabsCode` (old name),
 * so it compiles on either side of that rename. Replace its use with the
 * import from `@/constants/Languages` once both changes are merged.
 */
export function getVoiceLanguageCode(languageCode: string | null): string | undefined {
    if (!languageCode) return undefined; // auto-detect
    const language = findLanguageByCode(languageCode) as
        | { voiceCode?: string; elevenLabsCode?: string }
        | undefined;
    return language?.voiceCode ?? language?.elevenLabsCode;
}
