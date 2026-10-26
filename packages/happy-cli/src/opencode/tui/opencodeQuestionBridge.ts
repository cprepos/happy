/**
 * Questions of an `opencode serve` session (its `question` tool), answerable
 * from the terminal and from the app.
 *
 * OpenCode raises a question request (`question.asked`) and waits; both the
 * attached TUI and the Happy app show it. Whichever side answers first wins:
 * an app answer (the `communication` session RPC) is posted to
 * `/question/:id/reply`, a dismissal to `/question/:id/reject`; a TUI answer
 * arrives as `question.replied` / `question.rejected` and closes the form in
 * the app.
 *
 * In the app a request is an agent communication of kind `form`
 * (`agentState.communications`), one form question per OpenCode question,
 * with ids `q0`, `q1`, ... in OpenCode's order. OpenCode wants the answers
 * back as one list of strings per question, in that same order: the chosen
 * option labels followed by any typed text.
 *
 * Questions are never answered automatically, whatever the permission policy.
 */

import { logger } from '@/ui/logger';
import type { ApiSessionClient } from '@/api/apiSession';
import type { AgentCommunicationReply, AgentQuestion, AgentQuestionAnswer, AgentState } from '@/api/types';
import type { OpencodeQuestion } from './opencodeEventMapper';

export type OpencodeQuestionRequest = {
    id: string;
    questions: OpencodeQuestion[];
    /** OpenCode call id of the `question` tool call, used by the app to show the form on that card. */
    toolCallId?: string;
};

export type OpencodeQuestionTransport = {
    reply: (id: string, answers: string[][]) => Promise<void>;
    reject: (id: string) => Promise<void>;
};

/** Form question id of OpenCode question number `index`. */
function formQuestionId(index: number): string {
    return `q${index}`;
}

/** OpenCode questions -> the app's form questions. */
export function opencodeFormQuestions(questions: OpencodeQuestion[]): AgentQuestion[] {
    return questions.map((question, index) => ({
        id: formQuestionId(index),
        header: question.header,
        question: question.question,
        options: question.options.map((option) => ({
            label: option.label,
            ...(option.description ? { description: option.description } : {}),
        })),
        multiSelect: question.multiple === true,
        allowCustom: question.custom !== false,
    }));
}

/** The app's answers -> OpenCode's reply: per question, chosen labels then typed text. */
export function opencodeAnswersFromForm(
    questions: OpencodeQuestion[],
    answers: Record<string, AgentQuestionAnswer> | undefined,
): string[][] {
    return questions.map((question, index) => {
        const answer = answers?.[formQuestionId(index)];
        if (!answer) {
            return [];
        }
        const options = Array.isArray(answer.options) ? answer.options.filter((label) => typeof label === 'string') : [];
        const chosen = question.multiple === true ? options : options.slice(0, 1);
        const custom = typeof answer.custom === 'string' && question.custom !== false ? answer.custom.trim() : '';
        return custom ? [...chosen, custom] : chosen;
    });
}

/**
 * OpenCode's reply (from the TUI) -> the app's answers, for the answered
 * card. Strings that are option labels count as choices, the rest as typed text.
 */
export function formAnswersFromOpencode(
    questions: OpencodeQuestion[],
    answers: string[][],
): Record<string, AgentQuestionAnswer> {
    const result: Record<string, AgentQuestionAnswer> = {};
    questions.forEach((question, index) => {
        const values = Array.isArray(answers[index]) ? answers[index] : [];
        const labels = new Set(question.options.map((option) => option.label));
        const options = values.filter((value) => labels.has(value));
        const typed = values.filter((value) => !labels.has(value));
        if (options.length === 0 && typed.length === 0) {
            return;
        }
        result[formQuestionId(index)] = { options, ...(typed.length > 0 ? { custom: typed.join(', ') } : {}) };
    });
    return result;
}

/** Move one communication to `completedCommunications`. */
function completeCommunication(
    state: AgentState,
    id: string,
    status: 'answered' | 'cancelled',
    answers?: Record<string, AgentQuestionAnswer>,
): AgentState {
    const communication = state.communications?.[id];
    if (!communication) {
        return state;
    }
    const { [id]: _done, ...communications } = state.communications ?? {};
    return {
        ...state,
        communications,
        completedCommunications: {
            ...state.completedCommunications,
            [id]: {
                ...communication,
                completedAt: Date.now(),
                status,
                ...(answers ? { answers } : {}),
            },
        },
    };
}

