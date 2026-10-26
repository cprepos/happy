import React from 'react';
import { Ionicons } from '@expo/vector-icons';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { Item } from '@/components/Item';
import { ItemGroup } from '@/components/ItemGroup';
import { ItemList } from '@/components/ItemList';
import { VoicePresetItems } from '@/components/VoicePresetItems';
import { findVoicePreset, getSessionVoicePreset, setSessionVoice } from '@/realtime/voiceCatalog';
import { useSetting, useSettingMutable } from '@/sync/storage';
import { t } from '@/text';

export default React.memo(function SessionVoiceScreen() {
    const router = useRouter();
    const { id } = useLocalSearchParams<{ id: string }>();
    const sessionId = id ?? '';
    const defaultVoice = findVoicePreset(useSetting('voiceAssistantVoice'));
    const [voiceBySession, setVoiceBySession] = useSettingMutable('voiceBySession');
    const selectedId = getSessionVoicePreset(sessionId, voiceBySession)?.id ?? null;

    const select = React.useCallback((presetId: string | null) => {
        if (sessionId) {
            setVoiceBySession(setSessionVoice(voiceBySession, sessionId, presetId));
        }
        router.back();
    }, [sessionId, voiceBySession, setVoiceBySession, router]);

    return (
        <ItemList style={{ paddingTop: 0 }}>
            <ItemGroup
                title={t('settingsVoice.voicePicker.chatTitle')}
                footer={`${t('settingsVoice.voicePicker.chatFooter')} ${t('settingsVoice.voicePicker.footer')}`}
            >
                <Item
                    title={t('settingsVoice.voicePicker.useDefault')}
                    subtitle={t('settingsVoice.voicePicker.useDefaultSubtitle', {
                        name: defaultVoice?.label ?? t('settingsVoice.voicePicker.serverDefault'),
                    })}
                    icon={<Ionicons name="settings-outline" size={29} color="#007AFF" />}
                    rightElement={selectedId === null
                        ? <Ionicons name="checkmark-circle" size={24} color="#007AFF" />
                        : null}
                    onPress={() => select(null)}
                    showChevron={false}
                />
                <VoicePresetItems selectedId={selectedId} onSelect={select} />
            </ItemGroup>
        </ItemList>
    );
});
