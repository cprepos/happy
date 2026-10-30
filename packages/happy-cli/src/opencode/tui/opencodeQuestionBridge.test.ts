import { describe, expect, it } from 'vitest';
import type { ApiSessionClient } from '@/api/apiSession';
import type { AgentState } from '@/api/types';
import type { OpencodeQuestion } from './opencodeEventMapper';
import {
    formAnswersFromOpencode,
    OpencodeQuestionBridge,
    opencodeAnswersFromForm,
    opencodeFormQuestions,
} from './opencodeQuestionBridge';

type RpcHandler = (params: any) => Promise<unknown>;

/** Stands in for the session socket: keeps agent state and the registered RPC handlers. */
function fakeSession(initial: AgentState = {}) {
    const handlers = new Map<string, RpcHandler>();
    let state: AgentState = initial;
    const session = {
        rpcHandlerManager: {
            registerHandler: (method: string, handler: RpcHandler) => { handlers.set(method, handler); },
        },
        // Returns a promise because the real one does (ApiSessionClient
        // .updateAgentState is Promise<void>) and the bridge chains .catch on
        // it. A void double made every test here throw inside ask().
        updateAgentState: (update: (current: AgentState) => AgentState) => {
            state = update(state);
            return Promise.resolve();
        },
    };
    return {
        session: session as unknown as ApiSessionClient,
        state: () => state,
        callRpc: (method: string, params: unknown) => handlers.get(method)!(params),
    };
}

const COLOR: OpencodeQuestion = {
    question: 'Which color?',
    header: 'Color',
    options: [{ label: 'Red', description: 'warm' }, { label: 'Blue' }],
};
const TOPPINGS: OpencodeQuestion = {
    question: 'Which toppings?',
    header: 'Toppings',
    options: [{ label: 'Cheese' }, { label: 'Ham' }, { label: 'Olives' }],
    multiple: true,
};
const NAME: OpencodeQuestion = { question: 'Your name?', header: 'Name', options: [] };
const STRICT: OpencodeQuestion = { question: 'Pick one', header: 'Strict', options: [{ label: 'A' }], custom: false };

function setup(initial?: AgentState) {
    const fake = fakeSession(initial);
    const replies: Array<[string, string[][]]> = [];
    const rejects: string[] = [];
    const bridge = new OpencodeQuestionBridge(fake.session, {
        reply: async (id, answers) => { replies.push([id, answers]); },
        reject: async (id) => { rejects.push(id); },
    });
    return { fake, replies, rejects, bridge };
}

describe('opencode question mapping', () => {
    it('turns OpenCode questions into form questions in order', () => {
        expect(opencodeFormQuestions([COLOR, TOPPINGS, NAME, STRICT])).toEqual([
            { id: 'q0', header: 'Color', question: 'Which color?', options: [{ label: 'Red', description: 'warm' }, { label: 'Blue' }], multiSelect: false, allowCustom: true },
            { id: 'q1', header: 'Toppings', question: 'Which toppings?', options: [{ label: 'Cheese' }, { label: 'Ham' }, { label: 'Olives' }], multiSelect: true, allowCustom: true },
            { id: 'q2', header: 'Name', question: 'Your name?', options: [], multiSelect: false, allowCustom: true },
            { id: 'q3', header: 'Strict', question: 'Pick one', options: [{ label: 'A' }], multiSelect: false, allowCustom: false },
        ]);
    });

    it('maps single, multiple, typed and missing answers to one list per question', () => {
        expect(opencodeAnswersFromForm([COLOR, TOPPINGS, NAME, STRICT], {
            q0: { options: ['Red', 'Blue'] },
            q1: { options: ['Cheese', 'Olives'], custom: ' pineapple ' },
            q2: { options: [], custom: 'Ada' },
        })).toEqual([['Red'], ['Cheese', 'Olives', 'pineapple'], ['Ada'], []]);
        // Typed text is dropped where OpenCode does not accept it.
        expect(opencodeAnswersFromForm([STRICT], { q0: { options: ['A'], custom: 'B' } })).toEqual([['A']]);
        expect(opencodeAnswersFromForm([COLOR], undefined)).toEqual([[]]);
    });

    it('reads a terminal answer back as choices and typed text', () => {
        expect(formAnswersFromOpencode([COLOR, TOPPINGS, NAME], [['Blue'], ['Ham', 'anchovies'], []])).toEqual({
            q0: { options: ['Blue'] },
            q1: { options: ['Ham'], custom: 'anchovies' },
        });
    });
});

