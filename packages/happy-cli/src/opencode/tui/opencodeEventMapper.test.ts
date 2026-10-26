import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { SessionEnvelope } from '@slopus/happy-wire';
import {
    normalizeOpencodeToolInput,
    OpencodeEventMapper,
    opencodeToolKind,
    type OpencodeEvent,
    type OpencodeMirrorAction,
} from './opencodeEventMapper';

/** Events recorded from `opencode serve` 1.19.4 (noise like heartbeats removed). */
const RECORDED: OpencodeEvent[] = readFileSync(join(__dirname, '__fixtures__', 'opencode-1.19.4-events.jsonl'), 'utf8')
    .split('\n')
    .filter((line) => line.trim())
    .map((line) => JSON.parse(line));

const SESSION = 'ses_e88e92f2fffeV56TqchHIOMtHU';
/** The third prompt in the recording was posted through the API with this id. */
const OWN_MESSAGE = 'msg_17719cba9007yyxUFvd2hhuvS3';

function run(mapper: OpencodeEventMapper, events: OpencodeEvent[]): OpencodeMirrorAction[] {
    return events.flatMap((event) => mapper.handle(event));
}

function envelopesOf(actions: OpencodeMirrorAction[]): SessionEnvelope[] {
    return actions.flatMap((action) => (action.type === 'envelopes' ? action.envelopes : []));
}

/** Compact view of the envelopes: role + event type (+ text). */
function summarize(envelopes: SessionEnvelope[]): string[] {
    return envelopes.map((envelope) => {
        const ev = envelope.ev as any;
        if (ev.t === 'text') {
            return `${envelope.role}:${ev.thinking ? 'thinking' : 'text'}:${ev.text}`;
        }
        if (ev.t === 'tool-call-start') {
            return `${envelope.role}:tool-call-start:${ev.name}:${JSON.stringify(ev.args)}`;
        }
        if (ev.t === 'turn-end') {
            return `${envelope.role}:turn-end:${ev.status}`;
        }
        return `${envelope.role}:${ev.t}`;
    });
}

