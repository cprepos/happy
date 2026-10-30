import type { SessionListViewItem, SessionRowData } from '@/sync/storage';
import { getRepoPath, getWorktreeName, isWorktreePath } from '@/utils/worktreePaths';

/**
 * One session as the flat home list shows it: the session's own title, and the
 * project/worktree it belongs to spelled out on the row instead of being
 * implied by a card it sits inside.
 */
export interface FlatSessionRowData {
    session: SessionRowData;
    projectName: string;
    /** Null in a project's primary checkout, which needs no second name. */
    workspaceName: string | null;
    /**
     * The machine this chat runs on, as the store already names it
     * (`displayName || host || the session's own reported host`). Null for a
     * bot, which belongs to no checkout, and for a machine with no name of its
     * own, where a raw id would say less than nothing.
     *
     * Whether the row *draws* it is a separate question — see
     * `hasMultipleHosts`.
     */
    hostName: string | null;
}

/**
 * Whether these rows span more than one machine, which is the only time naming
 * the host on every row tells the reader anything. A single-machine account
 * would just repeat the same word down the column.
 *
 * Counts machines, not names: two hosts that happen to share a display name are
 * still two places the work can be.
 */
export function hasMultipleHosts(rows: readonly FlatSessionRowData[]): boolean {
    const machineIds = new Set<string>();
    for (const row of rows) {
        if (row.session.botId) continue;
        if (row.session.machineId) machineIds.add(row.session.machineId);
        if (machineIds.size > 1) return true;
    }
    return false;
}

/**
 * Flattens the project cards into one chronological list.
 *
 * Grouping by project is what loses the global ordering: sessions are sorted
 * once, then dealt into projects, so a project's older sessions end up directly
 * under its newest one. The flat list wants what the user last touched at the
 * top regardless of project, so it re-sorts the rows here.
 *
 * Archived rows (`type: 'session'`) and the headings above them are left alone
 * — they are already a flat, date-grouped tail that the caller appends.
 */
export function buildFlatSessionRows(
    items: readonly SessionListViewItem[],
    options: { sortByActivity: boolean },
): FlatSessionRowData[] {
    const rows: FlatSessionRowData[] = [];

    for (const item of items) {
        if (item.type === 'active-sessions' || item.type === 'bots') {
            for (const session of item.sessions) {
                rows.push(toFlatSessionRow(session));
            }
            continue;
        }
        if (item.type !== 'project') continue;
        for (const workspace of item.project.workspaces) {
            for (const session of workspace.sessions) {
                rows.push({
                    session,
                    projectName: item.project.name,
                    workspaceName: workspace.name ?? (workspace.id || null),
                    hostName: session.machineName ?? null,
                });
            }
        }
    }

    const sortKey = options.sortByActivity
        ? (row: FlatSessionRowData) => row.session.lastActivityAt
        : (row: FlatSessionRowData) => row.session.createdAt;

    return rows.sort((a, b) => {
        const activeDelta = Number(b.session.active) - Number(a.session.active);
        return activeDelta !== 0 ? activeDelta : sortKey(b) - sortKey(a);
    });
}

/**
 * Places a session that reached the list without a project card around it —
 * an archived row, or one of the active-sessions rows — using the same rule the
 * card grouping uses: a worktree names its repository as the project and itself
 * as the workspace.
 */
export function toFlatSessionRow(session: SessionRowData): FlatSessionRowData {
    if (session.botId) {
        return {
            session,
            projectName: `@${session.botUsername ?? ''}`,
            workspaceName: null,
            hostName: null,
        };
    }
    const path = session.path?.trim() || '';
    const worktree = isWorktreePath(path);
    const projectPath = worktree ? getRepoPath(path) : path;
    return {
        session,
        projectName: session.projectName
            ?? projectPath.split(/[\\/]/).filter(Boolean).at(-1)
            ?? '',
        workspaceName: session.workspaceName ?? (worktree ? getWorktreeName(path) : null),
        hostName: session.machineName ?? null,
    };
}
