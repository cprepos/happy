/**
 * The title Claude desktop shows for one of its Code sessions.
 *
 * The desktop keeps a session's title in its own session file
 * (`claude-code-sessions/<account>/<org>/local_<id>.json`, field `title`,
 * matched to the transcript by `cliSessionId`) and writes it back into the
 * transcript as `custom-title` lines. Claude Code itself writes `ai-title`
 * lines. The desktop's own lookup is the session file's title, then the last
 * `custom-title`, then the last `ai-title`; this reads them the same way, so a
 * mirrored session carries the title the desktop shows.
 */

import { open, readFile, readdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

/** Where Claude desktop keeps its Code session files on macOS. */
export const DESKTOP_CODE_SESSIONS_DIR = join(homedir(), 'Library', 'Application Support', 'Claude', 'claude-code-sessions');

/**
 * Reads the title for one desktop session, repeatedly. The session files are
 * small and read whole each time; the transcript only from where the last
 * read stopped, so polling a long chat stays cheap. Returns null while the
 * desktop has no title. Missing or unreadable files count as "no title from
 * there".
 */
export function createDesktopTitleReader(opts: {
    claudeSessionId: string;
    transcriptPath: string;
    sessionsDir?: string;
}): { read: () => Promise<string | null>; repoint: (claudeSessionId: string, transcriptPath: string) => void } {
    let claudeSessionId = opts.claudeSessionId;
    let transcriptPath = opts.transcriptPath;
    const sessionsDir = opts.sessionsDir ?? DESKTOP_CODE_SESSIONS_DIR;
    let offset = 0;
    let partial = '';
    let customTitle: string | null = null;
    let aiTitle: string | null = null;

    async function scanTranscript(): Promise<void> {
        let handle;
        try {
            handle = await open(transcriptPath, 'r');
        } catch {
            return;
        }
        try {
            const { size } = await handle.stat();
            if (size < offset) {
                // Rewritten from the start: read it again.
                offset = 0;
                partial = '';
                customTitle = null;
                aiTitle = null;
            }
            if (size === offset) return;
            const buffer = Buffer.alloc(size - offset);
            await handle.read(buffer, 0, buffer.length, offset);
            offset = size;
            const lines = (partial + buffer.toString('utf8')).split('\n');
            partial = lines.pop() ?? '';
            for (const line of lines) {
                // Cheap prefilter: title lines are rare in a long transcript.
                if (!line.includes('-title"')) continue;
                try {
                    const entry: unknown = JSON.parse(line);
                    if (!isRecord(entry)) continue;
                    if (entry.type === 'custom-title') customTitle = nonEmpty(entry.customTitle) ?? customTitle;
                    if (entry.type === 'ai-title') aiTitle = nonEmpty(entry.aiTitle) ?? aiTitle;
                } catch {
                    continue;
                }
            }
        } finally {
            await handle.close();
        }
    }

    return {
        async read() {
            const fromSessionFile = await titleFromSessionFiles(sessionsDir, claudeSessionId);
            await scanTranscript();
            return fromSessionFile ?? customTitle ?? aiTitle;
        },
        repoint(nextSessionId, nextTranscriptPath) {
            // A resumed or forked desktop session carries its history (and
            // its title lines) into the new transcript, so start that afresh.
            claudeSessionId = nextSessionId;
            if (nextTranscriptPath !== transcriptPath) {
                transcriptPath = nextTranscriptPath;
                offset = 0;
                partial = '';
                customTitle = null;
                aiTitle = null;
            }
        },
    };
}

async function titleFromSessionFiles(sessionsDir: string, claudeSessionId: string): Promise<string | null> {
    // <sessionsDir>/<account>/<org>/local_*.json; the file name is the
    // desktop's own id, so the match is on the cliSessionId inside.
    for (const account of await listDirs(sessionsDir)) {
        for (const org of await listDirs(join(sessionsDir, account))) {
            const orgDir = join(sessionsDir, account, org);
            let names: string[];
            try {
                names = await readdir(orgDir);
            } catch {
                continue;
            }
            for (const name of names) {
                if (!name.startsWith('local_') || !name.endsWith('.json')) continue;
                try {
                    const parsed: unknown = JSON.parse(await readFile(join(orgDir, name), 'utf8'));
                    if (!isRecord(parsed) || parsed.cliSessionId !== claudeSessionId) continue;
                    return nonEmpty(parsed.title);
                } catch {
                    continue;
                }
            }
        }
    }
    return null;
}

async function listDirs(dir: string): Promise<string[]> {
    try {
        const entries = await readdir(dir, { withFileTypes: true });
        return entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name);
    } catch {
        return [];
    }
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null;
}

function nonEmpty(value: unknown): string | null {
    return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}
