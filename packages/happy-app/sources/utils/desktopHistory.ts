import { isClaudeDesktopSession } from './harnessCatalog';

/**
 * The "Load previous history" button at the top of a Claude Desktop chat.
 * See docs/plans/happyify-desktop-sync.md, "Contract: on-demand history".
 */
export type DesktopHistoryButtonState = 'hidden' | 'ready' | 'loading' | 'failed';

/** Where this client's last `desktop-load-history` call stands. */
export type DesktopHistoryRequestState = 'idle' | 'loading' | 'failed';

export type DesktopHistoryMetadata = {
    harness?: string | null;
    desktopHistory?: { before?: number } | null;
} | null | undefined;

/** Transcript entries the desktop has not uploaded yet; 0 when unknown. */
export function desktopHistoryRemaining(metadata: DesktopHistoryMetadata): number {
    const before = metadata?.desktopHistory?.before;
    return typeof before === 'number' && Number.isFinite(before) && before > 0 ? before : 0;
}

/**
 * The button shows only for a Claude Desktop session with history left on the
 * desktop, once the reader has reached the oldest server page. It stays while
 * `before > 0`; a load that finishes the history hides it via metadata sync.
 */
export function desktopHistoryButtonState(input: {
    metadata: DesktopHistoryMetadata;
    reachedOldest: boolean;
    request: DesktopHistoryRequestState;
}): DesktopHistoryButtonState {
    if (!isClaudeDesktopSession(input.metadata)) return 'hidden';
    if (desktopHistoryRemaining(input.metadata) === 0) return 'hidden';
    if (!input.reachedOldest) return 'hidden';
    if (input.request === 'loading') return 'loading';
    if (input.request === 'failed') return 'failed';
    return 'ready';
}
