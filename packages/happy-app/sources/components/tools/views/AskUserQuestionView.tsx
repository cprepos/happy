import * as React from 'react';

import { Modal } from '@/modal';
import { sessionAllow, sessionDeny } from '@/sync/ops';
import { sync } from '@/sync/sync';
import { ToolViewProps } from './_all';
import {
    InlineQuestionForm,
    type InlineQuestion,
    type InlineQuestionAnswers,
} from './InlineQuestionForm';

interface AskUserQuestionInput {
    questions?: Array<{
        question: string;
        header: string;
        options: Array<{ label: string; description?: string }>;
        multiSelect?: boolean;
    }>;
}

export const AskUserQuestionView = React.memo<ToolViewProps>(({ tool, sessionId }) => {
    const input = tool.input as AskUserQuestionInput | undefined;
    const questions = React.useMemo<InlineQuestion[]>(() => (
        (input?.questions ?? []).map((question, index) => ({
            ...question,
            id: `question-${index}`,
            required: true,
        }))
    ), [input?.questions]);

    const handleSubmit = React.useCallback(async (answers: InlineQuestionAnswers) => {
        if (!sessionId || !tool.permission?.id) {
            Modal.alert('Error', 'Still loading — please try again in a moment.', [{ text: 'OK', style: 'cancel' }]);
            return;
        }

        const providerAnswers: Record<string, string> = {};
        questions.forEach((question, index) => {
            const originalQuestion = input?.questions?.[index];
            const selected = answers[question.id];
            if (originalQuestion && selected?.length) {
                providerAnswers[originalQuestion.question] = selected.join(', ');
            }
        });

        await sessionAllow(
            sessionId,
            tool.permission.id,
            undefined,
            undefined,
            'approved',
            { answers: providerAnswers },
        );
    }, [input?.questions, questions, sessionId, tool.permission?.id]);

    /**
     * Decline to answer. AskUserQuestion arrives as a permission rather than
     * a communication, so this denies it -- the form's other transport
     * (request_user_input) dismisses through sessionCancelCommunication.
     *
     * The reason matters: the CLI's default refusal text ends "STOP what you
     * are doing and wait for the user to tell you how to proceed", which is
     * right for a rejected edit and wrong here. Dismissing a question is not
     * a refusal of the work, so it says what actually happened and leaves the
     * agent free to carry on.
     */
    const handleDismiss = React.useCallback(async () => {
        if (!sessionId || !tool.permission?.id) return;
        await sessionDeny(
            sessionId,
            tool.permission.id,
            undefined,
            undefined,
            undefined,
            'The user dismissed this question without answering it. Do not ask it again as-is: continue with your best judgement, or ask something more specific if you genuinely cannot proceed.',
        );
    }, [sessionId, tool.permission?.id]);

    React.useEffect(() => {
        if (tool.state === 'running' && !tool.permission?.id && sessionId) {
            const timer = setTimeout(() => sync.onSessionVisible(sessionId), 2000);
            return () => clearTimeout(timer);
        }
    }, [tool.state, tool.permission?.id, sessionId]);

    if (questions.length === 0) return null;

    const isDismissed = tool.permission?.status === 'denied';

    return (
        <InlineQuestionForm
            questions={questions}
            canInteract={tool.state === 'running' && !!tool.permission?.id && !isDismissed}
            submittedAnswers={tool.state === 'completed' && !isDismissed ? {} : undefined}
            dismissed={isDismissed}
            onSubmit={handleSubmit}
            onDismiss={handleDismiss}
        />
    );
});