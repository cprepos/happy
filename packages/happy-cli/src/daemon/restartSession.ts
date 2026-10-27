/**
 * The daemon's `restart-happy-session`: stop whatever runs a Happy session,
 * whether or not this daemon tracks it and whether or not it responds, and
 * start it again in the same Happy session (same id, same key).
 *
 * The daemon supplies the session lookups and the resume itself
 * (`resumeSessionAttempt` with `HAPPY_RECONNECT_SESSION_ID`); this module owns
 * the order of things, the per-session lock and the result. OpenCode sessions
 * come back as the TUI-style headless owner (`happy opencode --resume <ses>
 * --headless`), the same thing `happy opencode --restart` starts, so the app's
 * questions and permissions keep working and a TUI can attach to it later.
 *
 * Restarts of one session never overlap: a second request while one runs
 * gets the first one's result, and so does one that arrives within a few
 * seconds after it succeeded (a double tap restarts once).
 */

import type { Metadata } from '@/api/types';
import type { ResumeSessionOptions } from '@/api/apiMachine';
import type { SpawnSessionResult } from '@/modules/common/registerCommonHandlers';
import type { PersistedSession } from '@/persistence';
import {
    DEFAULT_STOP_GRACE_MS,
    isRestartableFlavor,
    locateSessionProcesses,
    opencodePolicyFromPermissionMode,
    opencodeRestartPlan,
    stopSessionProcesses,
    type OpencodePermissionPolicyName,
    type ProcessOps,
    type TrackedPid,
} from '@/session/forceRestart';

export type RestartSessionResult =
    | { type: 'success'; sessionId: string; stoppedPids: number[]; newPid: number }
    | { type: 'error'; errorMessage: string };

/** What the resume needs to know beyond `ResumeSessionOptions` after a forced stop. */
export type RestartResumeContext = {
    /** Every process of the session was just verified gone; skip the persisted-pid conflict check. */
    afterForceStop: true;
    /** OpenCode only: the headless owner to launch. */
    opencode?: {
        opencodeSessionId?: string;
        permissionPolicy: OpencodePermissionPolicyName;
        cwd?: string;
    };
};

export type SessionRestarterDeps = {
    /** Metadata the daemon knows for the session: tracked, else the client's fallback, else sessions.json. */
    lookupMetadata: (happySessionId: string, options?: ResumeSessionOptions) => Metadata | undefined;
    trackedPids: (happySessionId: string) => TrackedPid[];
    readPersisted: () => Record<string, PersistedSession>;
    opencodeStateDir: string;
    /** Forget a tracked pid once it is confirmed gone. */
    onStopped: (pid: number) => void;
    resume: (happySessionId: string, options: ResumeSessionOptions | undefined, context: RestartResumeContext) => Promise<SpawnSessionResult>;
    /** The live pid now running the session (after a successful resume). */
    currentPid: (happySessionId: string) => number | undefined;
    ops?: ProcessOps;
    graceMs?: number;
    /** How long a success answers repeated requests; default 5 s. */
    dedupeWindowMs?: number;
    log?: (message: string) => void;
};

export type SessionRestarter = {
    restart: (happySessionId: string, options?: ResumeSessionOptions) => Promise<RestartSessionResult>;
    /** The restart running for this session, if any. */
    inFlight: (happySessionId: string) => Promise<RestartSessionResult> | undefined;
};

