import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { existsSync } from 'node:fs';
import { copyFile, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createEnvelope, type SessionEnvelope } from '@slopus/happy-wire';

import {
    DEFAULT_HISTORY_LIMIT,
    MAX_HISTORY_LIMIT,
    historyBeforeAfterRepoint,
    mapHistoryEntries,
    planHistoryChunk,
    readDesktopTranscript,
    stampEnvelopeTimes,
} from './desktopHistory';
import { getProjectPath } from './path';
import { readSessionEntries } from './sessionScanner';

const textEnvelope = (text: string): SessionEnvelope => createEnvelope('user', { t: 'text', text });

describe('planHistoryChunk', () => {
    it('takes the default 100 entries just below before', () => {
        expect(DEFAULT_HISTORY_LIMIT).toBe(100);
        expect(planHistoryChunk(250)).toEqual({ start: 150, end: 250 });
    });

    it('stops at the start of the transcript', () => {
        expect(planHistoryChunk(40)).toEqual({ start: 0, end: 40 });
        expect(planHistoryChunk(0)).toEqual({ start: 0, end: 0 });
    });

    it('caps the limit at 500', () => {
        expect(MAX_HISTORY_LIMIT).toBe(500);
        expect(planHistoryChunk(2000, 10_000)).toEqual({ start: 1500, end: 2000 });
        expect(planHistoryChunk(2000, 500)).toEqual({ start: 1500, end: 2000 });
    });

    it('honours a smaller limit and keeps at least one entry', () => {
        expect(planHistoryChunk(30, 7)).toEqual({ start: 23, end: 30 });
        expect(planHistoryChunk(30, 0)).toEqual({ start: 29, end: 30 });
        expect(planHistoryChunk(30, 2.9)).toEqual({ start: 28, end: 30 });
        expect(planHistoryChunk(300, Number.NaN)).toEqual({ start: 200, end: 300 });
    });
});

describe('stampEnvelopeTimes', () => {
    it('stamps each entry with its timestamp', () => {
        const stamped = stampEnvelopeTimes([[textEnvelope('a')], [textEnvelope('b')]], [1000, 2000]);
        expect(stamped.map((envelope) => envelope.time)).toEqual([1000, 2000]);
    });

    it('adds 1 ms per envelope from the same line', () => {
        const stamped = stampEnvelopeTimes([[textEnvelope('a'), textEnvelope('b'), textEnvelope('c')]], [5000]);
        expect(stamped.map((envelope) => envelope.time)).toEqual([5000, 5001, 5002]);
    });

    it('adds 1 ms for lines with equal or earlier timestamps', () => {
        const stamped = stampEnvelopeTimes(
            [[textEnvelope('a'), textEnvelope('b')], [textEnvelope('c')], [textEnvelope('d')], [textEnvelope('e')]],
            [5000, 5000, 4000, 9000],
        );
        expect(stamped.map((envelope) => envelope.time)).toEqual([5000, 5001, 5002, 5003, 9000]);
    });

    it('places lines without a timestamp after the last known one', () => {
        const stamped = stampEnvelopeTimes(
            [[textEnvelope('a')], [textEnvelope('b')], [textEnvelope('c')], [textEnvelope('d')]],
            [undefined, 3000, undefined, 8000],
        );
        expect(stamped.map((envelope) => envelope.time)).toEqual([3000, 3001, 3002, 8000]);
    });

    it('skips entries that produced no envelopes', () => {
        const stamped = stampEnvelopeTimes([[], [textEnvelope('a')], []], [100, 200, 300]);
        expect(stamped.map((envelope) => envelope.time)).toEqual([200]);
    });

    it('throws when there are envelopes but no timestamps', () => {
        expect(() => stampEnvelopeTimes([[textEnvelope('a')]], [undefined])).toThrow(/No transcript timestamps/);
        expect(stampEnvelopeTimes([[]], [undefined])).toEqual([]);
    });
});

