import type { Machine, Session } from '@/sync/storageTypes';
import type { RestartSessionResult } from '@/sync/ops';
import { isMachineOnline } from '@/utils/machineUtils';
import { HappyError } from '@/utils/errors';
import { t } from '@/text';

/**
 * "Restart agent" — the last-resort button for a chat whose agent stopped
 * answering. The daemon on the session's machine kills whatever process
 * drives the chat and starts the agent again into the same Happy session.
 *
 * It is offered whenever the session belongs to a machine, deliberately
 * including while the session still looks online: a wedged agent keeps its
 * keep-alive going, so "online" is exactly the state the user is stuck in.
 */
export function canShowRestartAgent(session: Pick<Session, 'id' | 'metadata'>): boolean {
    return Boolean(session.id && session.metadata?.machineId);
}

export function getRestartMachineName(
    session: Pick<Session, 'metadata'>,
    machine: Machine | null | undefined,
): string {
    return machine?.metadata?.displayName
        || machine?.metadata?.host
        || session.metadata?.host
        || session.metadata?.machineId
        || '';
}

export type RestartPrecheck =
    | { ok: true; machineId: string; machineName: string }
    | { ok: false; message: string };

/**
 * Everything that can be known before asking the machine anything. An
 * offline machine gets its own message instead of an RPC that would only
 * come back as "RPC method not available" — which would then read as an
 * outdated CLI.
 */
export function getRestartPrecheck(
    session: Pick<Session, 'id' | 'metadata'>,
    machine: Machine | null | undefined,
): RestartPrecheck {
    const machineId = session.metadata?.machineId;
    if (!session.id || !machineId) {
        return { ok: false, message: t('sessionInfo.resumeSessionMissingMachine') };
    }
    const machineName = getRestartMachineName(session, machine);
    if (!machine) {
        return { ok: false, message: t('sessionInfo.restartAgentMachineUnknown', { machine: machineName }) };
    }
    if (!isMachineOnline(machine)) {
        return { ok: false, message: t('sessionInfo.restartAgentMachineOffline', { machine: machineName }) };
    }
    return { ok: true, machineId, machineName };
}

/** The daemon's own words, except for a CLI that does not know the RPC. */
export function getRestartErrorMessage(result: Extract<RestartSessionResult, { type: 'error' }>): string {
    if (result.cliTooOld) {
        return t('sessionInfo.restartAgentCliTooOld');
    }
    return result.errorMessage;
}

export interface ConfirmRestartDeps {
    alert: (title: string, message?: string) => void;
    confirm: (
        title: string,
        message?: string,
        options?: { cancelText?: string; confirmText?: string; destructive?: boolean },
    ) => Promise<boolean>;
}

/**
 * The part of the press that happens before anything is running: refuse an
 * offline machine in words, otherwise ask. Resolves true only when the user
 * confirmed and the restart should go ahead.
 */
export async function confirmRestartAgent(
    session: Pick<Session, 'id' | 'metadata'>,
    machine: Machine | null | undefined,
    deps: ConfirmRestartDeps,
): Promise<boolean> {
    const precheck = getRestartPrecheck(session, machine);
    if (!precheck.ok) {
        deps.alert(t('sessionInfo.restartAgent'), precheck.message);
        return false;
    }
    return deps.confirm(
        t('sessionInfo.restartAgentConfirmTitle'),
        t('sessionInfo.restartAgentConfirmMessage', { machine: precheck.machineName }),
        {
            cancelText: t('common.cancel'),
            confirmText: t('sessionInfo.restartAgentConfirmButton'),
            destructive: true,
        },
    );
}

export interface ExecuteRestartDeps {
    restart: (options: { machineId: string; sessionId: string; model?: string; permissionMode?: string }) => Promise<RestartSessionResult>;
    refresh: () => Promise<void>;
    modes?: { model?: string; permissionMode?: string };
}

/**
 * The restart itself, run under useHappyAction (which owns the spinner and
 * shows a thrown HappyError). The machine is checked again: it may have gone
 * offline while the confirmation was open.
 */
export async function executeRestartAgent(
    session: Pick<Session, 'id' | 'metadata'>,
    machine: Machine | null | undefined,
    deps: ExecuteRestartDeps,
): Promise<Extract<RestartSessionResult, { type: 'success' }>> {
    const precheck = getRestartPrecheck(session, machine);
    if (!precheck.ok) {
        throw new HappyError(precheck.message, false);
    }
    const result = await deps.restart({
        machineId: precheck.machineId,
        sessionId: session.id,
        model: deps.modes?.model,
        permissionMode: deps.modes?.permissionMode,
    });
    if (result.type === 'error') {
        throw new HappyError(getRestartErrorMessage(result), false);
    }
    // Same session id, new process: pull the session row so presence and
    // agent state reflect the new process rather than the one that was killed.
    await deps.refresh();
    return result;
}
