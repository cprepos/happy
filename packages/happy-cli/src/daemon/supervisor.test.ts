import { describe, expect, it, vi } from 'vitest';
import {
  decideHandoff,
  detectDaemonSupervisor,
  parseDaemonSupervisor,
  restartSupervisedDaemon,
  SUPERVISED_HANDOFF_EXIT_CODE,
} from './supervisor';

describe('daemon supervisor', () => {
  it('parses launchd and systemd supervisors and rejects anything else', () => {
    expect(parseDaemonSupervisor('launchd:com.happy.cli-daemon')).toEqual({ kind: 'launchd', name: 'com.happy.cli-daemon' });
    expect(parseDaemonSupervisor('systemd:happy-cli-daemon.service')).toEqual({ kind: 'systemd', name: 'happy-cli-daemon.service' });
    for (const value of [undefined, '', 'launchd', 'runit:x', 'systemd:a b', 'systemd:$(id)', 'launchd:']) {
      expect(parseDaemonSupervisor(value)).toBeNull();
    }
  });

  it('detects the supervisor from the service definition, then from launchd', () => {
    expect(detectDaemonSupervisor({ HAPPY_DAEMON_SUPERVISOR: 'systemd:happy-cli-daemon.service' }, 'linux')).toBe('systemd:happy-cli-daemon.service');
    expect(detectDaemonSupervisor({ XPC_SERVICE_NAME: 'com.happy.cli-daemon' }, 'darwin')).toBe('launchd:com.happy.cli-daemon');
    expect(detectDaemonSupervisor({ XPC_SERVICE_NAME: 'com.happy.cli-daemon' }, 'linux')).toBeNull();
    expect(detectDaemonSupervisor({ XPC_SERVICE_NAME: 'application.com.apple.Terminal' }, 'darwin')).toBeNull();
    expect(detectDaemonSupervisor({}, 'darwin')).toBeNull();
  });

  it('hands a supervised daemon back to its service manager, and spawns otherwise', () => {
    expect(decideHandoff({ supervisor: 'launchd:com.happy.cli-daemon' })).toEqual({ action: 'exit-for-supervisor', exitCode: SUPERVISED_HANDOFF_EXIT_CODE });
    expect(decideHandoff({ supervisor: 'systemd:happy-cli-daemon.service' })).toEqual({ action: 'exit-for-supervisor', exitCode: 75 });
    expect(decideHandoff({ supervisor: null })).toEqual({ action: 'spawn-replacement', exitCode: 0 });
    expect(decideHandoff({ supervisor: 'bogus' })).toEqual({ action: 'spawn-replacement', exitCode: 0 });
  });

  it('restarts through launchctl or systemctl', () => {
    const execFileSync = vi.fn();
    restartSupervisedDaemon('launchd:com.happy.cli-daemon', { execFileSync, uid: () => 501 });
    expect(execFileSync).toHaveBeenLastCalledWith('launchctl', ['kickstart', '-k', 'gui/501/com.happy.cli-daemon'], expect.any(Object));
    restartSupervisedDaemon('systemd:happy-cli-daemon.service', { execFileSync, uid: () => 1000 });
    expect(execFileSync).toHaveBeenLastCalledWith('systemctl', ['--user', 'restart', 'happy-cli-daemon.service'], expect.any(Object));
    expect(() => restartSupervisedDaemon('bogus', { execFileSync, uid: () => 1 })).toThrow();
  });
});
