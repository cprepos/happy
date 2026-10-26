import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
    COMPACTION_COMPLETED_EVENT,
    COMPACTION_STARTED_EVENT,
    OpencodeEventMapper,
    type OpencodeEvent,
    type OpencodeMirrorAction,
} from './opencodeEventMapper';

/**
 * Event streams recorded from `opencode serve` 1.19.4 against a stub model
 * with a 4000-token context:
 * - overflow: the provider rejects the second prompt as too long; OpenCode
 *   compacts, re-posts the prompt and answers it.
 * - threshold: a reply reports usage near the limit; OpenCode compacts
 *   before the next step and continues with a synthetic prompt.
 * - manual: `POST /session/:id/summarize` (the TUI's /compact).
 * - failed: every request overflows, so the second compaction fails too.
 */
function recorded(name: string): OpencodeEvent[] {
    return readFileSync(join(__dirname, '__fixtures__', `opencode-1.19.4-compaction-${name}.jsonl`), 'utf8')
        .split('\n')
        .filter((line) => line.trim())
        .map((line) => JSON.parse(line));
}

function sessionOf(events: OpencodeEvent[]): string {
    return events.find((event) => event.type === 'session.created')?.properties.info.id
        ?? events.find((event) => event.properties?.sessionID)!.properties.sessionID;
}

/** What the app would see, in order: envelopes, session events and busy/idle. */
function timeline(actions: OpencodeMirrorAction[]): string[] {
    const lines: string[] = [];
    for (const action of actions) {
        if (action.type === 'envelopes') {
            for (const envelope of action.envelopes) {
                const ev = envelope.ev as any;
                if (ev.t === 'text') {
                    lines.push(`${envelope.role}:${ev.thinking ? 'thinking' : 'text'}:${ev.text}`);
                } else if (ev.t === 'turn-end') {
                    lines.push(`${envelope.role}:turn-end:${ev.status}`);
                } else if (ev.t === 'service') {
                    lines.push(`${envelope.role}:service:${ev.text}`);
                } else {
                    lines.push(`${envelope.role}:${ev.t}`);
                }
            }
        } else if (action.type === 'event') {
            lines.push(`event:${action.message}`);
        } else if (action.type === 'busy' || action.type === 'idle') {
            lines.push(action.type);
        }
    }
    return lines;
}

function play(events: OpencodeEvent[], own: (mapper: OpencodeEventMapper) => void = () => { }): string[] {
    const mapper = new OpencodeEventMapper(sessionOf(events));
    own(mapper);
    return timeline(events.flatMap((event) => mapper.handle(event)));
}

const S = 'ses_a';
const busy: OpencodeEvent = { type: 'session.status', properties: { sessionID: S, status: { type: 'busy' } } };
const idle: OpencodeEvent = { type: 'session.status', properties: { sessionID: S, status: { type: 'idle' } } };
const overflowError = (message: string): OpencodeEvent => ({
    type: 'session.error',
    properties: { sessionID: S, error: { name: 'ContextOverflowError', data: { message } } },
});

