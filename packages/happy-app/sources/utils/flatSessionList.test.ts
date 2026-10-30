import { describe, expect, it } from 'vitest';
import { buildFlatSessionRows, hasMultipleHosts, toFlatSessionRow } from './flatSessionList';
import type { SessionListViewItem, SessionRowData } from '@/sync/storage';

function row(overrides: Partial<SessionRowData> & { id: string }): SessionRowData {
    return {
        name: overrides.id,
        subtitle: '',
        avatarId: overrides.id,
        flavor: null,
        clientId: null,
        identityLine: null,
        providerKind: null,
        modelName: null,
        activitySummary: null,
        gitChangedFiles: null,
        gitCountsExact: true,
        gitDeletions: null,
        gitInsertions: null,
        state: 'waiting',
        createdAt: 0,
        lastActivityAt: 0,
        hasDraft: false,
        active: true,
        archived: false,
        machineId: 'machine',
        machineOffline: false,
        path: null,
        homeDir: null,
        completedTodosCount: 0,
        totalTodosCount: 0,
        hasUnread: false,
        projectId: null,
        projectName: null,
        workspaceId: null,
        workspaceName: null,
        ...overrides,
    };
}

function project(
    name: string,
    workspaces: { id: string; name: string | null; sessions: SessionRowData[] }[],
): SessionListViewItem {
    return {
        type: 'project',
        source: 'happy',
        project: {
            id: name,
            name,
            machineId: 'machine',
            workspaces,
            sessionCount: workspaces.reduce((total, w) => total + w.sessions.length, 0),
            activeCount: 0,
        },
    };
}

