/**
 * Permission requests of an `opencode serve` session, answerable from the
 * terminal and from the app.
 *
 * OpenCode raises a request (`permission.asked`) once, and both the attached
 * TUI and the Happy app show it. Whichever side answers first wins: an app
 * answer is posted to `/permission/:id/reply`; a TUI answer arrives as
 * `permission.replied` and clears the request from the app.
 */

import { logger } from '@/ui/logger';
import type { ApiSessionClient } from '@/api/apiSession';
import { BasePermissionHandler, type PermissionResult } from '@/utils/BasePermissionHandler';
import type { OpencodePermissionReply } from './opencodeEventMapper';

export type OpencodePermissionRequest = {
    id: string;
    toolName: string;
    input: Record<string, unknown>;
    /** OpenCode call id of the tool that asked, used by the app to join the request to the tool call. */
    toolCallId?: string;
};

export function opencodeReplyForDecision(decision: PermissionResult['decision']): OpencodePermissionReply {
    switch (decision) {
        case 'approved':
            return 'once';
        case 'approved_for_session':
            return 'always';
        default:
            return 'reject';
    }
}

export class OpencodePermissionBridge extends BasePermissionHandler {
    constructor(
        session: ApiSessionClient,
        private readonly sendReply: (id: string, reply: OpencodePermissionReply) => Promise<void>,
    ) {
        super(session);
    }

    protected getLogPrefix(): string {
        return '[OpenCode]';
    }

    /** Show a request in the app. Requests already shown are left alone. */
    ask(request: OpencodePermissionRequest): void {
        if (this.pendingRequests.has(request.id)) {
            return;
        }
        this.pendingRequests.set(request.id, {
            toolName: request.toolName,
            input: request.input,
            resolve: (result) => {
                this.sendReply(request.id, opencodeReplyForDecision(result.decision)).catch((error) => {
                    // Usually means the TUI answered first; OpenCode then reports it as replied.
                    logger.debug(`[OpenCode] Failed to answer permission ${request.id}:`, error);
                });
            },
            reject: () => { },
        });
        this.session.updateAgentState((state) => {
            const { [request.id]: _completed, ...completedRequests } = state.completedRequests || {};
            return {
                ...state,
                requests: {
                    ...state.requests,
                    [request.id]: {
                        tool: request.toolName,
                        arguments: request.input,
                        createdAt: Date.now(),
                        ...(request.toolCallId ? { toolUseId: request.toolCallId } : {}),
                    },
                },
                completedRequests,
            };
        });
    }

    /** OpenCode reports a request as answered (from the TUI, or our own reply echoed back). */
    resolveExternally(id: string, reply: OpencodePermissionReply): void {
        if (!this.pendingRequests.delete(id)) {
            return;
        }
        const approved = reply !== 'reject';
        this.session.updateAgentState((state) => {
            const request = state.requests?.[id];
            if (!request) {
                return state;
            }
            const { [id]: _answered, ...requests } = state.requests || {};
            return {
                ...state,
                requests,
                completedRequests: {
                    ...state.completedRequests,
                    [id]: {
                        ...request,
                        completedAt: Date.now(),
                        status: approved ? 'approved' : 'denied',
                        decision: reply === 'always' ? 'approved_for_session' : (approved ? 'approved' : 'denied'),
                    },
                },
            };
        });
        logger.debug(`[OpenCode] Permission ${id} answered in the terminal: ${reply}`);
    }

    /** Ids of the requests currently shown in the app. */
    pendingIds(): string[] {
        return [...this.pendingRequests.keys()];
    }
}
