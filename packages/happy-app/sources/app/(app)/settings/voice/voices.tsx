import React from 'react';
import { Ionicons } from '@expo/vector-icons';
import { useRouter } from 'expo-router';
import { Item } from '@/components/Item';
import { ItemGroup } from '@/components/ItemGroup';
import { ItemList } from '@/components/ItemList';
import { VoicePresetItems } from '@/components/VoicePresetItems';
import { findVoicePreset } from '@/realtime/voiceCatalog';
import { useSettingMutable } from '@/sync/storage';
import { t } from '@/text';

export default React.memo(function VoiceSelectionScreen() {
    const router = useRouter();
    const [voiceAssistantVoice, setVoiceAssistantVoice] = useSettingMutable('voiceAssistantVoice');
    // An id from a newer or older app version that this catalog lacks reads as the server default.
    const selectedId = findVoicePreset(voiceAssistantVoice)?.id ?? null;

    const select = React.useCallback((presetId: string | null) => {
        setVoiceAssistantVoice(presetId);
        router.back();
    }, [setVoiceAssistantVoice, router]);

    return (
        <ItemList style={{ paddingTop: 0 }}>
            <ItemGroup
                title={t('settingsVoice.voicePicker.title')}
                footer={t('settingsVoice.voicePicker.footer')}
            >
                <Item
                    title={t('settingsVoice.voicePicker.serverDefault')}
                    subtitle={t('settingsVoice.voicePicker.serverDefaultSubtitle')}
                    icon={<Ionicons name="server-outline" size={29} color="#007AFF" />}
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
