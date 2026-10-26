// Language codes passed to the voice agent (ISO 639-1, plus pt-br)
export type VoiceLanguage = "en" | "ja" | "zh" | "de" | "hi" | "fr" | "ko" | 
    "pt" | "pt-br" | "it" | "es" | "id" | "nl" | "tr" | "pl" | "sv" | "bg" | 
    "ro" | "ar" | "cs" | "el" | "fi" | "ms" | "da" | "ta" | "uk" | "ru" | 
    "hu" | "hr" | "sk" | "no" | "vi";

// Language type definition
export interface Language {
    code: string | null; // null for autodetect
    name: string;
    nativeName: string;
    region?: string;
    voiceCode?: VoiceLanguage; // Voice agent language code
}

// Comprehensive language list with locale codes, names, and regions
// First option is autodetect (null value)
export const LANGUAGES: Language[] = [
    { code: null, name: 'Auto-detect', nativeName: 'Auto-detect' },
    { code: 'en-US', name: 'English', nativeName: 'English', region: 'United States', voiceCode: 'en' },
    { code: 'en-GB', name: 'English', nativeName: 'English', region: 'United Kingdom', voiceCode: 'en' },
    { code: 'en-AU', name: 'English', nativeName: 'English', region: 'Australia', voiceCode: 'en' },
    { code: 'en-CA', name: 'English', nativeName: 'English', region: 'Canada', voiceCode: 'en' },
    { code: 'es-ES', name: 'Spanish', nativeName: 'Español', region: 'Spain', voiceCode: 'es' },
    { code: 'es-MX', name: 'Spanish', nativeName: 'Español', region: 'Mexico', voiceCode: 'es' },
    { code: 'es-AR', name: 'Spanish', nativeName: 'Español', region: 'Argentina', voiceCode: 'es' },
    { code: 'fr-FR', name: 'French', nativeName: 'Français', region: 'France', voiceCode: 'fr' },
    { code: 'fr-CA', name: 'French', nativeName: 'Français', region: 'Canada', voiceCode: 'fr' },
    { code: 'de-DE', name: 'German', nativeName: 'Deutsch', region: 'Germany', voiceCode: 'de' },
    { code: 'de-AT', name: 'German', nativeName: 'Deutsch', region: 'Austria', voiceCode: 'de' },
    { code: 'it-IT', name: 'Italian', nativeName: 'Italiano', voiceCode: 'it' },
    { code: 'pt-BR', name: 'Portuguese', nativeName: 'Português', region: 'Brazil', voiceCode: 'pt-br' },
    { code: 'pt-PT', name: 'Portuguese', nativeName: 'Português', region: 'Portugal', voiceCode: 'pt' },
    { code: 'ru-RU', name: 'Russian', nativeName: 'Русский', voiceCode: 'ru' },
    { code: 'zh-CN', name: 'Chinese', nativeName: '中文', region: 'Simplified', voiceCode: 'zh' },
    { code: 'zh-TW', name: 'Chinese', nativeName: '中文', region: 'Traditional', voiceCode: 'zh' },
    { code: 'ja-JP', name: 'Japanese', nativeName: '日本語', voiceCode: 'ja' },
    { code: 'ko-KR', name: 'Korean', nativeName: '한국어', voiceCode: 'ko' },
    { code: 'ar-SA', name: 'Arabic', nativeName: 'العربية', voiceCode: 'ar' },
    { code: 'hi-IN', name: 'Hindi', nativeName: 'हिन्दी', voiceCode: 'hi' },
    { code: 'nl-NL', name: 'Dutch', nativeName: 'Nederlands', voiceCode: 'nl' },
    { code: 'sv-SE', name: 'Swedish', nativeName: 'Svenska', voiceCode: 'sv' },
    { code: 'no-NO', name: 'Norwegian', nativeName: 'Norsk', voiceCode: 'no' },
    { code: 'da-DK', name: 'Danish', nativeName: 'Dansk', voiceCode: 'da' },
    { code: 'fi-FI', name: 'Finnish', nativeName: 'Suomi', voiceCode: 'fi' },
    { code: 'pl-PL', name: 'Polish', nativeName: 'Polski', voiceCode: 'pl' },
    { code: 'tr-TR', name: 'Turkish', nativeName: 'Türkçe', voiceCode: 'tr' },
    { code: 'he-IL', name: 'Hebrew', nativeName: 'עברית' }, // No voice language code; the agent auto-detects
    { code: 'th-TH', name: 'Thai', nativeName: 'ไทย' }, // No voice language code; the agent auto-detects
    { code: 'vi-VN', name: 'Vietnamese', nativeName: 'Tiếng Việt', voiceCode: 'vi' },
    { code: 'id-ID', name: 'Indonesian', nativeName: 'Bahasa Indonesia', voiceCode: 'id' },
    { code: 'ms-MY', name: 'Malay', nativeName: 'Bahasa Melayu', voiceCode: 'ms' },
    { code: 'uk-UA', name: 'Ukrainian', nativeName: 'Українська', voiceCode: 'uk' },
    { code: 'cs-CZ', name: 'Czech', nativeName: 'Čeština', voiceCode: 'cs' },
    { code: 'hu-HU', name: 'Hungarian', nativeName: 'Magyar', voiceCode: 'hu' },
    { code: 'ro-RO', name: 'Romanian', nativeName: 'Română', voiceCode: 'ro' },
    { code: 'bg-BG', name: 'Bulgarian', nativeName: 'Български', voiceCode: 'bg' },
    { code: 'el-GR', name: 'Greek', nativeName: 'Ελληνικά', voiceCode: 'el' },
    { code: 'hr-HR', name: 'Croatian', nativeName: 'Hrvatski', voiceCode: 'hr' },
    { code: 'sk-SK', name: 'Slovak', nativeName: 'Slovenčina', voiceCode: 'sk' },
    { code: 'sl-SI', name: 'Slovenian', nativeName: 'Slovenščina' }, // No voice language code; the agent auto-detects
    { code: 'et-EE', name: 'Estonian', nativeName: 'Eesti' }, // No voice language code; the agent auto-detects
    { code: 'lv-LV', name: 'Latvian', nativeName: 'Latviešu' }, // No voice language code; the agent auto-detects
    { code: 'lt-LT', name: 'Lithuanian', nativeName: 'Lietuvių' }, // No voice language code; the agent auto-detects
];

/**
 * Format display name for a language
 */
export const getLanguageDisplayName = (language: Language) => {
    const parts = [];
    
    if (language.name !== language.nativeName) {
        parts.push(`${language.name} (${language.nativeName})`);
    } else {
        parts.push(language.name);
    }
    
    if (language.region) {
        parts.push(language.region);
    }
    
    return parts.join(' - ');
};

/**
 * Find a language by its code (including null for autodetect)
 */
export const findLanguageByCode = (code: string | null): Language | undefined => {
    return LANGUAGES.find(lang => lang.code === code);
};

/**
 * Get the voice agent language code for a given language
 */
export const getVoiceCode = (language: Language): VoiceLanguage | undefined => {
    return language.voiceCode;
};

/**
 * Get the voice agent language code from the user's language preference (handles null/autodetect)
 */
export const getVoiceLanguageCode = (
    languageCode: string | null
): VoiceLanguage | undefined => {
    if (!languageCode) return undefined; // Auto-detect case
    const language = findLanguageByCode(languageCode);
    return language?.voiceCode;
};

/**
 * Get all languages that have a voice agent language code
 */
export const getVoiceSupportedLanguages = (): Language[] => {
    return LANGUAGES.filter(lang => lang.voiceCode !== undefined);
};