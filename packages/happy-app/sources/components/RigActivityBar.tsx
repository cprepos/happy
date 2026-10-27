import * as React from 'react';
import { View, Text, Pressable } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useUnistyles } from 'react-native-unistyles';
import { Typography } from '@/constants/Typography';
import type { Metadata, SubagentInfo } from '@/sync/storageTypes';
import { getRigActivityIndicators } from '@/sync/rig';

const iconByKey = {
    subagents: 'people-outline',
    workflows: 'git-network-outline',
    processes: 'terminal-outline',
    tasks: 'checkbox-outline',
} as const;

const labelByKey = {
    subagents: 'agents',
    workflows: 'workflows',
    processes: 'processes',
    tasks: 'tasks',
} as const;

function statusDotColor(status: SubagentInfo['status'], theme: any): string {
    switch (status) {
        case 'running': return theme.colors.accent ?? '#34C759';
        case 'completed': return theme.colors.textSecondary;
        case 'failed': return '#FF3B30';
        case 'stopped': return theme.colors.textSecondary;
        default: return theme.colors.textSecondary;
    }
}

function formatDuration(ms: number | undefined): string {
    if (ms == null) return '';
    const seconds = Math.round(ms / 1000);
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    const remainingSeconds = seconds % 60;
    return `${minutes}m ${remainingSeconds}s`;
}

function formatTokens(tokens: number | undefined): string {
    if (tokens == null) return '';
    if (tokens < 1000) return `${tokens}`;
    if (tokens < 1000000) return `${(tokens / 1000).toFixed(1)}k`;
    return `${(tokens / 1000000).toFixed(1)}M`;
}

