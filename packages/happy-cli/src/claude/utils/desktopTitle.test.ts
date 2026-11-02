import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { appendFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDesktopTitleReader } from './desktopTitle';

const SID = '22a6dd8a-32ec-4081-ab2f-63a5b6c2eff5';

describe('createDesktopTitleReader', () => {
    let root: string;
    let sessionsDir: string;
    let transcriptPath: string;

    beforeEach(async () => {
        root = await mkdtemp(join(tmpdir(), 'desktop-title-'));
        sessionsDir = join(root, 'claude-code-sessions');
        transcriptPath = join(root, `${SID}.jsonl`);
        await mkdir(join(sessionsDir, 'account', 'org'), { recursive: true });
    });

    afterEach(async () => {
        await rm(root, { recursive: true, force: true });
    });

    const line = (entry: object) => `${JSON.stringify(entry)}\n`;

    it('has no title while the desktop has none', async () => {
        await writeFile(transcriptPath, line({ type: 'user', message: { role: 'user', content: 'hi' } }));
        const reader = createDesktopTitleReader({ claudeSessionId: SID, transcriptPath, sessionsDir });
        expect(await reader.read()).toBeNull();
    });

    it('takes the ai-title, then a later custom-title over it', async () => {
        await writeFile(transcriptPath, line({ type: 'ai-title', aiTitle: 'Happyify test session', sessionId: SID }));
        const reader = createDesktopTitleReader({ claudeSessionId: SID, transcriptPath, sessionsDir });
        expect(await reader.read()).toBe('Happyify test session');
        await appendFile(transcriptPath, line({ type: 'custom-title', customTitle: 'Repository overview', sessionId: SID }));
        expect(await reader.read()).toBe('Repository overview');
        await appendFile(transcriptPath, line({ type: 'ai-title', aiTitle: 'A newer AI title', sessionId: SID }));
        expect(await reader.read()).toBe('Repository overview');
    });

    it("prefers the desktop session file's title, matched by cliSessionId", async () => {
        await writeFile(transcriptPath, line({ type: 'ai-title', aiTitle: 'From the transcript', sessionId: SID }));
        await writeFile(join(sessionsDir, 'account', 'org', 'local_other.json'), JSON.stringify({ cliSessionId: 'someone-else', title: 'Wrong session' }));
        await writeFile(join(sessionsDir, 'account', 'org', 'local_mine.json'), JSON.stringify({ cliSessionId: SID, title: 'Renamed on the desktop', titleSource: 'user' }));
        const reader = createDesktopTitleReader({ claudeSessionId: SID, transcriptPath, sessionsDir });
        expect(await reader.read()).toBe('Renamed on the desktop');
    });

    it('finishes a title line split across two reads', async () => {
        const full = line({ type: 'custom-title', customTitle: 'Split line', sessionId: SID });
        await writeFile(transcriptPath, full.slice(0, 20));
        const reader = createDesktopTitleReader({ claudeSessionId: SID, transcriptPath, sessionsDir });
        expect(await reader.read()).toBeNull();
        await appendFile(transcriptPath, full.slice(20));
        expect(await reader.read()).toBe('Split line');
    });

    it('starts over on the new transcript when repointed', async () => {
        await writeFile(transcriptPath, line({ type: 'ai-title', aiTitle: 'Old', sessionId: SID }));
        const reader = createDesktopTitleReader({ claudeSessionId: SID, transcriptPath, sessionsDir });
        expect(await reader.read()).toBe('Old');
        const next = join(root, 'next.jsonl');
        await writeFile(next, line({ type: 'custom-title', customTitle: 'Old (fork)', sessionId: 'next' }));
        reader.repoint('next', next);
        expect(await reader.read()).toBe('Old (fork)');
    });

    it('has no title when no file exists', async () => {
        const reader = createDesktopTitleReader({ claudeSessionId: SID, transcriptPath: join(root, 'missing.jsonl'), sessionsDir: join(root, 'nope') });
        expect(await reader.read()).toBeNull();
    });
});