export function createSessionRestarter(deps: SessionRestarterDeps): SessionRestarter {
    const log = deps.log ?? (() => { });
    const running = new Map<string, Promise<RestartSessionResult>>();
    const recent = new Map<string, { at: number; result: RestartSessionResult }>();
    const now = () => (deps.ops?.now ?? Date.now)();

    const attempt = async (happySessionId: string, options?: ResumeSessionOptions): Promise<RestartSessionResult> => {
        const metadata = deps.lookupMetadata(happySessionId, options);
        if (!metadata) {
            return { type: 'error', errorMessage: `Session ${happySessionId} is not known on this machine and the request carried no session data, so it cannot be restarted.` };
        }
        const flavor = metadata.flavor ?? 'claude';
        if (!isRestartableFlavor(flavor)) {
            return { type: 'error', errorMessage: `Restarting is not supported for ${flavor} sessions (only Claude, Codex and OpenCode).` };
        }
        const resumeTarget = flavor === 'claude'
            ? metadata.claudeSessionId
            : (flavor === 'codex' ? metadata.codexThreadId : metadata.opencodeSessionId);

        const located = locateSessionProcesses({
            flavor,
            happySessionId,
            resumeTarget,
            tracked: deps.trackedPids(happySessionId),
            persisted: deps.readPersisted(),
            opencodeStateDir: flavor === 'opencode' ? deps.opencodeStateDir : undefined,
            ops: deps.ops,
        });
        if (located.unverified.length > 0) {
            return { type: 'error', errorMessage: `Not restarting session ${happySessionId}: ${located.unverified.map((entry) => entry.reason).join('; ')}.` };
        }
        log(`[RESTART] Session ${happySessionId} (${flavor}): stopping ${located.targets.map((target) => `${target.pid} (${target.source})`).join(', ') || 'nothing (not running)'}`);

        const plan = flavor === 'opencode'
            ? opencodeRestartPlan(located, { happySessionId, opencodeSessionId: metadata.opencodeSessionId })
            : null;

        const stopped = await stopSessionProcesses(located.targets, {
            ops: deps.ops,
            graceMs: deps.graceMs ?? DEFAULT_STOP_GRACE_MS,
            opencodeStateDir: flavor === 'opencode' ? deps.opencodeStateDir : undefined,
            log: (message) => log(`[RESTART] ${message}`),
        });
        for (const pid of stopped.stoppedPids) {
            deps.onStopped(pid);
        }
        if (stopped.survivors.length > 0) {
            return { type: 'error', errorMessage: `Could not stop session ${happySessionId}: pid ${stopped.survivors.join(', ')} still running after SIGKILL. Nothing was started.` };
        }

        const result = await deps.resume(happySessionId, options, {
            afterForceStop: true,
            ...(plan ? {
                opencode: {
                    opencodeSessionId: plan.opencodeSessionId,
                    permissionPolicy: plan.permissionPolicy ?? opencodePolicyFromPermissionMode(options?.permissionMode) ?? 'auto',
                    cwd: plan.cwd,
                },
            } : {}),
        });
        if (result.type === 'requestToApproveDirectoryCreation') {
            return { type: 'error', errorMessage: `The session's directory ${result.directory} no longer exists.` };
        }
        if (result.type === 'error') {
            const what = stopped.stoppedPids.length > 0 ? `Stopped pid ${stopped.stoppedPids.join(', ')}, but starting it again failed` : 'Starting it failed';
            return { type: 'error', errorMessage: `${what}: ${result.errorMessage}` };
        }
        const newPid = deps.currentPid(happySessionId);
        if (newPid === undefined) {
            return { type: 'error', errorMessage: `Session ${happySessionId} was started again but its process is already gone; see the daemon log.` };
        }
        return { type: 'success', sessionId: result.sessionId, stoppedPids: stopped.stoppedPids, newPid };
    };

    return {
        restart: (happySessionId, options) => {
            const inFlight = running.get(happySessionId);
            if (inFlight) {
                return inFlight;
            }
            const last = recent.get(happySessionId);
            if (last && now() - last.at < (deps.dedupeWindowMs ?? 5_000)) {
                return Promise.resolve(last.result);
            }
            recent.delete(happySessionId);
            const promise = attempt(happySessionId, options)
                .catch((error): RestartSessionResult => ({
                    type: 'error',
                    errorMessage: `Failed to restart session: ${error instanceof Error ? error.message : String(error)}`,
                }))
                .then((result) => {
                    running.delete(happySessionId);
                    if (result.type === 'success') {
                        recent.set(happySessionId, { at: now(), result });
                    }
                    return result;
                });
            running.set(happySessionId, promise);
            return promise;
        },
        inFlight: (happySessionId) => running.get(happySessionId),
    };
}
