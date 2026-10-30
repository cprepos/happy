import * as React from 'react';
import { ActivityIndicator, Platform, Pressable, Text, View } from 'react-native';
import { StyleSheet, useUnistyles } from 'react-native-unistyles';
import { ProjectHomeList } from '@/components/ProjectHomeList';
import { MOBILE_GLASS_HEADER_HEIGHT } from '@/components/navigation/headerMetrics';
import { useVisibleSessionListViewData } from '@/hooks/useVisibleSessionListViewData';

/**
 * The grouped home screen on this account's own sessions, reachable without
 * switching the home layout for every device. Same component the home screen
 * mounts, so rows open the sessions they name, and the switch at the top shows
 * either grouping — the project tree or the chats under their host.
 */
export default function ProjectHomePreviewScreen() {
    const styles = stylesheet;
    const { theme } = useUnistyles();
    const data = useVisibleSessionListViewData();
    const [grouping, setGrouping] = React.useState<'project' | 'machine'>('project');

    if (data === null) {
        return (
            <View style={[styles.container, styles.centered]}>
                <ActivityIndicator size="small" color={theme.colors.textSecondary} />
            </View>
        );
    }

    return (
        <View style={styles.container}>
            {/* This screen's header is translucent on iOS and the list runs
                under it, so the first row has to be let down past it — the
                same clearance the settings screen gives its own list. Without
                it the machine heading sat behind the header bar. */}
            <ProjectHomeList
                grouping={grouping}
                topContentInset={Platform.OS === 'ios' ? MOBILE_GLASS_HEADER_HEIGHT : 0}
                scrollIndicatorTopInset={Platform.OS === 'ios' ? MOBILE_GLASS_HEADER_HEIGHT : 0}
                bottomContentInset={24}
            />
            <View style={styles.switcher}>
                {(['project', 'machine'] as const).map((mode) => (
                    <Pressable
                        key={mode}
                        style={[styles.switch, grouping === mode && styles.switchActive]}
                        onPress={() => setGrouping(mode)}
                    >
                        <Text style={styles.switchLabel}>{mode}</Text>
                    </Pressable>
                ))}
            </View>
        </View>
    );
}

const stylesheet = StyleSheet.create((theme) => ({
    container: {
        flex: 1,
        backgroundColor: theme.colors.groupped.background,
    },
    centered: {
        alignItems: 'center',
        justifyContent: 'center',
    },
    switcher: {
        position: 'absolute',
        bottom: 24,
        alignSelf: 'center',
        flexDirection: 'row',
        gap: 4,
        padding: 4,
        borderRadius: 999,
        backgroundColor: theme.colors.surface,
    },
    switch: {
        paddingHorizontal: 14,
        paddingVertical: 6,
        borderRadius: 999,
    },
    switchActive: {
        backgroundColor: theme.colors.surfaceHigh,
    },
    switchLabel: {
        color: theme.colors.text,
        fontSize: 13,
    },
}));
