/**
 * The service manager that keeps the daemon running, when there is one.
 *
 * selfhost/cli-service/install-service.sh sets HAPPY_DAEMON_SUPERVISOR in the
 * launchd plist or systemd unit, as `launchd:<label>` or `systemd:<unit>`. The
 * daemon records it in daemon.state.json, so other CLI processes know to ask
 * the service manager for a restart rather than start a daemon of their own
 * beside it (which the service manager would then restart, and the two would
 * keep replacing each other).
 */
import { execFileSync } from 'node:child_process';

export const DAEMON_SUPERVISOR_ENV = 'HAPPY_DAEMON_SUPERVISOR';
export const LAUNCHD_DAEMON_LABEL = 'com.happy.cli-daemon';

export interface DaemonSupervisor {
  kind: 'launchd' | 'systemd';
  name: string;
}

const NAME_PATTERN = /^[A-Za-z0-9_.@-]+$/;

export function parseDaemonSupervisor(value: string | undefined | null): DaemonSupervisor | null {
  if (!value) return null;
  const separator = value.indexOf(':');
  if (separator === -1) return null;
  const kind = value.slice(0, separator);
  const name = value.slice(separator + 1);
  if ((kind !== 'launchd' && kind !== 'systemd') || !NAME_PATTERN.test(name)) return null;
  return { kind, name };
}

export function formatDaemonSupervisor(supervisor: DaemonSupervisor): string {
  return `${supervisor.kind}:${supervisor.name}`;
}

/**
 * The supervisor of this process, as recorded by the service definition. A
 * launchd job installed before the variable existed still has launchd's own
 * XPC_SERVICE_NAME.
 */
export function detectDaemonSupervisor(
  env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
): string | null {
  const declared = parseDaemonSupervisor(env[DAEMON_SUPERVISOR_ENV]);
  if (declared) return formatDaemonSupervisor(declared);
  if (platform === 'darwin' && env.XPC_SERVICE_NAME === LAUNCHD_DAEMON_LABEL) {
    return formatDaemonSupervisor({ kind: 'launchd', name: LAUNCHD_DAEMON_LABEL });
  }
  return null;
}

/** Exit code that tells a service manager to start the daemon again (EX_TEMPFAIL). */
export const SUPERVISED_HANDOFF_EXIT_CODE = 75;

export type HandoffDecision =
  | { action: 'exit-for-supervisor'; exitCode: number }
  | { action: 'spawn-replacement'; exitCode: number };

/**
 * What the daemon does when its bundle is replaced on disk. A supervised
 * daemon exits non-zero and lets the service manager start the new bundle, so
 * the replacement stays under supervision. An unsupervised one starts its own
 * replacement, as before.
 */
export function decideHandoff({ supervisor }: { supervisor: string | null | undefined }): HandoffDecision {
  if (parseDaemonSupervisor(supervisor)) {
    return { action: 'exit-for-supervisor', exitCode: SUPERVISED_HANDOFF_EXIT_CODE };
  }
  return { action: 'spawn-replacement', exitCode: 0 };
}

export interface RestartSupervisedDaemonDeps {
  execFileSync: (file: string, args: string[], options: { stdio: 'ignore'; timeout: number }) => unknown;
  uid: () => number;
}

const defaultRestartDeps: RestartSupervisedDaemonDeps = {
  execFileSync: (file, args, options) => execFileSync(file, args, options),
  uid: () => (typeof process.getuid === 'function' ? process.getuid() : 0),
};

/** The command that restarts the supervised daemon. */
export function supervisorRestartCommand(supervisor: DaemonSupervisor, uid: number): { file: string; args: string[] } {
  if (supervisor.kind === 'launchd') {
    return { file: 'launchctl', args: ['kickstart', '-k', `gui/${uid}/${supervisor.name}`] };
  }
  return { file: 'systemctl', args: ['--user', 'restart', supervisor.name] };
}

/** Ask the service manager to restart the daemon. Throws when it cannot. */
export function restartSupervisedDaemon(supervisorValue: string, deps: RestartSupervisedDaemonDeps = defaultRestartDeps): void {
  const supervisor = parseDaemonSupervisor(supervisorValue);
  if (!supervisor) throw new Error(`Unrecognized daemon supervisor: ${supervisorValue}`);
  const { file, args } = supervisorRestartCommand(supervisor, deps.uid());
  deps.execFileSync(file, args, { stdio: 'ignore', timeout: 30_000 });
}