describe('OpencodeEventMapper compaction', () => {
    it('shows a context overflow that OpenCode compacts as two event lines, not an error', () => {
        const lines = play(recorded('overflow'));
        expect(lines).toEqual([
            'user:text:[test] first prompt',
            'agent:turn-start',
            'busy',
            'agent:text:Answer after compaction: OK.',
            'agent:turn-end:completed',
            'idle',
            'user:text:[test] OVERFLOW please',
            'agent:turn-start',
            'busy',
            `event:${COMPACTION_STARTED_EVENT}`,
            `event:${COMPACTION_COMPLETED_EVENT}`,
            'agent:text:Answer after compaction: OK.',
            'agent:turn-end:completed',
            'idle',
        ]);
        // No error, no summary text, no copy of the re-posted prompt.
        expect(lines.join('\n')).not.toMatch(/maximum context length|SUMMARY-OF-CONVERSATION|service/);
    });

    it('stays busy from the overflow until the answer after compaction', () => {
        const events = recorded('overflow');
        const mapper = new OpencodeEventMapper(sessionOf(events));
        const overflowAt = events.findIndex((event) => event.type === 'session.error');
        const compactedAt = events.findIndex((event) => event.type === 'session.compacted');
        const states: boolean[] = [];
        events.forEach((event, index) => {
            mapper.handle(event);
            if (index >= overflowAt && index <= compactedAt) states.push(mapper.isBusy);
        });
        expect(states.length).toBeGreaterThan(5);
        expect(states.every(Boolean)).toBe(true);
        expect(mapper.isBusy).toBe(false);
    });

    it('does not repeat a prompt the app sent when OpenCode re-posts it after compacting', () => {
        const lines = play(recorded('overflow'), (mapper) => mapper.markOwnMessage('msg_1776c5858001CYhaxx7Hy7iFHh'));
        expect(lines.filter((line) => line.startsWith('user:'))).toEqual(['user:text:[test] first prompt']);
        expect(lines).toContain(`event:${COMPACTION_COMPLETED_EVENT}`);
    });

    it('shows compaction near the context limit and keeps the text before it apart', () => {
        expect(play(recorded('threshold'))).toEqual([
            'user:text:[test] BIGUSAGE prompt',
            'agent:turn-start',
            'busy',
            'agent:text:Big answer done.',
            `event:${COMPACTION_STARTED_EVENT}`,
            `event:${COMPACTION_COMPLETED_EVENT}`,
            'agent:text:Answer after compaction: OK.',
            'agent:turn-end:completed',
            'idle',
        ]);
    });

    it('shows a manual /compact the same way, without the summary', () => {
        expect(play(recorded('manual'))).toEqual([
            'agent:turn-start',
            'busy',
            `event:${COMPACTION_STARTED_EVENT}`,
            `event:${COMPACTION_COMPLETED_EVENT}`,
            'agent:turn-end:completed',
            'idle',
        ]);
    });

    it('reports a compaction that cannot fit either as an error', () => {
        expect(play(recorded('failed'))).toEqual([
            'user:text:[test] warmup',
            'agent:turn-start',
            'busy',
            'agent:text:Answer after compaction: OK.',
            'agent:turn-end:completed',
            'idle',
            'user:text:[test] OVERFLOW-ALWAYS please',
            'agent:turn-start',
            'busy',
            `event:${COMPACTION_STARTED_EVENT}`,
            `event:${COMPACTION_COMPLETED_EVENT}`,
            `event:${COMPACTION_STARTED_EVENT}`,
            'agent:service:Error: Session too large to compact - context exceeds model limit even after stripping media',
            'agent:turn-end:failed',
            'idle',
        ]);
    });

    it('reports the overflow when auto compaction is off and OpenCode just stops', () => {
        // compaction.auto = false: OpenCode publishes the error and goes idle,
        // then records the error on the assistant message.
        const mapper = new OpencodeEventMapper(S);
        const lines = timeline([
            busy,
            overflowError('prompt is too long: 210000 tokens > 200000 maximum'),
            idle,
            {
                type: 'message.updated',
                properties: {
                    sessionID: S,
                    info: { id: 'msg_1', sessionID: S, role: 'assistant', mode: 'build', finish: 'error', error: { name: 'ContextOverflowError', data: { message: 'prompt is too long' } } },
                },
            },
        ].flatMap((event) => mapper.handle(event)));
        expect(lines).toEqual([
            'agent:turn-start',
            'busy',
            'agent:service:Error: prompt is too long: 210000 tokens > 200000 maximum',
            'agent:turn-end:failed',
            'idle',
        ]);
    });

    it('still shows other errors right away', () => {
        const mapper = new OpencodeEventMapper(S);
        const lines = timeline([
            busy,
            { type: 'session.error', properties: { sessionID: S, error: { name: 'APIError', data: { message: 'rate limited' } } } },
        ].flatMap((event) => mapper.handle(event)));
        expect(lines).toEqual(['agent:turn-start', 'busy', 'agent:service:Error: rate limited']);
    });

    it('ignores compaction in sub-agent sessions', () => {
        const manual = recorded('manual');
        const child = sessionOf(manual);
        const mapper = new OpencodeEventMapper('ses_parent');
        const events: OpencodeEvent[] = [
            { type: 'session.created', properties: { sessionID: child, info: { id: child, parentID: 'ses_parent', title: 'task' } } },
            ...manual,
        ];
        expect(timeline(events.flatMap((event) => mapper.handle(event)))).toEqual([]);
    });
});