describe('buildFlatSessionRows', () => {
    it('shows only the bot identity and omits its machine label', () => {
        const rows = buildFlatSessionRows([{
            type: 'bots',
            sessions: [
                row({ id: 'laptop-bot', name: 'Assistant', botId: 'bot-1', botUsername: 'assistant', machineId: 'laptop', machineName: 'My Laptop' }),
                row({ id: 'desktop-bot', name: 'Assistant', botId: 'bot-2', botUsername: 'assistant', machineId: 'desktop', machineName: 'Office Mac' }),
            ],
        }], { sortByActivity: true });
        expect(rows.map((item) => item.projectName)).toEqual(['@assistant', '@assistant']);
        expect(rows.every((item) => item.workspaceName === null)).toBe(true);
    });

    it('includes bot rows in recency order without inventing a project', () => {
        const bot = row({
            id: 'bot-session', lastActivityAt: 200,
            botId: 'bot-1', botUsername: 'assistant',
            path: '/home/steve/Happy/Bots/assistant',
        });
        const rows = buildFlatSessionRows([
            { type: 'bots', sessions: [bot] },
            project('alpha', [{ id: '', name: null, sessions: [row({ id: 'chat', lastActivityAt: 100 })] }]),
        ], { sortByActivity: true });
        expect(rows.map((r) => r.session.id)).toEqual(['bot-session', 'chat']);
        expect(rows[0]).toMatchObject({ projectName: '@assistant', workspaceName: null });
    });

    it('names the project and worktree each session belongs to', () => {
        const rows = buildFlatSessionRows([
            project('happy', [
                { id: '', name: null, sessions: [row({ id: 'primary' })] },
                { id: '/wt/innsbruck', name: 'innsbruck', sessions: [row({ id: 'worktree' })] },
            ]),
        ], { sortByActivity: true });

        expect(rows.map((r) => [r.session.id, r.projectName, r.workspaceName])).toEqual([
            ['primary', 'happy', null],
            ['worktree', 'happy', 'innsbruck'],
        ]);
    });

    it('falls back to the worktree path when the group has no name', () => {
        const rows = buildFlatSessionRows([
            project('happy', [{ id: '/wt/innsbruck', name: null, sessions: [row({ id: 'a' })] }]),
        ], { sortByActivity: true });

        expect(rows[0].workspaceName).toBe('/wt/innsbruck');
    });

    it('restores global recency across projects, active sessions first', () => {
        const rows = buildFlatSessionRows([
            project('alpha', [{
                id: '',
                name: null,
                sessions: [
                    row({ id: 'alpha-new', lastActivityAt: 300 }),
                    row({ id: 'alpha-old', lastActivityAt: 100 }),
                ],
            }]),
            project('beta', [{
                id: '',
                name: null,
                sessions: [
                    row({ id: 'beta-mid', lastActivityAt: 200 }),
                    row({ id: 'beta-dead', lastActivityAt: 400, active: false }),
                ],
            }]),
        ], { sortByActivity: true });

        expect(rows.map((r) => r.session.id)).toEqual([
            'alpha-new',
            'beta-mid',
            'alpha-old',
            'beta-dead',
        ]);
    });

    it('sorts on creation date when activity sorting is off', () => {
        const rows = buildFlatSessionRows([
            project('alpha', [{
                id: '',
                name: null,
                sessions: [
                    row({ id: 'older-but-active-recently', createdAt: 1, lastActivityAt: 900 }),
                    row({ id: 'newer', createdAt: 5, lastActivityAt: 5 }),
                ],
            }]),
        ], { sortByActivity: false });

        expect(rows.map((r) => r.session.id)).toEqual(['newer', 'older-but-active-recently']);
    });

    it('ignores archived rows and headings, which stay a separate tail', () => {
        const rows = buildFlatSessionRows([
            { type: 'header', title: 'Today' },
            { type: 'session', session: row({ id: 'archived', archived: true }) },
            { type: 'projects-header', source: 'happy' },
            project('alpha', [{ id: '', name: null, sessions: [row({ id: 'live' })] }]),
        ], { sortByActivity: true });

        expect(rows.map((r) => r.session.id)).toEqual(['live']);
    });

    it('names the machine each chat runs on, and nothing for a bot', () => {
        const rows = buildFlatSessionRows([
            { type: 'bots', sessions: [row({ id: 'bot', botId: 'bot-1', botUsername: 'assistant', machineName: 'My Laptop' })] },
            project('alpha', [{
                id: '',
                name: null,
                sessions: [
                    row({ id: 'named', machineId: 'laptop', machineName: 'My Laptop' }),
                    row({ id: 'nameless', machineId: 'other', machineName: null }),
                ],
            }]),
        ], { sortByActivity: true });

        const byId = new Map(rows.map((r) => [r.session.id, r.hostName]));
        expect(byId.get('named')).toBe('My Laptop');
        // A machine with no name of its own says nothing rather than a raw id.
        expect(byId.get('nameless')).toBeNull();
        expect(byId.get('bot')).toBeNull();
    });

    it('carries the host onto a row that reached the list on its own', () => {
        expect(toFlatSessionRow(row({ id: 'archived', machineName: 'Office Mac' })).hostName).toBe('Office Mac');
    });
});

describe('hasMultipleHosts', () => {
    const rowsFor = (sessions: SessionRowData[]) => buildFlatSessionRows([
        project('alpha', [{ id: '', name: null, sessions }]),
    ], { sortByActivity: true });

    it('is false for one machine, so a single-machine account repeats nothing', () => {
        expect(hasMultipleHosts(rowsFor([
            row({ id: 'a', machineId: 'laptop', machineName: 'My Laptop' }),
            row({ id: 'b', machineId: 'laptop', machineName: 'My Laptop' }),
        ]))).toBe(false);
    });

    it('is true for two machines even when they share a display name', () => {
        expect(hasMultipleHosts(rowsFor([
            row({ id: 'a', machineId: 'one', machineName: 'prep-ml' }),
            row({ id: 'b', machineId: 'two', machineName: 'prep-ml' }),
        ]))).toBe(true);
    });

    it('does not count bots, which belong to no machine the reader can see', () => {
        expect(hasMultipleHosts(rowsFor([
            row({ id: 'a', machineId: 'laptop', machineName: 'My Laptop' }),
            row({ id: 'bot', machineId: 'server', machineName: 'Server', botId: 'bot-1', botUsername: 'assistant' }),
        ]))).toBe(false);
    });
});