const AgentRow = React.memo(function AgentRow({
    agent,
    expanded,
    onToggle,
}: {
    agent: SubagentInfo;
    expanded: boolean;
    onToggle: () => void;
}) {
    const { theme } = useUnistyles();
    const dotColor = statusDotColor(agent.status, theme);
    const isRunning = agent.status === 'running';
    const elapsed = isRunning ? Date.now() - agent.startedAt : agent.durationMs;

    return (
        <Pressable onPress={onToggle} style={{ paddingVertical: 4, paddingHorizontal: 4, marginLeft: (agent.spawnDepth ?? 1) > 1 ? 16 : 0 }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                <View style={{
                    width: 6, height: 6, borderRadius: 3,
                    backgroundColor: dotColor,
                }} />
                <Text
                    style={{ flex: 1, fontSize: 12, color: theme.colors.text, ...Typography.default() }}
                    numberOfLines={1}
                >
                    {agent.title ?? agent.type ?? 'Agent'}
                </Text>
                {agent.type ? (
                    <View style={{
                        paddingHorizontal: 5, paddingVertical: 1,
                        borderRadius: 4,
                        backgroundColor: theme.colors.surface,
                    }}>
                        <Text style={{ fontSize: 9, color: theme.colors.textSecondary, ...Typography.default() }}>
                            {agent.type}
                        </Text>
                    </View>
                ) : null}
                {elapsed != null ? (
                    <Text style={{ fontSize: 10, color: theme.colors.textSecondary, ...Typography.default() }}>
                        {formatDuration(elapsed)}
                    </Text>
                ) : null}
                {agent.tokens != null ? (
                    <Text style={{ fontSize: 10, color: theme.colors.textSecondary, ...Typography.default() }}>
                        {formatTokens(agent.tokens)} tok
                    </Text>
                ) : null}
                <Ionicons
                    name={expanded ? 'chevron-up' : 'chevron-down'}
                    size={12}
                    color={theme.colors.textSecondary}
                />
            </View>
            {expanded ? (
                <View style={{ paddingLeft: 12, paddingTop: 4, gap: 2 }}>
                    {agent.prompt ? (
                        <Text style={{ fontSize: 11, color: theme.colors.textSecondary, ...Typography.default() }} numberOfLines={3}>
                            {agent.prompt}
                        </Text>
                    ) : null}
                    {agent.summary ? (
                        <Text style={{ fontSize: 11, color: theme.colors.text, ...Typography.default() }} numberOfLines={2}>
                            {agent.summary}
                        </Text>
                    ) : null}
                    {agent.lastToolName ? (
                        <Text style={{ fontSize: 10, color: theme.colors.textSecondary, ...Typography.default() }}>
                            ↳ {agent.lastToolName}
                        </Text>
                    ) : null}
                    {agent.status !== 'running' ? (
                        <Text style={{ fontSize: 10, color: statusDotColor(agent.status, theme), ...Typography.default() }}>
                            {agent.status}
                            {agent.toolUses != null ? ` · ${agent.toolUses} tool calls` : ''}
                        </Text>
                    ) : null}
                </View>
            ) : null}
        </Pressable>
    );
});

export const RigActivityBar = React.memo(function RigActivityBar({
    metadata,
    subagents,
}: {
    metadata: Metadata | null;
    subagents?: Record<string, SubagentInfo>;
}) {
    const { theme } = useUnistyles();
    const indicators = getRigActivityIndicators(metadata);
    const [panelOpen, setPanelOpen] = React.useState(false);
    const [expandedAgents, setExpandedAgents] = React.useState<Set<string>>(new Set());

    const agentList = React.useMemo(() => {
        if (!subagents) return [];
        return Object.values(subagents)
            .filter(a => a.status === 'running')
            .sort((a, b) => b.startedAt - a.startedAt);
    }, [subagents]);

    const runningCount = agentList.length;

    const togglePanel = React.useCallback(() => {
        setPanelOpen(prev => !prev);
    }, []);

    const toggleAgent = React.useCallback((id: string) => {
        setExpandedAgents(prev => {
            const next = new Set(prev);
            if (next.has(id)) next.delete(id);
            else next.add(id);
            return next;
        });
    }, []);

    if (indicators.length === 0 && agentList.length === 0) return null;

    return (
        <View style={{ paddingHorizontal: 16, paddingVertical: 5 }}>
            <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 10, alignItems: 'center' }}>
                {indicators.map((indicator) => {
                    if (indicator.key === 'subagents' && agentList.length > 0) {
                        return (
                            <Pressable key={indicator.key} onPress={togglePanel} style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
                                <Ionicons name={iconByKey[indicator.key]} size={12} color={theme.colors.textSecondary} />
                                <Text style={{ fontSize: 11, color: theme.colors.textSecondary, ...Typography.default() }}>
                                    {runningCount > 0 ? runningCount : indicator.count}{indicator.queued ? ` +${indicator.queued} queued` : ''} {labelByKey[indicator.key]}
                                </Text>
                                <Ionicons
                                    name={panelOpen ? 'chevron-up' : 'chevron-down'}
                                    size={10}
                                    color={theme.colors.textSecondary}
                                />
                            </Pressable>
                        );
                    }
                    return (
                        <View key={indicator.key} style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
                            <Ionicons name={iconByKey[indicator.key]} size={12} color={theme.colors.textSecondary} />
                            <Text style={{ fontSize: 11, color: theme.colors.textSecondary, ...Typography.default() }}>
                                {indicator.count}{indicator.queued ? ` +${indicator.queued} queued` : ''} {labelByKey[indicator.key]}
                            </Text>
                        </View>
                    );
                })}
                {agentList.length > 0 && !indicators.some(i => i.key === 'subagents') ? (
                    <Pressable onPress={togglePanel} style={{ flexDirection: 'row', alignItems: 'center', gap: 4 }}>
                        <Ionicons name="people-outline" size={12} color={theme.colors.textSecondary} />
                        <Text style={{ fontSize: 11, color: theme.colors.textSecondary, ...Typography.default() }}>
                            {runningCount > 0 ? `${runningCount} running` : `${agentList.length} agents`}
                        </Text>
                        <Ionicons
                            name={panelOpen ? 'chevron-up' : 'chevron-down'}
                            size={10}
                            color={theme.colors.textSecondary}
                        />
                    </Pressable>
                ) : null}
            </View>
            {panelOpen && agentList.length > 0 ? (
                <View style={{
                    marginTop: 6,
                    borderTopWidth: 0.5,
                    borderTopColor: theme.colors.divider,
                    paddingTop: 4,
                }}>
                    {agentList.map(agent => (
                        <AgentRow
                            key={agent.id}
                            agent={agent}
                            expanded={expandedAgents.has(agent.id)}
                            onToggle={() => toggleAgent(agent.id)}
                        />
                    ))}
                </View>
            ) : null}
        </View>
    );
});
