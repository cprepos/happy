/**
 * Environment variables that identify one particular Happy or provider
 * session. A daemon can live much longer than the session that created it, so
 * these must never flow from an ambient daemon environment into a new child.
 */
export const SESSION_SCOPED_ENV_KEYS = [
    'HAPPY_RECONNECT_SESSION_ID',
    'HAPPY_RECONNECT_ENCRYPTION_KEY',
    'HAPPY_RECONNECT_ENCRYPTION_VARIANT',
    'HAPPY_RECONNECT_SEQ',
    'HAPPY_RECONNECT_METADATA_VERSION',
    'HAPPY_RECONNECT_AGENT_STATE_VERSION',
    'HAPPY_FORKED_FROM_SESSION_ID',
    'HAPPY_FORKED_FROM_MESSAGE_ID',
    'HAPPY_FORK_CLAUDE_SESSION_ID',
    'HAPPY_FORK_CODEX_THREAD_ID',
    'HAPPY_SIDE_CHAT',
    'CODEX_THREAD_ID',
] as const;

/**
 * Environment variables that belong to the daemon process itself. A session
 * child must never inherit them, or it would believe it is the supervised
 * daemon.
 */
export const DAEMON_SCOPED_ENV_KEYS = [
    'HAPPY_DAEMON_SUPERVISOR',
] as const;

export interface SessionReconnectEnv {
    sessionId: string;
    keyBase64: string;
    variant: 'legacy' | 'dataKey';
    seq: number;
    metadataVersion: number;
    agentStateVersion: number;
}

/**
 * The session-scoped values this process was launched with. Read once at
 * startup, before anything else can spawn a child, so the values cannot leak
 * further down the process tree.
 */
export interface SessionScopedEnvSnapshot {
    reconnect: SessionReconnectEnv | null;
    forkedFromSessionId: string | undefined;
    forkedFromMessageId: string | undefined;
    forkClaudeSessionId: string | undefined;
    forkCodexThreadId: string | undefined;
    sideChat: boolean;
}

function parseIntOrZero(value: string | undefined): number {
    const parsed = parseInt(value || '0', 10);
    return Number.isFinite(parsed) ? parsed : 0;
}

/**
 * Take the session-scoped values out of `env` and return them. Every
 * SESSION_SCOPED_ENV_KEYS entry is deleted from `env`, so any process this one
 * spawns afterwards (agent, tools, a `happy --version` run by the agent) cannot
 * join the session by accident.
 */
export function consumeSessionScopedEnv(env: NodeJS.ProcessEnv = process.env): SessionScopedEnvSnapshot {
    const sessionId = env.HAPPY_RECONNECT_SESSION_ID;
    const keyBase64 = env.HAPPY_RECONNECT_ENCRYPTION_KEY;
    const variantRaw = env.HAPPY_RECONNECT_ENCRYPTION_VARIANT;
    const variant = variantRaw === 'legacy' || variantRaw === 'dataKey' ? variantRaw : undefined;
    const reconnect: SessionReconnectEnv | null = sessionId && keyBase64 && variant
        ? {
            sessionId,
            keyBase64,
            variant,
            seq: parseIntOrZero(env.HAPPY_RECONNECT_SEQ),
            metadataVersion: parseIntOrZero(env.HAPPY_RECONNECT_METADATA_VERSION),
            agentStateVersion: parseIntOrZero(env.HAPPY_RECONNECT_AGENT_STATE_VERSION),
        }
        : null;

    const snapshot: SessionScopedEnvSnapshot = {
        reconnect,
        forkedFromSessionId: env.HAPPY_FORKED_FROM_SESSION_ID || undefined,
        forkedFromMessageId: env.HAPPY_FORKED_FROM_MESSAGE_ID || undefined,
        forkClaudeSessionId: env.HAPPY_FORK_CLAUDE_SESSION_ID || undefined,
        forkCodexThreadId: env.HAPPY_FORK_CODEX_THREAD_ID || undefined,
        sideChat: env.HAPPY_SIDE_CHAT === '1',
    };

    for (const key of SESSION_SCOPED_ENV_KEYS) {
        delete env[key];
    }
    return snapshot;
}

/**
 * Remove session-scoped state inherited from a parent process without
 * modifying the source environment.
 */
export function sanitizeSessionEnvironment<T extends Record<string, string>>(env: T): T;
export function sanitizeSessionEnvironment(env?: NodeJS.ProcessEnv): NodeJS.ProcessEnv;
export function sanitizeSessionEnvironment(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
    const sanitized = { ...env };
    for (const key of SESSION_SCOPED_ENV_KEYS) {
        delete sanitized[key];
    }
    return sanitized;
}

/**
 * Build a child environment from clean ambient values plus explicit values for
 * the session being launched. Explicit values deliberately win so fork and
 * resume requests continue to work.
 */
export function buildSessionChildEnvironment(
    ambientEnv: NodeJS.ProcessEnv = process.env,
    explicitEnv: NodeJS.ProcessEnv = {},
): NodeJS.ProcessEnv {
    const child: NodeJS.ProcessEnv = {
        ...sanitizeSessionEnvironment(ambientEnv),
    };
    for (const key of DAEMON_SCOPED_ENV_KEYS) {
        delete child[key];
    }
    // launchd names the job in XPC_SERVICE_NAME, which detectDaemonSupervisor
    // reads for daemons installed before HAPPY_DAEMON_SUPERVISOR existed.
    if (child.XPC_SERVICE_NAME === 'com.happy.cli-daemon') {
        delete child.XPC_SERVICE_NAME;
    }
    return {
        ...child,
        ...explicitEnv,
    };
}

/**
 * tmux windows inherit their server environment, including keys omitted from
 * `new-window -e`. These are the keys the shell must explicitly unset before
 * starting a child, unless this launch intentionally supplies a replacement.
 */
export function sessionEnvironmentKeysToUnset(explicitEnv: NodeJS.ProcessEnv = {}): string[] {
    return SESSION_SCOPED_ENV_KEYS.filter((key) => explicitEnv[key] === undefined);
}

export function wrapTmuxCommandWithSessionEnvironmentSanitizer(
    command: string,
    explicitEnv: NodeJS.ProcessEnv = {},
): string {
    const keysToUnset = sessionEnvironmentKeysToUnset(explicitEnv);
    if (keysToUnset.length === 0) {
        return command;
    }
    return `unset ${keysToUnset.join(' ')}; ${command}`;
}
