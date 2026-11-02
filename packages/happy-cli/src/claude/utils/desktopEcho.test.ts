import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { RawJSONLinesSchema, type RawJSONLines } from '@/claude/types';
import { createDesktopEchoMatcher, parseDesktopDelivery } from './desktopEcho';

/**
 * Real transcript lines from the happyify Phase 0 spikes (Claude Code 2.1.290
 * and 2.1.309), with the spike hook's "Message from the user's phone (via
 * Happy): " prefix rewritten to the contract's `[Happy] ` prefix.
 */
const fixture: RawJSONLines[] = readFileSync(join(__dirname, '__fixtures__', 'desktopRewakeTranscript.jsonl'), 'utf-8')
    .split('\n')
    .filter((line) => line.trim().length > 0)
    .map((line) => RawJSONLinesSchema.parse(JSON.parse(line)));

const byUuid = (uuid: string): RawJSONLines => {
    const entry = fixture.find((message) => message.type !== 'summary' && message.uuid === uuid);
    if (!entry) throw new Error(`fixture has no entry ${uuid}`);
    return entry;
};

const STOP_REWAKE = '4745ba67-4ba1-40c0-839a-573c87b9b935';
const SESSION_START_REWAKE = '56f56f2c-e24e-430f-89f1-651ed3f64221';
const STOP_REWAKE_COMMAND = 'f0e0d48a-bde7-4e06-af94-bc814e47e756';
const LEGACY_FEEDBACK = '075057a9-abcf-415d-bc55-acfb36e2ab3c';
const TYPED_PROMPT_TEXT = 'Reply with just: happyify test session ready';

describe('parseDesktopDelivery', () => {
    it('extracts the text and hook from a Stop rewake', () => {
        const entry = byUuid(STOP_REWAKE);
        expect(parseDesktopDelivery((entry as any).message.content)).toEqual({
            hook: 'Stop',
            text: 'Reply with exactly: PHONE INJECTION INTO DESKTOP WORKS',
        });
    });

    it('extracts the text and hook from a SessionStart rewake', () => {
        const entry = byUuid(SESSION_START_REWAKE);
        expect(parseDesktopDelivery((entry as any).message.content)).toEqual({
            hook: 'SessionStart:resume',
            text: 'Reply with exactly: SPIKE2 FIRST MESSAGE FROM PHONE',
        });
    });

    it('extracts the text from the older "Stop hook feedback" format', () => {
        const entry = byUuid(LEGACY_FEEDBACK);
        expect(parseDesktopDelivery((entry as any).message.content)).toEqual({
            hook: '/Users/cprepos/.happyify-test/marketplace/plugins/happyify/scripts/hook.sh rewake',
            text: 'Reply with exactly: INJECTION WORKS 42',
        });
    });

    it('keeps multi-line text whole', () => {
        const content = '<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\n'
            + 'Stop hook blocking error from command "Stop": [Happy] first line\n\nsecond line\n\n</system-reminder>';
        expect(parseDesktopDelivery(content)?.text).toBe('first line\n\nsecond line');
    });

    it('ignores other plugins\' Stop hook output and typed prompts', () => {
        expect(parseDesktopDelivery('Stop hook blocking error from command "Stop": lint failed')).toBeNull();
        expect(parseDesktopDelivery(TYPED_PROMPT_TEXT)).toBeNull();
    });
});

describe('createDesktopEchoMatcher', () => {
    it('drops the echo of every enqueued message and forwards everything else', () => {
        const matcher = createDesktopEchoMatcher();
        matcher.expect('local-1', 'Reply with exactly: INJECTION WORKS 42');
        matcher.expect('local-2', 'Reply with exactly: PHONE INJECTION INTO DESKTOP WORKS');
        matcher.expect('local-3', 'Reply with exactly: SPIKE2 FIRST MESSAGE FROM PHONE');
        matcher.expect('local-4', 'Please create an empty file by running this shell command: touch ~/happyify-spike1/perm-test.txt\n');

        const decisions = fixture.map((message) => matcher.classify(message));
        const echoes = decisions.filter((decision) => decision.kind === 'echo');
        expect(echoes.map((decision) => decision.kind === 'echo' && decision.localId)).toEqual(['local-1', 'local-2', 'local-3', 'local-4']);

        // The typed prompt, assistant replies and the stop_hook_summary system
        // entry all pass through untouched.
        const forwarded = fixture.filter((_, index) => decisions[index].kind === 'forward');
        expect(forwarded).toHaveLength(fixture.length - 4);
        expect(forwarded.some((message) => message.type === 'user' && message.message.content === TYPED_PROMPT_TEXT)).toBe(true);
        expect(forwarded.some((message) => message.type === 'system')).toBe(true);
        expect(forwarded.filter((message) => message.type === 'assistant')).toHaveLength(3);
        expect(matcher.pendingCount()).toBe(0);
    });

    it('consumes identical messages oldest first', () => {
        const matcher = createDesktopEchoMatcher();
        matcher.expect('a', 'Reply with exactly: PHONE INJECTION INTO DESKTOP WORKS');
        matcher.expect('b', 'Reply with exactly: PHONE INJECTION INTO DESKTOP WORKS');
        const first = matcher.classify(byUuid(STOP_REWAKE));
        const second = matcher.classify({ ...byUuid(STOP_REWAKE), uuid: 'other' } as RawJSONLines);
        expect(first).toMatchObject({ kind: 'echo', localId: 'a' });
        expect(second).toMatchObject({ kind: 'echo', localId: 'b' });
    });

    it('rewrites a delivery it did not enqueue to the plain phone text', () => {
        const matcher = createDesktopEchoMatcher();
        const decision = matcher.classify(byUuid(STOP_REWAKE_COMMAND));
        expect(decision.kind).toBe('foreign');
        if (decision.kind !== 'foreign') return;
        expect(decision.text).toBe('Please create an empty file by running this shell command: touch ~/happyify-spike1/perm-test.txt');
        expect(decision.message.type).toBe('user');
        expect((decision.message as any).message.content).toBe(decision.text);
        expect((decision.message as any).uuid).toBe(STOP_REWAKE_COMMAND);
        expect((decision.message as any).isMeta).toBe(false);
    });

    it('forget drops a message so its text is no longer matched', () => {
        const matcher = createDesktopEchoMatcher();
        matcher.expect('gone', 'Reply with exactly: PHONE INJECTION INTO DESKTOP WORKS');
        matcher.forget('gone');
        expect(matcher.classify(byUuid(STOP_REWAKE)).kind).toBe('foreign');
    });
});
