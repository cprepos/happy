/**
 * Routes OpenCode permission requests by the session's permission policy.
 *
 * In `auto` (the default for `happy opencode`) a request is approved once,
 * straight away, the way `opencode --auto` does it: nothing is shown in the
 * app, and a rule that denies a tool still denies it because OpenCode never
 * asks about those. In `ask` the request goes to the permission bridge,
 * which shows it in the app (the TUI shows it too) and posts the answer.
 *
 * `opencode attach` has no `--auto`, and the server's permission rules cannot
 * be switched per prompt from the app, so the policy lives here and can
 * change with every message.
 *
 * Two requests are treated differently from what the policy alone would do:
 *
 * - `doom_loop` is always shown. OpenCode raises it when a tool is called
 *   three times in a row with identical input, as its guard against a stuck
 *   model. Approving it automatically would turn the guard off, so this is the
 *   one place auto differs from `opencode --auto`.
 * - A tool that reaches outside the project asks twice for one call:
 *   `external_directory`, then the tool's own permission. Both carry the same
 *   call id and land on the same card in the app, and the first already names
 *   the command or file. Once the person has allowed the first, the second is
 *   answered for them, so one tool call is one question.
 */

import { logger } from '@/ui/logger';
import type { OpencodePermissionReply } from './opencodeEventMapper';
import type { OpencodePermissionRequest } from './opencodePermissionBridge';
import type { OpencodePermissionPolicy } from './opencodeSessionConfig';

const DOOM_LOOP_PERMISSION = 'doom_loop';
const EXTERNAL_DIRECTORY_PERMISSION = 'external_directory';

export class OpencodePermissionRouter {
    /** Requests auto-approved (or being approved), so a re-listed request is not answered twice. */
    private readonly autoApproved = new Set<string>();
    /** Requests already answered, so one re-listed from a stale snapshot does not come back. */
    private readonly replied = new Set<string>();
    /** `external_directory` requests shown to the person: request id -> tool call id. */
    private readonly directoryAsks = new Map<string, string>();
    /** Tool calls whose `external_directory` request the person allowed. */
    private readonly allowedCalls = new Set<string>();

    constructor(
        private currentPolicy: OpencodePermissionPolicy,
        private readonly deps: {
            ask: (request: OpencodePermissionRequest) => void;
            reply: (id: string, reply: OpencodePermissionReply) => Promise<void>;
        },
    ) { }

    get policy(): OpencodePermissionPolicy {
        return this.currentPolicy;
    }

    setPolicy(policy: OpencodePermissionPolicy): void {
        if (policy !== this.currentPolicy) {
            logger.debug(`[OpenCode] Permission policy: ${policy}`);
            this.currentPolicy = policy;
        }
    }

    /** OpenCode reports a request as answered, by whichever side answered it. */
    handleReplied(id: string, reply: OpencodePermissionReply): void {
        this.replied.add(id);
        const callId = this.directoryAsks.get(id);
        if (callId && reply !== 'reject') {
            this.allowedCalls.add(callId);
        }
    }

    private needsPerson(request: OpencodePermissionRequest): boolean {
        if (request.toolName === DOOM_LOOP_PERMISSION) {
            return true;
        }
        if (this.currentPolicy !== 'ask') {
            return false;
        }
        return request.toolName === EXTERNAL_DIRECTORY_PERMISSION
            || !request.toolCallId
            || !this.allowedCalls.has(request.toolCallId);
    }

    handleAsked(request: OpencodePermissionRequest): void {
        if (this.replied.has(request.id)) {
            return;
        }
        if (this.needsPerson(request)) {
            if (request.toolName === EXTERNAL_DIRECTORY_PERMISSION && request.toolCallId) {
                this.directoryAsks.set(request.id, request.toolCallId);
            }
            this.deps.ask(request);
            return;
        }
        if (this.autoApproved.has(request.id)) {
            return;
        }
        this.autoApproved.add(request.id);
        logger.debug(`[OpenCode] Auto-approving ${request.toolName} (${request.id})`);
        this.deps.reply(request.id, 'once').catch((error) => {
            // Leave it to a person rather than leave the agent stuck.
            logger.debug(`[OpenCode] Auto-approve of ${request.id} failed, asking instead:`, error);
            this.autoApproved.delete(request.id);
            this.deps.ask(request);
        });
    }
}
