import type { MessageMeta, PermissionMode } from '@/api/types';

import type { ReasoningEffort } from './codexAppServerTypes';
import { isRemoteCodexPermissionMode } from './executionPolicy';

const VALID_REMOTE_EFFORTS: readonly ReasoningEffort[] = [
    'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra',
];

const DEFAULT_CODEX_EFFORT: ReasoningEffort = 'medium';

type Resolution<T> =
    | { kind: 'updated'; value: T }
    | { kind: 'retained'; value: T }
    | { kind: 'ignored'; incoming: unknown; value: T };

export type CodexRemoteModeResolution = {
    permissionMode: PermissionMode;
    model: string | undefined;
    effort: ReasoningEffort | undefined;
    permission: Resolution<PermissionMode>;
    modelResolution: Resolution<string | undefined>;
    effortResolution: Resolution<ReasoningEffort | undefined>;
};

/**
 * Mutable per-session mode state for remote Codex turns.
 *
 * The launch policy is restored immediately after abort for the approval
 * handler's safety window. Model and effort stay sticky for compatibility
 * with older apps, while current apps reassert all three selected values on
 * every message.
 */
export class CodexRemoteModeState {
    readonly initialPermissionMode: PermissionMode;
    currentPermissionMode: PermissionMode;
    currentPermissionModeExplicitlySet = false;
    currentModel: string | undefined;
    currentEffort: ReasoningEffort | undefined;

    constructor(options: {
        permissionMode: PermissionMode;
        model?: string;
        effort?: ReasoningEffort;
    }) {
        this.initialPermissionMode = options.permissionMode;
        this.currentPermissionMode = options.permissionMode;
        this.currentModel = options.model;
        this.currentEffort = options.effort;
    }

    resolve(meta: MessageMeta | undefined): CodexRemoteModeResolution {
        let permission: Resolution<PermissionMode>;
        if (meta?.permissionMode) {
            if (isRemoteCodexPermissionMode(meta.permissionMode)) {
                this.currentPermissionMode = meta.permissionMode;
                this.currentPermissionModeExplicitlySet = true;
                permission = { kind: 'updated', value: this.currentPermissionMode };
            } else {
                permission = {
                    kind: 'ignored',
                    incoming: meta.permissionMode,
                    value: this.currentPermissionMode,
                };
            }
        } else {
            permission = { kind: 'retained', value: this.currentPermissionMode };
        }

        let modelResolution: Resolution<string | undefined>;
        if (meta !== undefined && Object.prototype.hasOwnProperty.call(meta, 'model')) {
            this.currentModel = meta?.model || undefined;
            modelResolution = { kind: 'updated', value: this.currentModel };
        } else {
            modelResolution = { kind: 'retained', value: this.currentModel };
        }

        let effortResolution: Resolution<ReasoningEffort | undefined>;
        if (meta !== undefined && Object.prototype.hasOwnProperty.call(meta, 'effort')) {
            const incoming = meta?.effort;
            if (incoming === null || incoming === undefined) {
                this.currentEffort = undefined;
                effortResolution = { kind: 'updated', value: undefined };
            } else if ((VALID_REMOTE_EFFORTS as readonly string[]).includes(incoming)) {
                this.currentEffort = incoming as ReasoningEffort;
                effortResolution = { kind: 'updated', value: this.currentEffort };
            } else {
                effortResolution = {
                    kind: 'ignored',
                    incoming,
                    value: this.currentEffort,
                };
            }
        } else {
            effortResolution = { kind: 'retained', value: this.currentEffort };
        }

        return {
            permissionMode: this.currentPermissionMode,
            model: this.currentModel,
            effort: this.currentEffort,
            permission,
            modelResolution,
            effortResolution,
        };
    }

    resetAfterAbort(): void {
        this.currentPermissionMode = this.initialPermissionMode;
        this.currentPermissionModeExplicitlySet = false;
    }
}
/**
 * The mode state a Codex session launches with.
 *
 * There is no default Codex model on purpose. With nothing picked, the model
 * stays undefined, so thread/start carries `model: null` and turn/start no
 * `model` at all, and Codex runs its own default for the signed-in account.
 * A hard-coded name breaks accounts that do not offer it: a ChatGPT plan
 * rejects GPT-6.1 Sol with `modelNotFound`. A picked model, from `--model` or
 * a message's `meta.model`, is still sent exactly as given.
 */
export function createCodexRemoteModeState(options: {
    permissionMode: PermissionMode;
    model?: string;
    effort?: ReasoningEffort;
}): CodexRemoteModeState {
    return new CodexRemoteModeState({
        permissionMode: options.permissionMode,
        model: options.model,
        effort: options.effort ?? DEFAULT_CODEX_EFFORT,
    });
}
