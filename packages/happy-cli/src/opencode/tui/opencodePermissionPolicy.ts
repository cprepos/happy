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
 */

import { logger } from '@/ui/logger';
import type { OpencodePermissionReply } from './opencodeEventMapper';
import type { OpencodePermissionRequest } from './opencodePermissionBridge';
import type { OpencodePermissionPolicy } from './opencodeSessionConfig';

export class OpencodePermissionRouter {
    /** Requests auto-approved (or being approved), so a re-listed request is not answered twice. */
    private readonly autoApproved = new Set<string>();

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

    handleAsked(request: OpencodePermissionRequest): void {
        if (this.currentPolicy === 'ask') {
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
