import * as React from 'react';

import { sessionAnswerQuestion, sessionCancelCommunication } from '@/sync/ops';
import { useSessionAgentFormCommunication } from '@/sync/storage';
import type { AgentQuestionAnswer } from '@/sync/storageTypes';
import { ToolViewProps } from './_all';
import {
    InlineQuestionForm,
    type InlineQuestion,
    type InlineQuestionAnswers,
    type InlineQuestionCustomAnswers,
} from './InlineQuestionForm';

/**
 * Inline renderer for agent communications (forms) joined to a tool call:
 * Happy/Codex request_user_input and OpenCode's question tool.
 */
export const RequestUserInputView = React.memo<ToolViewProps>(({ tool, sessionId }) => {
    const communication = useSessionAgentFormCommunication(sessionId ?? '', tool.callId ?? '');

    // A question takes written answers unless the agent turned that off.
    const questions = React.useMemo<InlineQuestion[]>(() => (
        (communication?.questions ?? []).map(question => ({
            ...question,
            allowCustom: question.allowCustom !== false,
        }))
    ), [communication?.questions]);

    const submittedAnswers = React.useMemo<InlineQuestionAnswers | null>(() => {
        if (!communication || communication.status === 'pending') return null;
        if (communication.status === 'cancelled' || !communication.answers) return {};
        const answers: InlineQuestionAnswers = {};
        for (const [questionId, answer] of Object.entries(communication.answers)) {
            const values = [...answer.options];
            if (answer.custom) values.push(answer.custom);
            answers[questionId] = values;
        }
        return answers;
    }, [communication]);

    const handleSubmit = React.useCallback(async (answers: InlineQuestionAnswers, customAnswers: InlineQuestionCustomAnswers) => {
        if (!sessionId || !communication || communication.status !== 'pending') return;

        const communicationAnswers: Record<string, AgentQuestionAnswer> = {};
        for (const question of communication.questions) {
            const selected = answers[question.id] ?? [];
            const custom = question.allowCustom !== false ? customAnswers[question.id]?.trim() : undefined;
            if (selected.length === 0 && !custom) continue;
            communicationAnswers[question.id] = {
                options: question.multiSelect
                    ? selected
                    : selected.slice(0, 1),
                ...(custom ? { custom } : {}),
            };
        }
        await sessionAnswerQuestion(sessionId, communication.id, communicationAnswers, communication.kind);
    }, [communication, sessionId]);

    const handleDismiss = React.useCallback(async () => {
        if (!sessionId || !communication || communication.status !== 'pending') return;
        await sessionCancelCommunication(sessionId, communication.id, communication.kind);
    }, [communication, sessionId]);

    if (!communication || questions.length === 0) {
        return null;
    }

    return (
        <InlineQuestionForm
            questions={questions}
            canInteract={tool.state === 'running' && communication.status === 'pending'}
            submittedAnswers={submittedAnswers}
            dismissed={communication.status === 'cancelled'}
            onSubmit={handleSubmit}
            onDismiss={handleDismiss}
        />
    );
});
