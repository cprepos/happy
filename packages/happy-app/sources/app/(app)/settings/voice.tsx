import React from 'react';
import { Ionicons } from '@expo/vector-icons';
import { useRouter } from 'expo-router';
import { Item } from '@/components/Item';
import { ItemGroup } from '@/components/ItemGroup';
import { ItemList } from '@/components/ItemList';
import { useSetting } from '@/sync/storage';
import { findLanguageByCode, getLanguageDisplayName, LANGUAGES } from '@/constants/Languages';
import { findVoicePreset } from '@/realtime/voiceCatalog';
import { t } from '@/text';

export default React.memo(function VoiceSettingsScreen() {
    const router = useRouter();
    const voiceAssistantLanguage = useSetting('voiceAssistantLanguage');
    const voicePreset = findVoicePreset(useSetting('voiceAssistantVoice'));

    // Find current language or default to first option
    const currentLanguage = findLanguageByCode(voiceAssistantLanguage) || LANGUAGES[0];

    return (
        <ItemList style={{ paddingTop: 0 }}>
            <ItemGroup
                title={t('settingsVoice.languageTitle')}
                footer={t('settingsVoice.languageDescription')}
            >
                <Item
                    title={t('settingsVoice.preferredLanguage')}
                    subtitle={t('settingsVoice.preferredLanguageSubtitle')}
                    icon={<Ionicons name="language-outline" size={29} color="#007AFF" />}
                    detail={getLanguageDisplayName(currentLanguage)}
                    onPress={() => router.push('/settings/voice/language')}
                />
            </ItemGroup>
            <ItemGroup
                title={t('settingsVoice.voiceTitle')}
                footer={t('settingsVoice.voiceDescription')}
            >
                <Item
                    title={t('settingsVoice.voice')}
                    subtitle={t('settingsVoice.voiceSubtitle')}
                    icon={<Ionicons name="mic-outline" size={29} color="#007AFF" />}
                    detail={voicePreset?.label ?? t('settingsVoice.voicePicker.serverDefault')}
                    onPress={() => router.push('/settings/voice/voices' as any)}
                />
            </ItemGroup>
        </ItemList>
    );
});