export class OpencodeQuestionBridge {
    private readonly pending = new Map<string, OpencodeQuestionRequest>();

    constructor(
        private session: ApiSessionClient,
        private readonly transport: OpencodeQuestionTransport,
    ) {
        this.registerRpcHandler();
    }

    /** Point at a new session client after an offline reconnection swapped it. */
    updateSession(session: ApiSessionClient): void {
        this.session = session;
        this.registerRpcHandler();
    }

    private registerRpcHandler(): void {
        this.session.rpcHandlerManager.registerHandler<AgentCommunicationReply, { success: true }>(
            'communication',
            async (reply) => {
                const request = reply && typeof reply.id === 'string' ? this.pending.get(reply.id) : undefined;
                if (!request) {
                    throw new Error('This question is no longer waiting for an answer');
                }
                if (reply.status === 'cancelled') {
                    await this.transport.reject(request.id);
                    this.complete(request.id, 'cancelled');
                    logger.debug(`[OpenCode] Question ${request.id} dismissed from the app`);
                    return { success: true };
                }
                if (reply.status !== 'answered') {
                    throw new Error(`Unknown communication status: ${String(reply.status)}`);
                }
                const answers = opencodeAnswersFromForm(request.questions, reply.answers);
                await this.transport.reply(request.id, answers);
                this.complete(request.id, 'answered', formAnswersFromOpencode(request.questions, answers));
                logger.debug(`[OpenCode] Question ${request.id} answered from the app`);
                return { success: true };
            },
        );
    }

    private complete(id: string, status: 'answered' | 'cancelled', answers?: Record<string, AgentQuestionAnswer>): boolean {
        if (!this.pending.delete(id)) {
            return false;
        }
        this.session.updateAgentState((state) => completeCommunication(state, id, status, answers));
        return true;
    }

    /** Show a question in the app. Questions already shown are left alone. */
    ask(request: OpencodeQuestionRequest): void {
        if (this.pending.has(request.id) || request.questions.length === 0) {
            return;
        }
        this.pending.set(request.id, request);
        this.session.updateAgentState((state) => {
            const { [request.id]: _completed, ...completedCommunications } = state.completedCommunications ?? {};
            return {
                ...state,
                communications: {
                    ...state.communications,
                    [request.id]: {
                        kind: 'form',
                        createdAt: Date.now(),
                        ...(request.toolCallId ? { toolUseId: request.toolCallId } : {}),
                        form: { questions: opencodeFormQuestions(request.questions) },
                    },
                },
                completedCommunications,
            };
        });
    }

    /** OpenCode reports a question as answered or dismissed (from the TUI, or our own reply echoed back). */
    resolveExternally(id: string, status: 'answered' | 'cancelled', answers?: string[][]): void {
        const request = this.pending.get(id);
        if (!request) {
            return;
        }
        this.complete(id, status, status === 'answered' && answers ? formAnswersFromOpencode(request.questions, answers) : undefined);
        logger.debug(`[OpenCode] Question ${id} ${status} in the terminal`);
    }

    /** Dismiss every question still waiting (the user stopped the turn). */
    rejectAll(): void {
        for (const id of [...this.pending.keys()]) {
            this.transport.reject(id).catch((error) => {
                // OpenCode may already have dropped it with the aborted turn.
                logger.debug(`[OpenCode] Failed to dismiss question ${id}:`, error);
            });
            this.complete(id, 'cancelled');
        }
    }

    /**
     * Close every question shown in the app without telling OpenCode: on
     * start (left over from a previous process, whose server is gone) and on
     * shutdown.
     */
    reset(): void {
        this.pending.clear();
        this.session.updateAgentState((state) => {
            let next = state;
            for (const id of Object.keys(state.communications ?? {})) {
                next = completeCommunication(next, id, 'cancelled');
            }
            return next;
        });
    }

    /** Ids of the questions currently shown in the app. */
    pendingIds(): string[] {
        return [...this.pending.keys()];
    }
}