describe('OpencodeQuestionBridge', () => {
    it('shows a question in the app as a form joined to its tool call', () => {
        const { fake, bridge } = setup();
        bridge.ask({ id: 'que_1', questions: [COLOR], toolCallId: 'call_1' });
        bridge.ask({ id: 'que_1', questions: [COLOR], toolCallId: 'call_1' });

        expect(fake.state().communications).toEqual({
            que_1: {
                kind: 'form',
                createdAt: expect.any(Number),
                toolUseId: 'call_1',
                form: { questions: opencodeFormQuestions([COLOR]) },
            },
        });
        expect(bridge.pendingIds()).toEqual(['que_1']);
    });

    it('marks a question without a tool call as answered outside the transcript', () => {
        const { fake, bridge } = setup();
        bridge.ask({ id: 'que_c', questions: [NAME] });
        expect(fake.state().communications?.que_c).toMatchObject({ kind: 'form', inTranscript: false });
        expect(fake.state().communications?.que_c?.toolUseId).toBeUndefined();
    });

    it('forwards an app answer to OpenCode and records it as answered', async () => {
        const { fake, replies, bridge } = setup();
        bridge.ask({ id: 'que_1', questions: [COLOR, TOPPINGS, NAME] });

        await expect(fake.callRpc('communication', {
            id: 'que_1',
            kind: 'form',
            status: 'answered',
            answers: { q0: { options: ['Red'] }, q1: { options: ['Cheese', 'Ham'] }, q2: { options: [], custom: 'Ada' } },
        })).resolves.toEqual({ success: true });

        expect(replies).toEqual([['que_1', [['Red'], ['Cheese', 'Ham'], ['Ada']]]]);
        expect(fake.state().communications).toEqual({});
        expect(fake.state().completedCommunications?.que_1).toMatchObject({
            kind: 'form',
            status: 'answered',
            answers: { q0: { options: ['Red'] }, q1: { options: ['Cheese', 'Ham'] }, q2: { options: [], custom: 'Ada' } },
        });

        // OpenCode echoes the reply back; nothing changes.
        bridge.resolveExternally('que_1', 'answered', [['Red'], ['Cheese', 'Ham'], ['Ada']]);
        expect(replies).toHaveLength(1);
    });

    it('dismisses a question from the app', async () => {
        const { fake, replies, rejects, bridge } = setup();
        bridge.ask({ id: 'que_1', questions: [COLOR] });
        await fake.callRpc('communication', { id: 'que_1', kind: 'form', status: 'cancelled' });

        expect(rejects).toEqual(['que_1']);
        expect(replies).toEqual([]);
        expect(fake.state().completedCommunications?.que_1).toMatchObject({ status: 'cancelled' });
        expect(bridge.pendingIds()).toEqual([]);
    });

    it('refuses answers for questions it is not waiting on', async () => {
        const { fake, replies, rejects, bridge } = setup();
        bridge.ask({ id: 'que_1', questions: [COLOR] });

        await expect(fake.callRpc('communication', { id: 'que_other', kind: 'form', status: 'answered', answers: {} })).rejects.toThrow();
        await expect(fake.callRpc('communication', { id: 'que_other', kind: 'form', status: 'cancelled' })).rejects.toThrow();
        expect(replies).toEqual([]);
        expect(rejects).toEqual([]);
    });

    it('closes a question answered in the terminal, and ignores a late app answer', async () => {
        const { fake, replies, bridge } = setup();
        bridge.ask({ id: 'que_1', questions: [COLOR], toolCallId: 'call_1' });
        bridge.ask({ id: 'que_2', questions: [NAME] });
        bridge.resolveExternally('que_1', 'answered', [['Blue']]);
        bridge.resolveExternally('que_2', 'cancelled');

        expect(fake.state().communications).toEqual({});
        expect(fake.state().completedCommunications?.que_1).toMatchObject({ status: 'answered', toolUseId: 'call_1', answers: { q0: { options: ['Blue'] } } });
        expect(fake.state().completedCommunications?.que_2).toMatchObject({ status: 'cancelled' });

        await expect(fake.callRpc('communication', { id: 'que_1', kind: 'form', status: 'answered', answers: { q0: { options: ['Red'] } } })).rejects.toThrow();
        expect(replies).toEqual([]);
    });

    it('keeps a question open when OpenCode refuses the reply', async () => {
        const fake = fakeSession();
        const bridge = new OpencodeQuestionBridge(fake.session, {
            reply: async () => { throw new Error('404'); },
            reject: async () => { },
        });
        bridge.ask({ id: 'que_1', questions: [COLOR] });
        await expect(fake.callRpc('communication', { id: 'que_1', kind: 'form', status: 'answered', answers: { q0: { options: ['Red'] } } })).rejects.toThrow('404');
        expect(bridge.pendingIds()).toEqual(['que_1']);
        expect(fake.state().communications?.que_1).toBeDefined();
    });

    it('dismisses waiting questions when the turn is aborted', () => {
        const { fake, rejects, bridge } = setup();
        bridge.ask({ id: 'que_1', questions: [COLOR] });
        bridge.rejectAll();
        expect(rejects).toEqual(['que_1']);
        expect(fake.state().completedCommunications?.que_1).toMatchObject({ status: 'cancelled' });
    });

    it('closes questions left over from a previous process on reset', () => {
        const { fake, bridge } = setup({
            communications: { que_old: { kind: 'form', createdAt: 1, form: { questions: opencodeFormQuestions([COLOR]) } } },
        });
        bridge.reset();
        expect(fake.state().communications).toEqual({});
        expect(fake.state().completedCommunications?.que_old).toMatchObject({ status: 'cancelled' });
    });
});
