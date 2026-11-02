import { rigCanAbort } from '@/sync/rig';
import type { Metadata } from '@/sync/storageTypes';
import { isClaudeDesktopSession } from '@/utils/harnessCatalog';

/**
 * Whether the phone can stop this session's turn. Happy Agent says so in its
 * capabilities. A Claude Desktop session cannot: the turn runs in the desktop
 * app, and the process Happy talks to only mirrors it.
 */
export function sessionCanAbort(metadata: Metadata | null | undefined): boolean {
    return rigCanAbort(metadata) && !isClaudeDesktopSession(metadata);
}