describe('OpencodeEventMapper', () => {
    it('maps a recorded TUI + API session into app envelopes', () => {
        const mapper = new OpencodeEventMapper(SESSION);
        mapper.markOwnMessage(OWN_MESSAGE);
        const actions = run(mapper, RECORDED);

        expect(summarize(envelopesOf(actions))).toEqual([
            'user:text:Reply with exactly the word PINEAPPLE-API and nothing else.',
            'agent:turn-start',
            'agent:thinking:The user is asking me to reply with exactly the word "PINEAPPLE-API" and nothing else. This is a simple request.',
            'agent:text:PINEAPPLE-API',
            'agent:turn-end:completed',
            'user:text:Use the bash tool to run: echo TUI-TYPED > tuifile.txt',
            'agent:turn-start',
            'agent:thinking:The user wants to use the bash tool to run `echo TUI-TYPED > tuifile.txt`.',
            'agent:tool-call-start:execute:{"command":"echo TUI-TYPED > tuifile.txt"}',
            'agent:tool-call-end',
            'agent:thinking:The command executed successfully. It wrote "TUI-TYPED" to tuifile.txt. Let\'s confirm it worked.',
            'agent:text:Done — created `tuifile.txt` with `TUI-TYPED`.',
            'agent:turn-end:completed',
        ]);
    });

    it('forwards finished paragraphs of a streaming part before the part ends', () => {
        const mapper = new OpencodeEventMapper(SESSION);
        const msg = 'msg_stream';
        const part = { id: 'prt_stream', messageID: msg, sessionID: SESSION, type: 'text', text: '' };
        const delta = (text: string): OpencodeEvent => ({
            type: 'message.part.delta',
            properties: { sessionID: SESSION, messageID: msg, partID: part.id, field: 'text', delta: text },
        });
        run(mapper, [
            { type: 'session.status', properties: { sessionID: SESSION, status: { type: 'busy' } } },
            { type: 'message.updated', properties: { info: { id: msg, sessionID: SESSION, role: 'assistant' } } },
            { type: 'message.part.updated', properties: { part } },
            delta('First paragraph.\n\nSecond'),
        ]);

        expect(summarize(envelopesOf(mapper.flushStreamingText()))).toEqual(['agent:text:First paragraph.']);
        expect(mapper.flushStreamingText()).toEqual([]);

        const rest = run(mapper, [
            delta(' paragraph.'),
            { type: 'message.part.updated', properties: { part: { ...part, text: 'First paragraph.\n\nSecond paragraph.' } } },
            { type: 'session.idle', properties: { sessionID: SESSION } },
        ]);
        expect(summarize(envelopesOf(rest))).toEqual(['agent:text:Second paragraph.', 'agent:turn-end:completed']);
        expect(mapper.flushStreamingText()).toEqual([]);
    });

    it('reports permissions, busy/idle and the title alongside the envelopes', () => {
        const mapper = new OpencodeEventMapper(SESSION);
        const actions = run(mapper, RECORDED).filter((action) => action.type !== 'envelopes');

        expect(actions).toEqual([
            { type: 'title', title: 'exp1' },
            { type: 'busy' },
            { type: 'idle' },
            { type: 'busy' },
            {
                type: 'permission-asked',
                id: 'per_177179946001R4bfPMs4P9Gc41',
                toolName: 'execute',
                input: { command: 'echo TUI-TYPED > tuifile.txt', patterns: ['echo TUI-TYPED > tuifile.txt'] },
                toolCallId: 'chatcmpl-tool-891fbf4505619420',
            },
            { type: 'permission-replied', id: 'per_177179946001R4bfPMs4P9Gc41', reply: 'once' },
            { type: 'idle' },
        ]);
    });

    it('uses the OpenCode call id on tool envelopes so permissions join their tool call', () => {
        const mapper = new OpencodeEventMapper(SESSION);
        const calls = envelopesOf(run(mapper, RECORDED))
            .map((envelope) => envelope.ev as any)
            .filter((ev) => ev.t === 'tool-call-start' || ev.t === 'tool-call-end')
            .map((ev) => `${ev.t}:${ev.call}`);
        expect(calls).toEqual([
            'tool-call-start:chatcmpl-tool-891fbf4505619420',
            'tool-call-end:chatcmpl-tool-891fbf4505619420',
        ]);
    });

    it('does not echo messages Happy posted for the app', () => {
        const mapper = new OpencodeEventMapper(SESSION);
        mapper.markOwnMessage(OWN_MESSAGE);
        const texts = summarize(envelopesOf(run(mapper, RECORDED)));
        expect(texts.some((line) => line.includes('custom id test'))).toBe(false);

        const unmarked = new OpencodeEventMapper(SESSION);
        expect(summarize(envelopesOf(run(unmarked, RECORDED)))).toContain('user:text:custom id test');
    });

    it('never sends the same text twice when deltas are followed by the full part', () => {
        const mapper = new OpencodeEventMapper(SESSION);
        const envelopes = envelopesOf(run(mapper, RECORDED));
        const outputs = summarize(envelopes).filter((line) => line.startsWith('agent:text:'));
        expect(outputs).toEqual(['agent:text:PINEAPPLE-API', 'agent:text:Done — created `tuifile.txt` with `TUI-TYPED`.']);
    });

    it('ignores events from unrelated sessions', () => {
        const mapper = new OpencodeEventMapper('ses_other');
        const actions = run(mapper, RECORDED.filter((event) => event.type !== 'message.updated'));
        expect(actions).toEqual([]);
    });

    it('buffers parts that arrive before their message role', () => {
        const mapper = new OpencodeEventMapper('ses_a');
        const early = mapper.handle({
            type: 'message.part.updated',
            properties: { part: { id: 'prt_1', messageID: 'msg_1', sessionID: 'ses_a', type: 'text', text: 'hello' } },
        });
        expect(early).toEqual([]);
        const late = mapper.handle({
            type: 'message.updated',
            properties: { info: { id: 'msg_1', sessionID: 'ses_a', role: 'user' } },
        });
        expect(summarize(envelopesOf(late))).toEqual(['user:text:hello']);
    });

    it('follows the TUI into another top-level session', () => {
        const mapper = new OpencodeEventMapper('ses_a');
        const actions = run(mapper, [
            { type: 'message.updated', properties: { info: { id: 'msg_9', sessionID: 'ses_b', role: 'user' } } },
            { type: 'message.part.updated', properties: { part: { id: 'prt_9', messageID: 'msg_9', sessionID: 'ses_b', type: 'text', text: 'over here' } } },
        ]);
        expect(actions[0]).toEqual({ type: 'session-changed', sessionId: 'ses_b' });
        expect(mapper.sessionId).toBe('ses_b');
        expect(summarize(envelopesOf(actions))).toEqual(['user:text:over here']);
    });

    it('does not follow sub-agent sessions but forwards their permissions', () => {
        const mapper = new OpencodeEventMapper('ses_a');
        const actions = run(mapper, [
            { type: 'session.created', properties: { info: { id: 'ses_child', parentID: 'ses_a', title: 'sub' } } },
            { type: 'message.updated', properties: { info: { id: 'msg_c', sessionID: 'ses_child', role: 'user' } } },
            {
                type: 'permission.asked',
                properties: { id: 'per_c', sessionID: 'ses_child', permission: 'edit', metadata: { filePath: '/x.ts' } },
            },
        ]);
        expect(mapper.sessionId).toBe('ses_a');
        expect(actions).toEqual([
            { type: 'permission-asked', id: 'per_c', toolName: 'edit', input: { filePath: '/x.ts', path: '/x.ts', file_path: '/x.ts' } },
        ]);
    });

    it('reports questions of the followed session joined to the question tool call', () => {
        const mapper = new OpencodeEventMapper('ses_a');
        const questions = [
            { question: 'Which color?', header: 'Color', options: [{ label: 'Red', description: 'warm' }, { label: 'Blue', description: '' }], multiple: true, custom: false },
        ];
        const actions = run(mapper, [
            { type: 'message.updated', properties: { info: { id: 'msg_a', sessionID: 'ses_a', role: 'assistant' } } },
            {
                type: 'message.part.updated',
                properties: {
                    part: {
                        id: 'prt_q', messageID: 'msg_a', sessionID: 'ses_a', type: 'tool', tool: 'question', callID: 'call_q',
                        state: { status: 'running', input: { questions } },
                    },
                },
            },
            {
                type: 'question.asked',
                properties: { id: 'que_1', sessionID: 'ses_a', questions, tool: { messageID: 'msg_a', callID: 'call_q' } },
            },
            { type: 'question.replied', properties: { sessionID: 'ses_a', requestID: 'que_1', answers: [['Red']] } },
            { type: 'question.rejected', properties: { sessionID: 'ses_a', requestID: 'que_2' } },
            { type: 'question.asked', properties: { id: 'que_x', sessionID: 'ses_unrelated', questions } },
        ]);
        expect(summarize(envelopesOf(actions))).toEqual([
            'agent:turn-start',
            `agent:tool-call-start:question:${JSON.stringify({ questions })}`,
        ]);
        expect((envelopesOf(actions)[1].ev as any).call).toBe('call_q');
        expect(actions.filter((action) => action.type !== 'envelopes')).toEqual([
            {
                type: 'question-asked',
                id: 'que_1',
                questions: [{ question: 'Which color?', header: 'Color', options: [{ label: 'Red', description: 'warm' }, { label: 'Blue', description: '' }], multiple: true, custom: false }],
                toolCallId: 'call_q',
            },
            { type: 'question-resolved', id: 'que_1', status: 'answered', answers: [['Red']] },
            { type: 'question-resolved', id: 'que_2', status: 'cancelled' },
        ]);
    });

    it('forwards sub-agent questions without a tool call to join', () => {
        const mapper = new OpencodeEventMapper('ses_a');
        const actions = run(mapper, [
            { type: 'session.created', properties: { info: { id: 'ses_child', parentID: 'ses_a', title: 'sub' } } },
            {
                type: 'question.asked',
                properties: { id: 'que_c', sessionID: 'ses_child', questions: [{ question: 'Name?', header: 'Name' }], tool: { messageID: 'm', callID: 'call_c' } },
            },
        ]);
        expect(actions).toEqual([
            { type: 'question-asked', id: 'que_c', questions: [{ question: 'Name?', header: 'Name', options: [] }] },
        ]);
    });

    it('marks aborted turns cancelled and errors failed', () => {
        const mapper = new OpencodeEventMapper('ses_a');
        const aborted = run(mapper, [
            { type: 'session.status', properties: { sessionID: 'ses_a', status: { type: 'busy' } } },
            { type: 'session.error', properties: { sessionID: 'ses_a', error: { name: 'MessageAbortedError', data: {} } } },
            { type: 'session.idle', properties: { sessionID: 'ses_a' } },
        ]);
        expect(summarize(envelopesOf(aborted))).toEqual(['agent:turn-start', 'agent:turn-end:cancelled']);

        const failed = run(mapper, [
            { type: 'session.status', properties: { sessionID: 'ses_a', status: { type: 'busy' } } },
            { type: 'session.error', properties: { sessionID: 'ses_a', error: { name: 'APIError', data: { message: 'rate limited' } } } },
            { type: 'session.status', properties: { sessionID: 'ses_a', status: { type: 'idle' } } },
        ]);
        expect(summarize(envelopesOf(failed))).toEqual(['agent:turn-start', 'agent:service', 'agent:turn-end:failed']);
        expect((envelopesOf(failed)[1].ev as any).text).toBe('Error: rate limited');
    });

    it('skips OpenCode placeholder titles', () => {
        const mapper = new OpencodeEventMapper('ses_a');
        const actions = run(mapper, [
            { type: 'session.updated', properties: { info: { id: 'ses_a', title: 'New session - 2026-10-26T03:00:00.000Z' } } },
            { type: 'session.updated', properties: { info: { id: 'ses_a', title: 'Fix the build' } } },
            { type: 'session.updated', properties: { info: { id: 'ses_a', title: 'Fix the build' } } },
        ]);
        expect(actions).toEqual([{ type: 'title', title: 'Fix the build' }]);
    });

    it('closeTurn ends an open turn once', () => {
        const mapper = new OpencodeEventMapper('ses_a');
        mapper.handle({ type: 'session.status', properties: { sessionID: 'ses_a', status: { type: 'busy' } } });
        expect(summarize(mapper.closeTurn('cancelled'))).toEqual(['agent:turn-end:cancelled']);
        expect(mapper.closeTurn('cancelled')).toEqual([]);
    });
});

describe('tool helpers', () => {
    it('maps OpenCode tools to the kinds the app renders', () => {
        expect(opencodeToolKind('bash')).toBe('execute');
        expect(opencodeToolKind('write')).toBe('edit');
        expect(opencodeToolKind('grep')).toBe('search');
        expect(opencodeToolKind('read')).toBe('read');
        expect(opencodeToolKind('my_mcp_tool')).toBe('my_mcp_tool');
    });

    it('adds the argument spellings the app reads', () => {
        expect(normalizeOpencodeToolInput({ filePath: '/a', oldString: 'x', newString: 'y' })).toEqual({
            filePath: '/a',
            path: '/a',
            file_path: '/a',
            oldString: 'x',
            newString: 'y',
            oldText: 'x',
            newText: 'y',
        });
        expect(normalizeOpencodeToolInput(null)).toEqual({});
        expect(normalizeOpencodeToolInput(['x'])).toEqual({});
    });
});