describe('desktop history from a transcript on disk', () => {
    let workDir: string;
    let configDir: string;
    let projectDir: string;
    let previousConfigDir: string | undefined;
    const sessionId = 'history-session';

    beforeEach(async () => {
        const unique = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
        workDir = join(tmpdir(), `desktop-history-${unique}`);
        configDir = join(tmpdir(), `desktop-history-config-${unique}`);
        previousConfigDir = process.env.CLAUDE_CONFIG_DIR;
        process.env.CLAUDE_CONFIG_DIR = configDir;
        projectDir = getProjectPath(workDir);
        await mkdir(projectDir, { recursive: true });
    });

    afterEach(async () => {
        if (previousConfigDir === undefined) {
            delete process.env.CLAUDE_CONFIG_DIR;
        } else {
            process.env.CLAUDE_CONFIG_DIR = previousConfigDir;
        }
        for (const dir of [workDir, configDir]) {
            if (existsSync(dir)) await rm(dir, { recursive: true, force: true });
        }
    });

    const writeTranscript = (id: string, lines: unknown[]) =>
        writeFile(join(projectDir, `${id}.jsonl`), lines.map((line) => JSON.stringify(line)).join('\n') + '\n');

    const userLine = (uuid: string, text: string, timestamp: string) => ({
        type: 'user', uuid, timestamp, sessionId, message: { role: 'user', content: text },
    });
    const assistantLine = (uuid: string, text: string, timestamp: string) => ({
        type: 'assistant', uuid, timestamp, sessionId,
        message: { role: 'assistant', model: 'claude', content: [{ type: 'text', text }] },
    });

    it('maps Happy rewake lines back to the plain text the phone sent', async () => {
        await copyFile(join(__dirname, '__fixtures__', 'desktopRewakeTranscript.jsonl'), join(projectDir, `${sessionId}.jsonl`));
        const entries = await readDesktopTranscript(projectDir, sessionId);
        const envelopes = mapHistoryEntries(entries);

        const userTexts = envelopes
            .filter((envelope) => envelope.role === 'user' && envelope.ev.t === 'text')
            .map((envelope) => (envelope.ev as { text: string }).text);
        expect(userTexts).toEqual([
            'Reply with just: happyify test session ready',
            'Reply with exactly: INJECTION WORKS 42',
            'Reply with exactly: PHONE INJECTION INTO DESKTOP WORKS',
            'Reply with exactly: SPIKE2 FIRST MESSAGE FROM PHONE',
            expect.any(String),
        ]);
        expect(userTexts.some((text) => text.includes('[Happy]') || text.includes('hook'))).toBe(false);
    });

    it('stamps strictly increasing times from the transcript and closes the turn', async () => {
        await copyFile(join(__dirname, '__fixtures__', 'desktopRewakeTranscript.jsonl'), join(projectDir, `${sessionId}.jsonl`));
        const envelopes = mapHistoryEntries(await readDesktopTranscript(projectDir, sessionId));

        const times = envelopes.map((envelope) => envelope.time);
        for (let i = 1; i < times.length; i += 1) {
            expect(times[i]).toBeGreaterThan(times[i - 1]);
        }
        expect(times[0]).toBe(Date.parse('2026-11-02T20:15:42.485Z'));
        expect(times[times.length - 1]).toBeLessThan(Date.parse('2026-11-02T21:07:00.000Z'));

        const starts = envelopes.filter((envelope) => envelope.ev.t === 'turn-start').length;
        const ends = envelopes.filter((envelope) => envelope.ev.t === 'turn-end').length;
        expect(starts).toBeGreaterThan(0);
        expect(ends).toBe(starts);
    });

    it('closes a turn left open at the end of the chunk', async () => {
        await copyFile(join(__dirname, '__fixtures__', 'desktopRewakeTranscript.jsonl'), join(projectDir, `${sessionId}.jsonl`));
        const entries = await readDesktopTranscript(projectDir, sessionId);
        // Ends on an assistant reply, so its turn is still open.
        const envelopes = mapHistoryEntries(entries.slice(0, 4));
        const last = envelopes[envelopes.length - 1];
        expect(last.ev).toEqual({ t: 'turn-end', status: 'completed' });
        expect(last.time).toBeGreaterThan(envelopes[envelopes.length - 2].time);
    });

    it('leaves out summaries and maps a chunk taken by planHistoryChunk', async () => {
        await writeTranscript(sessionId, [
            userLine('u1', 'first', '2026-11-01T10:00:00.000Z'),
            assistantLine('a1', 'one', '2026-11-01T10:00:01.000Z'),
            { type: 'summary', summary: 'A title', leafUuid: 'a1' },
            userLine('u2', 'second', '2026-11-01T10:00:02.000Z'),
            assistantLine('a2', 'two', '2026-11-01T10:00:03.000Z'),
        ]);
        const entries = await readDesktopTranscript(projectDir, sessionId);
        expect(entries).toHaveLength(5);

        const chunk = planHistoryChunk(entries.length, 2);
        expect(chunk).toEqual({ start: 3, end: 5 });
        const envelopes = mapHistoryEntries(entries.slice(chunk.start, chunk.end));
        expect(envelopes.map((envelope) => envelope.ev.t)).toEqual(['text', 'turn-start', 'text', 'turn-end']);
        expect(envelopes.map((envelope) => envelope.time)).toEqual([
            Date.parse('2026-11-01T10:00:02.000Z'),
            Date.parse('2026-11-01T10:00:03.000Z'),
            Date.parse('2026-11-01T10:00:03.000Z') + 1,
            Date.parse('2026-11-01T10:00:03.000Z') + 2,
        ]);

        const summaryOnly = mapHistoryEntries(entries.slice(2, 3));
        expect(summaryOnly).toEqual([]);
    });

    it('does not upload images: an image block maps to its text only', async () => {
        await writeTranscript(sessionId, [{
            type: 'user', uuid: 'img', timestamp: '2026-11-01T10:00:00.000Z', sessionId,
            message: { role: 'user', content: [
                { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'iVBORw0KGgo=' } },
                { type: 'text', text: 'look at this' },
            ] },
        }]);
        const envelopes = mapHistoryEntries(await readDesktopTranscript(projectDir, sessionId));
        expect(envelopes.map((envelope) => envelope.ev)).toEqual([{ t: 'text', text: 'look at this' }]);
    });

    it('throws when the transcript cannot be read', async () => {
        await expect(readDesktopTranscript(projectDir, 'missing')).rejects.toThrow();
    });

    it('recomputes before against a resumed transcript', async () => {
        const old = [
            userLine('u1', 'one', '2026-11-01T10:00:00.000Z'),
            assistantLine('a1', 'one', '2026-11-01T10:00:01.000Z'),
            userLine('u2', 'two', '2026-11-01T10:00:02.000Z'),
            assistantLine('a2', 'two', '2026-11-01T10:00:03.000Z'),
        ];
        await writeTranscript('old', old);
        // The resumed file repeats the old history, then continues.
        await writeTranscript('new', [...old, userLine('u3', 'three', '2026-11-01T10:00:04.000Z')]);
        const oldEntries = await readSessionEntries(projectDir, 'old');
        const newEntries = await readSessionEntries(projectDir, 'new');

        // Two entries were still unloaded: the same two lead the new file.
        expect(historyBeforeAfterRepoint(oldEntries, 2, newEntries)).toBe(2);
        // Everything loaded already.
        expect(historyBeforeAfterRepoint(oldEntries, 0, newEntries)).toBe(0);

        // A /clear (no shared entries) has nothing to load.
        await writeTranscript('cleared', [userLine('c1', 'fresh', '2026-11-01T11:00:00.000Z')]);
        expect(historyBeforeAfterRepoint(oldEntries, 4, await readSessionEntries(projectDir, 'cleared'))).toBe(0);
    });
});
