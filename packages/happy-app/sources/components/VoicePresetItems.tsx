import React from 'react';
import { Ionicons } from '@expo/vector-icons';
import { Item } from '@/components/Item';
import { VOICE_PRESETS, type VoicePreset } from '@/realtime/voiceCatalog';
import { t } from '@/text';

/** Translated "accent · tone" line shown under a preset's name. */
export function describeVoicePreset(preset: VoicePreset): string {
    const accent = preset.accent === 'uk'
        ? t('settingsVoice.voicePicker.accentUk')
        : t('settingsVoice.voicePicker.accentUs');
    const tone = {
        warm: t('settingsVoice.voicePicker.toneWarm'),
        bright: t('settingsVoice.voicePicker.toneBright'),
        soft: t('settingsVoice.voicePicker.toneSoft'),
        calm: t('settingsVoice.voicePicker.toneCalm'),
        deep: t('settingsVoice.voicePicker.toneDeep'),
        lively: t('settingsVoice.voicePicker.toneLively'),
    }[preset.tone];
    return `${accent} · ${tone}`;
}

/** One selectable row per voice preset, with a checkmark on `selectedId`. */
export const VoicePresetItems = React.memo(function VoicePresetItems(props: {
    selectedId: string | null;
    onSelect: (presetId: string) => void;
}) {
    return (
        <>
            {VOICE_PRESETS.map((preset) => (
                <Item
                    key={preset.id}
                    title={preset.label}
                    subtitle={describeVoicePreset(preset)}
                    icon={<Ionicons name="person-circle-outline" size={29} color="#007AFF" />}
                    rightElement={props.selectedId === preset.id
                        ? <Ionicons name="checkmark-circle" size={24} color="#007AFF" />
                        : null}
                    onPress={() => props.onSelect(preset.id)}
                    showChevron={false}
                />
            ))}
        </>
    );
});
