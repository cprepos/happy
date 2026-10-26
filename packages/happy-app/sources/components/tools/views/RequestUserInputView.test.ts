import * as React from 'react';
// @ts-expect-error react-test-renderer has no declarations in this workspace.
import { act, create } from 'react-test-renderer';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
    communication: null as any,
    answer: vi.fn(async (..._args: unknown[]) => { }),
    cancel: vi.fn(async (..._args: unknown[]) => { }),
}));

vi.mock('react-native', async () => {
    const React = await import('react');
    const host = (name: string) => (props: any) => React.createElement(name, props, props.children);
    return {
        Text: host('Text'),
        View: host('View'),
        TextInput: host('TextInput'),
        TouchableOpacity: host('TouchableOpacity'),
        ActivityIndicator: host('ActivityIndicator'),
        Platform: { OS: 'ios', select: (values: any) => values.ios ?? values.default },
    };
});
vi.mock('react-native-unistyles', () => {
    // Any theme path (theme.colors.button.primary.background, ...) resolves to a color.
    const color: any = new Proxy(() => '#000', {
        get: (_target, key) => (key === Symbol.toPrimitive ? () => '#000' : color),
    });
    const theme = { colors: color };
    return {
        StyleSheet: { create: (styles: any) => (typeof styles === 'function' ? styles(theme) : styles) },
        useUnistyles: () => ({ theme }),
    };
});
vi.mock('@expo/vector-icons', () => ({ Ionicons: 'Ionicons' }));
vi.mock('@/text', () => ({ t: (key: string) => key }));
vi.mock('../ToolSectionView', async () => {
    const React = await import('react');
    return { ToolSectionView: (props: any) => React.createElement('Section', null, props.children) };
});
vi.mock('@/sync/storage', () => ({ useSessionAgentFormCommunication: () => state.communication }));
vi.mock('@/sync/ops', () => ({
    sessionAnswerQuestion: (...args: unknown[]) => state.answer(...args),
    sessionCancelCommunication: (...args: unknown[]) => state.cancel(...args),
}));
vi.mock('./_all', () => ({}));

import { RequestUserInputView } from './RequestUserInputView';

const renderers: ReturnType<typeof create>[] = [];
function render(element: React.ReactElement) {
    let renderer: ReturnType<typeof create>;
    act(() => { renderer = create(element); });
    renderers.push(renderer!);
    return renderer!;
}
function textOf(node: any): string {
    if (typeof node === 'string') return node;
    if (Array.isArray(node)) return node.map(textOf).join('');
    return node?.children ? textOf(node.children) : '';
}
const tool = { name: 'question', state: 'running', callId: 'call_q', input: {} } as any;
const view = () => React.createElement(RequestUserInputView, { tool, sessionId: 'ses_1', metadata: null, messages: [] } as any);
const buttons = (tree: ReturnType<typeof create>) => tree.root.findAllByType('TouchableOpacity');
const submitButton = (tree: ReturnType<typeof create>) => buttons(tree).find((node: any) => textOf(node.children).includes('tools.askUserQuestion.submit'))!;
const dismissButton = (tree: ReturnType<typeof create>) => buttons(tree).find((node: any) => textOf(node.children).includes('agentQuestion.dismiss'));

function pending(questions: any[]) {
    return { id: 'que_1', createdAt: 1, toolUseId: 'call_q', kind: 'form', questions, status: 'pending' };
}

beforeEach(() => {
    vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
    const original = console.error;
    vi.spyOn(console, 'error').mockImplementation((message: unknown, ...args: unknown[]) => {
        if (typeof message === 'string' && message.startsWith('react-test-renderer is deprecated')) return;
        original(message, ...args);
    });
    state.answer.mockClear();
    state.cancel.mockClear();
});
afterEach(() => {
    act(() => renderers.splice(0).forEach((renderer) => renderer.unmount()));
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
});

describe('RequestUserInputView', () => {
    it('answers a question without options with written text', async () => {
        state.communication = pending([{ id: 'q0', header: 'Name', question: 'Your name?', options: [], allowCustom: true }]);
        const tree = render(view());

        expect(textOf(tree.toJSON())).toContain('Your name?');
        expect(submitButton(tree).props.disabled).toBe(true);
        const input = tree.root.findByType('TextInput');
        act(() => input.props.onChangeText('  Ada '));
        expect(submitButton(tree).props.disabled).toBe(false);

        await act(async () => { await submitButton(tree).props.onPress(); });
        expect(state.answer).toHaveBeenCalledWith('ses_1', 'que_1', { q0: { options: [], custom: 'Ada' } }, 'form');
        expect(textOf(tree.toJSON())).toContain('Ada');
    });

    it('sends chosen options and written text together, per question', async () => {
        state.communication = pending([
            { id: 'q0', header: 'Color', question: 'Which color?', options: [{ label: 'Red' }, { label: 'Blue' }] },
            { id: 'q1', header: 'Toppings', question: 'Which?', options: [{ label: 'Cheese' }, { label: 'Ham' }], multiSelect: true },
        ]);
        const tree = render(view());
        const option = (label: string) => buttons(tree).find((node: any) => textOf(node.children) === label)!;

        act(() => option('Blue').props.onPress());
        act(() => option('Cheese').props.onPress());
        act(() => option('Ham').props.onPress());
        const inputs = tree.root.findAllByType('TextInput');
        expect(inputs).toHaveLength(2);
        act(() => inputs[1].props.onChangeText('olives'));

        await act(async () => { await submitButton(tree).props.onPress(); });
        expect(state.answer).toHaveBeenCalledWith('ses_1', 'que_1', {
            q0: { options: ['Blue'] },
            q1: { options: ['Cheese', 'Ham'], custom: 'olives' },
        }, 'form');
    });

    it('hides the written answer when the agent does not accept one', () => {
        state.communication = pending([
            { id: 'q0', header: 'Pick', question: 'Pick one', options: [{ label: 'A' }], allowCustom: false },
        ]);
        const tree = render(view());
        expect(tree.root.findAllByType('TextInput')).toHaveLength(0);
    });

    it('dismisses a question', async () => {
        state.communication = pending([{ id: 'q0', header: 'Name', question: 'Your name?', options: [] }]);
        const tree = render(view());
        await act(async () => { await dismissButton(tree)!.props.onPress(); });
        expect(state.cancel).toHaveBeenCalledWith('ses_1', 'que_1', 'form');
        expect(state.answer).not.toHaveBeenCalled();
    });

    it('shows a dismissed question as dismissed, and an answered one with its answer', () => {
        state.communication = { ...pending([{ id: 'q0', header: 'Name', question: 'Your name?', options: [] }]), status: 'cancelled' };
        const dismissed = render(view());
        expect(textOf(dismissed.toJSON())).toContain('agentQuestion.dismissed');
        expect(dismissButton(dismissed)).toBeUndefined();

        state.communication = {
            ...pending([{ id: 'q0', header: 'Color', question: 'Which?', options: [{ label: 'Red' }] }]),
            status: 'answered',
            answers: { q0: { options: ['Red'], custom: 'dark' } },
        };
        const answered = render(view());
        expect(textOf(answered.toJSON())).toContain('Red, dark');
    });
});
